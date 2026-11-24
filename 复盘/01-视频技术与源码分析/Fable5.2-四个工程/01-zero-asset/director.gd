extends Node
# Self-playing showcase: a timeline of scenes, each with its own setup, walker/boss direction and
# cinematic camera. `--shots` jumps between scenes, saves PNGs and reports FPS.

const SUN := Vector3(-0.62, 0.0, -0.72)

var scenes: Array = []
var si := -1
var st := 0.0
var sub := -1
var cut := true
var w
var cam: Camera3D
var attr: CameraAttributesPractical
var cp := Vector3.ZERO
var ct := Vector3.ZERO
var anchor := Vector3.ZERO
var anchor2 := Vector3.ZERO
var chase_dir := Vector3(0, 0, -1)
var flags := {}
var noise_t := 0.0
var only_scene := -1
var probe := 0.0
var probe_t := 0.0
var probe_n := 0
var demo_t := 0.0
# shots / fps
var shot_i := 0
var shot_total := 0
var frames := 0
var acc_t := 0.0
var warm := 0
var win_t := 0.0
var win_f := 0
var fps_min := 99999.0
var last_usec := 0
var gpu_acc := 0.0
var cpu_acc := 0.0
var proc_n := 0


func build() -> void:
	w = G.walker
	cam = G.cam
	attr = CameraAttributesPractical.new()
	attr.dof_blur_amount = 0.07
	cam.attributes = attr
	scenes = [
		{"dur": 6.0, "enter": _e_title, "update": _u_title, "shots": [3.6]},
		{"dur": 10.0, "enter": _e_reveal, "update": _u_reveal, "shots": [8.2]},
		{"dur": 14.0, "enter": _e_legs, "update": _u_legs, "shots": [2.6, 12.0]},
		{"dur": 7.0, "enter": _e_core, "update": _u_core, "shots": [5.95]},
		{"dur": 20.0, "enter": _e_swarm, "update": _u_swarm, "shots": [2.6, 7.2, 12.2]},
		{"dur": 14.0, "enter": _e_entrance, "update": _u_entrance, "shots": [5.2, 9.3, 12.6]},
		{"dur": 26.0, "enter": _e_fight, "update": _u_fight, "shots": [7.2, 10.75, 16.2, 24.6]},
		{"dur": 12.0, "enter": _e_victory, "update": _u_victory, "shots": [1.9, 8.6]},
	]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			only_scene = int(a.substr(8))
		if a.begins_with("--probe="):
			probe = float(a.substr(8))
			DirAccess.make_dir_absolute("res://_shots")
	if G.shots:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		DirAccess.make_dir_absolute("res://_shots")
		var f := FileAccess.open("res://_shots/.gdignore", FileAccess.WRITE)
		if f != null:
			f.close()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	G.hud.snap_hidden()
	G.hud.cross.visible = false
	G.fx.bars_target = 1.0
	G.fx.bars_v = 1.0
	last_usec = Time.get_ticks_usec()
	_goto(maxi(only_scene, 0), true)


func _goto(i: int, fresh: bool) -> void:
	si = i
	st = 0.0
	sub = -1
	cut = true
	flags.clear()
	shot_i = 0
	warm = 25
	Engine.time_scale = 1.0
	scenes[si].enter.call(fresh)


func _process(dt: float) -> void:
	var now := Time.get_ticks_usec()
	var real := (now - last_usec) / 1000000.0
	last_usec = now
	var vp := get_viewport().get_viewport_rid()
	gpu_acc += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	cpu_acc += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
	proc_n += 1
	if G.shots and real > 0.2 and warm == 0:
		print("  hitch %.2fs at scene %d t=%.2f (warm=%d)" % [real, si, st, warm])
	if warm > 0:
		warm -= 1
	else:
		frames += 1
		acc_t += real
		win_t += real
		win_f += 1
		if win_t >= 0.5:
			fps_min = minf(fps_min, win_f / win_t)
			win_t = 0.0
			win_f = 0
	st += dt
	noise_t += dt
	var sc: Dictionary = scenes[si]
	sc.update.call(dt)
	# handheld drift + shake
	var nz := Vector3(sin(noise_t * 0.9) + sin(noise_t * 2.3) * 0.5, sin(noise_t * 1.1 + 2.0) + sin(noise_t * 2.9) * 0.5, 0.0) * 0.035
	cp.y = maxf(cp.y, G.h(cp.x, cp.z) + 0.35)
	cam.look_at_from_position(cp, ct + nz * cp.distance_to(ct) * 0.05)
	G.fx.apply_shake(cam)
	cut = false
	# shots
	var shots: Array = sc.shots
	if G.shots and shot_i < shots.size() and st >= shots[shot_i]:
		shot_i += 1
		shot_total += 1
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://_shots/%02d_s%d_%d.png" % [shot_total, si, shot_i])
		last_usec = Time.get_ticks_usec()
		warm = 2
		print("shot %d  scene %d  t=%.1f  creatures=%d  skips=%d  fps=%.0f" % [shot_total, si, st, G.creatures.size(), G.audio.playback.get_skips(), Engine.get_frames_per_second()])
	if probe > 0.0:
		demo_t += dt
		probe_t += dt
		if probe_t >= probe:
			probe_t = 0.0
			probe_n += 1
			var pimg := get_viewport().get_texture().get_image()
			pimg.resize(960, 540)
			pimg.save_png("res://_shots/probe_%02d_s%d_t%03d.png" % [probe_n, si, int(demo_t)])
		if si == scenes.size() - 1 and st >= sc.dur - 0.05:
			print("probe loop done, demo length %.1f s" % demo_t)
			print(G.audio.report())
			get_tree().quit()
			return
	var done: bool = st >= sc.dur
	if G.shots and shot_i >= shots.size() and st >= shots[shots.size() - 1] + 0.25:
		done = true
	if done:
		if G.shots and (si == scenes.size() - 1 or only_scene >= 0):
			print("FPS avg %.1f  min(0.5s window) %.1f  frames %d  | viewport render time avg: gpu %.1f ms, cpu %.1f ms" % [frames / maxf(acc_t, 0.001), fps_min, frames, gpu_acc / maxf(proc_n, 1), cpu_acc / maxf(proc_n, 1)])
			var ps := "script ms/frame:"
			for k in G.prof:
				ps += " %s %.2f" % [k, G.prof[k] / 1000.0 / maxf(proc_n, 1)]
			print(ps)
			print(G.audio.report())
			get_tree().quit()
			return
		_goto((si + 1) % scenes.size(), G.shots or si == scenes.size() - 1)


# ---------------------------------------------------------------- helpers

func _sub(i: int) -> bool:
	if sub != i:
		sub = i
		cut = true
		return true
	return false


func _once(key: String, at: float) -> bool:
	if st >= at and not flags.has(key):
		flags[key] = true
		return true
	return false


func _cam(p: Vector3, tgt: Vector3, fov: float, stiff := 0.0, dt := 0.016) -> void:
	if cut or stiff <= 0.0:
		cp = p
		ct = tgt
	else:
		cp = G.damp(cp, p, stiff, dt)
		ct = G.damp(ct, tgt, stiff * 1.3, dt)
	cam.fov = fov


func _dof(far_dist := -1.0, trans := 20.0, near_dist := -1.0) -> void:
	attr.dof_blur_far_enabled = far_dist > 0.0
	if far_dist > 0.0:
		attr.dof_blur_far_distance = far_dist
		attr.dof_blur_far_transition = trans
	attr.dof_blur_near_enabled = near_dist > 0.0
	if near_dist > 0.0:
		attr.dof_blur_near_distance = near_dist
		attr.dof_blur_near_transition = near_dist * 0.8


func _go(tgt: Vector3, sp := 1.0, stop := 2.5) -> void:
	var d: Vector3 = G.flat(tgt - w.pos)
	if d.length() < stop:
		w.cmd_move = Vector3.ZERO
	else:
		w.cmd_move = d.normalized() * sp


func _place_walker(p: Vector3, yaw: float) -> void:
	var hp: float = w.hp
	var en: float = w.energy
	w.reset(p, yaw)
	w.hp = hp
	w.energy = en
	w.ai = true
	w.invuln = true


func _clear_enemies() -> void:
	for c in G.creatures:
		c.queue_free()
	G.creatures.clear()
	G.fx.clear()


func _clear_cores() -> void:
	for c in G.cores:
		if is_instance_valid(c):
			c.queue_free()
	G.cores.clear()


func _chase(dt: float, dist: float, height: float, side: float, look_ahead := 26.0) -> void:
	var aim: Vector3 = G.flat(w.cmd_aim - w.center())
	if aim.length() > 0.5:
		aim = aim.normalized()
		if cut:
			chase_dir = aim
		chase_dir = chase_dir.lerp(aim, 1.0 - exp(-2.2 * dt)).normalized()
	var right := Vector3(-chase_dir.z, 0, chase_dir.x)
	var c: Vector3 = w.center()
	_cam(c - chase_dir * dist + Vector3.UP * height + right * side, c + chase_dir * look_ahead + Vector3(0, 1.5, 0), 62.0, 7.0, dt)


# ---------------------------------------------------------------- 0 title

func _e_title(_fresh: bool) -> void:
	G.main.reset_game()
	G.hud.snap_hidden()
	G.hud.show_end(false)
	G.fx.fade_v = 1.0
	G.fx.bars_target = 1.0
	G.audio.intensity = 0
	G.world.mood_target = 0.0
	w.hp = w.MAX_HP
	_place_walker(Vector3(-8, 0, 150), 0.0)
	w.ai_fire = false
	w.face_aim = false
	w.cmd_sprint = false
	_dof()


func _u_title(dt: float) -> void:
	G.fx.fade_v = clampf(1.0 - st / 1.6, 0.0, 1.0)
	_go(Vector3(-6, 0, 60), 0.7)
	if _once("t_on", 1.0):
		G.hud.show_title(true, false)
	if _once("t_off", 4.4):
		G.hud.show_title(false)
	var p := Vector3(40.0 - st * 2.2, 0, 205.0 - st * 5.0)
	p.y = G.h(p.x, p.z) + 20.0 - st * 1.0
	_cam(p, Vector3(12, 46.0 - st * 1.5, 40), 52.0)


# ---------------------------------------------------------------- 1 landscape reveal

func _e_reveal(fresh: bool) -> void:
	if fresh:
		G.main.reset_game()
		_place_walker(Vector3(-8, 0, 120), 0.0)
	G.hud.show_title(false)
	G.fx.fade_v = 0.0
	G.audio.intensity = 1
	w.ai_fire = false


func _u_reveal(dt: float) -> void:
	_go(Vector3(-6, 0, 20), 0.75)
	var c: Vector3 = w.center()
	if st < 5.0:
		if _sub(0):
			anchor = G.ground(w.pos + w.fwd() * 21.0 + Vector3(-5.5, 0, 0))
		var k := smoothstep(0.0, 5.0, st)
		_cam(anchor + Vector3(0, 0.55 + k * 6.5, 0) + Vector3(-k * 3.0, 0, k * 2.0), c + Vector3(0, -0.3 + k * 1.5, 0), lerpf(34.0, 46.0, k), 5.0, dt)
		_dof(c.distance_to(cp) + 12.0, 40.0)
	else:
		_sub(1)
		var k := (st - 5.0) / 5.0
		var side := -SUN.normalized()
		_cam(c + side * (27.0 - k * 5.0) + Vector3(0, 0.4 + k * 1.2, 0) + w.fwd() * (6.0 - k * 4.0), c + Vector3(0, 2.5, 0) + w.fwd() * 3.0, 40.0, 6.0, dt)
		_dof(90.0, 80.0)


# ---------------------------------------------------------------- 2 walker close-up

func _e_legs(_fresh: bool) -> void:
	G.hud.show_title(false)
	G.fx.fade_v = 0.0
	_place_walker(Vector3(-30, 0, 66), 0.0)
	w.ai_fire = false
	w.face_aim = false
	G.audio.intensity = 1


func _u_legs(dt: float) -> void:
	_go(Vector3(-30, 0, -20), 0.52)
	var c: Vector3 = w.center()
	var f: Vector3 = w.fwd()
	var r := Vector3(-f.z, 0, f.x)
	if st < 5.0:
		_sub(0)
		var p: Vector3 = w.pos + r * 9.0 + f * (3.4 - st * 0.7)
		p.y = G.h(p.x, p.z) + 1.25
		_cam(p, G.ground(w.pos + f * 0.4, 1.3), 34.0, 9.0, dt)
		_dof(15.0, 12.0)
	elif st < 9.6:
		if _sub(1):
			anchor = G.ground(w.pos + f * 19.5 + r * 0.9, 0.7)
		var d := G.flat(w.pos - anchor).length()
		var tgt := c + Vector3(0, -0.4, 0)
		if d < 5.0:
			tgt = c + Vector3(0, 0.3, 0) - f * 1.0
		_cam(anchor, tgt, 58.0, 6.0, dt)
		_dof(30.0, 30.0)
	else:
		_sub(2)
		var a := 0.9 + (st - 9.6) * 0.42
		_cam(c + Vector3(sin(a) * 8.5, 5.2 - (st - 9.6) * 0.5, cos(a) * 8.5), c + Vector3(0, -0.4, 0), 50.0, 7.0, dt)
		_dof(20.0, 25.0)
		w.ai = false
		var sw := st * 1.5
		w.cmd_aim = c + Vector3(sin(sw) * 30.0, 3.0 + sin(sw * 0.7) * 5.0, cos(sw) * 30.0)
		w.cmd_fire = false
		w.cmd_beam = false


# ---------------------------------------------------------------- 3 core pickup

func _e_core(_fresh: bool) -> void:
	_clear_cores()
	_clear_enemies()
	G.main.cores_got = 0
	anchor = G.main.CORE_SITES[0]
	flags["core"] = G.main.spawn_core(anchor)
	_place_walker(anchor + Vector3(5, 0, 36), 0.0)
	w.ai_fire = false
	G.hud.show_bars(true)
	G.audio.intensity = 1


func _u_core(dt: float) -> void:
	var core = flags["core"]
	var cpos: Vector3 = G.ground(anchor, 3.2)
	_go(anchor, 0.8, 1.0)
	if _once("force", 5.75) and is_instance_valid(core):
		core.collect()
	var a := 0.75 + st * 0.2
	var k := smoothstep(2.0, 6.0, st)
	_cam(cpos + Vector3(sin(a) * (12.0 - k * 2.0), -1.6 + k * 1.0, cos(a) * (12.0 - k * 2.0)), cpos.lerp(w.center(), 0.25 + 0.3 * k), 46.0, 6.0, dt)
	_dof(45.0, 40.0)


# ---------------------------------------------------------------- 4 swarm fight

func _e_swarm(fresh: bool) -> void:
	_clear_cores()
	if fresh:
		_clear_enemies()
		_place_walker(G.main.CORE_SITES[0], 0.0)
		G.main.cores_got = 1
	w.ai = true
	w.ai_fire = true
	w.face_aim = true
	w.energy = w.MAX_EN
	G.hud.show_bars(true)
	G.audio.intensity = 2
	anchor = w.pos


func _u_swarm(dt: float) -> void:
	if _once("w1", 0.25):
		G.main.spawn_swarm(w.pos, 14, 30.0, 46.0, 1)
	if _once("w2", 3.6):
		G.main.spawn_swarm(w.pos, 10, 30.0, 46.0, 1)
	if _once("w3", 6.8):
		G.main.spawn_swarm(w.pos, 12, 28.0, 44.0, 2)
	if _once("w4", 10.0):
		G.main.spawn_swarm(w.pos, 12, 26.0, 42.0, 2)
	if _once("w5", 13.2):
		G.main.spawn_swarm(w.pos, 8, 24.0, 38.0, 1)
	w.energy = maxf(w.energy, 40.0)
	# slow circle strafe around the anchor
	var a := st * 0.35
	_go(anchor + Vector3(sin(a) * 9.0, 0, cos(a) * 9.0), 0.4, 1.0)
	if st > 17.2:
		for c in G.creatures:
			if not c.dead and G.rng.randf() < dt * 3.0:
				c.damage(200.0, c.pos, Vector3.UP)
	var c: Vector3 = w.center()
	if st < 4.0:
		_sub(0)
		_cam(c + Vector3(17.0 - st * 1.2, 13.0 - st * 0.8, 21.0), c + Vector3(0, -1, 0), 56.0, 5.0, dt)
		_dof()
	elif st < 10.0:
		_sub(1)
		_chase(dt, 12.0, 5.5, 3.0)
		_dof()
	elif st < 14.2:
		if _sub(2):
			anchor2 = G.ground(w.pos + Vector3(-13.0, 0, 9.0), 0.55)
		_cam(anchor2, c + Vector3(0, -0.5, 0), 38.0, 5.0, dt)
		_dof(c.distance_to(cp) + 10.0, 30.0)
	else:
		_sub(3)
		var b := 2.2 + (st - 14.2) * 0.4
		_cam(c + Vector3(sin(b) * 13.0, 4.5, cos(b) * 13.0), c + Vector3(0, 0.2, 0), 55.0, 6.0, dt)
		_dof()


# ---------------------------------------------------------------- 5 boss entrance

func _e_entrance(fresh: bool) -> void:
	_clear_cores()
	_clear_enemies()
	if fresh:
		_place_walker(G.main.CORE_SITES[0] + Vector3(0, 0, 4), 0.0)
	if G.boss != null:
		G.boss.queue_free()
		G.boss = null
	w.ai = true
	w.ai_fire = false
	w.face_aim = true
	w.cmd_move = Vector3.ZERO
	G.hud.show_bars(true)
	G.audio.intensity = 0
	w.hp = maxf(w.hp, 82.0)
	anchor = w.pos + Vector3(4.0, 0, -52.0)


func _u_entrance(dt: float) -> void:
	var c: Vector3 = w.center()
	w.cmd_move = Vector3.ZERO
	if st < 2.4:
		_sub(0)
		G.fx.shake(dt * 0.9)
		w.cmd_aim = G.ground(anchor, 3.0)
		if _once("d1", 0.8) or _once("d2", 1.5) or _once("d3", 2.0):
			G.fx.burst("dust_big", G.ground(anchor + Vector3(G.rng.randf_range(-6, 6), 0, G.rng.randf_range(-6, 6)), 0.5), Color(0.5, 0.32, 0.28, 0.7))
			G.audio.play("stomp", anchor, 2.0, 0.6)
		_cam(c + Vector3(3.6, 0.2 + st * 0.2, 9.5), G.ground(anchor, 5.0), 50.0, 5.0, dt)
		_dof()
		return
	if _once("boss", 2.4):
		G.main.spawn_boss(anchor, Vector3(-0.25, 0, 1))
		G.boss.passive = true
		G.boss.path_target = w.pos + Vector3(-46, 0, -24)
		G.world.mood_target = 0.3
	var b = G.boss
	w.cmd_aim = b.head()
	if _once("name", 7.6):
		G.hud.show_boss(true)
	if st < 7.2:
		_sub(1)
		var k := smoothstep(2.4, 7.2, st)
		_cam(c + Vector3(3.6 - k * 1.0, 0.7 + k * 0.6, 9.5 - k * 1.5), b.head().lerp(G.ground(anchor, 6.0), 0.4), lerpf(50.0, 38.0, k), 4.0, dt)
		_dof()
	elif st < 11.2:
		if _sub(2):
			var hd: Vector3 = b.head()
			anchor2 = G.ground(hd + b.dir * 17.0 + Vector3(b.dir.z, 0, -b.dir.x) * 2.5, 0.5)
		var k := clampi(int((st - 7.2) * 2.4), 0, 9)
		_cam(anchor2, b.seg_pos[k] + Vector3(0, 0.5, 0), 72.0, 4.0, dt)
		_dof()
	else:
		_sub(3)
		var mid: Vector3 = b.seg_pos[5]
		var k := (st - 11.2) / 2.8
		_cam(c + Vector3(7.0 + k * 2.0, 0.6, 12.0 - k * 2.0), mid.lerp(c, 0.25) + Vector3(0, 2.0, 0), 44.0, 5.0, dt)
		_dof()


# ---------------------------------------------------------------- 6 boss fight

func _e_fight(fresh: bool) -> void:
	_clear_cores()
	if fresh:
		_clear_enemies()
		_place_walker(G.main.CORE_SITES[0] + Vector3(0, 0, 4), 0.0)
		G.main.spawn_boss(w.pos + Vector3(-44, 0, -30), Vector3(-0.3, 0, 1), true)
		G.world.mood_target = 0.3
	var b = G.boss
	b.passive = true
	b.path_target = null
	w.ai = true
	w.ai_fire = true
	w.face_aim = true
	w.energy = w.MAX_EN
	G.hud.show_bars(true)
	G.hud.show_boss(true)
	G.audio.intensity = 3


func _u_fight(dt: float) -> void:
	var b = G.boss
	var c: Vector3 = w.center()
	var hd: Vector3 = b.head()
	w.energy = maxf(w.energy, 35.0)
	# scripted health so the fight lands on its beats
	var frac := 1.0
	if st < 14.6:
		frac = lerpf(1.0, 0.51, st / 14.6)
	elif st < 15.2:
		frac = 0.49
	else:
		frac = lerpf(0.49, 0.05, clampf((st - 18.6) / 7.2, 0.0, 1.0))
	b.hp = minf(b.hp, b.MAX_HP * frac)
	b.hp = maxf(b.hp, b.MAX_HP * 0.04)
	if _once("spit1", 2.6):
		b.force_attack = "spit"
	if st > 6.0 and st < 9.2:
		b.path_target = w.pos + G.flat(hd - w.pos).normalized() * 15.0
	else:
		b.path_target = null
	if _once("slam", 9.0):
		b.force_attack = "slam"
	if _once("brood", 17.2):
		G.main.spawn_swarm(w.pos, 9, 24.0, 36.0, 1)
	if _once("charge", 20.2):
		b.force_attack = "charge"
	if _once("spit2", 23.4):
		b.force_attack = "spit"
	# circle strafe relative to the boss head
	var away: Vector3 = G.flat(w.pos - hd)
	var dist := away.length()
	away = away.normalized()
	var tang := Vector3(away.z, 0, -away.x)
	var mv := tang * 0.55
	if dist < 24.0:
		mv += away * 0.7
	elif dist > 42.0:
		mv -= away * 0.4
	if G.flat(w.pos).length() > 120.0:
		mv -= G.flat(w.pos).normalized() * 0.8
	w.cmd_move = mv.limit_length(0.8)
	if st < 5.0:
		_sub(0)
		_chase(dt, 9.5, 3.6, 2.8, 30.0)
		_dof()
	elif st < 9.0:
		_sub(1)
		var mid := c.lerp(hd, 0.5)
		var a := 0.6 + (st - 5.0) * 0.16
		_cam(mid + Vector3(sin(a) * 44.0, 15.0, cos(a) * 44.0), mid + Vector3(0, 1, 0), 48.0, 4.0, dt)
		_dof()
	elif st < 13.2:
		_sub(2)
		var p: Vector3 = c + away * 11.0 + tang * 9.0
		p.y = G.h(p.x, p.z) + 0.9
		_cam(p, hd.lerp(c, 0.3) + Vector3(0, 2.0, 0), 60.0, 5.0, dt)
		_dof()
	elif st < 18.6:
		if _sub(3):
			anchor2 = hd + b.dir * 27.0 + Vector3(b.dir.z, 0, -b.dir.x) * 13.0
		var p: Vector3 = anchor2
		p.y = G.h(p.x, p.z) + 1.4
		_cam(p, hd + Vector3(0, 1.0, 0), 50.0, 3.0, dt)
		_dof()
	elif st < 22.2:
		_sub(4)
		_chase(dt, 9.0, 3.4, -2.8, 30.0)
		_dof()
	else:
		_sub(5)
		var a := 1.0 + (st - 22.2) * 0.3
		var mid := hd.lerp(c, 0.35)
		_cam(mid + Vector3(sin(a) * 24.0, 5.0, cos(a) * 24.0), mid + Vector3(0, 2.0, 0), 56.0, 4.0, dt)
		_dof()


# ---------------------------------------------------------------- 7 death + victory

func _e_victory(fresh: bool) -> void:
	_clear_cores()
	if fresh:
		_clear_enemies()
		_place_walker(G.main.CORE_SITES[0] + Vector3(0, 0, 4), 0.0)
		G.main.spawn_boss(w.pos + Vector3(-34, 0, -22), Vector3(0.6, 0, 1), true)
		G.world.mood = 1.0
		G.world.mood_target = 1.0
		G.hud.show_bars(true)
		G.hud.show_boss(true)
	var b = G.boss
	b.passive = true
	b.hp = 0.0
	b.die()
	w.ai_fire = false
	w.cmd_fire = false
	w.cmd_beam = false
	w.cmd_move = Vector3.ZERO
	anchor = b.seg_pos[7]


func _u_victory(dt: float) -> void:
	var c: Vector3 = w.center()
	w.cmd_move = Vector3.ZERO
	w.ai = false
	w.cmd_fire = false
	w.cmd_beam = false
	for cr in G.creatures:
		if not cr.dead and G.rng.randf() < dt * 2.0:
			cr.damage(200.0, cr.pos, Vector3.UP)
	if st < 5.6:
		_sub(0)
		if G.boss != null:
			w.cmd_aim = G.boss.head()
		Engine.time_scale = 0.45 if (st > 3.6 and st < 4.7) else 1.0
		var a := 0.4 + st * 0.12
		var foc: Vector3 = anchor.lerp(G.boss.head() if G.boss != null else anchor, clampf(st / 4.0, 0.0, 1.0))
		_cam(foc + Vector3(sin(a) * (66.0 - st * 3.0), 15.0, cos(a) * (66.0 - st * 3.0)), foc + Vector3(0, 2, 0), 50.0, 3.0, dt)
		_dof()
		return
	Engine.time_scale = 1.0
	_sub(1)
	if _once("calm", 5.6):
		G.world.mood_target = 0.0
		G.fx.heat_target = 0.0
		G.audio.intensity = 0
		G.hud.show_bars(false)
		G.hud.show_boss(false)
		w.cmd_aim = c + SUN.normalized() * -40.0 + Vector3(0, 6, 0)
	if _once("win", 6.6):
		G.hud.show_end(true, true, false)
	if _once("win_off", 10.4):
		G.hud.show_end(false)
	var k := (st - 5.6) / 6.4
	var side := -SUN.normalized()
	_cam(c + side * (12.5 - k * 2.5) + Vector3(-side.z, 0, side.x) * 2.5 + Vector3(0, -0.6, 0), c + Vector3(0, 1.4, 0), 44.0, 5.0, dt)
	_dof(60.0, 60.0)
	G.fx.fade_v = clampf((st - 10.8) / 1.1, 0.0, 1.0)
