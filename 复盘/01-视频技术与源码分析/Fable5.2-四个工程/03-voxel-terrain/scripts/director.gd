extends Node3D

# Scripted camera + set pieces for --demo and --shots.

const VoxelWorld := preload("res://scripts/voxel_world.gd")

const CAV := Vector3(232, 33, 285)
const MESA := Vector3(372, 0, 160)
const CHAIN_A := Vector3(355, 0, 368)
const CHAIN_B := Vector3(445, 0, 300)

var main: Node3D
var world: RefCounted
var fx: Node3D
var cam: Camera3D
var lamp: OmniLight3D
var head_light: OmniLight3D
var _fn := Callable()
var _t0 := 0.0
var _clock := 0.0
var _sun: Vector3
var _tun_e := Vector3.ZERO
var _tun_x := Vector3.ZERO
var _head := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _chain_y := PackedFloat32Array()
var _mesa_top := 66.0
var _df_t := 0.0
var _df_i := 0


func _ready() -> void:
	world = main.world
	fx = main.fx
	_sun = main.SUN_DIR.normalized()
	_rng.seed = 77
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.15
	cam.far = 3000.0
	add_child(cam)
	cam.make_current()
	lamp = OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.82, 0.62)
	lamp.omni_range = 24.0
	lamp.omni_attenuation = 1.2
	lamp.light_energy = 0.0
	lamp.shadow_enabled = true
	cam.add_child(lamp)
	head_light = OmniLight3D.new()
	head_light.light_color = Color(1.0, 0.62, 0.3)
	head_light.omni_range = 30.0
	head_light.light_energy = 0.0
	head_light.light_volumetric_fog_energy = 2.0
	add_child(head_light)
	_find_tunnel()
	_mesa_top = world.surface_y(MESA.x, MESA.z)
	if main.mode == "bench2":
		_run_bench2()
	elif main.mode == "bench":
		_run_bench()
	elif main.mode == "shots":
		_run_shots()
	elif main.mode == "texshots":
		_run_texshots()
	else:
		_run_demo()


func _process(dt: float) -> void:
	_clock += dt
	if main.demo_frames and main.mode == "demo":
		_df_t += dt
		if _df_t >= 3.0:
			_df_t = 0.0
			_df_i += 1
			_grab("demo_%02d" % _df_i)
	if _fn.is_valid():
		_fn.call(_clock - _t0)
	var sh: Vector3 = fx.shake_offset()
	cam.global_position += sh * 1.6
	cam.rotate_object_local(Vector3.FORWARD, sh.x * 0.035)
	cam.rotate_object_local(Vector3.RIGHT, sh.y * 0.02)


func _wait(s: float) -> void:
	await get_tree().create_timer(s, false).timeout


func _shot(fn: Callable, dur: float) -> void:
	_fn = fn
	_t0 = _clock
	fn.call(0.0)
	await _wait(dur)


func _settle(extra: float = 0.3) -> void:
	await get_tree().process_frame
	while world.busy():
		await get_tree().process_frame
	await _wait(extra)


func _look(pos: Vector3, target: Vector3) -> void:
	cam.global_position = pos
	if pos.distance_squared_to(target) > 0.01:
		var up := Vector3.UP
		if absf((target - pos).normalized().y) > 0.995:
			up = Vector3.FORWARD
		cam.look_at(target, up)


func _spl(pts: Array, u: float) -> Vector3:
	var n := pts.size() - 1
	var f := clampf(u, 0.0, 1.0) * n
	var i := mini(int(f), n - 1)
	var t := f - i
	var p0: Vector3 = pts[maxi(i - 1, 0)]
	var p1: Vector3 = pts[i]
	var p2: Vector3 = pts[i + 1]
	var p3: Vector3 = pts[mini(i + 2, n)]
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t)


func _ss(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


func _ground(p: Vector3, clearance: float) -> Vector3:
	var g: float = world.surface_y(p.x, p.z, p.y + 30.0)
	g = maxf(g, VoxelWorld.WATER)
	if p.y < g + clearance:
		p.y = g + clearance
	return p


func _sy(x: float, z: float) -> float:
	return world.surface_y(x, z)


func _find_tunnel() -> void:
	# a line through the mountain aimed straight at the sun; entry/exit are where the
	# line stays in open air for a good stretch (ignores small pockets and overhangs)
	var best := 0.0
	for hy in [100.0, 106.0, 94.0, 112.0, 88.0]:
		var pc := Vector3(165, hy, 165)
		var e := _open_point(pc, -_sun)
		var x := _open_point(pc, _sun)
		var clear := 0.0
		while clear < 60.0 and not world.solid(e - _sun * (clear + 4.0)) and (e - _sun * (clear + 4.0)).y > VoxelWorld.WATER + 4.0:
			clear += 4.0
		var score := clear + minf(e.distance_to(x), 110.0) * 0.3
		if score > best:
			best = score
			_tun_e = e
			_tun_x = x


func _open_point(from: Vector3, dir: Vector3) -> Vector3:
	var p := from
	var run := 0.0
	var start := from
	for i in 600:
		p += dir * 0.5
		if world.solid(p):
			run = 0.0
		else:
			if run == 0.0:
				start = p
			run += 0.5
			if run >= 26.0:
				return start
	return start


# ------------------------------------------------------------------ camera moves

const REVEAL := [Vector3(486, 27, 470), Vector3(446, 31, 432), Vector3(398, 56, 398), Vector3(352, 96, 372)]
const GORGE := [Vector3(6, 30, 429), Vector3(40, 30, 416), Vector3(72, 31, 405), Vector3(105, 33, 392), Vector3(128, 36, 372), Vector3(150, 40, 352), Vector3(164, 54, 326), Vector3(176, 86, 296)]
const CAVE := [Vector3(318, 114, 428), Vector3(303, 80, 408), Vector3(288, 46, 374), Vector3(266, 37, 348), Vector3(250, 35, 322), Vector3(238, 34.5, 302), Vector3(233, 35, 289)]


func _cam_reveal(t: float) -> void:
	var u := _ss(t / 9.0)
	var p := _ground(_spl(REVEAL, u), 3.5)
	_look(p, Vector3(300, 44, 310).lerp(Vector3(185, 78, 190), u))


func _cam_gorge(t: float) -> void:
	var u := clampf(t / 8.0, 0.0, 1.0)
	u = u * (0.6 + 0.4 * u)
	var p := _spl(GORGE, u)
	var ahead := _spl(GORGE, minf(u + 0.12, 1.0))
	if u > 0.8:
		ahead = ahead.lerp(Vector3(165, 110, 165), _ss((u - 0.8) / 0.2))
		ahead += Vector3(0.01, 0.0, 0.01)
	_look(p, ahead + (ahead - p).normalized() * 4.0)


func _cam_field(t: float) -> void:
	var top := _mesa_top
	var a := 0.75 + t * 0.085
	var r := lerpf(47.0, 33.0, _ss(t / 13.0))
	var p := Vector3(MESA.x + cos(a) * r, top + lerpf(17.0, 9.0, _ss(t / 13.0)), MESA.z + sin(a) * r)
	_look(p, Vector3(MESA.x, top + 1.0 - 3.0 * _ss(t / 13.0), MESA.z))


func _cam_tunnel_out(t: float) -> void:
	var side := _sun.cross(Vector3.UP).normalized()
	var p := _tun_e - _sun * (44.0 - t * 2.0) + side * 20.0 + Vector3(0, 6, 0)
	_look(_ground(p, 4.0), _tun_e + _sun * 4.0)


func _cam_tunnel_in(_t: float) -> void:
	var side := _sun.cross(Vector3.UP).normalized()
	var lenx := (_tun_x - _tun_e).dot(_sun)
	var s := minf((_head - _tun_e).dot(_sun) - 12.0, lenx - 17.0)
	var p := _tun_e + _sun * s + side * sin(_clock * 0.9) * 0.8 + Vector3(0, 0.4, 0)
	_look(p, p + _sun * 20.0 + side * sin(_clock * 0.9 + 1.0) * 0.6)


func _cam_tunnel_axis(t: float) -> void:
	var d := 14.0
	for i in 30:
		var q := _tun_e - _sun * (d + 8.0)
		if world.solid(q) or world.solid(q - Vector3(0, 3.5, 0)) or q.y < VoxelWorld.WATER + 3.0:
			break
		d += 4.0
	d = minf(d, 90.0)
	var p := _tun_e - _sun * maxf(d - 12.0 + t * 2.0, 6.0)
	_look(p, _tun_e + _sun * 30.0)


func _cam_cave(t: float) -> void:
	var u := clampf(t / 10.5, 0.0, 1.0)
	u = u * (1.25 - 0.25 * u)
	if t < 10.5:
		var p := _spl(CAVE, u)
		var ahead := _spl(CAVE, minf(u + 0.1, 1.0))
		if u > 0.85:
			ahead = ahead.lerp(CAV + Vector3(-18, -5, -10), _ss((u - 0.85) / 0.15))
		_look(p, ahead + (ahead - p).normalized() * 3.0 + Vector3(0.01, 0, 0))
	else:
		var k := t - 10.5
		var a := 1.3 + k * 0.22
		var p := Vector3(233, 35, 289) + Vector3(-k * 0.9, k * 0.25, -k * 0.7)
		var tg := (CAV + Vector3(-18, -5, -10)).lerp(CAV + Vector3(cos(a) * 26.0, -3.0, sin(a) * 22.0), _ss(k / 5.0) * 0.7)
		_look(p, tg)


func _cam_meteor(t: float) -> void:
	var u := _ss(t / 9.5)
	var p := Vector3(356, 118, 446).lerp(Vector3(322, 96, 408), u)
	_look(_ground(p, 8.0), Vector3(238, 50, 262))


func _cam_meteor_low(t: float) -> void:
	var x := 286.0
	var z := 336.0
	var p := Vector3(x + t * 1.2, _sy(x, z) + 4.5, z + t * 0.8)
	_look(_ground(p, 3.5), Vector3(232, p.y + 16.0, 268))


func _cam_chain(t: float) -> void:
	var dir := (CHAIN_B - CHAIN_A).normalized()
	var perp := Vector3(-dir.z, 0, dir.x)
	var base := CHAIN_B + dir * 24.0
	var gy := _sy(base.x, base.z)
	var k := _ss((t - 3.8) / 6.5)
	var k2 := _ss((t - 10.5) / 6.5)
	var p := Vector3(base.x, gy + 6.0, base.z) - dir * t * 0.7
	p += (perp * 46.0 + Vector3(0, 52, 0) + dir * 10.0) * k
	p += (-dir * 70.0 - perp * 30.0 + Vector3(0, -24, 0)) * k2
	var mid := (CHAIN_A + CHAIN_B) * 0.5
	var tg := Vector3(CHAIN_A.x, gy + 2.0, CHAIN_A.z).lerp(Vector3(mid.x, gy - 8.0, mid.z), k)
	tg = tg.lerp(Vector3(CHAIN_A.x, gy - 12.0, CHAIN_A.z), k2 * 0.6)
	_look(_ground(p, 4.0), tg)


func _cam_outro(t: float) -> void:
	var a := 0.9 + t * 0.045
	var p := Vector3(256 + cos(a) * 330.0, 150.0 + t * 3.0, 256 + sin(a) * 330.0)
	_look(p, Vector3(256, 30, 256))


func _cam_barrage(t: float) -> void:
	var a := 2.2 + t * 0.03
	var p := Vector3(240 + cos(a) * 150.0, 120.0, 250 + sin(a) * 150.0)
	_look(_ground(p, 10.0), Vector3(240, 45, 250))


# ------------------------------------------------------------------ actions

func _sweep(a: Vector3, b: Vector3, dur: float, r: float, op: int, show := true) -> void:
	var steps := int(a.distance_to(b) / (r * 0.42)) + 2
	for i in steps:
		var p := a.lerp(b, i / float(steps - 1))
		world.edit(op, p, r)
		if show:
			main.set_brush(p, r)
		if dur > 0.0:
			await _wait(dur / steps)
	if show:
		main.set_brush(Vector3(0, -1000, 0), 0.0)


func _collapse(speed: float) -> void:
	var top := _mesa_top
	var y := top - 3.0
	await _sweep(Vector3(MESA.x - 25, y, MESA.z - 9), Vector3(MESA.x + 25, y, MESA.z - 9), 3.0 * speed, 6.5, VoxelWorld.OP_DIG)
	await _sweep(Vector3(MESA.x + 25, y, MESA.z + 9), Vector3(MESA.x - 25, y, MESA.z + 9), 2.8 * speed, 6.5, VoxelWorld.OP_DIG)
	await _wait(0.6 * speed)
	await _sweep(Vector3(MESA.x - 23, y - 2.0, MESA.z), Vector3(MESA.x + 23, y - 2.0, MESA.z), 1.6 * speed, 8.5, VoxelWorld.OP_DIG)


func _bore(speed: float, r: float) -> void:
	var lenx := (_tun_x - _tun_e).dot(_sun)
	var s := -8.0
	var last := -100.0
	head_light.light_energy = 5.0
	var prev := Time.get_ticks_usec()
	var puff := 0.0
	while s < lenx + 9.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := minf((now - prev) / 1000000.0, 0.05)
		prev = now
		s += speed * dt
		_head = _tun_e + _sun * s
		head_light.global_position = _head - _sun * 3.0
		while last + 1.5 < s:
			last += 1.5
			world.edit(VoxelWorld.OP_DIG, _tun_e + _sun * last, r)
		puff -= dt
		if puff <= 0.0 and s < 5.0:
			puff = 0.2
			fx.puff(_head - _sun * 2.0, r * 0.9, -_sun)
	_head = _tun_e + _sun * (lenx + 9.0)
	head_light.light_energy = 0.0


func _chain(pass_i: int, interval: float) -> void:
	var n := 17
	if _chain_y.is_empty():
		for i in n:
			var p := CHAIN_A.lerp(CHAIN_B, i / float(n - 1))
			_chain_y.append(_sy(p.x, p.z))
	for i in n:
		var p := CHAIN_A.lerp(CHAIN_B, i / float(n - 1))
		var wob := sin(i * 0.9 + pass_i) * 2.5
		var dir := (CHAIN_B - CHAIN_A).normalized()
		p += Vector3(-dir.z, 0, dir.x) * wob
		p.y = _chain_y[i] - 2.0 - pass_i * 9.5
		fx.explode(p, 9.0 + pass_i * 0.8)
		if interval > 0.0:
			await _wait(interval)


func _barrage(dur: float, rate: float) -> void:
	var t := 0.0
	var acc := 0.0
	var prev := Time.get_ticks_usec()
	while t < dur:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - prev) / 1000000.0
		prev = now
		t += dt
		acc += dt * rate
		while acc >= 1.0:
			acc -= 1.0
			var a := _rng.randf() * TAU
			var rr := sqrt(_rng.randf()) * 95.0
			var x := 240.0 + cos(a) * rr
			var z := 250.0 + sin(a) * rr
			fx.explode(Vector3(x, _sy(x, z) - 1.0, z), 6.0 + _rng.randf() * 3.5)


# ------------------------------------------------------------------ demo

func _cut(fn: Callable) -> void:
	await main.fade(1.0, 0.22)
	_fn = fn
	_t0 = _clock
	fn.call(0.0)
	lamp.light_energy = 0.0
	await get_tree().process_frame
	main.fade(0.0, 0.3)


func _run_demo() -> void:
	main.set_fade(1.0)
	main.spawn_block_field(MESA, 7, 5, 4)
	_fn = _cam_reveal
	_t0 = _clock
	await _wait(1.0)
	_t0 = _clock
	main.fade(0.0, 1.6)
	await _wait(9.0)

	await _cut(_cam_gorge)
	await _wait(7.8)

	await _cut(_cam_field)
	await _wait(2.6)
	_collapse(1.0)
	await _wait(10.4)

	await _cut(_cam_tunnel_out)
	await _wait(1.0)
	_bore(21.0, 5.5)
	await _wait(1.7)
	_fn = _cam_tunnel_in
	lamp.light_energy = 1.2
	await _wait(8.6)
	lamp.light_energy = 0.0
	await _cut(_cam_tunnel_axis)
	await _wait(3.6)

	await _cut(_cam_cave)
	lamp.light_energy = 0.5
	await _wait(12.6)
	var hit: Variant = world.raycast(Vector3(226, 35, 284), Vector3(-0.85, -0.12, -0.5).normalized(), 60.0)
	if hit != null:
		fx.explode(hit, 5.5)
	await _wait(3.2)

	await _cut(_cam_meteor)
	await _wait(0.6)
	fx.meteor_shower(Vector3(238, 0, 266), 84.0, 16, 7.5)
	await _wait(9.6)
	_fn = _cam_meteor_low
	_t0 = _clock
	for i in 5:
		var a := -2.2 + i * 0.5
		var x := 262.0 + cos(a) * (26.0 + i * 9.0)
		var z := 306.0 + sin(a) * (26.0 + i * 9.0)
		fx.meteor(Vector3(x, _sy(x, z), z), 9.0 + i)
		await _wait(0.75)
	await _wait(2.0)

	await _cut(_cam_chain)
	await _wait(1.2)
	for i in 3:
		_chain(i, 0.11)
		await _wait(2.75)
	await _wait(7.6)

	await _cut(_cam_outro)
	await _wait(5.2)
	await main.fade(1.0, 1.0)
	if main.demo_frames:
		print("demo loop done, t=", _clock)
		get_tree().quit()
	else:
		get_tree().reload_current_scene()


# ------------------------------------------------------------------ shots

func _snap(nm: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_shots/%s.png" % nm)
	print("shot ", nm)


func _run_shots() -> void:
	main.set_fade(0.0)
	main.spawn_block_field(MESA, 7, 5, 4)
	_fn = Callable()
	_cam_reveal(7.2)
	await _wait(1.2)
	await _snap("01_reveal")
	_cam_gorge(2.6)
	await _wait(0.5)
	await _snap("02_gorge")
	_cam_gorge(5.6)
	await _wait(0.5)
	await _snap("02b_arch")

	_cam_field(3.0)
	await _wait(0.6)
	await _snap("03a_field")
	await _collapse(0.25)
	await _settle(2.4)
	_cam_field(9.0)
	await _wait(0.3)
	await _snap("03_collapse")

	_cam_tunnel_out(0.5)
	_bore(60.0, 5.5)
	await _wait(0.45)
	await _snap("04a_bore_start")
	_fn = _cam_tunnel_in
	lamp.light_energy = 1.2
	await _wait(0.9)
	await _snap("04b_bore_inside")
	await _wait(1.6)
	await _settle(0.6)
	await _snap("04_tunnel")
	_fn = Callable()
	lamp.light_energy = 0.0
	_cam_tunnel_axis(1.0)
	await _wait(0.5)
	await _snap("04c_tunnel_axis")

	lamp.light_energy = 0.5
	_cam_cave(5.0)
	await _wait(0.5)
	await _snap("05a_cave_tube")
	_cam_cave(12.5)
	await _wait(0.5)
	await _snap("05_cave")
	var hit: Variant = world.raycast(Vector3(226, 35, 284), Vector3(-0.85, -0.12, -0.5).normalized(), 60.0)
	if hit != null:
		fx.explode(hit, 5.5)
	await _wait(0.8)
	_cam_cave(14.5)
	await _wait(0.4)
	await _snap("05b_cave_blast")
	lamp.light_energy = 0.0

	_cam_meteor(4.0)
	fx.meteor_shower(Vector3(238, 0, 266), 84.0, 12, 2.4)
	await _wait(2.75)
	await _snap("06_meteor")
	await _wait(2.5)
	await _settle(0.3)
	_cam_meteor_low(1.0)
	fx.meteor(Vector3(250, _sy(250, 296), 296), 11.0)
	await _wait(1.83)
	await _snap("06b_meteor_low")
	await _settle(0.5)

	_fn = _cam_chain
	_t0 = _clock
	await _wait(0.3)
	_chain(0, 0.07)
	await _wait(1.45)
	await _snap("07_chain")
	await _wait(0.6)
	await _chain(1, 0.05)
	await _chain(2, 0.05)
	await _settle(1.5)
	_fn = Callable()
	_cam_chain(10.0)
	await _wait(0.5)
	await _snap("08_canyon")
	_cam_chain(16.5)
	await _wait(0.5)
	await _snap("08b_canyon_low")

	# measured barrage
	_fn = _cam_barrage
	_t0 = _clock
	await _settle(1.0)
	main.perf_begin()
	_barrage(10.0, 12.0)
	await _wait(8.0)
	var res: Dictionary = main.perf_end()
	await _wait(1.2)
	await _snap("09_barrage")
	await _wait(1.0)
	var w := world
	print("BARRAGE frames=%d avg_fps=%.1f worst_ms=%.2f p99_ms=%.2f p99.9_ms=%.2f frames_over_16.6=%d gpu_ms=%.2f render_cpu_ms=%.2f draws=%d prims=%d" % [res.frames, res.avg_fps, res.worst_ms, res.p99_ms, res.p999_ms, res.over_16, res.gpu_ms, res.cpu_ms, res.draws, res.prims])
	var slow: Array = res.slow
	slow.sort_custom(func(a, b): return a[0] > b[0])
	for i in mini(slow.size(), 6):
		print("  slow frame ms=%.1f apply=%.2f process=%.2f physics=%.2f gpu=%.2f rcpu=%.2f" % slow[i])
	print("PHYS shape ms total=%.1f" % (world.phys_usec / 1000.0))
	print("MESH jobs=%d avg_ms=%.2f max_ms=%.2f | APPLY avg_ms=%.3f max_ms=%.2f | EDIT avg_ms=%.2f (%d ops)" % [w.mesh_jobs, w.mesh_usec / 1000.0 / maxi(w.mesh_jobs, 1), w.mesh_usec_max / 1000.0, w.apply_usec_sum / 1000.0 / maxi(w.apply_frames, 1), w.apply_usec_max / 1000.0, w.edit_usec / 1000.0 / maxi(w.edit_ops, 1), w.edit_ops])
	print("WORLD voxels=%d chunks=%d active=%d tris=%d rebuilt_tris=%d rebuilt_chunks=%d threads=%d" % [VoxelWorld.NV, VoxelWorld.NCH, w.active_chunks, w.total_tris, w.stat_tris, w.stat_chunks, w.max_jobs])
	await _settle(0.5)
	_cam_outro(2.0)
	await _wait(0.6)
	await _snap("10_outro")
	get_tree().quit()


# ------------------------------------------------------------------ bench (A/B of render features)

func _measure(label: String) -> void:
	await _wait(0.5)
	var vp := get_viewport().get_viewport_rid()
	var n := 0
	var g := 0.0
	var c := 0.0
	var t0 := Time.get_ticks_usec()
	while n < 60:
		await get_tree().process_frame
		g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		c += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		n += 1
	var ft := (Time.get_ticks_usec() - t0) / 1000.0 / n
	print("BENCH %-22s frame=%.2f ms gpu=%.2f ms rcpu=%.2f ms" % [label, ft, g / n, c / n])


func _run_bench() -> void:
	main.set_fade(0.0)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_fn = _cam_barrage
	_t0 = _clock
	var env: Environment = main.env
	var sun: DirectionalLight3D = main.sun
	await _measure("baseline")
	env.volumetric_fog_enabled = false
	await _measure("no volumetric fog")
	env.volumetric_fog_enabled = true
	env.ssao_enabled = false
	await _measure("no ssao")
	env.ssao_enabled = true
	env.glow_enabled = false
	await _measure("no glow")
	env.glow_enabled = true
	sun.shadow_enabled = false
	await _measure("no sun shadow")
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	await _measure("2 shadow splits")
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	for l in main.glow_lights:
		l.visible = false
	await _measure("no glow lights")
	for l in main.glow_lights:
		l.visible = true
	main.terrain_mat.shader = load("res://shaders/flat.gdshader")
	await _measure("flat terrain shader")
	get_viewport().scaling_3d_scale = 0.5
	await _measure("flat + half res")
	get_viewport().scaling_3d_scale = 1.0
	await _measure("baseline again(flat)")
	get_tree().quit()


func _grab(nm: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(960, 540, Image.INTERPOLATE_BILINEAR)
	img.save_png("res://_shots/%s.png" % nm)


func _bar_measure(label: String) -> void:
	await _settle(2.5)
	main.perf_begin()
	_barrage(5.0, 12.0)
	await _wait(5.0)
	var r: Dictionary = main.perf_end()
	print("BAR %-16s avg_fps=%.1f worst=%.2f p99=%.2f over16=%d gpu=%.2f rcpu=%.2f apply_avg=%.2f apply_max=%.2f" % [label, r.avg_fps, r.worst_ms, r.p99_ms, r.over_16, r.gpu_ms, r.cpu_ms, world.apply_usec_sum / 1000.0 / maxi(world.apply_frames, 1), world.apply_usec_max / 1000.0])


func _run_bench2() -> void:
	main.set_fade(0.0)
	_fn = _cam_barrage
	_t0 = _clock
	await _bar_measure("warmup")
	await _bar_measure("baseline")
	fx.no_dust = true
	await _bar_measure("no dust")
	fx.no_dust = false
	fx.no_light = true
	await _bar_measure("no flash light")
	fx.no_light = false
	fx.no_debris = true
	await _bar_measure("no debris")
	fx.no_debris = false
	main.no_heat = true
	await _bar_measure("no heat")
	main.no_heat = false
	fx.no_dust = true
	fx.no_light = true
	fx.no_debris = true
	fx.no_spark = true
	main.no_heat = true
	await _bar_measure("edits only")
	get_tree().quit()


# Close-range surface checks: turf underfoot, a freshly cut bank, a rock face, a mid-distance slope.
func _run_texshots() -> void:
	main.set_fade(0.0)
	_fn = Callable()
	await _settle(0.5)
	var y := _mesa_top
	var c := Vector3(MESA.x, y, MESA.z)
	_look(c + Vector3(-3.0, 1.7, 4.0), c + Vector3(6.0, 0.0, -6.0))
	await _wait(0.6)
	await _snap("t1_turf_near")
	_look(c + Vector3(-14.0, 6.0, 16.0), c + Vector3(20.0, -2.0, -30.0))
	await _wait(0.4)
	await _snap("t2_turf_mid")
	await _sweep(c + Vector3(-8, -1.0, -6), c + Vector3(10, -1.0, -6), 0.0, 5.0, VoxelWorld.OP_DIG, false)
	await _settle(0.6)
	_look(c + Vector3(-6.0, 2.2, 3.5), c + Vector3(4.0, -3.0, -6.0))
	await _wait(0.4)
	await _snap("t3_cut_bank")
	_look(c + Vector3(1.0, -2.2, -3.0), c + Vector3(8.0, -3.5, -8.5))
	await _wait(0.4)
	await _snap("t4_cut_close")
	_cam_gorge(2.6)
	await _wait(0.5)
	await _snap("t5_rock_gorge")
	_cam_reveal(7.2)
	await _wait(0.8)
	await _snap("t6_reveal")
	get_tree().quit()
