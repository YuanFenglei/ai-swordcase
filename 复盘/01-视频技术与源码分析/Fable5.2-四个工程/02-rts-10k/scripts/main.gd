extends Node3D
## Bootstrap, RTS controls, AI commander, demo director and the --shots benchmark runner.

const World := preload("res://scripts/world.gd")
const Sim := preload("res://scripts/sim.gd")
const Hud := preload("res://scripts/hud.gd")

var world: World
var sim: Sim
var cam: Camera3D
var hud: Hud
var mats: Array[ShaderMaterial] = []
var mode := "play"
var units_n := 20000
var max_n := 100000
var quitting := false
var xflags := ""
var split2 := true

# camera rig
var ct := Vector3(-60, 0, 0)
var cyaw := 0.0
var cpitch := 0.75
var cdist := 330.0
var cfov := 50.0
var alpha := 0.0

# reinforcements
var target_total := 0
var spawn_rate := 1600.0
var lat: Array[int] = [0, 0]
var spawn_carry := 0.0

# script
var events: Array = []
var ev_i := 0
var segs: Array = []
var seg_i := -1
var follow_id := -1
var dyn := Vector3.ZERO
var dyn_want := Vector3.ZERO
var dyn_t := 0.0
var loop_len := 112.0
var ramp_t0 := 74.0
var ramp_len := 24.0
var ai_next := 50.0
var ai_adv := false
var charge_t := 38.0
var red_front := 118.0
var red_start := 200.0

# play input
var drag_from := Vector2.ZERO
var dragging := false
var rotating := false
var groups := {}

# fps
var f_n := 0
var f_t := 0.0
var fps_show := 0.0
var rec := false
var rec_dt := PackedFloat32Array()
var rec_cpu := 0.0
var rec_gpu := 0.0
var rec_proc := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			mode = "demo"
		elif a == "--shots":
			mode = "shots"
		elif a.begins_with("--units="):
			units_n = clampi(int(a.get_slice("=", 1)), 200, 200000)
		elif a.begins_with("--bench="):
			mode = "bench"
			units_n = clampi(int(a.get_slice("=", 1)), 200, 400000)
		elif a.begins_with("--x="):
			xflags = a.get_slice("=", 1)
		elif a.begins_with("--max="):
			max_n = clampi(int(a.get_slice("=", 1)), 20000, 200000)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var t0 := Time.get_ticks_msec()
	world = World.new()
	add_child(world)
	world.build()
	var cap := units_n
	if mode == "demo" or mode == "shots":
		units_n = 20000
		cap = max_n
	max_n = maxi(max_n, units_n)
	sim = Sim.new()
	sim.setup(int(cap * 1.3) + 4096, world, mode == "play")
	sim.hook = _pre_tick
	var kinds: Array[float] = [0.0, 1.0, 2.0, 0.0]
	var umats: Array[ShaderMaterial] = []
	for t in Sim.NT:
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/unit.gdshader")
		m.set_shader_parameter("height_tex", world.height_tex)
		m.set_shader_parameter("kind", kinds[t])
		m.set_shader_parameter("usize", 1.22)
		m.set_shader_parameter("trim_b", Color(0.86, 0.80, 0.66))
		umats.append(m)
		mats.append(m)
	for c in sim.nchunks:
		sim.ch_nodes[c].material_override = umats[sim.c_type[c]]
		add_child(sim.ch_nodes[c])
	var am := ShaderMaterial.new()
	am.shader = load("res://shaders/arrow.gdshader")
	am.set_shader_parameter("height_tex", world.height_tex)
	_add_mm(sim.mm_arrow, am, false)
	var pm := ShaderMaterial.new()
	pm.shader = load("res://shaders/puff.gdshader")
	_add_mm(sim.mm_puff, pm, false)

	cam = Camera3D.new()
	cam.far = 5000.0
	cam.near = 0.5
	add_child(cam)
	cam.make_current()

	var mmat := ShaderMaterial.new()
	mmat.shader = load("res://shaders/minimap.gdshader")
	mmat.set_shader_parameter("base_tex", world.minimap_base)
	mmat.set_shader_parameter("unit_tex", sim.mm_tex)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)
	hud.build(mmat)

	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print("setup ms: ", Time.get_ticks_msec() - t0, "  capacity: ", sim.cap, "  threads: ", OS.get_processor_count(), "  viewport: ", get_viewport().size)
	if xflags.contains("noshadow"):
		world.sun.shadow_enabled = false
	if xflags.contains("ortho"):
		world.sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	if xflags.contains("nomsaa"):
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	if xflags.contains("noglow"):
		world.env.glow_enabled = false
	if xflags.contains("nofog"):
		world.env.fog_enabled = false
	_start()
	if xflags.contains("fastloop"):
		loop_len = 14.0
	if xflags.contains("quit"):
		_quit_after(float(xflags.get_slice("quit", 1)))
	if mode == "shots":
		_shots()
	elif mode == "bench":
		_bench()
	elif xflags.contains("selftest"):
		_selftest()


func _add_mm(mm: MultiMesh, m: ShaderMaterial, shadows: bool) -> void:
	var n := MultiMeshInstance3D.new()
	n.multimesh = mm
	n.material_override = m
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.extra_cull_margin = 2000.0
	add_child(n)
	mats.append(m)


func _start() -> void:
	target_total = 0
	ev_i = 0
	seg_i = -1
	events.clear()
	if mode == "bench":
		sim.spawn_army(0, units_n / 2, 34.0, Sim.O_HUNT)
		sim.spawn_army(1, units_n - units_n / 2, 104.0, Sim.O_HUNT)
		cam_override = 1
		ct = Vector3(10, 0, 0)
		cyaw = 0.0
		cpitch = deg_to_rad(44.0)
		cdist = 520.0
	elif mode == "play":
		sim.spawn_army(0, units_n / 2, -112.0, Sim.O_HOLD)
		sim.spawn_army(1, units_n - units_n / 2, 118.0, Sim.O_HOLD)
		ct = Vector3(-70, 0, 0)
		cdist = 300.0
		cpitch = 0.8
	else:
		sim.spawn_army(0, units_n / 2, -112.0, Sim.O_HOLD)
		sim.spawn_army(1, units_n - units_n / 2, red_start, Sim.O_HOLD)
		events = [
			[1.0, _march],
			[4.0, func() -> void: target_total = units_n],
			[charge_t, _advance],
			[charge_t + 13.0, _charge],
		]
		_build_segs()


func _slices(tm: int, ty: int, n: int, gx: float, dx: float) -> void:
	var w := 410.0 / n
	for k in n:
		var z0 := -205.0 + w * k
		sim.order_units(sim.ids_of(tm, ty, z0 if k > 0 else -1e9, z0 + w if k < n - 1 else 1e9), Sim.O_AMOVE, Vector2(gx, z0 + w * 0.5), w * 0.5, dx)


func _march() -> void:
	var bdx := 138.0
	var rdx := red_front - red_start
	for ty in 2:
		_slices(0, ty, 8 if ty == 0 else 4, -112.0 + bdx, bdx)
		_slices(1, ty, 6 if ty == 0 else 3, red_front, rdx)
	for sg: float in [-1.0, 1.0]:
		var z0 := -1e9 if sg < 0.0 else 0.0
		sim.order_units(sim.ids_of(0, 2, z0, z0 + 1e9), Sim.O_AMOVE, Vector2(-112.0 + bdx, sg * 245.0), 30.0, bdx)
		sim.order_units(sim.ids_of(1, 2, z0, z0 + 1e9), Sim.O_AMOVE, Vector2(red_front, sg * 245.0), 30.0, rdx)


func _advance() -> void:
	for ty in 2:
		_slices(0, ty, 8 if ty == 0 else 4, 72.0, 46.0)
		_slices(1, ty, 6 if ty == 0 else 3, 72.0, -46.0)
	for sg: float in [-1.0, 1.0]:
		var z0 := -1e9 if sg < 0.0 else 0.0
		sim.order_units(sim.ids_of(0, 2, z0, z0 + 1e9), Sim.O_AMOVE, Vector2(84.0, sg * 245.0), 30.0, 58.0)
		sim.order_units(sim.ids_of(1, 2, z0, z0 + 1e9), Sim.O_AMOVE, Vector2(60.0, sg * 245.0), 30.0, -58.0)


func _charge() -> void:
	sim.order_units(sim.ids_of(0), Sim.O_HUNT)
	sim.order_units(sim.ids_of(1), Sim.O_HUNT)


## Runs on the main thread while the sim thread is parked between two ticks.
func _pre_tick() -> void:
	var t := sim.sim_time
	while ev_i < events.size() and t >= events[ev_i][0]:
		(events[ev_i][1] as Callable).call()
		ev_i += 1
	if mode == "play":
		if not ai_adv and t >= 18.0:
			ai_adv = true
			for ty in 2:
				_slices(1, ty, 6 if ty == 0 else 3, 60.0, -58.0)
			sim.order_units(sim.ids_of(1, 2), Sim.O_HUNT)
		if t >= ai_next:
			ai_next = t + 6.0
			var ids := PackedInt32Array()
			for i in sim.ids_of(1):
				if sim.order[i] == Sim.O_HOLD:
					ids.append(i)
			sim.order_units(ids, Sim.O_HUNT)
		return
	if mode == "demo" and t >= ramp_t0:
		target_total = int(lerpf(units_n, max_n, clampf((t - ramp_t0) / ramp_len, 0.0, 1.0)))
	_reinforce()


func _reinforce() -> void:
	var tot := sim.alive[0] + sim.alive[1]
	if tot >= target_total:
		spawn_carry = 0.0
		return
	spawn_carry += spawn_rate * Sim.TICK
	var n := mini(int(spawn_carry), target_total - tot)
	spawn_carry -= n
	var made := 0
	var guard := 0
	while made < n and guard < n * 6:
		guard += 1
		var tm := 0 if sim.alive[0] <= sim.alive[1] else 1
		var k := lat[tm]
		lat[tm] = k + 1
		var col := (k / 440) % 22
		var row := k % 440
		var ty := 0 if k % 67 != 0 else 3
		if col % 5 == 3:
			ty = 1
		elif col % 5 == 4:
			ty = 2
			if row % 2 == 1:
				continue
		var x := (264.0 + col * 1.25) * (-1.0 if tm == 0 else 1.0)
		var z := -274.0 + row * 1.25
		if sim.spawn(tm, ty, x, z, 1.0 if tm == 0 else -1.0, 0.0, Sim.O_HUNT) >= 0:
			made += 1


# ---------------------------------------------------------------- camera

func _apply_cam() -> void:
	var cp := cos(cpitch)
	cam.position = ct + Vector3(-cp * cos(cyaw), sin(cpitch), -cp * sin(cyaw)) * cdist
	for q in world.rocks:
		var d := Vector2(cam.position.x - q.x, cam.position.z - q.y).length()
		if d < q.z * 1.6:
			var need := world.h_at(q.x, q.y) + q.z * clampf((1.6 - d / q.z) / 0.45, 0.0, 1.0) + 2.0
			if cam.position.y < need:
				cam.position.y = need
	cam.look_at(ct, Vector3.UP)
	cam.fov = cfov
	cam.near = clampf(cdist * 0.02, 0.2, 4.0)
	world.sun.directional_shadow_max_distance = clampf(cdist * 1.7 + 50.0, 70.0, 900.0)
	sim.cam_pos = cam.position
	sim.lod_dist = (0.0 if xflags.contains("nolod") else 135.0) * 0.4663 / tan(deg_to_rad(cfov * 0.5)) + (1e6 if xflags.contains("nolod") else 0.0)
	var ortho := cdist > (230.0 if split2 else 200.0)
	if ortho == split2:
		split2 = not ortho
		world.sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if split2 else DirectionalLight3D.SHADOW_ORTHOGONAL


func _ground(sp: Vector2) -> Vector3:
	var o := cam.project_ray_origin(sp)
	var d := cam.project_ray_normal(sp)
	var t := 2500.0
	if d.y < -0.02:
		t = minf(t, -o.y / d.y)
	var p := o + d * t
	return Vector3(clampf(p.x, -330.0, 330.0), 0.0, clampf(p.z, -330.0, 330.0))


func _clear(p: Vector2, yaw: float, dist: float) -> Vector2:
	# nudge a camera target along the front until no rock sits near it or between it and the camera
	var off := Vector2(-cos(yaw), -sin(yaw)) * dist
	for k in 11:
		var q := p + Vector2(0.0, (k + 1) / 2 * 18.0 * (1.0 if k % 2 == 1 else -1.0))
		var ok := true
		for r in world.rocks:
			var c := Vector2(r.x, r.y)
			for j in 4:
				if (q + off * (j / 3.0)).distance_to(c) < r.z * 1.3 + 9.0:
					ok = false
		if ok:
			return q
	return p


func _seg(t0: float, t1: float, a: Array, b: Array, kind := "") -> void:
	segs.append({"t0": t0, "t1": t1, "a": a, "b": b, "kind": kind})


func _build_segs() -> void:
	segs.clear()
	var bx := World.river_x(150.0)
	# [x, z, yaw, pitch deg, dist, fov]
	_seg(0.0, 9.0, [-150.0, 0.0, 0.0, 12.0, 110.0, 55.0], [-10.0, 0.0, 0.12, 30.0, 430.0, 50.0])
	_seg(9.0, 19.0, [bx - 6.0, 150.0, 0.55, 46.0, 105.0, 45.0], [bx + 4.0, 150.0, 1.05, 40.0, 72.0, 45.0])
	_seg(19.0, 27.0, [0.0, 0.0, 2.45, 7.0, 6.5, 50.0], [0.0, 0.0, 2.95, 10.0, 10.0, 50.0], "follow_ford")
	_seg(27.0, 38.0, [-45.0, 30.0, 0.0, 80.0, 300.0, 45.0], [-10.0, 0.0, 0.0, 76.0, 230.0, 45.0])
	_seg(38.0, 46.0, [30.0, 30.0, -0.22, 8.0, 70.0, 55.0], [60.0, 20.0, -0.3, 12.0, 60.0, 55.0])
	_seg(46.0, 58.0, [0.0, 0.0, 1.15, 24.0, 70.0, 48.0], [0.0, 0.0, 1.75, 18.0, 44.0, 48.0], "front")
	_seg(58.0, 66.0, [0.0, 0.0, 0.5, 9.0, 8.0, 50.0], [0.0, 0.0, 0.95, 12.0, 11.0, 50.0], "melee")
	_seg(66.0, 74.0, [0.0, 0.0, 0.0, 72.0, 200.0, 45.0], [0.0, 0.0, 0.25, 62.0, 150.0, 45.0], "front")
	_seg(74.0, 112.0, [20.0, 0.0, -0.25, 34.0, 420.0, 50.0], [0.0, 0.0, 0.3, 50.0, 640.0, 50.0])


func _demo_cam(t: float, dt: float) -> void:
	var si := 0
	for i in segs.size():
		if t >= segs[i].t0:
			si = i
	var s: Dictionary = segs[si]
	var cut := si != seg_i
	seg_i = si
	var k := clampf((t - s.t0) / (s.t1 - s.t0), 0.0, 1.0)
	k = lerpf(k, smoothstep(0.0, 1.0, k), 0.6)
	var a: Array = s.a
	var b: Array = s.b
	var tx := lerpf(a[0], b[0], k)
	var tz := lerpf(a[1], b[1], k)
	cyaw = lerpf(a[2], b[2], k)
	cpitch = deg_to_rad(lerpf(a[3], b[3], k))
	cdist = lerpf(a[4], b[4], k)
	cfov = lerpf(a[5], b[5], k)
	var kind: String = s.kind
	if kind == "":
		ct = Vector3(tx, 0.0, tz)
		return
	if kind == "front":
		dyn_t -= dt
		if cut or dyn_t <= 0.0:
			dyn_t = 0.4
			var fc := sim.hot_spot(Vector2(72, 0) if cut else Vector2(dyn_want.x, dyn_want.z))
			if cut:
				fc = _clear(fc, (s.a[2] + s.b[2]) * 0.5, s.a[4])
			dyn_want = Vector3(fc.x, 0.5, fc.y)
	else:
		if cut or follow_id < 0 or sim.state[follow_id] == 0 or sim.state[follow_id] == 4:
			if kind == "follow_ford":
				var p := Vector2(World.river_x(0.0) + 4.0, 0.0) if cut else Vector2(dyn.x, dyn.z)
				follow_id = sim.nearest_unit(p, 0, 80.0, 0)
			else:
				var fc := _clear(sim.hot_spot(Vector2(72, 0)), (s.a[2] + s.b[2]) * 0.5, s.b[4] + 6.0) if cut else Vector2(dyn.x, dyn.z)
				follow_id = sim.nearest_unit(fc, 0, 60.0, 0, Sim.ST_ATK)
				if follow_id < 0:
					follow_id = sim.nearest_unit(fc, -1, 80.0, 0)
		if follow_id >= 0:
			dyn_want = sim.unit_pos(follow_id, alpha) + Vector3(0, 1.3, 0)
	if cut:
		dyn = dyn_want
	dyn = dyn.lerp(dyn_want, 1.0 - exp(-dt * 5.0))
	ct = dyn


# ---------------------------------------------------------------- frame

func _process(dt: float) -> void:
	if quitting:
		return
	var p0 := Time.get_ticks_usec()
	alpha = sim.frame()
	var st := sim.shader_time(alpha)
	for m in mats:
		m.set_shader_parameter("alpha", alpha)
		m.set_shader_parameter("sim_time", st)
	if mode == "play":
		_play_cam(dt)
	else:
		var t := sim.sim_time
		if mode == "demo" and t >= loop_len:
			_restart()
			return
		if cam_override < 0 and mode != "bench":
			_demo_cam(st, dt)
	_apply_cam()

	f_n += 1
	f_t += dt
	if f_t >= 0.25:
		fps_show = f_n / f_t
		f_n = 0
		f_t = 0.0
		hud.fps_lbl.text = str(int(round(fps_show)))
	var a0 := sim.alive[0]
	var a1 := sim.alive[1]
	hud.units_lbl.text = Hud.fmt(a0 + a1)
	hud.blue_lbl.text = Hud.fmt(a0)
	hud.red_lbl.text = Hud.fmt(a1)
	hud.ratio = float(a0) / maxf(float(a0 + a1), 1.0)
	var vs := Vector2(get_viewport().size)
	var poly := PackedVector2Array()
	for c: Vector2 in [Vector2(0, 0), Vector2(vs.x, 0), vs, Vector2(0, vs.y)]:
		var g := _ground(c)
		poly.append(Vector2((g.x + 320.0) / 640.0, (g.z + 320.0) / 640.0))
	hud.view_poly = poly
	if mode == "play":
		hud.sel_lbl.text = "" if sim.selection.is_empty() else "已选 " + Hud.fmt(sim.selection.size())
		if sim.sim_time > 5.0 and (a0 == 0 or a1 == 0):
			hud.end_lbl.text = "胜利" if a1 == 0 else "失败"
	hud.queue_redraw()
	if rec:
		rec_dt.append(dt)
		var vp := get_viewport().get_viewport_rid()
		rec_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
		rec_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		rec_proc += float(Time.get_ticks_usec() - p0) * 0.001


func _restart() -> void:
	quitting = true
	sim.shutdown()
	get_tree().reload_current_scene()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit()


func _quit() -> void:
	if quitting:
		return
	quitting = true
	sim.shutdown()
	get_tree().quit()


# ---------------------------------------------------------------- play mode

func _play_cam(dt: float) -> void:
	var mv := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): mv.x += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): mv.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): mv.y += 1.0
	if Input.is_key_pressed(KEY_A) and not Input.is_key_pressed(KEY_CTRL): mv.y -= 1.0
	if Input.is_key_pressed(KEY_LEFT): mv.y -= 1.0
	if Input.is_key_pressed(KEY_Q): cyaw -= dt * 1.4
	if Input.is_key_pressed(KEY_E): cyaw += dt * 1.4
	var f := Vector3(cos(cyaw), 0, sin(cyaw))
	var r := Vector3(-sin(cyaw), 0, cos(cyaw))
	ct += (f * mv.x + r * mv.y) * dt * (cdist * 1.1 + 20.0)
	ct.x = clampf(ct.x, -300.0, 300.0)
	ct.z = clampf(ct.z, -300.0, 300.0)
	ct.y = 0.0


func _minimap_world(p: Vector2) -> Vector2:
	var r := Rect2(hud.minimap.position, hud.minimap.size)
	var u := (p - r.position) / r.size
	return Vector2(u.x * 640.0 - 320.0, u.y * 640.0 - 320.0)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		_quit()
		return
	if mode != "play" or quitting:
		return
	var on_map := Rect2(hud.minimap.position, hud.minimap.size).has_point(get_viewport().get_mouse_position())
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cdist = maxf(cdist * 0.88, 6.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cdist = minf(cdist * 1.14, 700.0)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			rotating = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if on_map:
					var w := _minimap_world(mb.position)
					ct = Vector3(w.x, 0, w.y)
				else:
					dragging = true
					drag_from = mb.position
					hud.drag = Rect2(mb.position, Vector2.ZERO)
					hud.dragging = true
			elif dragging:
				dragging = false
				hud.dragging = false
				var rc := Rect2(drag_from, mb.position - drag_from).abs()
				var ids: PackedInt32Array
				if rc.size.length() < 6.0:
					var g := _ground(mb.position)
					var i := sim.nearest_unit(Vector2(g.x, g.z), 0, 3.0 + cdist * 0.01)
					ids = PackedInt32Array([i]) if i >= 0 else PackedInt32Array()
				else:
					var q := PackedVector2Array()
					for c: Vector2 in [rc.position, Vector2(rc.end.x, rc.position.y), rc.end, Vector2(rc.position.x, rc.end.y)]:
						var g := _ground(c)
						q.append(Vector2(g.x, g.z))
					ids = sim.select_quad(q, 0)
				sim.set_selection(ids)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and not sim.selection.is_empty():
			var goal: Vector2
			if on_map:
				goal = _minimap_world(mb.position)
			else:
				var g := _ground(mb.position)
				goal = Vector2(g.x, g.z)
			sim.order_units(_live(sim.selection), Sim.O_AMOVE if mb.ctrl_pressed else Sim.O_MOVE, goal)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if dragging:
			hud.drag = Rect2(drag_from, mm.position - drag_from).abs()
		if rotating:
			cyaw += mm.relative.x * 0.005
			cpitch = clampf(cpitch + mm.relative.y * 0.004, 0.12, 1.5)
	elif e is InputEventKey and e.pressed and not e.echo:
		var k := e as InputEventKey
		if k.keycode == KEY_H:
			sim.order_units(_live(sim.selection), Sim.O_HOLD)
		elif k.keycode == KEY_F:
			sim.order_units(_live(sim.selection), Sim.O_HUNT)
		elif k.keycode == KEY_A and k.ctrl_pressed:
			sim.set_selection(sim.ids_of(0))
		elif k.keycode >= KEY_1 and k.keycode <= KEY_9:
			if k.ctrl_pressed:
				groups[k.keycode] = sim.selection.duplicate()
			elif groups.has(k.keycode):
				sim.set_selection(_live(groups[k.keycode]))


func _live(ids: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in ids:
		if sim.state[i] != 0 and sim.state[i] != 4 and sim.team[i] == 0:
			out.append(i)
	return out


# ---------------------------------------------------------------- --shots

var cam_override := -1
var results: Array = []


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := ProjectSettings.globalize_path("res://_shots")
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir + "/" + name + ".png")
	print("shot ", name, "  sim_t=", snappedf(sim.sim_time, 0.1), "  units=", sim.alive[0] + sim.alive[1])


func _until(t: float) -> void:
	while sim.sim_time < t:
		await get_tree().process_frame


func _wall(sec: float) -> void:
	var e := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < e:
		await get_tree().process_frame


func _click(btn: int, pos: Vector2, pressed: bool, ctrl := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = btn
	e.position = pos
	e.global_position = pos
	e.pressed = pressed
	e.ctrl_pressed = ctrl
	Input.parse_input_event(e)


func _key(code: Key, ctrl := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	e.ctrl_pressed = ctrl
	Input.parse_input_event(e)


## Drives the play-mode input paths with synthetic events (box select, groups, move, attack-move, hold, zoom).
func _selftest() -> void:
	await _wall(1.5)
	Input.warp_mouse(Vector2(900, 500))
	_click(MOUSE_BUTTON_LEFT, Vector2(500, 300), true)
	await _wall(0.2)
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(1300, 800)
	mm.relative = Vector2(800, 500)
	Input.parse_input_event(mm)
	await _wall(0.2)
	_click(MOUSE_BUTTON_LEFT, Vector2(1300, 800), false)
	await _wall(0.5)
	print("selftest box-selected: ", sim.selection.size())
	_key(KEY_1, true)
	await _wall(0.2)
	_click(MOUSE_BUTTON_RIGHT, Vector2(1100, 420), true)
	await _wall(6.0)
	await _shot("play_move")
	_key(KEY_A, true)
	await _wall(0.3)
	print("selftest select-all: ", sim.selection.size())
	_click(MOUSE_BUTTON_RIGHT, Vector2(1000, 300), true, true)
	await _wall(0.3)
	_key(KEY_1)
	await _wall(0.3)
	print("selftest group 1: ", sim.selection.size())
	_key(KEY_H)
	_click(MOUSE_BUTTON_WHEEL_UP, Vector2(960, 540), true)
	_click(MOUSE_BUTTON_LEFT, Vector2(180, 900), true)
	_click(MOUSE_BUTTON_LEFT, Vector2(180, 900), false)
	await _wall(1.0)
	_key(KEY_A, true)
	await _wall(0.3)
	_key(KEY_F)
	await _wall(20.0)
	await _shot("play_battle")
	print("selftest alive: ", sim.alive)
	_quit()


func _quit_after(sec: float) -> void:
	while Time.get_ticks_msec() < int(sec * 1000.0):
		await get_tree().process_frame
	print("timed quit at sim_t=", snappedf(sim.sim_time, 0.1), " fps=", snappedf(fps_show, 0.1))
	_quit()


func _bench() -> void:
	await _wall(1.0)
	if sim.alive[0] + sim.alive[1] < int(units_n * 0.97):
		# the formation area is full: pour the rest in from the map edges
		spawn_rate = 20000.0
		target_total = units_n
		var until := Time.get_ticks_msec() + 30000
		while sim.alive[0] + sim.alive[1] < int(units_n * 0.97) and Time.get_ticks_msec() < until:
			await get_tree().process_frame
	await _wall(3.0)
	await _measure("bench", 1.0, 5.0)
	_print_results()
	_quit()


func _measure(label: String, warm := 2.0, dur := 6.0) -> void:
	sim.speed = 1.0
	await _wall(warm)
	sim.take_stats()
	rec_dt.clear()
	rec_cpu = 0.0
	rec_gpu = 0.0
	rec_proc = 0.0
	var k0 := sim.flow_count
	var w0 := Time.get_ticks_usec()
	rec = true
	await _wall(dur)
	rec = false
	var wall := float(Time.get_ticks_usec() - w0) * 1e-6
	var s := sim.take_stats()
	var n := rec_dt.size()
	var sorted := rec_dt.duplicate()
	sorted.sort()
	var worst := sorted[n - 1]
	var p99 := sorted[int(n * 0.99)]
	s["label"] = label
	s["units"] = sim.alive[0] + sim.alive[1]
	s["fps"] = n / wall
	s["low1"] = 1.0 / p99
	s["min"] = 1.0 / worst
	s["cpu"] = rec_cpu / n
	s["gpu"] = rec_gpu / n
	s["proc"] = rec_proc / n
	s["hz"] = s.ticks / wall
	s["flow_hz"] = (sim.flow_count - k0) / wall
	results.append(s)
	print("measured ", label, ": ", snappedf(s.fps, 0.1), " fps")


func _grow(n: int) -> void:
	n = mini(n, max_n)
	spawn_rate = 9000.0
	target_total = n
	while sim.alive[0] + sim.alive[1] < n - 300:
		await get_tree().process_frame
	spawn_rate = 1600.0
	await _wall(5.0)


func _shots() -> void:
	sim.speed = 3.0
	await _until(8.6)
	await _shot("01_reveal")
	await _until(16.0)
	await _shot("02_bridge")
	await _until(24.0)
	await _shot("03_march_closeup")
	await _until(36.0)
	await _shot("04_topdown_flow")
	await _until(43.5)
	await _shot("05_charge")
	await _until(53.0)
	await _shot("06_frontline")
	await _until(62.0)
	await _shot("07_melee_closeup")
	await _until(71.0)
	await _shot("08_front_topdown")
	# benchmark: whole battlefield in view
	cam_override = 1
	ct = Vector3(10, 0, 0)
	cyaw = 0.0
	cpitch = deg_to_rad(44.0)
	cdist = 520.0
	cfov = 50.0
	await _measure("20k")
	await _shot("09_20k_wide")
	if max_n >= 50000:
		await _grow(50000)
		await _measure("50k")
		await _shot("10_50k_wide")
	if max_n >= 100000:
		await _grow(100000)
		await _measure("100k")
		await _shot("11_100k_wide")
	_print_results()
	_quit()


func _print_results() -> void:
	print("")
	print("units    fps   1%low   min | sim Hz  tick ms = grid + update(neigh/brain/move) + serial | upload  flow ms(Hz) | render cpu  gpu  script")
	for s: Dictionary in results:
		print("%6d  %5.1f  %5.1f  %5.1f | %5.1f  %6.2f = %4.2f + %6.2f (%5.2f/%5.2f/%5.2f) + %4.2f | %5.2f  %6.1f (%3.1f) | %5.2f  %5.2f  %5.2f" % [
			s.units, s.fps, s.low1, s.min, s.hz, s.tick, s.grid, s.update, s.neigh, s.brain, s.move, s.serial, s.upload, s.flow, s.flow_hz, s.cpu, s.gpu, s.proc])
