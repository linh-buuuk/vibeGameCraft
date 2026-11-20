class_name TouchControls
extends Control
## Multi-touch controls drawn with _draw (no textures):
## - left side: floating joystick (appears where the thumb lands)
## - right side: drag to look
## - buttons: jump, break (hold), place (tap)
## Every finger is tracked by its index, so joystick + look + buttons
## work simultaneously without stealing each other's touches.

const JOY_RADIUS := 80.0
const KNOB_RADIUS := 34.0
const BUTTON_RADIUS := 46.0
const JOY_ZONE := 0.42 # left fraction of the screen used for the joystick

var move_vector := Vector2.ZERO
var jump_held := false
var break_held := false

## Rects (in this control's coordinates) that the HUD wants to handle itself.
var blocked_rects: Array[Rect2] = []
## Extra margin from notches / rounded corners.
var safe_margin := Rect2() # position = left/top, size = right/bottom

var _look_delta := Vector2.ZERO
var _place_requests := 0
var _joy_index := -1
var _joy_origin := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _look_index := -1
var _buttons := {} # name -> {center: Vector2, label: String}
var _button_touch := {} # touch index -> button name

# Dark translucent fill + white ring with a dark edge: readable on snow/sand and on sky.
const COL_FILL := Color(0.05, 0.07, 0.1, 0.30)
const COL_ACTIVE := Color(0.05, 0.07, 0.1, 0.50)
const COL_RING := Color(1, 1, 1, 0.75)
const COL_EDGE := Color(0, 0, 0, 0.35)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_layout)
	_layout()


func _layout() -> void:
	var right := size.x - safe_margin.size.x - 40.0
	var bottom := size.y - safe_margin.size.y - 40.0
	_buttons = {
		"jump": {"center": Vector2(right - BUTTON_RADIUS, bottom - BUTTON_RADIUS), "label": "Jump"},
		"break": {"center": Vector2(right - BUTTON_RADIUS * 3.4, bottom - BUTTON_RADIUS * 0.9), "label": "Mine"},
		"place": {"center": Vector2(right - BUTTON_RADIUS * 1.2, bottom - BUTTON_RADIUS * 3.4), "label": "Place"},
	}
	queue_redraw()


func consume_look_delta() -> Vector2:
	var d := _look_delta
	_look_delta = Vector2.ZERO
	return d


func consume_place() -> bool:
	if _place_requests > 0:
		_place_requests -= 1
		return true
	return false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		var pos := _to_local(event.position)
		if event.pressed:
			_on_press(event.index, pos)
		else:
			_on_release(event.index)
	elif event is InputEventScreenDrag:
		_on_drag(event.index, _to_local(event.position), event.relative)



func _to_local(p: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * p


## Exposed for tests: returns what the touch was assigned to.
func _on_press(index: int, pos: Vector2) -> String:
	for r in blocked_rects:
		if r.has_point(pos):
			return ""
	for name: String in _buttons:
		if pos.distance_to(_buttons[name].center) <= BUTTON_RADIUS * 1.25:
			_button_touch[index] = name
			match name:
				"jump": jump_held = true
				"break": break_held = true
				"place": _place_requests += 1
			queue_redraw()
			return name
	if pos.x < size.x * JOY_ZONE and _joy_index == -1:
		_joy_index = index
		_joy_origin = pos
		_joy_knob = pos
		move_vector = Vector2.ZERO
		queue_redraw()
		return "joystick"
	if _look_index == -1:
		_look_index = index
		return "look"
	return ""


func _on_release(index: int) -> void:
	if _button_touch.has(index):
		match _button_touch[index]:
			"jump": jump_held = false
			"break": break_held = false
		_button_touch.erase(index)
	if index == _joy_index:
		_joy_index = -1
		move_vector = Vector2.ZERO
	if index == _look_index:
		_look_index = -1
	queue_redraw()


func _on_drag(index: int, pos: Vector2, relative: Vector2) -> void:
	if index == _joy_index:
		var off := (pos - _joy_origin).limit_length(JOY_RADIUS)
		_joy_knob = _joy_origin + off
		var v := off / JOY_RADIUS
		move_vector = v if v.length() > 0.12 else Vector2.ZERO # dead zone
		queue_redraw()
	elif index == _look_index or _button_touch.get(index, "") == "break":
		# Dragging from the break button also aims, so you can dig while turning.
		_look_delta += relative


func _draw() -> void:
	# Joystick: faint hint when idle, full when a thumb is down.
	if _joy_index != -1:
		draw_circle(_joy_origin, JOY_RADIUS, COL_FILL)
		_ring(_joy_origin, JOY_RADIUS, 1.0)
		draw_circle(_joy_knob, KNOB_RADIUS, Color(1, 1, 1, 0.55))
		draw_arc(_joy_knob, KNOB_RADIUS, 0, TAU, 32, COL_EDGE, 2.0, true)
	else:
		var hint := Vector2(safe_margin.position.x + 150.0, size.y - safe_margin.size.y - 150.0)
		draw_circle(hint, JOY_RADIUS, Color(0.05, 0.07, 0.1, 0.16))
		_ring(hint, JOY_RADIUS, 0.55)
		draw_circle(hint, KNOB_RADIUS, Color(1, 1, 1, 0.22))

	var font := get_theme_default_font()
	var held := _button_touch.values()
	for name: String in _buttons:
		var b: Dictionary = _buttons[name]
		draw_circle(b.center, BUTTON_RADIUS, COL_ACTIVE if held.has(name) else COL_FILL)
		_ring(b.center, BUTTON_RADIUS, 1.0)
		var fs := 18
		var ts := font.get_string_size(b.label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
		draw_string_outline(font, b.center + Vector2(-ts.x * 0.5, fs * 0.35), b.label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.35))
		draw_string(font, b.center + Vector2(-ts.x * 0.5, fs * 0.35), b.label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))


## White ring with a thin dark edge outside it.
func _ring(c: Vector2, r: float, alpha: float) -> void:
	draw_arc(c, r + 1.5, 0, TAU, 48, Color(COL_EDGE, COL_EDGE.a * alpha), 2.0, true)
	draw_arc(c, r - 0.5, 0, TAU, 48, Color(COL_RING, COL_RING.a * alpha), 2.0, true)
