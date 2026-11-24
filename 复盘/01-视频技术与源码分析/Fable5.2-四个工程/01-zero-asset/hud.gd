extends CanvasLayer
# HUD and menus. Text is limited to titles, labels, buttons and numbers.

signal start_pressed
signal quit_pressed
signal retry_pressed

var font: SystemFont
var root: Control
var bars: Control
var hp_bar: ProgressBar
var en_bar: ProgressBar
var core_lbl: Label
var boss_box: Control
var boss_bar: ProgressBar
var cross: Control
var title_box: Control
var title_lbl: Label
var title_btns: Control
var end_box: Control
var end_lbl: Label
var end_btn: Button
var title_a := 0.0
var title_target := 0.0
var end_a := 0.0
var end_target := 0.0
var boss_a := 0.0
var boss_target := 0.0
var bars_a := 0.0
var bars_target := 0.0


func build() -> void:
	layer = 5
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "SimHei"])
	font.font_weight = 700
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	bars = Control.new()
	bars.set_anchors_preset(Control.PRESET_FULL_RECT)
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bars)
	hp_bar = _bar(bars, "机体", Vector2(64, 968), 420.0, Color(0.95, 0.93, 0.88))
	en_bar = _bar(bars, "能量", Vector2(64, 1012), 420.0, G.C_CYAN)
	core_lbl = _label(bars, "核心 0 / 5", 34, Color(0.8, 0.97, 1.0))
	core_lbl.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	core_lbl.position = Vector2(1920 - 64 - 300, 984)
	core_lbl.size = Vector2(300, 48)
	core_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	boss_box = Control.new()
	boss_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(boss_box)
	var bl := _label(boss_box, "蚀母", 44, Color(1.0, 0.85, 0.9))
	bl.position = Vector2(460, 52)
	bl.size = Vector2(1000, 60)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_bar = _pbar(boss_box, Vector2(460, 122), Vector2(1000, 14), G.C_MAGENTA)

	cross = Control.new()
	cross.position = Vector2(960, 540)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cross.draw.connect(_draw_cross)
	root.add_child(cross)

	title_box = Control.new()
	title_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title_box)
	title_lbl = _label(title_box, "蚀原", 230, Color(1.0, 0.96, 0.9))
	title_lbl.position = Vector2(0, 150)
	title_lbl.size = Vector2(1920, 340)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.label_settings.outline_size = 0
	title_lbl.label_settings.shadow_size = 6
	title_lbl.label_settings.shadow_color = Color(0.05, 0.0, 0.08, 0.45)
	title_lbl.label_settings.shadow_offset = Vector2(0, 6)
	var tf := SystemFont.new()
	tf.font_names = font.font_names
	tf.font_weight = 900
	var fv := FontVariation.new()
	fv.base_font = tf
	fv.spacing_glyph = 90
	title_lbl.label_settings.font = fv
	title_btns = Control.new()
	title_btns.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_child(title_btns)
	var b1 := _button(title_btns, "开始", Vector2(810, 520))
	b1.pressed.connect(func(): start_pressed.emit())
	var b2 := _button(title_btns, "退出", Vector2(810, 606))
	b2.pressed.connect(func(): quit_pressed.emit())

	end_box = Control.new()
	end_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	end_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(end_box)
	end_lbl = _label(end_box, "胜利", 200, Color(1.0, 0.96, 0.9))
	end_lbl.position = Vector2(0, 300)
	end_lbl.size = Vector2(1920, 300)
	end_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_lbl.label_settings.font = fv
	end_lbl.label_settings.outline_size = 0
	end_lbl.label_settings.shadow_size = 6
	end_lbl.label_settings.shadow_color = Color(0.05, 0.0, 0.08, 0.45)
	end_lbl.label_settings.shadow_offset = Vector2(0, 6)
	end_btn = _button(end_box, "再来一次", Vector2(810, 720))
	end_btn.pressed.connect(func(): retry_pressed.emit())

	for c in [bars, boss_box, title_box, end_box]:
		c.modulate.a = 0.0
		c.visible = false
	cross.visible = false


func _draw_cross() -> void:
	var c := Color(0.75, 0.97, 1.0, 0.9)
	cross.draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 40, c, 2.0, true)
	cross.draw_circle(Vector2.ZERO, 2.2, c)
	for a in 4:
		var d := Vector2.RIGHT.rotated(a * PI * 0.5)
		cross.draw_line(d * 20.0, d * 30.0, c, 2.0, true)


func _label(parent: Control, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = size
	ls.font_color = col
	ls.outline_size = maxi(size / 10, 3)
	ls.outline_color = Color(0.02, 0.02, 0.05, 0.75)
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _pbar(parent: Control, pos: Vector2, size: Vector2, col: Color) -> ProgressBar:
	var p := ProgressBar.new()
	p.position = pos
	p.size = size
	p.custom_minimum_size = size
	p.show_percentage = false
	p.max_value = 1.0
	p.step = 0.0
	p.value = 1.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.02, 0.02, 0.05, 0.6)
	bg.border_color = Color(1, 1, 1, 0.25)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(2)
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	fg.set_corner_radius_all(2)
	fg.shadow_color = Color(col.r, col.g, col.b, 0.45)
	fg.shadow_size = 8
	p.add_theme_stylebox_override("background", bg)
	p.add_theme_stylebox_override("fill", fg)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	return p


func _bar(parent: Control, text: String, pos: Vector2, width: float, col: Color) -> ProgressBar:
	var l := _label(parent, text, 28, Color(0.92, 0.95, 1.0))
	l.position = pos
	l.size = Vector2(80, 36)
	return _pbar(parent, pos + Vector2(84, 13), Vector2(width, 12), col)


func _button(parent: Control, text: String, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(300, 68)
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 34)
	b.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.03, 0.04, 0.08, 0.55) if st == "normal" else (Color(0.2, 0.9, 1.0, 0.28) if st == "hover" else Color(0.2, 0.9, 1.0, 0.5))
		sb.border_color = Color(0.75, 0.95, 1.0, 0.8 if st != "normal" else 0.4)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(3)
		b.add_theme_stylebox_override(st, sb)
	b.pressed.connect(func(): G.audio.play("ui", G.cam.global_position, -6.0))
	parent.add_child(b)
	return b


func show_title(on: bool, with_buttons := true) -> void:
	title_target = 1.0 if on else 0.0
	title_btns.visible = with_buttons


func show_end(on: bool, win := true, with_button := true) -> void:
	end_target = 1.0 if on else 0.0
	if on:
		end_lbl.text = "胜利" if win else "失败"
		end_lbl.label_settings.font_color = Color(1.0, 0.96, 0.9) if win else Color(1.0, 0.45, 0.4)
		end_btn.visible = with_button


func show_bars(on: bool) -> void:
	bars_target = 1.0 if on else 0.0


func show_boss(on: bool) -> void:
	boss_target = 1.0 if on else 0.0


func snap_hidden() -> void:
	title_target = 0.0
	end_target = 0.0
	bars_target = 0.0
	boss_target = 0.0
	title_a = 0.0
	end_a = 0.0
	bars_a = 0.0
	boss_a = 0.0


func _fade(c: Control, a: float) -> void:
	c.modulate.a = a
	c.visible = a > 0.01


func _process(dt: float) -> void:
	title_a = move_toward(title_a, title_target, dt * 1.2)
	end_a = move_toward(end_a, end_target, dt * 1.2)
	bars_a = move_toward(bars_a, bars_target, dt * 2.0)
	boss_a = move_toward(boss_a, boss_target, dt * 1.5)
	_fade(title_box, title_a)
	_fade(end_box, end_a)
	_fade(bars, bars_a)
	_fade(boss_box, boss_a)
	var w = G.walker
	if w != null:
		hp_bar.value = w.hp / w.MAX_HP
		en_bar.value = w.energy / w.MAX_EN
	core_lbl.text = "核心 %d / %d" % [mini(G.main.cores_got, G.main.CORES), G.main.CORES]
	if G.boss != null:
		boss_bar.value = G.boss.hp / G.boss.MAX_HP
