class_name Player
extends Node3D
## First-person player with axis-separated AABB collision against the voxel
## grid (no physics engine). Supports keyboard/mouse and TouchControls.

const HALF_W := 0.3
const HEIGHT := 1.8
const EYE := 1.62
const WALK_SPEED := 4.6
const ACCEL := 40.0
const GRAVITY := 28.0
const SWIM_SPEED_FACTOR := 0.55
const SWIM_GRAVITY := 9.0
const SWIM_MAX_SINK := 3.0
const SWIM_UP_SPEED := 3.4
const SWIM_EXIT_VELOCITY := 6.5
const JUMP_VELOCITY := 8.4
const REACH := 5.5
const MOUSE_SENS := 0.0025
const TOUCH_SENS := 0.0045
const EPS := 0.001

signal slot_changed(slot: int)

var world: World
var touch: TouchControls
var active := false

var velocity := Vector3.ZERO
var on_floor := false
var in_water := false
## Set when horizontal movement was blocked last tick (used to climb out of water).
var hit_wall := false
var yaw := 0.0
var pitch := 0.0
var camera: Camera3D

var selected_slot := 0
var target := {} # current raycast hit
var break_progress := 0.0
var _break_pos := Vector3i(0, -999, 0)
var _highlight: MeshInstance3D


func _ready() -> void:
	camera = Camera3D.new()
	camera.position.y = EYE
	camera.fov = 75.0
	camera.near = 0.05
	camera.far = 200.0
	add_child(camera)
	_highlight = _make_highlight()
	_highlight.top_level = true
	_highlight.visible = false
	add_child(_highlight)


func select_slot(slot: int) -> void:
	selected_slot = posmod(slot, Blocks.HOTBAR.size())
	slot_changed.emit(selected_slot)


func selected_block() -> int:
	return Blocks.HOTBAR[selected_slot]


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			if event.button_index == MOUSE_BUTTON_LEFT and not _touch_visible():
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				try_place()
			MOUSE_BUTTON_WHEEL_UP:
				select_slot(selected_slot - 1)
			MOUSE_BUTTON_WHEEL_DOWN:
				select_slot(selected_slot + 1)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look(event.relative * MOUSE_SENS)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
			select_slot(event.keycode - KEY_1)


func _touch_visible() -> bool:
	return touch != null and touch.visible


func _look(delta: Vector2) -> void:
	yaw -= delta.x
	pitch = clampf(pitch - delta.y, deg_to_rad(-89.0), deg_to_rad(89.0))


func _read_move_input() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S): v.y += 1.0
	if Input.is_physical_key_pressed(KEY_A): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D): v.x += 1.0
	if touch:
		v += touch.move_vector
	return v.limit_length(1.0)


func _wants_jump() -> bool:
	return Input.is_physical_key_pressed(KEY_SPACE) or (touch != null and touch.jump_held)


func _wants_break() -> bool:
	var mouse := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	return mouse or (touch != null and touch.break_held)


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

func _physics_process(dt: float) -> void:
	if not active or world == null:
		return
	if touch:
		_look(touch.consume_look_delta() * TOUCH_SENS)
		if touch.consume_place():
			try_place()
	physics_step(dt, _read_move_input(), _wants_jump())


func _process(dt: float) -> void:
	rotation = Vector3(0, yaw, 0)
	camera.rotation = Vector3(pitch, 0, 0)
	if not active or world == null:
		return
	_update_target()
	_update_breaking(dt)


## One simulation tick. Separate from input so it can be unit tested.
func physics_step(dt: float, move: Vector2, jump: bool) -> void:
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var wish := right * move.x - forward * move.y
	in_water = world.get_block(Vector3i(floori(position.x), floori(position.y + 0.4), floori(position.z))) == Blocks.WATER
	var speed := WALK_SPEED * (SWIM_SPEED_FACTOR if in_water else 1.0)
	var horiz := Vector3(velocity.x, 0, velocity.z).move_toward(wish * speed, ACCEL * dt)
	velocity.x = horiz.x
	velocity.z = horiz.z

	if in_water:
		# Slow sinking; hold jump to swim up; walking into a shore hops out.
		velocity.y = maxf(velocity.y - SWIM_GRAVITY * dt, -SWIM_MAX_SINK)
		if jump:
			velocity.y = move_toward(velocity.y, SWIM_UP_SPEED, 30.0 * dt)
		if _should_auto_jump(wish):
			velocity.y = maxf(velocity.y, SWIM_EXIT_VELOCITY)
		elif hit_wall and wish.length_squared() > 0.04:
			velocity.y = maxf(velocity.y, SWIM_UP_SPEED) # swimming into a bank climbs it
	else:
		velocity.y = maxf(velocity.y - GRAVITY * dt, -50.0)
		if on_floor and (jump or _should_auto_jump(wish)):
			velocity.y = JUMP_VELOCITY
	on_floor = false

	hit_wall = false
	_move_axis(1, velocity.y * dt)
	_move_axis(0, velocity.x * dt)
	_move_axis(2, velocity.z * dt)


## Step up 1-block ledges automatically when walking into them (mobile friendly).
func _should_auto_jump(wish: Vector3) -> bool:
	if wish.length_squared() < 0.04:
		return false
	var ahead := position + wish.normalized() * (HALF_W + 0.35)
	var feet := Vector3i(floori(ahead.x), floori(position.y + 0.01), floori(ahead.z))
	var above := feet + Vector3i.UP
	var head := feet + Vector3i(0, 2, 0)
	return world.is_collidable_at(feet) and not world.is_collidable_at(above) and not world.is_collidable_at(head) \
		and not world.is_collidable_at(Vector3i(floori(position.x), floori(position.y) + 2, floori(position.z)))


func _aabb_min() -> Vector3:
	return position - Vector3(HALF_W, 0, HALF_W)


func _aabb_max() -> Vector3:
	return position + Vector3(HALF_W, HEIGHT, HALF_W)


func _move_axis(axis: int, amount: float) -> void:
	if amount == 0.0:
		return
	position[axis] += amount
	var lo := _aabb_min()
	var hi := _aabb_max()
	var min_b := Vector3i(floori(lo.x), floori(lo.y), floori(lo.z))
	var max_b := Vector3i(floori(hi.x - EPS), floori(hi.y - EPS), floori(hi.z - EPS))
	for y in range(min_b.y, max_b.y + 1):
		for z in range(min_b.z, max_b.z + 1):
			for x in range(min_b.x, max_b.x + 1):
				var b := Vector3i(x, y, z)
				if not world.is_collidable_at(b):
					continue
				if amount > 0.0:
					var limit := float(b[axis]) - (HEIGHT if axis == 1 else HALF_W) - EPS
					position[axis] = minf(position[axis], limit)
				else:
					var limit := float(b[axis] + 1) + (0.0 if axis == 1 else HALF_W) + EPS
					position[axis] = maxf(position[axis], limit)
					if axis == 1:
						on_floor = true
				velocity[axis] = 0.0
				if axis != 1:
					hit_wall = true


func overlaps_block(b: Vector3i) -> bool:
	var lo := _aabb_min()
	var hi := _aabb_max()
	return lo.x < b.x + 1 and hi.x > b.x and lo.y < b.y + 1 and hi.y > b.y and lo.z < b.z + 1 and hi.z > b.z


# ---------------------------------------------------------------------------
# Block interaction
# ---------------------------------------------------------------------------

func _update_target() -> void:
	target = world.raycast(camera.global_position, -camera.global_basis.z, REACH)
	_highlight.visible = not target.is_empty()
	if _highlight.visible:
		_highlight.global_position = Vector3(target.pos) + Vector3(0.5, 0.5, 0.5)


func _update_breaking(dt: float) -> void:
	if target.is_empty() or not _wants_break():
		break_progress = 0.0
		return
	var t := Blocks.break_time(target.id)
	if t < 0.0:
		break_progress = 0.0
		return
	if target.pos != _break_pos:
		_break_pos = target.pos
		break_progress = 0.0
	break_progress += dt / t
	if break_progress >= 1.0:
		world.set_block(target.pos, Blocks.AIR)
		break_progress = 0.0
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(20)


func try_place() -> bool:
	if target.is_empty():
		return false
	var p: Vector3i = target.pos + target.normal
	if not Blocks.is_replaceable(world.get_block(p)) or overlaps_block(p):
		return false
	return world.set_block(p, selected_block())


func _make_highlight() -> MeshInstance3D:
	var s := 0.502
	var c := [
		Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, -s, s), Vector3(-s, -s, s),
		Vector3(-s, s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(-s, s, s),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	var verts := PackedVector3Array()
	for i in edges:
		verts.append(c[i])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.08, 0.08, 0.1)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
