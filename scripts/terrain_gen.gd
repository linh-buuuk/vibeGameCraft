class_name TerrainGen
extends RefCounted
## Pure terrain generator. `generate(key)` depends only on (seed, key) and is
## safe to run on worker threads: after _init the noise objects and tables are
## only read.
##
## Pipeline (per column, then per voxel):
##  1. Climate/shape noises, each remapped to a uniform 0..1 value through a
##     quantile table sampled at start-up (so thresholds mean "x% of the world"
##     instead of guessing the noise distribution):
##       continentalness → ocean / coast / inland base height
##       erosion          → how strong mountains can be (low = rugged)
##       peaks & valleys  → ridged noise that forms the actual ridges
##       temperature, humidity → biome choice (temperature drops with altitude)
##       river            → |noise| near 0 carves winding channels to below sea level
##  2. Height = spline(continentalness) + spline(erosion) * spline(peaks) + detail,
##     then swamps flatten towards the sea and rivers carve. Height never depends
##     on the biome, so biome borders have no seams.
##  3. Biome from (height, temperature, humidity, river, slope) → surface layers.
##  4. Spaghetti caves: two 3D noises sampled on a coarse global lattice (4 blocks)
##     and interpolated; a tunnel is where both are near zero. Caves are never
##     carved in or next to columns holding water, so static water never hangs.
##  5. Ore veins and per-biome trees (kept inside the chunk).

const CS := ChunkMesher.CS
const H := ChunkMesher.H
const SEA := 32
const LAT := 4 # cave lattice spacing (blocks), same in x/y/z
const LAT_N := CS / LAT + 1 # lattice points per chunk side, including the shared edge
const LAT_Y := H / LAT + 1

enum Biome { OCEAN, BEACH, PLAINS, FOREST, BIRCH_FOREST, DESERT, TAIGA, SNOWY_PLAINS, SWAMP, MOUNTAINS, SNOWY_PEAKS, RIVER }

const BIOME_NAMES := ["Ocean", "Beach", "Plains", "Forest", "Birch Forest", "Desert",
	"Taiga", "Snowy Plains", "Swamp", "Mountains", "Snowy Peaks", "River"]
const BIOME_COLORS := [Color("2d5fb8"), Color("e8d79a"), Color("8cc65a"), Color("3f8f3a"), Color("8fbf6a"),
	Color("e2c46c"), Color("2f6b4a"), Color("e9eef4"), Color("5d7a43"), Color("8d8f92"), Color("ffffff"), Color("3f86e0")]

## Tunnel threshold on the interpolated a*a + b*b field. 0.052 ≈ 4th percentile
## → roughly 4% of underground volume becomes tunnels. Bigger = more/wider caves.
const CAVE_THRESHOLD := 0.052

var seed_value: int
var _cont := FastNoiseLite.new()
var _eros := FastNoiseLite.new()
var _pv := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _temp := FastNoiseLite.new()
var _humid := FastNoiseLite.new()
var _river := FastNoiseLite.new()
var _cave_a := FastNoiseLite.new()
var _cave_b := FastNoiseLite.new()

## Quantile tables: sorted raw samples, used to map raw → uniform 0..1.
var _q := {}
var _base_spline := PackedVector2Array(BASE_SPLINE)
var _amp_spline := PackedVector2Array(AMP_SPLINE)
var _peak_spline := PackedVector2Array(PEAK_SPLINE)


func _init(p_seed: int = 1337) -> void:
	seed_value = p_seed
	_setup(_cont, 1, 0.0016, 4)
	_setup(_eros, 2, 0.0022, 3)
	_setup(_pv, 3, 0.0045, 3)
	_pv.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_setup(_detail, 4, 0.035, 2)
	_setup(_temp, 5, 0.0015, 1)
	_setup(_humid, 6, 0.0022, 2)
	_setup(_river, 7, 0.0028, 1)
	_setup(_cave_a, 8, 0.028, 1)
	_setup(_cave_b, 9, 0.028, 1)
	for name in ["cont", "eros", "pv", "temp", "humid"]:
		_q[name] = _build_quantiles(get("_" + name))


func _setup(n: FastNoiseLite, salt: int, freq: float, octaves: int) -> void:
	n.seed = seed_value * 31 + salt
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = octaves
	if octaves <= 1:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE


func _build_quantiles(n: FastNoiseLite) -> PackedFloat32Array:
	# Spread samples far apart so they cover many noise "features".
	var samples := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 99
	for i in 4096:
		samples.append(n.get_noise_2d(rng.randf_range(-40000, 40000), rng.randf_range(-40000, 40000)))
	samples.sort()
	return samples


## Raw noise → approx uniform 0..1 using the sorted sample table.
static func _uniform(table: PackedFloat32Array, v: float) -> float:
	var i := table.bsearch(v)
	if i <= 0:
		return 0.0
	if i >= table.size():
		return 1.0
	var a := table[i - 1]
	var b := table[i]
	var f := 0.0 if b <= a else (v - a) / (b - a)
	return (float(i - 1) + f) / float(table.size() - 1)


## Piecewise-linear spline through (x, y) points sorted by x.
static func _spline(x: float, pts: PackedVector2Array) -> float:
	if x <= pts[0].x:
		return pts[0].y
	for i in range(1, pts.size()):
		if x <= pts[i].x:
			var a := pts[i - 1]
			var b := pts[i]
			return lerpf(a.y, b.y, (x - a.x) / (b.x - a.x))
	return pts[pts.size() - 1].y


const BASE_SPLINE := [Vector2(0.0, 12), Vector2(0.14, 16), Vector2(0.26, 24), Vector2(0.33, 30),
	Vector2(0.37, 33.5), Vector2(0.45, 36), Vector2(0.7, 42), Vector2(1.0, 50)]
const AMP_SPLINE := [Vector2(0.0, 46), Vector2(0.2, 34), Vector2(0.45, 14), Vector2(0.7, 5), Vector2(1.0, 2)]
const PEAK_SPLINE := [Vector2(0.0, 0.0), Vector2(0.4, 0.04), Vector2(0.7, 0.3), Vector2(0.9, 0.78), Vector2(1.0, 1.0)]


## Column sample: [height:int, temperature(altitude adjusted):float, humidity:float,
##                 river_factor:float (0 = river centre, 1 = no river), swampiness:float, continental:float]
func sample(wx: int, wz: int) -> Array:
	var c := _uniform(_q.cont, _cont.get_noise_2d(wx, wz))
	var e := _uniform(_q.eros, _eros.get_noise_2d(wx, wz))
	var pv := _uniform(_q.pv, _pv.get_noise_2d(wx, wz))
	var t := _uniform(_q.temp, _temp.get_noise_2d(wx, wz))
	var hum := _uniform(_q.humid, _humid.get_noise_2d(wx, wz))

	var land := smoothstep(0.36, 0.5, c)
	var h := _spline(c, _base_spline)
	h += _spline(e, _amp_spline) * _spline(pv, _peak_spline) * land
	h += _detail.get_noise_2d(wx, wz) * (1.0 + 2.0 * land)

	# Swamps: humid, temperate lowlands flatten to just above the sea → shallow pools.
	var swamp := smoothstep(0.72, 0.86, hum) * clampf(1.0 - absf(t - 0.5) * 3.0, 0.0, 1.0) * land
	if h < SEA + 12:
		# Target hovers around the waterline → a patchwork of mud pools and hummocks.
		var bumps := _detail.get_noise_2d(wx * 2.3 + 500.0, wz * 2.3) * 2.6
		h = lerpf(h, SEA - 0.6 + bumps, smoothstep(0.15, 0.55, swamp))

	# Rivers: a channel where |noise| ~ 0, carved below sea level, fading out in mountains.
	var river := smoothstep(0.0, 0.085, absf(_river.get_noise_2d(wx, wz)))
	if h > SEA:
		var fade := (1.0 - smoothstep(52.0, 66.0, h)) * smoothstep(0.38, 0.46, c)
		h = lerpf(h, lerpf(SEA - 2.5, h, river), fade)

	var hi := clampi(roundi(h), 3, H - 12)
	var t_eff := t - maxf(0.0, hi - SEA - 14) * 0.012
	return [hi, t_eff, hum, river, swamp, c]


func biome_of(s: Array, slope: int) -> int:
	var h: int = s[0]
	var t: float = s[1]
	var hum: float = s[2]
	if h <= SEA - 1:
		if s[4] > 0.35 and h >= SEA - 3:
			return Biome.SWAMP # shallow swamp pools
		return Biome.RIVER if (s[3] < 0.5 and s[5] > 0.38) else Biome.OCEAN
	if h <= SEA + 2 and s[5] < 0.47 and slope <= 2:
		return Biome.BEACH
	if h >= 74 or (h >= 62 and t < 0.25):
		return Biome.SNOWY_PEAKS
	if h >= 60:
		return Biome.MOUNTAINS
	if t < 0.22:
		return Biome.SNOWY_PLAINS if hum < 0.5 else Biome.TAIGA
	if t > 0.72 and hum < 0.55:
		return Biome.DESERT
	if s[4] > 0.35:
		return Biome.SWAMP
	if hum < 0.35:
		return Biome.PLAINS
	if t < 0.42:
		return Biome.BIRCH_FOREST
	return Biome.FOREST


## Biome at a single world column (for maps, spawn search, HUD).
func biome_at(wx: int, wz: int) -> int:
	var s := sample(wx, wz)
	var slope := 0
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		slope = maxi(slope, absi(int(sample(wx + d.x, wz + d.y)[0]) - int(s[0])))
	return biome_of(s, slope)


# ---------------------------------------------------------------------------
# Chunk generation
# ---------------------------------------------------------------------------

## Returns {"blocks": PackedByteArray (CS*CS*H), "top": highest non-air y}.
func generate(key: Vector2i) -> Dictionary:
	var ox := key.x * CS
	var oz := key.y * CS
	# Column samples with a 1-block margin (for slope + "next to water" checks).
	const M := CS + 2
	var samples: Array = []
	samples.resize(M * M)
	var heights := PackedInt32Array()
	heights.resize(M * M)
	for z in M:
		for x in M:
			var s := sample(ox + x - 1, oz + z - 1)
			samples[x + z * M] = s
			heights[x + z * M] = s[0]

	var b := PackedByteArray()
	b.resize(CS * CS * H)
	var biomes := PackedByteArray()
	biomes.resize(CS * CS)
	var cave := _cave_lattice(key)
	var top := 0
	var detail_rng := RandomNumberGenerator.new()

	for z in CS:
		for x in CS:
			var mi := (x + 1) + (z + 1) * M
			var s: Array = samples[mi]
			var h: int = s[0]
			var nh := [heights[mi + 1], heights[mi - 1], heights[mi + M], heights[mi - M]]
			var slope := 0
			var wet_nb := false
			for v: int in nh:
				slope = maxi(slope, absi(v - h))
				wet_nb = wet_nb or v <= SEA
			var biome := biome_of(s, slope)
			biomes[x + z * CS] = biome
			var t: float = s[1]

			# Surface layers: [top, filler, filler depth, deep filler, deep depth]
			var top_id := Blocks.GRASS
			var fill := Blocks.DIRT
			var depth := 3
			var deep := Blocks.STONE
			var deep_depth := 0
			match biome:
				Biome.OCEAN, Biome.RIVER:
					var floor_n := _detail.get_noise_2d((ox + x) * 3.0, (oz + z) * 3.0)
					top_id = Blocks.GRAVEL if SEA - h > 7 else (Blocks.CLAY if floor_n > 0.45 else Blocks.SAND)
					fill = top_id if top_id != Blocks.CLAY else Blocks.SAND
					depth = 3
				Biome.BEACH:
					top_id = Blocks.GRAVEL if t < 0.22 else Blocks.SAND
					fill = top_id
					depth = 3
					deep = Blocks.SANDSTONE if top_id == Blocks.SAND else Blocks.STONE
					deep_depth = 2
				Biome.DESERT:
					top_id = Blocks.SAND
					fill = Blocks.SAND
					depth = 3
					deep = Blocks.SANDSTONE
					deep_depth = 4
				Biome.SNOWY_PLAINS, Biome.TAIGA:
					top_id = Blocks.SNOW_GRASS
				Biome.SWAMP:
					top_id = Blocks.SWAMP_GRASS if h >= SEA else Blocks.DIRT # muddy pool floor
				Biome.MOUNTAINS:
					top_id = Blocks.GRASS if slope <= 1 else (Blocks.GRAVEL if slope == 2 else Blocks.STONE)
					fill = Blocks.DIRT if slope <= 1 else Blocks.STONE
					depth = 2
				Biome.SNOWY_PEAKS:
					top_id = Blocks.SNOW
					fill = Blocks.SNOW if slope <= 2 else Blocks.STONE
					depth = 1
			# Cliffs are bare rock in every grassy biome.
			if slope >= 4 and (top_id == Blocks.GRASS or top_id == Blocks.SNOW_GRASS or top_id == Blocks.SWAMP_GRASS):
				top_id = Blocks.STONE
				fill = Blocks.STONE

			var col := x + z * CS
			for y in range(0, h + 1):
				var id := Blocks.STONE
				if y == 0:
					id = Blocks.BEDROCK
				elif y == h:
					id = top_id
				elif y >= h - depth:
					id = fill
				elif y >= h - depth - deep_depth:
					id = deep
				b[col + y * CS * CS] = id
			# Water (and ice on cold water) up to sea level.
			for y in range(h + 1, SEA + 1):
				b[col + y * CS * CS] = Blocks.ICE if (y == SEA and t < 0.2 and biome != Biome.RIVER) else Blocks.WATER
			top = maxi(top, maxi(h, SEA if h < SEA else 0))

			# Caves: only in dry columns whose neighbours are dry too.
			if h > SEA + 1 and not wet_nb:
				_carve_column(b, cave, x, z, h)

	_place_ores(key, b)
	top = maxi(top, _place_trees(key, b, heights, biomes, M))
	return {"blocks": b, "top": mini(top, H - 1)}


## Cave field on the global lattice covering this chunk (including shared edges),
## value = a*a + b*b; tunnels where it is below CAVE_THRESHOLD.
func _cave_lattice(key: Vector2i) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(LAT_N * LAT_N * LAT_Y)
	var lx0 := key.x * (CS / LAT)
	var lz0 := key.y * (CS / LAT)
	for ly in LAT_Y:
		for lz in LAT_N:
			for lx in LAT_N:
				var wx := float((lx0 + lx) * LAT)
				var wy := float(ly * LAT) * 1.6 # squash vertically → flatter, longer tunnels
				var wz := float((lz0 + lz) * LAT)
				var a := _cave_a.get_noise_3d(wx, wy, wz)
				var c := _cave_b.get_noise_3d(wx, wy, wz)
				f[lx + lz * LAT_N + ly * LAT_N * LAT_N] = a * a + c * c
	return f


## Point-wise cave field value at a world position (reference for tests).
func cave_value(wx: int, wy: int, wz: int) -> float:
	var key := Vector2i(floori(float(wx) / CS), floori(float(wz) / CS))
	var lat := _cave_lattice(key)
	return _cave_interp(lat, wx - key.x * CS, wy, wz - key.y * CS)


static func _cave_interp(lat: PackedFloat32Array, x: int, y: int, z: int) -> float:
	var fx := float(x) / LAT
	var fy := float(y) / LAT
	var fz := float(z) / LAT
	var ix := mini(int(fx), LAT_N - 2)
	var iy := mini(int(fy), LAT_Y - 2)
	var iz := mini(int(fz), LAT_N - 2)
	var tx := fx - ix
	var ty := fy - iy
	var tz := fz - iz
	var s := LAT_N * LAT_N
	var i := ix + iz * LAT_N + iy * s
	var c00 := lerpf(lat[i], lat[i + 1], tx)
	var c10 := lerpf(lat[i + LAT_N], lat[i + LAT_N + 1], tx)
	var c01 := lerpf(lat[i + s], lat[i + s + 1], tx)
	var c11 := lerpf(lat[i + s + LAT_N], lat[i + s + LAT_N + 1], tx)
	return lerpf(lerpf(c00, c10, tz), lerpf(c01, c11, tz), ty)


func _carve_column(b: PackedByteArray, lat: PackedFloat32Array, x: int, z: int, h: int) -> void:
	# Bilinear in x/z once per lattice level, then linear in y inside each cell.
	var fx := float(x) / LAT
	var fz := float(z) / LAT
	var ix := mini(int(fx), LAT_N - 2)
	var iz := mini(int(fz), LAT_N - 2)
	var tx := fx - ix
	var tz := fz - iz
	var s := LAT_N * LAT_N
	var col := x + z * CS
	var prev := 0.0
	for ly in range(0, mini(h / LAT + 1, LAT_Y - 1) + 1):
		var i := ix + iz * LAT_N + ly * s
		var v := lerpf(lerpf(lat[i], lat[i + 1], tx), lerpf(lat[i + LAT_N], lat[i + LAT_N + 1], tx), tz)
		if ly > 0:
			var y0 := (ly - 1) * LAT
			for k in LAT:
				var y := y0 + k
				if y < 4 or y > h:
					continue
				if lerpf(prev, v, float(k) / LAT) < CAVE_THRESHOLD:
					b[col + y * CS * CS] = Blocks.AIR
		prev = v


func _place_ores(key: Vector2i, b: PackedByteArray) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.x, key.y, seed_value)) ^ 0x5eed
	for vein in 14:
		var iron := vein >= 9
		var size := rng.randi_range(3, 5) if iron else rng.randi_range(5, 9)
		var p := Vector3i(rng.randi_range(1, CS - 2), rng.randi_range(5, 40 if iron else 70), rng.randi_range(1, CS - 2))
		for i in size:
			var idx := p.x + p.z * CS + p.y * CS * CS
			if b[idx] == Blocks.STONE:
				b[idx] = Blocks.IRON_ORE if iron else Blocks.COAL_ORE
			p += [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1)][rng.randi() % 6]
			p = p.clamp(Vector3i(0, 1, 0), Vector3i(CS - 1, H - 1, CS - 1))


# ---------------------------------------------------------------------------
# Trees (kept inside the chunk so generation stays per-chunk)
# ---------------------------------------------------------------------------

## [attempts per chunk, chance per attempt]
const TREE_DENSITY := {
	Biome.PLAINS: [2, 0.35], Biome.FOREST: [9, 0.9], Biome.BIRCH_FOREST: [8, 0.9],
	Biome.TAIGA: [8, 0.85], Biome.SNOWY_PLAINS: [2, 0.35], Biome.SWAMP: [3, 0.7],
	Biome.MOUNTAINS: [2, 0.4], Biome.DESERT: [3, 0.5],
}


func _place_trees(key: Vector2i, b: PackedByteArray, heights: PackedInt32Array, biomes: PackedByteArray, m: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.x, key.y, seed_value))
	var top := 0
	# Use the biome at the chunk centre to pick the attempt count, then each
	# tree checks its own column's biome.
	var centre_biome: int = biomes[8 + 8 * CS]
	var dens: Array = TREE_DENSITY.get(centre_biome, [1, 0.15])
	for i in dens[0]:
		var x := rng.randi_range(2, CS - 3)
		var z := rng.randi_range(2, CS - 3)
		var roll := rng.randf()
		var kind := rng.randf()
		var biome: int = biomes[x + z * CS]
		if not TREE_DENSITY.has(biome) or roll > TREE_DENSITY[biome][1]:
			continue
		var h := heights[(x + 1) + (z + 1) * m]
		var ground := b[x + z * CS + h * CS * CS]
		if h + 1 >= H or b[x + z * CS + (h + 1) * CS * CS] != Blocks.AIR:
			continue
		match biome:
			Biome.DESERT:
				if ground == Blocks.SAND:
					top = maxi(top, _cactus(b, x, z, h, rng))
			Biome.TAIGA, Biome.SNOWY_PLAINS, Biome.MOUNTAINS:
				if ground in [Blocks.SNOW_GRASS, Blocks.GRASS]:
					top = maxi(top, _spruce(b, x, z, h, rng))
			Biome.BIRCH_FOREST:
				if ground == Blocks.GRASS:
					top = maxi(top, _round_tree(b, x, z, h, rng, Blocks.BIRCH_LOG, Blocks.BIRCH_LEAVES, rng.randi_range(5, 7)))
			_:
				if ground in [Blocks.GRASS, Blocks.SWAMP_GRASS]:
					var birch := biome == Biome.FOREST and kind < 0.2
					top = maxi(top, _round_tree(b, x, z, h, rng,
						Blocks.BIRCH_LOG if birch else Blocks.LOG,
						Blocks.BIRCH_LEAVES if birch else Blocks.LEAVES, rng.randi_range(4, 6)))
	return top


static func _put(b: PackedByteArray, x: int, y: int, z: int, id: int, only_air := true) -> void:
	if x < 0 or x >= CS or z < 0 or z >= CS or y < 1 or y >= H:
		return
	var i := x + z * CS + y * CS * CS
	if not only_air or b[i] == Blocks.AIR:
		b[i] = id


static func _round_tree(b: PackedByteArray, x: int, z: int, h: int, rng: RandomNumberGenerator,
		log_id: int, leaf_id: int, trunk: int) -> int:
	for y in range(h + 1, h + 1 + trunk):
		_put(b, x, y, z, log_id, false)
	var top := h + trunk
	for ly in range(top - 1, top + 2):
		var rad := 2 if ly < top + 1 else 1
		for lz in range(-rad, rad + 1):
			for lx in range(-rad, rad + 1):
				if abs(lx) == rad and abs(lz) == rad and rng.randf() < 0.6:
					continue # rounded corners
				_put(b, x + lx, ly, z + lz, leaf_id)
	return mini(top + 1, H - 1)


static func _spruce(b: PackedByteArray, x: int, z: int, h: int, rng: RandomNumberGenerator) -> int:
	var trunk := rng.randi_range(6, 8)
	for y in range(h + 1, h + 1 + trunk):
		_put(b, x, y, z, Blocks.SPRUCE_LOG, false)
	var top := h + trunk
	# Cone: alternating radius 2/1 going down, a tip on top.
	_put(b, x, top + 1, z, Blocks.SPRUCE_LEAVES)
	for ly in range(top, h + 2, -1):
		var k := top - ly
		var rad := 1 if (k < 2 or k % 2 == 1) else 2
		for lz in range(-rad, rad + 1):
			for lx in range(-rad, rad + 1):
				if rad == 2 and abs(lx) == 2 and abs(lz) == 2:
					continue
				_put(b, x + lx, ly, z + lz, Blocks.SPRUCE_LEAVES)
	return mini(top + 1, H - 1)


static func _cactus(b: PackedByteArray, x: int, z: int, h: int, rng: RandomNumberGenerator) -> int:
	var tall := rng.randi_range(2, 4)
	for y in range(h + 1, h + 1 + tall):
		_put(b, x, y, z, Blocks.CACTUS)
	return mini(h + tall, H - 1)
