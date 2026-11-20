class_name World
extends Node3D
## Owns chunk data, streaming around the player and background work: both
## terrain generation (TerrainGen) and meshing (ChunkMesher) run on the
## WorkerThreadPool. No physics engine is involved: the player collides
## against the voxel grid directly.

const CS := ChunkMesher.CS
const H := ChunkMesher.H
const P := ChunkMesher.P
const SEA_LEVEL := TerrainGen.SEA

## Chunks meshed in each direction around the player (4 → 9x9 chunks).
@export var view_radius := 4
## Max concurrent generation jobs on worker threads.
@export var max_gen_tasks := 2
## Max concurrent mesh jobs on worker threads.
@export var max_mesh_tasks := 3


class ChunkData:
	var blocks: PackedByteArray
	var top := H - 1 # highest non-air y (upper bound)
	var mesh: MeshInstance3D
	var water_mesh: MeshInstance3D
	var modified := false
	var dirty := true
	var meshing := false


var gen: TerrainGen
var material: ShaderMaterial
var water_material: ShaderMaterial
var chunks := {} # Vector2i -> ChunkData

var _center := Vector2i(1 << 30, 0)
var _gen_queue: Array[Vector2i] = []
var _gen_tasks := {} # task_id -> Vector2i
var _gen_pending := {} # Vector2i -> true while a job runs
var _gen_results := {} # Vector2i -> Dictionary
var _urgent: Array[Vector2i] = [] # chunks to remesh first (player edits)
var _tasks := {} # task_id -> Vector2i
var _results := {} # Vector2i -> Dictionary
var _results_mutex := Mutex.new()

## Rolling timings (ms) of worker jobs, for on-device profiling.
var stats := {"gen_ms": 0.0, "gen_n": 0, "mesh_ms": 0.0, "mesh_n": 0}


func _init(seed_value: int = 1337) -> void:
	gen = TerrainGen.new(seed_value)

	material = ShaderMaterial.new()
	material.shader = preload("res://shaders/voxel.gdshader")
	material.set_shader_parameter("atlas", Blocks.atlas_texture())
	water_material = ShaderMaterial.new()
	water_material.shader = preload("res://shaders/water.gdshader")
	water_material.set_shader_parameter("atlas", Blocks.atlas_texture())
	water_material.render_priority = 1
	set_fog_distance(view_radius)


func set_fog_distance(radius_chunks: int) -> void:
	var far := float(radius_chunks * CS)
	for m in [material, water_material]:
		m.set_shader_parameter("fog_start", far * 0.45)
		m.set_shader_parameter("fog_end", far - 2.0)


func set_fog_color(c: Color) -> void:
	material.set_shader_parameter("fog_color", c)
	water_material.set_shader_parameter("fog_color", c)


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------

static func chunk_key(world_pos: Vector3) -> Vector2i:
	return Vector2i(floori(world_pos.x / CS), floori(world_pos.z / CS))


## Synchronous generation (tests, tools). Same result as the worker path.
func generate_chunk(key: Vector2i) -> PackedByteArray:
	return gen.generate(key).blocks


## Call every frame with the player's position.
func update_streaming(focus: Vector3) -> void:
	var c := chunk_key(focus)
	if c != _center:
		_center = c
		_rebuild_gen_queue()
		_unload_far()

	_collect_gen_results()
	_schedule_generation()
	_collect_mesh_results()
	_schedule_meshing()


func _in_range(key: Vector2i, r: int) -> bool:
	var d := (key - _center).abs()
	return maxi(d.x, d.y) <= r


func _rebuild_gen_queue() -> void:
	_gen_queue.clear()
	var r := view_radius + 1 # one extra ring so borders/AO have neighbour data
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var key := _center + Vector2i(dx, dz)
			if not chunks.has(key) and not _gen_pending.has(key):
				_gen_queue.append(key)
	_gen_queue.sort_custom(func(a, b): return (a - _center).length_squared() < (b - _center).length_squared())


func _schedule_generation() -> void:
	while _gen_tasks.size() < max_gen_tasks and not _gen_queue.is_empty():
		var key: Vector2i = _gen_queue.pop_front()
		if chunks.has(key) or _gen_pending.has(key):
			continue
		_gen_pending[key] = true
		var id := WorkerThreadPool.add_task(_gen_job.bind(key), false, "chunk gen")
		_gen_tasks[id] = key


## Runs on a worker thread.
func _gen_job(key: Vector2i) -> void:
	var t0 := Time.get_ticks_usec()
	var result := gen.generate(key)
	result["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	_results_mutex.lock()
	_gen_results[key] = result
	_results_mutex.unlock()


func _collect_gen_results() -> void:
	for id: int in _gen_tasks.keys():
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		var key: Vector2i = _gen_tasks[id]
		_gen_tasks.erase(id)
		_gen_pending.erase(key)
		_results_mutex.lock()
		var result: Dictionary = _gen_results.get(key, {})
		_gen_results.erase(key)
		_results_mutex.unlock()
		_add_stat("gen", result.get("ms", 0.0))
		# The player may have moved on while this ran: drop chunks now out of range.
		if result.is_empty() or chunks.has(key) or not _in_range(key, view_radius + 2):
			continue
		var cd := ChunkData.new()
		cd.blocks = result.blocks
		cd.top = result.top
		chunks[key] = cd


func _add_stat(kind: String, ms: float) -> void:
	var n: int = stats[kind + "_n"]
	stats[kind + "_ms"] = (stats[kind + "_ms"] * n + ms) / (n + 1)
	stats[kind + "_n"] = mini(n + 1, 200) # rolling-ish average


func _unload_far() -> void:
	var limit := view_radius + 2
	for key: Vector2i in chunks.keys():
		if _in_range(key, limit):
			continue
		var cd: ChunkData = chunks[key]
		if cd.meshing:
			continue
		_free_meshes(cd)
		if cd.modified:
			cd.dirty = true # keep player edits in memory, drop the mesh only
		else:
			chunks.erase(key)


func _free_meshes(cd: ChunkData) -> void:
	if cd.mesh:
		cd.mesh.queue_free()
		cd.mesh = null
	if cd.water_mesh:
		cd.water_mesh.queue_free()
		cd.water_mesh = null


func is_area_ready(focus: Vector3, radius: int) -> bool:
	var c := chunk_key(focus)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cd: ChunkData = chunks.get(c + Vector2i(dx, dz))
			if cd == null or cd.dirty or cd.meshing:
				return false
	return true


# ---------------------------------------------------------------------------
# Block access
# ---------------------------------------------------------------------------

## Returns AIR for chunks that are not generated yet (use is_collidable_at for physics).
func get_block(p: Vector3i) -> int:
	if p.y < 0:
		return Blocks.BEDROCK
	if p.y >= H:
		return Blocks.AIR
	var key := Vector2i(floori(float(p.x) / CS), floori(float(p.z) / CS))
	var cd: ChunkData = chunks.get(key)
	if cd == null:
		return Blocks.AIR
	return cd.blocks[(p.x - key.x * CS) + (p.z - key.y * CS) * CS + p.y * CS * CS]


## Physics query. Ungenerated chunks count as solid so a player who outruns
## generation is stopped instead of falling through the world.
func is_collidable_at(p: Vector3i) -> bool:
	if p.y < 0:
		return true
	if p.y >= H:
		return false
	var key := Vector2i(floori(float(p.x) / CS), floori(float(p.z) / CS))
	var cd: ChunkData = chunks.get(key)
	if cd == null:
		return true
	return Blocks.is_collidable(cd.blocks[(p.x - key.x * CS) + (p.z - key.y * CS) * CS + p.y * CS * CS])


## Kept for older call sites.
func is_solid_at(p: Vector3i) -> bool:
	return is_collidable_at(p)


func set_block(p: Vector3i, id: int) -> bool:
	if p.y < 0 or p.y >= H:
		return false
	var key := Vector2i(floori(float(p.x) / CS), floori(float(p.z) / CS))
	var cd: ChunkData = chunks.get(key)
	if cd == null:
		return false
	var lx := p.x - key.x * CS
	var lz := p.z - key.y * CS
	cd.blocks[lx + lz * CS + p.y * CS * CS] = id
	if id != Blocks.AIR:
		cd.top = maxi(cd.top, p.y)
	cd.modified = true
	# Remesh this chunk and every neighbour whose padded border contains p.
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var nlx := lx - dx * CS
			var nlz := lz - dz * CS
			if nlx < -1 or nlx > CS or nlz < -1 or nlz > CS:
				continue
			var nk := key + Vector2i(dx, dz)
			var ncd: ChunkData = chunks.get(nk)
			if ncd:
				ncd.dirty = true
				if not _urgent.has(nk):
					_urgent.append(nk)
	return true


## Highest collidable block (ignores water).
func surface_height(wx: int, wz: int) -> int:
	for y in range(H - 1, -1, -1):
		if Blocks.is_collidable(get_block(Vector3i(wx, y, wz))):
			return y
	return 0


## Voxel DDA raycast through non-targetable blocks (air, water).
## Returns {} or {"pos": Vector3i, "normal": Vector3i, "id": int}.
func raycast(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	dir = dir.normalized()
	var pos := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	var step := Vector3i(int(signf(dir.x)), int(signf(dir.y)), int(signf(dir.z)))
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for a in 3:
		if dir[a] == 0.0:
			t_max[a] = INF
			t_delta[a] = INF
		else:
			var boundary := float(pos[a] + (1 if step[a] > 0 else 0))
			t_max[a] = (boundary - origin[a]) / dir[a]
			t_delta[a] = absf(1.0 / dir[a])
	var normal := Vector3i.ZERO
	var t := 0.0
	while t <= max_dist:
		var id := get_block(pos)
		if Blocks.is_targetable(id):
			return {"pos": pos, "normal": normal, "id": id}
		var a := 0
		if t_max.y < t_max[a]:
			a = 1
		if t_max.z < t_max[a]:
			a = 2
		t = t_max[a]
		t_max[a] += t_delta[a]
		pos[a] += step[a]
		normal = Vector3i.ZERO
		normal[a] = -step[a]
	return {}


# ---------------------------------------------------------------------------
# Meshing (worker threads)
# ---------------------------------------------------------------------------

func _neighbors_ready(key: Vector2i) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not chunks.has(key + Vector2i(dx, dz)):
				return false
	return true


func _schedule_meshing() -> void:
	if _tasks.size() >= max_mesh_tasks:
		return
	var urgent := _urgent.duplicate()
	_urgent.clear()
	var normal: Array[Vector2i] = []
	for key: Vector2i in chunks:
		if not _in_range(key, view_radius):
			continue
		var cd: ChunkData = chunks[key]
		if cd.dirty and not cd.meshing and not urgent.has(key):
			normal.append(key)
	normal.sort_custom(func(a, b): return (a - _center).length_squared() < (b - _center).length_squared())

	for key: Vector2i in urgent + normal:
		var cd: ChunkData = chunks.get(key)
		if cd == null or cd.meshing or not cd.dirty:
			continue
		if _tasks.size() >= max_mesh_tasks or not _neighbors_ready(key):
			if urgent.has(key) and not _urgent.has(key):
				_urgent.append(key) # keep edit priority for next frame
			continue
		var parts: Array[PackedByteArray] = []
		var top := 0
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var ncd: ChunkData = chunks[key + Vector2i(dx, dz)]
				parts.append(ncd.blocks)
				top = maxi(top, ncd.top)
		cd.dirty = false
		cd.meshing = true
		var id := WorkerThreadPool.add_task(_mesh_job.bind(key, parts, top), false, "chunk mesh")
		_tasks[id] = key


## Runs on a worker thread. `parts` are copy-on-write snapshots, safe to read.
func _mesh_job(key: Vector2i, parts: Array[PackedByteArray], top: int) -> void:
	var t0 := Time.get_ticks_usec()
	var result := ChunkMesher.build(build_padded(parts, top), top)
	result["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	_results_mutex.lock()
	_results[key] = result
	_results_mutex.unlock()


## parts: 3x3 neighbourhood row-major by (dz, dx), centre at index 4.
## Only rows up to `top` are copied (everything above is air).
static func build_padded(parts: Array[PackedByteArray], top: int = H - 1) -> PackedByteArray:
	var out := PackedByteArray()
	var plane := CS * CS
	for y in range(0, mini(top, H - 1) + 1):
		var yo := y * plane
		for pz in P:
			var lz := pz - 1
			var cz := 0 if lz < 0 else (2 if lz >= CS else 1)
			var row := (lz - (cz - 1) * CS) * CS + yo
			out.append(parts[cz * 3][row + CS - 1]) # x = -1 from the west chunk
			out.append_array(parts[cz * 3 + 1].slice(row, row + CS))
			out.append(parts[cz * 3 + 2][row]) # x = CS from the east chunk
	out.resize(P * P * H) # zero-filled (air) above `top`
	return out


func _collect_mesh_results() -> void:
	for id: int in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		var key: Vector2i = _tasks[id]
		_tasks.erase(id)
		_results_mutex.lock()
		var result: Dictionary = _results.get(key, {})
		_results.erase(key)
		_results_mutex.unlock()
		_add_stat("mesh", result.get("ms", 0.0))
		var cd: ChunkData = chunks.get(key)
		if cd == null:
			continue
		cd.meshing = false
		_apply_mesh(key, cd, result)


func _apply_mesh(key: Vector2i, cd: ChunkData, result: Dictionary) -> void:
	cd.mesh = _set_surface(cd.mesh, key, result.get("opaque", {}), material)
	cd.water_mesh = _set_surface(cd.water_mesh, key, result.get("water", {}), water_material)


func _set_surface(mi: MeshInstance3D, key: Vector2i, arrays_in: Dictionary, mat: Material) -> MeshInstance3D:
	if arrays_in.is_empty():
		if mi:
			mi.mesh = null
		return mi
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = arrays_in.vertices
	arrays[Mesh.ARRAY_TEX_UV] = arrays_in.uvs
	arrays[Mesh.ARRAY_COLOR] = arrays_in.colors
	arrays[Mesh.ARRAY_INDEX] = arrays_in.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(key.x * CS, 0, key.y * CS)
		add_child(mi)
	mi.mesh = mesh
	return mi


func _exit_tree() -> void:
	for id: int in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	for id: int in _gen_tasks.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()
	_gen_tasks.clear()
