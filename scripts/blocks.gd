class_name Blocks
## Block registry + procedurally generated texture atlas (no image assets needed).

enum {
	AIR, GRASS, DIRT, STONE, COBBLE, SAND, LOG, LEAVES, PLANKS, BRICK, BEDROCK,
	WATER, SNOW_GRASS, SNOW, SANDSTONE, GRAVEL, CACTUS, SPRUCE_LOG, SPRUCE_LEAVES,
	BIRCH_LOG, BIRCH_LEAVES, COAL_ORE, IRON_ORE, CLAY, SWAMP_GRASS, ICE,
}

const TILE_PX := 16
const ATLAS_TILES := 8 # atlas is ATLAS_TILES x ATLAS_TILES tiles

# Tile indices inside the atlas.
enum Tile {
	GRASS_TOP, GRASS_SIDE, DIRT, STONE, COBBLE, SAND, LOG_SIDE, LOG_TOP, LEAVES, PLANKS, BRICK, BEDROCK,
	WATER, SNOW, SNOW_SIDE, SANDSTONE_SIDE, SANDSTONE_TOP, GRAVEL, CACTUS_SIDE, CACTUS_TOP,
	SPRUCE_SIDE, SPRUCE_LEAVES, BIRCH_SIDE, BIRCH_LEAVES, COAL_ORE, IRON_ORE, CLAY,
	SWAMP_TOP, SWAMP_SIDE, ICE,
}

## Per block: [top tile, side tile, bottom tile, seconds to break (<0 = unbreakable), display name]
const DATA := {
	GRASS: [Tile.GRASS_TOP, Tile.GRASS_SIDE, Tile.DIRT, 0.45, "Grass"],
	DIRT: [Tile.DIRT, Tile.DIRT, Tile.DIRT, 0.4, "Dirt"],
	STONE: [Tile.STONE, Tile.STONE, Tile.STONE, 1.0, "Stone"],
	COBBLE: [Tile.COBBLE, Tile.COBBLE, Tile.COBBLE, 1.1, "Cobblestone"],
	SAND: [Tile.SAND, Tile.SAND, Tile.SAND, 0.35, "Sand"],
	LOG: [Tile.LOG_TOP, Tile.LOG_SIDE, Tile.LOG_TOP, 0.8, "Oak Log"],
	LEAVES: [Tile.LEAVES, Tile.LEAVES, Tile.LEAVES, 0.2, "Leaves"],
	PLANKS: [Tile.PLANKS, Tile.PLANKS, Tile.PLANKS, 0.7, "Planks"],
	BRICK: [Tile.BRICK, Tile.BRICK, Tile.BRICK, 1.2, "Bricks"],
	BEDROCK: [Tile.BEDROCK, Tile.BEDROCK, Tile.BEDROCK, -1.0, "Bedrock"],
	WATER: [Tile.WATER, Tile.WATER, Tile.WATER, -1.0, "Water"],
	SNOW_GRASS: [Tile.SNOW, Tile.SNOW_SIDE, Tile.DIRT, 0.45, "Snowy Grass"],
	SNOW: [Tile.SNOW, Tile.SNOW, Tile.SNOW, 0.3, "Snow"],
	SANDSTONE: [Tile.SANDSTONE_TOP, Tile.SANDSTONE_SIDE, Tile.SANDSTONE_TOP, 0.9, "Sandstone"],
	GRAVEL: [Tile.GRAVEL, Tile.GRAVEL, Tile.GRAVEL, 0.45, "Gravel"],
	CACTUS: [Tile.CACTUS_TOP, Tile.CACTUS_SIDE, Tile.CACTUS_TOP, 0.3, "Cactus"],
	SPRUCE_LOG: [Tile.LOG_TOP, Tile.SPRUCE_SIDE, Tile.LOG_TOP, 0.8, "Spruce Log"],
	SPRUCE_LEAVES: [Tile.SPRUCE_LEAVES, Tile.SPRUCE_LEAVES, Tile.SPRUCE_LEAVES, 0.2, "Spruce Leaves"],
	BIRCH_LOG: [Tile.LOG_TOP, Tile.BIRCH_SIDE, Tile.LOG_TOP, 0.8, "Birch Log"],
	BIRCH_LEAVES: [Tile.BIRCH_LEAVES, Tile.BIRCH_LEAVES, Tile.BIRCH_LEAVES, 0.2, "Birch Leaves"],
	COAL_ORE: [Tile.COAL_ORE, Tile.COAL_ORE, Tile.COAL_ORE, 1.4, "Coal Ore"],
	IRON_ORE: [Tile.IRON_ORE, Tile.IRON_ORE, Tile.IRON_ORE, 1.8, "Iron Ore"],
	CLAY: [Tile.CLAY, Tile.CLAY, Tile.CLAY, 0.4, "Clay"],
	SWAMP_GRASS: [Tile.SWAMP_TOP, Tile.SWAMP_SIDE, Tile.DIRT, 0.45, "Swamp Grass"],
	ICE: [Tile.ICE, Tile.ICE, Tile.ICE, 0.5, "Ice"],
}

## Blocks offered in the hotbar, in order.
const HOTBAR := [GRASS, DIRT, STONE, COBBLE, SAND, LOG, PLANKS, BRICK, LEAVES]


## Hides the faces behind it and darkens corners (mesher).
static func is_opaque(id: int) -> bool:
	return id != AIR and id != WATER


## Blocks the player (physics).
static func is_collidable(id: int) -> bool:
	return id != AIR and id != WATER


## Can be selected by the crosshair (raycast).
static func is_targetable(id: int) -> bool:
	return id != AIR and id != WATER


## Can be replaced by placing a block into it.
static func is_replaceable(id: int) -> bool:
	return id == AIR or id == WATER


## Kept for older call sites: "solid" == collidable.
static func is_solid(id: int) -> bool:
	return is_collidable(id)


## face: 0 = top, 1 = side, 2 = bottom
static func tile_for(id: int, face: int) -> int:
	return DATA[id][face]


static func break_time(id: int) -> float:
	return DATA[id][3] if DATA.has(id) else -1.0


static func display_name(id: int) -> String:
	return DATA[id][4] if DATA.has(id) else ""


## UV rect (in 0..1 atlas space) of a tile.
static func tile_uv_rect(tile: int) -> Rect2:
	var s := 1.0 / ATLAS_TILES
	return Rect2((tile % ATLAS_TILES) * s, (tile / ATLAS_TILES) * s, s, s)


# ---------------------------------------------------------------------------
# Procedural atlas
# ---------------------------------------------------------------------------

static var _atlas: ImageTexture


static func atlas_texture() -> ImageTexture:
	if _atlas == null:
		_atlas = ImageTexture.create_from_image(build_atlas_image())
	return _atlas


static func build_atlas_image() -> Image:
	var size := TILE_PX * ATLAS_TILES
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color.MAGENTA)
	for t in Tile.values():
		_paint_tile(img, t)
	return img


static func _paint_tile(img: Image, tile: int) -> void:
	var ox := (tile % ATLAS_TILES) * TILE_PX
	var oy := (tile / ATLAS_TILES) * TILE_PX
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + tile * 7919
	for y in TILE_PX:
		for x in TILE_PX:
			img.set_pixel(ox + x, oy + y, _tile_pixel(tile, x, y, rng))


static func _jitter(c: Color, rng: RandomNumberGenerator, amount: float) -> Color:
	var k := 1.0 + rng.randf_range(-amount, amount)
	return Color(c.r * k, c.g * k, c.b * k, 1.0)


## Grass-like side: coloured fringe with a jagged lower edge over dirt.
static func _fringe(top: Color, x: int, y: int, rng: RandomNumberGenerator) -> Color:
	var edge := 3 + int(abs(sin(x * 1.7)) * 2.0) + (1 if x % 3 == 0 else 0)
	return _jitter(top if y < edge else Color("8d5f3f"), rng, 0.12)


## Stone with a few clusters of `ore` colour.
static func _ore(ore: Color, x: int, y: int, rng: RandomNumberGenerator) -> Color:
	const SPOTS := [Vector2(4, 4), Vector2(11, 6), Vector2(6, 11), Vector2(12, 12)]
	for s: Vector2 in SPOTS:
		if Vector2(x, y).distance_to(s) < 1.7:
			return _jitter(ore, rng, 0.1)
	return _jitter(Color("8f959e") if rng.randf() > 0.08 else Color("6b7077"), rng, 0.07)


static func _tile_pixel(tile: int, x: int, y: int, rng: RandomNumberGenerator) -> Color:
	const GRASS_C := Color("78c25a")
	const DIRT_C := Color("8d5f3f")
	const STONE_C := Color("8f959e")
	match tile:
		Tile.GRASS_TOP:
			return _jitter(GRASS_C, rng, 0.12)
		Tile.GRASS_SIDE:
			return _fringe(GRASS_C.darkened(0.05), x, y, rng)
		Tile.DIRT:
			return _jitter(DIRT_C, rng, 0.15)
		Tile.STONE:
			var c := STONE_C
			if rng.randf() < 0.08:
				c = c.darkened(0.25)
			return _jitter(c, rng, 0.07)
		Tile.COBBLE:
			# Rounded stones: darker mortar on a skewed grid.
			var cell_x := (x + (y / 5) * 3) % 6
			var mortar := cell_x == 0 or y % 5 == 0
			return _jitter(Color("6d727a") if mortar else Color("a1a7af"), rng, 0.08)
		Tile.SAND:
			return _jitter(Color("ead79c"), rng, 0.06)
		Tile.LOG_SIDE:
			var stripe := 0.9 if (x % 4 == 0) else 1.0
			return _jitter(Color("7b5434") * stripe, rng, 0.06)
		Tile.LOG_TOP:
			var d := Vector2(x - 7.5, y - 7.5).length()
			if d > 6.8:
				return _jitter(Color("7b5434"), rng, 0.06)
			var ring := 0.88 if int(d) % 2 == 0 else 1.0
			return _jitter(Color("c99b62") * ring, rng, 0.04)
		Tile.LEAVES:
			var c := Color("4e9b47")
			if rng.randf() < 0.18:
				c = c.darkened(0.3)
			return _jitter(c, rng, 0.1)
		Tile.PLANKS:
			var seam := y % 4 == 3 or (x == (5 if (y / 4) % 2 == 0 else 12))
			return _jitter(Color("a3703f") if seam else Color("c48e55"), rng, 0.05)
		Tile.BRICK:
			var row := y / 4
			var mortar := y % 4 == 3 or (x + (4 if row % 2 == 0 else 0)) % 8 == 0
			return _jitter(Color("d6cdbf") if mortar else Color("b3533f"), rng, 0.07)
		Tile.BEDROCK:
			return _jitter(Color("3a3c40") if rng.randf() < 0.5 else Color("55585d"), rng, 0.1)
		Tile.WATER:
			var wave := 1.08 if (x + y * 2) % 7 == 0 else 1.0
			return _jitter(Color("3f76e4") * wave, rng, 0.04)
		Tile.SNOW:
			return _jitter(Color("f2f6fb"), rng, 0.03)
		Tile.SNOW_SIDE:
			return _fringe(Color("eef3f8"), x, y, rng)
		Tile.SANDSTONE_SIDE:
			var band := 0.88 if (y % 5 == 4) else (1.04 if y < 3 else 1.0)
			return _jitter(Color("d9c48c") * band, rng, 0.03)
		Tile.SANDSTONE_TOP:
			return _jitter(Color("e3cf98"), rng, 0.04)
		Tile.GRAVEL:
			var shades := [Color("8a8580"), Color("6f6a66"), Color("a39e98"), Color("7d7874")]
			return _jitter(shades[rng.randi() % shades.size()], rng, 0.05)
		Tile.CACTUS_SIDE:
			var c := Color("4f8a2b")
			if x % 4 == 1:
				c = c.darkened(0.2)
			if (x * 7 + y * 3) % 11 == 0:
				c = Color("d8e6b0") # spines
			return _jitter(c, rng, 0.06)
		Tile.CACTUS_TOP:
			var d := Vector2(x - 7.5, y - 7.5).length()
			return _jitter(Color("6aa83b") if d < 5.0 else Color("4f8a2b"), rng, 0.06)
		Tile.SPRUCE_SIDE:
			var stripe := 0.85 if (x % 3 == 0) else 1.0
			return _jitter(Color("4b3420") * stripe, rng, 0.06)
		Tile.SPRUCE_LEAVES:
			var c := Color("2f5d3a")
			if rng.randf() < 0.2:
				c = c.darkened(0.3)
			return _jitter(c, rng, 0.1)
		Tile.BIRCH_SIDE:
			var mark := (y * 5 + (x / 4) * 3) % 9 == 0 and x % 4 != 3
			return _jitter(Color("2b2b2b") if mark else Color("e6e2d6"), rng, 0.04)
		Tile.BIRCH_LEAVES:
			var c := Color("7fb04f")
			if rng.randf() < 0.18:
				c = c.darkened(0.25)
			return _jitter(c, rng, 0.1)
		Tile.COAL_ORE:
			return _ore(Color("26272b"), x, y, rng)
		Tile.IRON_ORE:
			return _ore(Color("d8af93"), x, y, rng)
		Tile.CLAY:
			return _jitter(Color("9aa3b4"), rng, 0.04)
		Tile.SWAMP_TOP:
			return _jitter(Color("5b7a3a"), rng, 0.12)
		Tile.SWAMP_SIDE:
			return _fringe(Color("56733a"), x, y, rng)
		Tile.ICE:
			var streak := (x + y) % 6 == 0
			return _jitter(Color("b9d8f7") if streak else Color("9cc4f2"), rng, 0.03)
	return Color.MAGENTA
