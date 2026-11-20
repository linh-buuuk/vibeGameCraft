class_name Hud
extends Control
## Lightweight HUD: everything is StyleBoxFlat + AtlasTexture icons, no
## shaders, no blur, no runtime shadows. Redraws only when state changes.

const SLOT := 64.0
const GAP := 6.0

var player: Player
var touch: TouchControls
var safe_margin := Rect2()

var _slots: Array[Panel] = []
var _style_slot: StyleBoxFlat
var _style_selected: StyleBoxFlat
var _hotbar: HBoxContainer
var _name_label: Label
var _fps_label: Label
var _name_tween: Tween
var _last_progress := -1.0
var _underwater: ColorRect
var _biome_t := 0.0
var _biome_name := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_style_slot = StyleBoxFlat.new()
	_style_slot.bg_color = Color(0.1, 0.11, 0.14, 0.55)
	_style_slot.set_corner_radius_all(10)
	_style_slot.set_border_width_all(2)
	_style_slot.border_color = Color(1, 1, 1, 0.12)
	_style_selected = _style_slot.duplicate()
	_style_selected.bg_color = Color(0.98, 0.85, 0.45, 0.35)
	_style_selected.border_color = Color(1.0, 0.9, 0.55, 0.95)
	_style_selected.set_border_width_all(3)

	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", int(GAP))
	_hotbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hotbar)
	for i in Blocks.HOTBAR.size():
		_hotbar.add_child(_make_slot(i))

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 22)
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_name_label.add_theme_constant_override("outline_size", 6)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.modulate.a = 0.0
	add_child(_name_label)

	_underwater = ColorRect.new()
	_underwater.color = Color(0.12, 0.32, 0.65, 0.38)
	_underwater.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_underwater.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_underwater.visible = false
	add_child(_underwater)
	move_child(_underwater, 0)

	_fps_label = Label.new()
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_fps_label.add_theme_constant_override("outline_size", 4)
	add_child(_fps_label)

	resized.connect(_layout)
	player.slot_changed.connect(_on_slot_changed)
	_on_slot_changed(player.selected_slot, false)
	_layout()


func _make_slot(i: int) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(SLOT, SLOT)
	p.add_theme_stylebox_override("panel", _style_slot)
	p.pivot_offset = Vector2(SLOT, SLOT) * 0.5
	var icon := TextureRect.new()
	var at := AtlasTexture.new()
	at.atlas = Blocks.atlas_texture()
	var r := Blocks.tile_uv_rect(Blocks.tile_for(Blocks.HOTBAR[i], 1))
	var px := float(Blocks.TILE_PX * Blocks.ATLAS_TILES)
	at.region = Rect2(r.position * px, r.size * px)
	icon.texture = at
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 12
	icon.offset_top = 12
	icon.offset_right = -12
	icon.offset_bottom = -12
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(icon)
	p.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			player.select_slot(i)
			accept_event())
	_slots.append(p)
	return p


func _layout() -> void:
	var w := Blocks.HOTBAR.size() * SLOT + (Blocks.HOTBAR.size() - 1) * GAP
	var bottom := size.y - safe_margin.size.y - 14.0
	_hotbar.size = Vector2(w, SLOT)
	_hotbar.position = Vector2((size.x - w) * 0.5, bottom - SLOT)
	_name_label.size = Vector2(400, 30)
	_name_label.position = Vector2((size.x - 400) * 0.5, _hotbar.position.y - 42)
	_fps_label.position = Vector2(safe_margin.position.x + 12, safe_margin.position.y + 8)
	if touch:
		touch.blocked_rects = [Rect2(_hotbar.position, _hotbar.size).grow(4)]
	queue_redraw()


func _on_slot_changed(slot: int, animate := true) -> void:
	for i in _slots.size():
		_slots[i].add_theme_stylebox_override("panel", _style_selected if i == slot else _style_slot)
	_name_label.text = Blocks.display_name(Blocks.HOTBAR[slot])
	if not animate:
		return
	var s := _slots[slot]
	s.scale = Vector2(1.12, 1.12)
	create_tween().tween_property(s, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if _name_tween:
		_name_tween.kill()
	_name_label.modulate.a = 1.0
	_name_tween = create_tween()
	_name_tween.tween_interval(1.0)
	_name_tween.tween_property(_name_label, "modulate:a", 0.0, 0.4)


func _process(_dt: float) -> void:
	_biome_t -= _dt
	if _biome_t <= 0.0 and player.world:
		_biome_t = 0.5
		var b := player.world.gen.biome_at(floori(player.position.x), floori(player.position.z))
		_biome_name = TerrainGen.BIOME_NAMES[b]
	_fps_label.text = "%d FPS · %s" % [Engine.get_frames_per_second(), _biome_name]
	if player.camera and player.world:
		var e := player.camera.global_position
		_underwater.visible = player.world.get_block(Vector3i(floori(e.x), floori(e.y), floori(e.z))) == Blocks.WATER
	if not is_equal_approx(player.break_progress, _last_progress):
		_last_progress = player.break_progress
		queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var col := Color(1, 1, 1, 0.85)
	var shadow := Color(0, 0, 0, 0.35)
	for off in [Vector2(1, 1), Vector2.ZERO]:
		var k: Color = shadow if off != Vector2.ZERO else col
		draw_rect(Rect2(c + off + Vector2(-9, -1), Vector2(18, 2)), k)
		draw_rect(Rect2(c + off + Vector2(-1, -9), Vector2(2, 18)), k)
	if player.break_progress > 0.0:
		draw_arc(c, 22, 0, TAU, 40, Color(0, 0, 0, 0.3), 5.0, true)
		draw_arc(c, 22, -PI / 2, -PI / 2 + TAU * player.break_progress, 40, Color(1, 0.88, 0.5, 0.95), 5.0, true)
