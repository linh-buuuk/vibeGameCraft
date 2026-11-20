extends SceneTree
## Headless test runner:
##   godot --headless --path . -s res://tests/run_tests.gd

var _failures := 0
var _count := 0


func _initialize() -> void:
	_test_face_winding()
	_test_single_block_mesh()
	_test_adjacent_blocks_cull()
	_test_vertex_ao()
	_test_build_padded()
	_test_raycast()
	_test_set_block_marks_neighbours()
	_test_player_lands_on_floor()
	_test_player_blocked_by_wall_and_auto_jumps()
	_test_touch_multi_finger()
	_test_atlas()
	_test_edit_remesh_end_to_end()
	_test_padded_top_limit()
	_test_water_mesh()
	_test_ungenerated_is_collidable()
	_test_player_swims()
	_test_place_into_water()
	_test_gen_deterministic_threaded()
	_test_cave_lattice_shared_edges()
	_test_water_never_hangs()
	_test_biome_variety()
	_test_swim_out_onto_shore()
	_test_generate_top_bound()
	_test_swamp_has_pools()
	_report_timings()
	print("\n%d checks, %d failed" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_count += 1
	if not cond:
		_failures += 1
		print("FAIL: ", msg)


# --- helpers ----------------------------------------------------------------

func _empty_padded() -> PackedByteArray:
	var d := PackedByteArray()
	d.resize(ChunkMesher.P * ChunkMesher.P * ChunkMesher.H)
	return d


func _flat_world(floor_y: int) -> World:
	var w := World.new()
	for cz in range(-1, 2):
		for cx in range(-1, 2):
			var cd := World.ChunkData.new()
			cd.blocks = PackedByteArray()
			cd.blocks.resize(World.CS * World.CS * World.H)
			for z in World.CS:
				for x in World.CS:
					for y in range(0, floor_y + 1):
						cd.blocks[x + z * World.CS + y * World.CS * World.CS] = Blocks.STONE
			cd.dirty = false
			w.chunks[Vector2i(cx, cz)] = cd
	return w


# --- mesher -----------------------------------------------------------------

func _test_face_winding() -> void:
	for f in 6:
		var c: Array = ChunkMesher.FACE_CORNERS[f]
		var a := Vector3(c[1] - c[0])
		var b := Vector3(c[2] - c[0])
		var n := Vector3(ChunkMesher.FACE_NORMALS[f])
		# Godot front faces are clockwise => cross product points away from the normal.
		check(a.cross(b).dot(n) < 0.0, "face %d winding must be clockwise from outside" % f)


func _test_single_block_mesh() -> void:
	var d := _empty_padded()
	d[ChunkMesher.index(5, 10, 5)] = Blocks.STONE
	var r: Dictionary = ChunkMesher.build(d).opaque
	check(r.vertices.size() == 24, "single block → 24 verts, got %d" % r.vertices.size())
	check(r.indices.size() == 36, "single block → 36 indices")
	check(ChunkMesher.build(_empty_padded()).is_empty(), "empty chunk → empty result")


func _test_adjacent_blocks_cull() -> void:
	var d := _empty_padded()
	d[ChunkMesher.index(5, 10, 5)] = Blocks.STONE
	d[ChunkMesher.index(6, 10, 5)] = Blocks.STONE
	var r: Dictionary = ChunkMesher.build(d).opaque
	check(r.vertices.size() == 40, "two blocks → 10 faces, got %d verts" % r.vertices.size())


func _test_vertex_ao() -> void:
	# Floor at y=10 with a wall block standing on it: floor top face next to
	# the wall must get darker vertices on the wall side.
	var d := _empty_padded()
	for z in range(1, 17):
		for x in range(1, 17):
			d[ChunkMesher.index(x, 10, z)] = Blocks.STONE
	d[ChunkMesher.index(6, 11, 5)] = Blocks.STONE
	var r: Dictionary = ChunkMesher.build(d).opaque
	var dark := 0
	for i in r.vertices.size():
		var v: Vector3 = r.vertices[i]
		if is_equal_approx(v.y, 11.0) and v.x >= 4.0 and v.x <= 5.0 and v.z >= 4.0 and v.z <= 5.0:
			if r.colors[i].r < 0.99:
				dark += 1
	check(dark > 0, "floor vertices touching the wall should be occluded")
	# Cave light: bottom face of an overhang should be darker than open top.
	check(r.colors.size() == r.vertices.size(), "one colour per vertex")


func _test_build_padded() -> void:
	var parts: Array[PackedByteArray] = []
	for i in 9:
		var b := PackedByteArray()
		b.resize(World.CS * World.CS * World.H)
		b.fill(i + 1)
		parts.append(b)
	var p := World.build_padded(parts)
	check(p[ChunkMesher.index(0, 3, 0)] == 1, "padded (-1,-1) corner comes from NW chunk")
	check(p[ChunkMesher.index(17, 3, 17)] == 9, "padded (16,16) corner comes from SE chunk")
	check(p[ChunkMesher.index(8, 3, 8)] == 5, "padded interior comes from centre chunk")
	check(p[ChunkMesher.index(17, 3, 8)] == 6, "padded +x border comes from east chunk")
	check(p[ChunkMesher.index(8, 3, 0)] == 2, "padded -z border comes from north chunk")


# --- world ------------------------------------------------------------------

func _test_raycast() -> void:
	var w := _flat_world(10)
	var hit := w.raycast(Vector3(3.5, 14.5, 3.5), Vector3.DOWN, 6.0)
	check(not hit.is_empty() and hit.pos == Vector3i(3, 10, 3), "raycast down hits floor block")
	check(not hit.is_empty() and hit.normal == Vector3i.UP, "raycast normal points up")
	var miss := w.raycast(Vector3(3.5, 14.5, 3.5), Vector3.UP, 6.0)
	check(miss.is_empty(), "raycast up hits nothing")
	var diag := w.raycast(Vector3(-0.5, 12.5, -0.5), Vector3(1, -1, 1), 8.0)
	check(not diag.is_empty() and diag.pos.y == 10, "diagonal ray across chunk border hits floor")
	w.free()


func _test_set_block_marks_neighbours() -> void:
	var w := _flat_world(10)
	w.set_block(Vector3i(0, 11, 5), Blocks.DIRT) # x=0 edge of chunk (0,0)
	check(w.get_block(Vector3i(0, 11, 5)) == Blocks.DIRT, "set_block writes")
	check(w.chunks[Vector2i(0, 0)].dirty, "own chunk dirty")
	check(w.chunks[Vector2i(-1, 0)].dirty, "west neighbour dirty for edge edit")
	check(not w.chunks[Vector2i(1, 0)].dirty, "east neighbour untouched")
	w.free()


# --- player -----------------------------------------------------------------

func _test_player_lands_on_floor() -> void:
	var w := _flat_world(10)
	var p := Player.new()
	p.world = w
	p.position = Vector3(5.5, 16.0, 5.5)
	for i in 120:
		p.physics_step(1.0 / 60.0, Vector2.ZERO, false)
	check(absf(p.position.y - 11.0) < 0.01, "player rests on floor top (y=%.3f)" % p.position.y)
	check(p.on_floor, "player on_floor")
	p.free()
	w.free()


func _test_player_blocked_by_wall_and_auto_jumps() -> void:
	var w := _flat_world(10)
	# 2-high wall at x=8 → must block. 1-high step at z=... handled separately.
	for z in range(0, 16):
		w.set_block(Vector3i(8, 11, z), Blocks.STONE)
		w.set_block(Vector3i(8, 12, z), Blocks.STONE)
	var p := Player.new()
	p.world = w
	p.position = Vector3(5.5, 11.0, 5.5)
	p.yaw = deg_to_rad(-90.0) # facing +x
	for i in 120:
		p.physics_step(1.0 / 60.0, Vector2(0, -1), false)
	check(p.position.x <= 8.0 - Player.HALF_W + 0.01, "2-high wall blocks player (x=%.3f)" % p.position.x)

	# Now a 1-high step: walking forward should auto-jump onto it.
	var w2 := _flat_world(10)
	for z in range(0, 16):
		for x in range(8, 16):
			w2.set_block(Vector3i(x, 11, z), Blocks.STONE)
	p.world = w2
	p.position = Vector3(5.5, 11.0, 5.5)
	p.velocity = Vector3.ZERO
	for i in 120:
		p.physics_step(1.0 / 60.0, Vector2(0, -1), false)
	check(p.position.x > 8.5 and absf(p.position.y - 12.0) < 0.05,
		"auto-jump climbs 1-block step (pos=%s)" % p.position)
	p.free()
	w.free()
	w2.free()


# --- touch ------------------------------------------------------------------

func _touch(t: TouchControls, idx: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = idx
	e.position = pos
	e.pressed = pressed
	t._input(e)


func _drag(t: TouchControls, idx: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = idx
	e.position = pos
	e.relative = rel
	t._input(e)


func _test_touch_multi_finger() -> void:
	var t := TouchControls.new()
	root.add_child(t)
	t.size = Vector2(1280, 720)
	t._layout()
	t.blocked_rects = [Rect2(350, 640, 580, 70)]

	_touch(t, 0, Vector2(200, 500), true) # left thumb → joystick
	_touch(t, 1, Vector2(800, 300), true) # right thumb → look
	_drag(t, 0, Vector2(200, 420), Vector2(0, -80))
	_drag(t, 1, Vector2(830, 300), Vector2(30, 0))
	check(t.move_vector.y < -0.9, "joystick up → move forward (%s)" % t.move_vector)
	check(t.consume_look_delta() == Vector2(30, 0), "look drag accumulates")
	check(t.move_vector.y < -0.9, "look drag does not disturb joystick")

	_touch(t, 0, Vector2(200, 420), false)
	check(t.move_vector == Vector2.ZERO, "releasing joystick finger stops movement")
	_drag(t, 1, Vector2(840, 300), Vector2(10, 0))
	check(t.consume_look_delta() == Vector2(10, 0), "look finger still tracked after joystick release")

	var jump_c: Vector2 = t._buttons.jump.center
	_touch(t, 2, jump_c, true)
	check(t.jump_held, "jump button held")
	_touch(t, 2, jump_c, false)
	check(not t.jump_held, "jump button released")

	_touch(t, 3, t._buttons.place.center, true)
	check(t.consume_place() and not t.consume_place(), "place tap fires exactly once")

	_touch(t, 4, Vector2(600, 680), true) # on hotbar
	_drag(t, 4, Vector2(620, 680), Vector2(20, 0))
	check(t.consume_look_delta() == Vector2(10, 0) * 0, "hotbar touch is not used for look")
	t.queue_free()


func _pump(w: World, focus: Vector3, until: Callable, max_ms := 20000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		w.update_streaming(focus)
		if until.call():
			return true
		OS.delay_msec(2)
	return false


func _vertex_count(w: World, key: Vector2i) -> int:
	var cd: World.ChunkData = w.chunks.get(key)
	if cd == null or cd.mesh == null or cd.mesh.mesh == null:
		return 0
	return cd.mesh.mesh.surface_get_array_len(0)


func _test_edit_remesh_end_to_end() -> void:
	var w := World.new()
	w.view_radius = 1
	root.add_child(w)
	var focus := Vector3(8, 30, 8)
	var ready := _pump(w, focus, func(): return w.is_area_ready(focus, 1))
	check(ready, "world streams and meshes the area around the player")
	var key := Vector2i(0, 0)
	var before := _vertex_count(w, key)
	check(before > 0, "centre chunk has a mesh")

	# Break the surface block at (8, h, 8): the mesh must change via the worker path.
	# (Vertex count can stay equal — e.g. removing a canopy leaf hides 3 faces and
	# exposes 3 — so compare the vertex data itself.)
	var verts_before: PackedVector3Array = w.chunks[key].mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var h := w.surface_height(8, 8)
	w.set_block(Vector3i(8, h, 8), Blocks.AIR)
	var changed := _pump(w, focus, func():
		if not w.is_area_ready(focus, 1):
			return false
		return w.chunks[key].mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] != verts_before, 5000)
	check(changed, "breaking a block remeshes the chunk")

	# Place a block floating in the air: +6 faces = +24 vertices.
	var mid := _vertex_count(w, key)
	w.set_block(Vector3i(5, World.H - 2, 5), Blocks.BRICK) # near the ceiling: also exercises `top` tracking
	_pump(w, focus, func(): return w.is_area_ready(focus, 1) and _vertex_count(w, key) != mid, 5000)
	check(_vertex_count(w, key) == mid + 24, "placing a floating block adds 24 verts (%d → %d)" % [mid, _vertex_count(w, key)])
	w.queue_free()


func _report_timings() -> void:
	var w := World.new()
	var t0 := Time.get_ticks_usec()
	for i in 8:
		w.generate_chunk(Vector2i(i, 3))
	var gen_ms := (Time.get_ticks_usec() - t0) / 8000.0
	var parts: Array[PackedByteArray] = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			parts.append(w.generate_chunk(Vector2i(dx, dz)))
	t0 = Time.get_ticks_usec()
	var r: Dictionary = ChunkMesher.build(World.build_padded(parts)).opaque
	var mesh_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("TIMING generate_chunk %.2f ms (main thread) | pad+mesh %.2f ms (worker), %d verts" % [gen_ms, mesh_ms, r.vertices.size()])
	w.free()


func _test_atlas() -> void:
	var img := Blocks.build_atlas_image()
	check(img.get_width() == Blocks.TILE_PX * Blocks.ATLAS_TILES, "atlas size")
	var magenta := 0
	for t in Blocks.Tile.values():
		var r := Blocks.tile_uv_rect(t)
		var px := Vector2i(r.position * img.get_width()) + Vector2i(8, 8)
		if img.get_pixelv(px).is_equal_approx(Color.MAGENTA):
			magenta += 1
	check(magenta == 0, "every tile is painted")


# --- world generation ---------------------------------------------------------

func _test_padded_top_limit() -> void:
	var w := World.new()
	var parts: Array[PackedByteArray] = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			parts.append(w.generate_chunk(Vector2i(dx + 3, dz + 5)))
	var full := World.build_padded(parts)
	var top := 0
	for i in 9:
		for y in range(World.H - 1, -1, -1):
			var any := false
			for j in World.CS * World.CS:
				if parts[i][j + y * World.CS * World.CS] != 0:
					any = true
					break
			if any:
				top = maxi(top, y)
				break
	check(World.build_padded(parts, top) == full, "padding limited to `top` equals full padding")
	w.free()


func _test_water_mesh() -> void:
	var d := _empty_padded()
	d[ChunkMesher.index(5, 10, 5)] = Blocks.WATER
	var r := ChunkMesher.build(d)
	check(r.opaque.is_empty() and r.water.vertices.size() == 24, "lone water block → 6 water faces only")
	var surface_y: float = r.water.vertices[0].y
	for v: Vector3 in r.water.vertices:
		if v.y > 10.5:
			surface_y = v.y
	check(is_equal_approx(surface_y, 11.0 - ChunkMesher.WATER_DROP), "water surface is lowered")

	# Stone under water: stone keeps all 6 faces (water is not opaque),
	# water emits no face towards the stone, and stone corners are not darkened by water.
	d = _empty_padded()
	d[ChunkMesher.index(5, 10, 5)] = Blocks.STONE
	d[ChunkMesher.index(5, 11, 5)] = Blocks.WATER
	d[ChunkMesher.index(6, 10, 5)] = Blocks.WATER
	r = ChunkMesher.build(d)
	check(r.opaque.vertices.size() == 24, "stone next to water keeps 6 faces")
	check(r.water.vertices.size() == 2 * 5 * 4, "each water block skips the face touching stone and the other water? (%d)" % r.water.vertices.size())
	var dry := d.duplicate()
	dry[ChunkMesher.index(5, 11, 5)] = Blocks.AIR
	dry[ChunkMesher.index(6, 10, 5)] = Blocks.AIR
	check(ChunkMesher.build(dry).opaque.colors == r.opaque.colors, "water changes no stone lighting (AO / sky)")


func _test_ungenerated_is_collidable() -> void:
	var w := World.new()
	check(w.is_collidable_at(Vector3i(100, 40, 100)), "ungenerated chunk is collidable (no falling through)")
	check(w.get_block(Vector3i(100, 40, 100)) == Blocks.AIR, "but reads as air for raycasts")
	w.free()


func _water_world(floor_y: int, water_top: int) -> World:
	var w := _flat_world(floor_y)
	for cd: World.ChunkData in w.chunks.values():
		for y in range(floor_y + 1, water_top + 1):
			for i in World.CS * World.CS:
				cd.blocks[i + y * World.CS * World.CS] = Blocks.WATER
	return w


func _test_player_swims() -> void:
	var w := _water_world(10, 18)
	var p := Player.new()
	p.world = w
	p.position = Vector3(5.5, 16.0, 5.5)
	for i in 30:
		p.physics_step(1.0 / 60.0, Vector2.ZERO, false)
	check(p.in_water, "player detects water")
	check(p.velocity.y >= -Player.SWIM_MAX_SINK - 0.01, "sinking is slow in water (vy=%.2f)" % p.velocity.y)
	var y0 := p.position.y
	for i in 60:
		p.physics_step(1.0 / 60.0, Vector2.ZERO, true)
	check(p.position.y > y0 + 1.0, "holding jump swims up (%.2f → %.2f)" % [y0, p.position.y])
	for i in 300:
		p.physics_step(1.0 / 60.0, Vector2.ZERO, false)
	check(absf(p.position.y - 11.0) < 0.01, "player sinks to the sea floor and stands on it")
	p.free()
	w.free()


func _test_place_into_water() -> void:
	var w := _water_world(10, 14)
	var p := Player.new()
	p.world = w
	p.position = Vector3(5.5, 20.0, 5.5)
	p.target = {"pos": Vector3i(8, 10, 8), "normal": Vector3i.UP, "id": Blocks.STONE}
	check(p.try_place(), "can place a block into water")
	check(w.get_block(Vector3i(8, 11, 8)) == p.selected_block(), "placed block replaced the water")
	var hit := w.raycast(Vector3(3.5, 14.5, 3.5), Vector3.DOWN, 8.0)
	check(not hit.is_empty() and hit.pos.y == 10, "raycast passes through water to the floor")
	p.free()
	w.free()


func _test_gen_deterministic_threaded() -> void:
	var g := TerrainGen.new(4242)
	var keys: Array[Vector2i] = [Vector2i(0, 0), Vector2i(7, -3), Vector2i(-12, 25), Vector2i(40, 40), Vector2i(-90, 3), Vector2i(5, 66)]
	var sync := {}
	for k in keys:
		sync[k] = g.generate(k).blocks
	var g2 := TerrainGen.new(4242)
	var out := {}
	var m := Mutex.new()
	var task := WorkerThreadPool.add_group_task(func(i: int):
		var r: PackedByteArray = g2.generate(keys[i]).blocks
		m.lock()
		out[keys[i]] = r
		m.unlock(), keys.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(task)
	var same := true
	for k in keys:
		same = same and out.get(k) == sync[k]
	check(same, "same seed → identical chunks, also when generated concurrently on workers")
	check(TerrainGen.new(1).generate(Vector2i(0, 0)).blocks != TerrainGen.new(2).generate(Vector2i(0, 0)).blocks,
		"different seeds → different chunks")


func _test_cave_lattice_shared_edges() -> void:
	var g := TerrainGen.new(7)
	var a := g._cave_lattice(Vector2i(3, 3))
	var east := g._cave_lattice(Vector2i(4, 3))
	var south := g._cave_lattice(Vector2i(3, 4))
	var n := TerrainGen.LAT_N
	var ok := true
	for ly in TerrainGen.LAT_Y:
		for i in n:
			var s := ly * n * n
			ok = ok and is_equal_approx(a[(n - 1) + i * n + s], east[0 + i * n + s])
			ok = ok and is_equal_approx(a[i + (n - 1) * n + s], south[i + 0 * n + s])
	check(ok, "cave lattice values match on shared chunk edges (no seams)")
	# Interpolated field at the border equals the point-wise reference from both sides.
	var wx := 4 * World.CS # first column of chunk x=4
	check(is_equal_approx(TerrainGen._cave_interp(a, World.CS, 21, 5), g.cave_value(wx, 21, 3 * World.CS + 5)),
		"cave field continuous across the chunk border")


func _test_water_never_hangs() -> void:
	var g := TerrainGen.new(1337)
	var bad := 0
	var water := 0
	var cs := World.CS
	for k in [Vector2i(0, 0), Vector2i(-6, 4), Vector2i(10, -8), Vector2i(20, 20), Vector2i(-30, -12),
			Vector2i(33, -2), Vector2i(-3, 41), Vector2i(55, 17), Vector2i(-48, -40), Vector2i(12, 60)]:
		var b: PackedByteArray = g.generate(k).blocks
		for y in range(1, TerrainGen.SEA + 1):
			for z in cs:
				for x in cs:
					if b[x + z * cs + y * cs * cs] != Blocks.WATER:
						continue
					water += 1
					if b[x + z * cs + (y - 1) * cs * cs] == Blocks.AIR:
						bad += 1
					for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var nx := x + d.x
						var nz := z + d.y
						if nx >= 0 and nx < cs and nz >= 0 and nz < cs and b[nx + nz * cs + y * cs * cs] == Blocks.AIR:
							bad += 1
	check(water > 0, "sample chunks contain water")
	check(bad == 0, "water never sits next to / above air inside a chunk (%d bad of %d)" % [bad, water])


func _test_biome_variety() -> void:
	var g := TerrainGen.new(1337)
	var near := {}
	for z in range(-400, 401, 16):
		for x in range(-400, 401, 16):
			near[g.biome_at(x, z)] = true
	var names := []
	for b in near:
		names.append(TerrainGen.Biome.keys()[b])
	check(near.size() >= 5, "≥5 biomes within 400 blocks of origin (got %d: %s)" % [near.size(), names])

	var counts := {}
	var total := 0
	for z in range(-3000, 3001, 40):
		for x in range(-3000, 3001, 40):
			var b := g.biome_at(x, z)
			counts[b] = counts.get(b, 0) + 1
			total += 1
	var line := ""
	for b in TerrainGen.Biome.values():
		line += "%s %.1f%%  " % [TerrainGen.Biome.keys()[b], 100.0 * counts.get(b, 0) / total]
	print("BIOMES ", line)
	check(counts.size() == TerrainGen.Biome.size(), "every biome appears in a 6 km square (%d/%d)" % [counts.size(), TerrainGen.Biome.size()])


func _test_swim_out_onto_shore() -> void:
	# Water 11..14 for x < 8; land (floor raised to 14) for x >= 8: a 1-block shore step at the waterline.
	var w := _water_world(10, 14)
	for z in range(-16, 32):
		for x in range(8, 32):
			for y in range(11, 15):
				w.set_block(Vector3i(x, y, z), Blocks.STONE)
	var p := Player.new()
	p.world = w
	p.position = Vector3(5.5, 13.6, 5.5) # floating at the surface
	p.yaw = deg_to_rad(-90.0) # facing +x
	for i in 240:
		p.physics_step(1.0 / 60.0, Vector2(0, -1), false) # just walk forward, no jump
	check(p.position.x > 8.5 and p.position.y >= 15.0 - 0.01 and not p.in_water,
		"walking out of water onto a 1-block shore works without pressing jump (pos=%s)" % p.position)
	p.free()
	w.free()


func _test_generate_top_bound() -> void:
	var g := TerrainGen.new(1337)
	var ok := true
	for k in [Vector2i(0, 0), Vector2i(3, -4), Vector2i(-20, 9), Vector2i(31, 31), Vector2i(-7, -50), Vector2i(44, -13)]:
		var r := g.generate(k)
		var b: PackedByteArray = r.blocks
		var real := 0
		for i in b.size():
			if b[i] != 0:
				real = maxi(real, i / (World.CS * World.CS))
		ok = ok and r.top >= real
	check(ok, "generate().top is never below the real highest block (mesher/padding rely on it)")


func _test_swamp_has_pools() -> void:
	var g := TerrainGen.new(1337)
	var swamp := 0
	var wet := 0
	for z in range(-1500, 1501, 6):
		for x in range(-1500, 1501, 6):
			var s := g.sample(x, z)
			if s[4] < 0.35:
				continue
			var b := g.biome_of(s, 0)
			if b != TerrainGen.Biome.SWAMP:
				continue
			swamp += 1
			if int(s[0]) < TerrainGen.SEA:
				wet += 1
	check(swamp > 0 and wet > swamp * 0.15 and wet < swamp * 0.8,
		"swamps mix pools and dry hummocks (%d of %d sampled swamp columns under water)" % [wet, swamp])
