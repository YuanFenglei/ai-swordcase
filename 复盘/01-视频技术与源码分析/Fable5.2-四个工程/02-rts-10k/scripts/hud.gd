extends Control

const BLUE := Color(0.30, 0.58, 1.0)
const RED := Color(1.0, 0.33, 0.22)
const INK := Color(0.97, 0.94, 0.88)

var font: SystemFont
var units_lbl: Label
var fps_lbl: Label
var blue_lbl: Label
var red_lbl: Label
var sel_lbl: Label
var end_lbl: Label
var minimap: TextureRect
var bar := Rect2(700, 58, 520, 14)
var ratio := 0.5
var drag := Rect2()
var dragging := false
var view_poly := PackedVector2Array()
var show_minimap := true


func _label(text: String, size: int, pos: Vector2, col := INK, outline := 10) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0.04, 0.03, 0.02, 0.85))
	l.add_theme_constant_override("outline_size", outline)
	add_child(l)
	return l


func build(mm_mat: ShaderMaterial) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Bahnschrift", "Microsoft YaHei UI", "Microsoft YaHei"])
	font.font_weight = 600
	_label("单位", 34, Vector2(56, 34), Color(0.93, 0.83, 0.62))
	units_lbl = _label("0", 132, Vector2(52, 62), INK, 16)
	_label("FPS", 34, Vector2(56, 232), Color(0.93, 0.83, 0.62))
	fps_lbl = _label("0", 132, Vector2(52, 260), INK, 16)
	blue_lbl = _label("0", 34, Vector2(bar.position.x - 150, bar.position.y - 22), BLUE)
	blue_lbl.size = Vector2(134, 44)
	blue_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	red_lbl = _label("0", 34, Vector2(bar.end.x + 16, bar.position.y - 22), RED)
	sel_lbl = _label("", 34, Vector2(860, 1010))
	sel_lbl.size = Vector2(200, 44)
	sel_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_lbl = _label("", 150, Vector2(0, 420), INK, 18)
	end_lbl.size = Vector2(1920, 200)
	end_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	minimap = TextureRect.new()
	minimap.position = Vector2(40, 1080 - 40 - 288)
	minimap.size = Vector2(288, 288)
	minimap.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	minimap.stretch_mode = TextureRect.STRETCH_SCALE
	minimap.texture = mm_mat.get_shader_parameter("base_tex")
	minimap.material = mm_mat
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(minimap)
	move_child(minimap, 0)


static func fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	var k := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		k += 1
		if k % 3 == 0 and i > 0:
			out = "," + out
	return out


func _draw() -> void:
	# strength bar
	draw_rect(bar.grow(3), Color(0.04, 0.03, 0.02, 0.8))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), BLUE)
	draw_rect(Rect2(bar.position + Vector2(bar.size.x * ratio, 0), Vector2(bar.size.x * (1.0 - ratio), bar.size.y)), RED)
	if show_minimap:
		var r := Rect2(minimap.position, minimap.size)
		draw_rect(r.grow(3), Color(0.04, 0.03, 0.02, 0.9), false, 6.0)
		draw_rect(r.grow(1), Color(0.93, 0.83, 0.62, 0.9), false, 2.0)
		if view_poly.size() == 4:
			var pts := PackedVector2Array()
			for p in view_poly:
				pts.append(r.position + Vector2(clampf(p.x, 0.0, 1.0), clampf(p.y, 0.0, 1.0)) * r.size)
			pts.append(pts[0])
			draw_polyline(pts, Color(1, 1, 1, 0.9), 2.0)
	if dragging:
		draw_rect(drag, Color(0.6, 0.85, 1.0, 0.12))
		draw_rect(drag, Color(0.75, 0.92, 1.0, 0.95), false, 2.0)
