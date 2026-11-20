extends Node3D
## Builds the scene in code: sky, world, player, HUD, touch controls.
##
## Command-line user args (after `--`):
##   --touch-ui            force touch controls on desktop
##   --screenshot=<path>   save a PNG once the world has loaded, then quit
##   --view=<n>            view radius in chunks
##   --seed=<n>            world seed
##   --biome=<name>        spawn in the nearest biome of that TerrainGen.Biome name (e.g. DESERT)
##   --pos=<x,y,z>         spawn at exactly this position (feet), e.g. inside a cave or underwater
##   --look=<yaw,pitch>    initial camera angles in degrees
##   --demo=build          place a small scripted hut in front of the player (for screenshots)

const HORIZON := Color(0.70, 0.83, 0.95)

var world: World
var player: Player
var hud: Hud
var touch: TouchControls
var _spawned := false
var _args := {}


func _ready() -> void:
	_parse_args()
	if OS.has_feature("mobile"):
		Engine.max_fps = 60

	_setup_environment()
	if _args.has("scale"):
		get_viewport().scaling_3d_scale = float(_args.scale)

	world = World.new(int(_args.get("seed", 1337)))
	if _args.has("view"):
		world.view_radius = int(_args.view)
		world.set_fog_distance(world.view_radius)
	world.set_fog_color(HORIZON)
	add_child(world)

	player = Player.new()
	player.world = world
	var spawn := _find_spawn_column(str(_args.get("biome", "")))
	player.position = Vector3(spawn.x + 0.5, World.H - 1, spawn.y + 0.5)
	if _args.has("pos"):
		player.position = _vec3_arg("pos")
	add_child(player)

	var ui := CanvasLayer.new()
	add_child(ui)
	var margin := _safe_margin()

	touch = TouchControls.new()
	touch.safe_margin = margin
	touch.visible = OS.has_feature("mobile") or DisplayServer.is_touchscreen_available() or _args.has("touch-ui")
	if _args.has("touch-ui") and not OS.has_feature("mobile"):
		Input.emulate_touch_from_mouse = true # test touch UI with the mouse (one finger)
	player.touch = touch

	hud = Hud.new()
	hud.player = player
	hud.touch = touch
	hud.safe_margin = margin
	ui.add_child(hud)
	ui.add_child(touch) # on top of the HUD visually; HUD hotbar rects are excluded


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else true


func _vec3_arg(name: String) -> Vector3:
	var v := str(_args[name]).split_floats(",")
	return Vector3(v[0], v[1], v[2]) if v.size() >= 3 else Vector3(v[0], v[1], 0.0)


func _setup_environment() -> void:
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("horizon_color", HORIZON)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


## Notch / rounded-corner insets in viewport units (mobile only).
func _safe_margin() -> Rect2:
	if not OS.has_feature("mobile"):
		return Rect2()
	var safe := DisplayServer.get_display_safe_area()
	var screen := DisplayServer.screen_get_size()
	var vp := get_viewport().get_visible_rect().size
	var k := vp / Vector2(screen)
	return Rect2(
		Vector2(safe.position.x, safe.position.y) * k,
		Vector2(screen.x - safe.end.x, screen.y - safe.end.y) * k)


var _perf_t := 0.0
var _perf_worst := 0.0
var _perf_frames := 0


func _process(dt: float) -> void:
	world.update_streaming(player.position)
	if not _spawned and world.is_area_ready(player.position, 1):
		_spawn()
	# Periodic perf line (lands in user://logs/godot.log on device).
	_perf_t += dt
	_perf_frames += 1
	_perf_worst = maxf(_perf_worst, dt)
	if _perf_t >= 10.0:
		print("PERF avg_fps=%.0f worst_ms=%.1f gen_ms=%.1f mesh_ms=%.1f chunks=%d pos=%s biome=%s" % [
			_perf_frames / _perf_t, _perf_worst * 1000.0,
			world.stats.gen_ms, world.stats.mesh_ms, world.chunks.size(),
			Vector3i(player.position),
			TerrainGen.Biome.keys()[world.gen.biome_at(floori(player.position.x), floori(player.position.z))]])
		_perf_t = 0.0
		_perf_worst = 0.0
		_perf_frames = 0


## Search outward (coarse rings) for dry, walkable land — or a specific biome.
func _find_spawn_column(biome_name: String) -> Vector2i:
	var want := TerrainGen.Biome.keys().find(biome_name.to_upper()) if biome_name != "" else -1
	const GOOD := [TerrainGen.Biome.PLAINS, TerrainGen.Biome.FOREST, TerrainGen.Biome.BIRCH_FOREST,
		TerrainGen.Biome.TAIGA, TerrainGen.Biome.SNOWY_PLAINS, TerrainGen.Biome.DESERT]
	for r in range(0, 3000, 8):
		var steps := maxi(1, r / 4)
		for i in steps:
			var a := TAU * i / steps
			var c := Vector2i(roundi(cos(a) * r), roundi(sin(a) * r))
			var biome := world.gen.biome_at(c.x, c.y)
			var h: int = world.gen.sample(c.x, c.y)[0]
			if want >= 0:
				if biome == want:
					return c
			elif biome in GOOD and h > World.SEA_LEVEL + 1 and h < 58:
				return c
	return Vector2i.ZERO


static func _is_ground(id: int) -> bool:
	return id in [Blocks.GRASS, Blocks.SNOW_GRASS, Blocks.SWAMP_GRASS, Blocks.SAND, Blocks.GRAVEL,
		Blocks.STONE, Blocks.SNOW, Blocks.DIRT, Blocks.SANDSTONE, Blocks.CLAY]


func _spawn() -> void:
	_spawned = true
	if _args.has("pos"):
		_finish_spawn()
		return
	# Pick the nearest column whose top block is ground (not a canopy or water).
	var x := floori(player.position.x)
	var z := floori(player.position.z)
	var best := Vector2i(x, z)
	for r in range(0, 12):
		var found := false
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var h := world.surface_height(x + dx, z + dz)
				var above := world.get_block(Vector3i(x + dx, h + 1, z + dz))
				if _is_ground(world.get_block(Vector3i(x + dx, h, z + dz))) and above == Blocks.AIR:
					best = Vector2i(x + dx, z + dz)
					found = true
					break
			if found:
				break
		if found:
			break
	player.position = Vector3(best.x + 0.5, world.surface_height(best.x, best.y) + 1.0, best.y + 0.5)
	# Face the most open direction so the first view isn't a tree trunk.
	var eye := player.position + Vector3(0, Player.EYE, 0)
	var best_dist := -1.0
	for i in 8:
		var yaw := TAU * i / 8.0
		var dir := Vector3(-sin(yaw), -0.15, -cos(yaw))
		var hit := world.raycast(eye, dir, 40.0)
		var dist := 40.0 if hit.is_empty() else eye.distance_to(Vector3(hit.pos))
		if dist > best_dist:
			best_dist = dist
			player.yaw = yaw
	player.pitch = deg_to_rad(-12.0)
	_finish_spawn()


func _finish_spawn() -> void:
	if _args.has("look"):
		var l := _vec3_arg("look")
		player.yaw = deg_to_rad(l.x)
		player.pitch = deg_to_rad(l.y)
	if str(_args.get("demo", "")) == "build":
		_build_demo_hut()
	player.active = true
	if _args.has("screenshot"):
		_take_screenshot(str(_args.screenshot))


## A 5x5 plank-and-brick hut with a doorway and window, 10 blocks in front of the player.
func _build_demo_hut() -> void:
	var fwd := Vector3(-sin(player.yaw), 0, -cos(player.yaw))
	var c := player.position + fwd * 10.0
	var cx := floori(c.x)
	var cz := floori(c.z)
	var base := world.surface_height(cx, cz) + 1
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			world.set_block(Vector3i(cx + dx, base - 1, cz + dz), Blocks.COBBLE)
			for dy in range(0, 4):
				var edge := absi(dx) == 2 or absi(dz) == 2
				var corner := absi(dx) == 2 and absi(dz) == 2
				var id := Blocks.AIR
				if dy == 3:
					id = Blocks.BRICK
				elif corner:
					id = Blocks.LOG
				elif edge:
					id = Blocks.PLANKS
				world.set_block(Vector3i(cx + dx, base + dy, cz + dz), id)
	# Doorway and window on the side facing the player.
	var face := Vector2i(-2 * signi(roundi(fwd.x * 100)), 0) if absf(fwd.x) > absf(fwd.z) \
		else Vector2i(0, -2 * signi(roundi(fwd.z * 100)))
	world.set_block(Vector3i(cx + face.x, base, cz + face.y), Blocks.AIR)
	world.set_block(Vector3i(cx + face.x, base + 1, cz + face.y), Blocks.AIR)
	var side := Vector2i(face.y, -face.x) / 2
	world.set_block(Vector3i(cx + face.x + side.x, base + 1, cz + face.y + side.y), Blocks.AIR)
	player.select_slot(Blocks.HOTBAR.find(Blocks.PLANKS))


func _take_screenshot(path: String) -> void:
	# Let the rest of the view distance load, then capture.
	var t := 0
	while not world.is_area_ready(player.position, world.view_radius) and t < 600:
		await get_tree().process_frame
		t += 1
	var t0 := Time.get_ticks_usec()
	for i in 120:
		await get_tree().process_frame
	var avg_ms := (Time.get_ticks_usec() - t0) / 120.0 / 1000.0
	print("STEADY_FRAME_MS %.2f (%.0f fps)" % [avg_ms, 1000.0 / avg_ms])
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SCREENSHOT_SAVED ", path, " ", img.get_size(), " frames_waited=", t)
	get_tree().quit()
