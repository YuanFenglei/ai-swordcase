extends CanvasLayer

const TOOLS := ["挖掘", "填充", "平滑", "炸药", "钻隧道"]
const MATS := ["草地", "泥土", "岩石", "玄武岩", "矿石", "水晶", "沙"]
const INK := Color(0.98, 0.93, 0.84)
const ACCENT := Color(1.0, 0.62, 0.28)

var main: Node3D
var _num: Array[Label] = []
var _tool_panels: Array[PanelContainer] = []
var _radius: Label
var _mat: Label
var _bar: Control
var _cross: Control
var _fps_acc := 0.0
var _fps_n := 0
var _fps_show := 0.0
var _tris_show := 0.0


func _ready() -> void:
	layer = 5
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 64)
	add_child(row)
	var play: bool = main.mode == "play"
	if play:
		row.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		row.position = Vector2(48, 36)
	else:
		row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		row.position = Vector2(64, 1080 - 170)
	for t in ["重建三角形", "重建区块", "FPS"]:
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", -4)
		var n := Label.new()
		n.text = "0"
		n.add_theme_font_size_override("font_size", 40 if play else 64)
		n.add_theme_color_override("font_color", INK)
		n.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
		n.add_theme_constant_override("shadow_offset_x", 0)
		n.add_theme_constant_override("shadow_offset_y", 3)
		n.add_theme_constant_override("shadow_outline_size", 8)
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 20 if play else 26)
		l.add_theme_color_override("font_color", ACCENT)
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
		l.add_theme_constant_override("shadow_offset_y", 2)
		vb.add_child(n)
		vb.add_child(l)
		row.add_child(vb)
		_num.append(n)
	if not play:
		return

	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 10)
	add_child(_bar)
	for t in TOOLS:
		var pc := PanelContainer.new()
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 26)
		l.add_theme_color_override("font_color", INK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size = Vector2(118, 44)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pc.add_child(l)
		_bar.add_child(pc)
		_tool_panels.append(pc)
	_radius = _chip("半径 6")
	_mat = _chip("材质 岩石")
	_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar.position.y -= 40
	_cross = ColorRect.new()
	_cross.color = Color(1, 1, 1, 0.85)
	_cross.custom_minimum_size = Vector2(4, 4)
	_cross.size = Vector2(4, 4)
	_cross.set_anchors_preset(Control.PRESET_CENTER)
	_cross.position = Vector2(-2, -2)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cross)
	set_tool(0, 6.0, 2)


func _chip(t: String) -> Label:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	pc.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 26)
	l.add_theme_color_override("font_color", ACCENT)
	l.custom_minimum_size = Vector2(130, 44)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pc.add_child(l)
	_bar.add_child(pc)
	return l


func set_tool(i: int, radius: float, mat: int) -> void:
	for k in _tool_panels.size():
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(6)
		if k == i:
			sb.bg_color = Color(0.95, 0.52, 0.2, 0.92)
		else:
			sb.bg_color = Color(0.07, 0.06, 0.06, 0.62)
		_tool_panels[k].add_theme_stylebox_override("panel", sb)
	_radius.text = "半径 %d" % int(round(radius))
	_mat.text = "材质 %s" % MATS[mat]
	_mat.get_parent().modulate.a = 1.0 if i == 1 else 0.0


func _fmt(v: int) -> String:
	var s := str(v)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


func _process(dt: float) -> void:
	_fps_acc += dt
	_fps_n += 1
	if _fps_acc >= 0.25:
		_fps_show = _fps_n / _fps_acc
		_fps_acc = 0.0
		_fps_n = 0
		_num[2].text = str(int(round(_fps_show)))
	var w: RefCounted = main.world
	if w == null or not w.loaded:
		return
	var target := float(w.stat_tris)
	_tris_show = target if target - _tris_show < 50.0 else lerpf(_tris_show, target, 1.0 - exp(-dt * 12.0))
	_num[0].text = _fmt(int(_tris_show))
	_num[1].text = _fmt(w.stat_chunks)
