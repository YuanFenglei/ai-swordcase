extends Node3D
# Game flow: title -> play (collect cores, fight swarms) -> boss -> win / lose -> restart.

const Creature = preload("res://creature.gd")
const Boss = preload("res://boss.gd")
const Core = preload("res://core.gd")

enum { TITLE, PLAY, WIN, LOSE }
const CORES := 5
const START := Vector3(0, 0, 70)
const CORE_SITES := [Vector3(6, 0, -18), Vector3(-92, 0, -40), Vector3(84, 0, -88), Vector3(-66, 0, 92), Vector3(108, 0, 58)]

var state := TITLE
var targets: Array = []
var cores_got := 0
var site_live: Array = []
var boss_pending := -1.0
var trickle_t := 0.0
var end_t := 0.0
var cam_yaw := 0.0
var cam_pitch := 0.22
var cam_pos := Vector3.ZERO
var title_t := 0.0
var enemies: Node3D
var selftest := false
var test_t := 0.0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	G.main = self
	G.creatures.clear()
	G.cores.clear()
	G.obstacles.clear()
	G.boss = null
	G.world = load("res://world.gd").new()
	add_child(G.world)
	G.world.build()
	G.terrain = load("res://terrain.gd").new()
	add_child(G.terrain)
	G.terrain.build()
	G.scatter = load("res://scatter.gd").new()
	add_child(G.scatter)
	for s in CORE_SITES:
		G.scatter.keep_clear.append(Vector3(s.x, s.z, 7.0))
	G.scatter.keep_clear.append(Vector3(START.x, START.z, 8.0))
	G.scatter.build()
	G.fx = load("res://fx.gd").new()
	add_child(G.fx)
	G.fx.build()
	G.audio = load("res://audio.gd").new()
	add_child(G.audio)
	G.audio.build()
	enemies = Node3D.new()
	add_child(enemies)
	G.walker = load("res://walker.gd").new()
	add_child(G.walker)
	G.walker.build()
	G.cam = Camera3D.new()
	G.cam.fov = 62.0
	G.cam.near = 0.15
	G.cam.far = 5000.0
	add_child(G.cam)
	G.cam.make_current()
	G.hud = load("res://hud.gd").new()
	add_child(G.hud)
	G.hud.build()
	G.hud.start_pressed.connect(start_game)
	G.hud.quit_pressed.connect(func(): get_tree().quit())
	G.hud.retry_pressed.connect(start_game)
	Boss.resources()
	Creature.resources()
	Core.resources()
	if G.shots:
		print("boot ms: ", Time.get_ticks_msec() - t0)
	reset_game()
	if G.demo:
		G.director = load("res://director.gd").new()
		add_child(G.director)
		G.director.build()
	else:
		selftest = OS.get_cmdline_user_args().has("--selftest")
		_enter_title()


# ---------------------------------------------------------------- world state

func reset_game() -> void:
	for c in G.creatures:
		c.queue_free()
	G.creatures.clear()
	for c in G.cores:
		if is_instance_valid(c):
			c.queue_free()
	G.cores.clear()
	if G.boss != null:
		G.boss.queue_free()
		G.boss = null
	RenderingServer.global_shader_parameter_set(&"push_b", Vector3(0, -999, 0))
	G.fx.clear()
	G.fx.heat_target = 0.0
	G.world.mood_target = 0.0
	cores_got = 0
	boss_pending = -1.0
	trickle_t = 10.0
	site_live.clear()
	for s in CORE_SITES:
		spawn_core(s)
		site_live.append(true)
	G.walker.reset(START, 0.0)
	G.walker.ai = false
	G.walker.invuln = false
	G.audio.loop("beam", false)


func spawn_core(p: Vector3) -> Node3D:
	var c := Core.new()
	add_child(c)
	c.build(p)
	G.cores.append(c)
	return c


func spawn_creature(p: Vector3, big := false) -> void:
	var c := Creature.new()
	enemies.add_child(c)
	c.spawn(p, big)
	G.creatures.append(c)


func spawn_swarm(center: Vector3, n: int, rmin: float, rmax: float, bigs := 0) -> void:
	for i in n:
		var a := G.rng.randf() * TAU
		var r := G.rng.randf_range(rmin, rmax)
		spawn_creature(center + Vector3(cos(a) * r, 0, sin(a) * r), i < bigs)


func spawn_boss(at: Vector3, heading: Vector3, emerged := false) -> void:
	if G.boss != null:
		G.boss.queue_free()
	var b := Boss.new()
	add_child(b)
	G.boss = b
	b.build(at, heading)
	if emerged:
		b.emerge_t = 20.0
		b.state = "stalk"
		b.speed = 6.0
		for i in 3:
			b._update_body(0.2)
	else:
		var g := G.ground(at)
		G.fx.explode(g + Vector3(0, 1, 0), 4.0, G.C_MAGENTA)
		G.fx.ring(g, 40.0, 1.3, G.C_MAGENTA, 5.0)
		for k in 8:
			var a := TAU * k / 8.0
			G.fx.burst("dust_big", G.ground(g + Vector3(cos(a), 0, sin(a)) * 6.0, 1.0), Color(0.5, 0.32, 0.28, 0.7))
		G.fx.shake(1.0)
		G.audio.play("roar", g, 6.0, 1.0)
	G.audio.intensity = 3


func on_core(_c: Node3D) -> void:
	cores_got += 1
	G.walker.energy = minf(G.walker.energy + 45.0, G.walker.MAX_EN)
	G.walker.hp = minf(G.walker.hp + 25.0, G.walker.MAX_HP)
	if state == PLAY and cores_got >= CORES:
		boss_pending = 4.0


func on_boss_enrage() -> void:
	G.world.mood_target = 1.0
	G.fx.heat_target = 1.0
	G.audio.intensity = 3
	if not G.demo:
		spawn_swarm(G.walker.pos, 8, 24.0, 38.0, 1)


# ---------------------------------------------------------------- hit queries

func ray_hit(from: Vector3, dir: Vector3, maxd: float, _friendly: bool) -> Dictionary:
	var best := maxd
	var tgt = null
	for t in targets:
		if t.dead:
			continue
		var oc: Vector3 = t.pos - from
		var b := oc.dot(dir)
		if b < 0.0 or b - t.radius > best:
			continue
		var d2: float = oc.length_squared() - b * b
		var r2: float = t.radius * t.radius
		if d2 < r2:
			var th := b - sqrt(r2 - d2)
			if th < best and th > 0.0:
				best = th
				tgt = t
	# terrain march
	var d := 2.0
	var hit := tgt != null
	while d < best:
		var p := from + dir * d
		if p.y < G.h(p.x, p.z):
			var lo := d - 2.0
			var hi := d
			for k in 5:
				var m := (lo + hi) * 0.5
				var q := from + dir * m
				if q.y < G.h(q.x, q.z):
					hi = m
				else:
					lo = m
			best = hi
			tgt = null
			hit = true
			break
		d += 2.0
	return {"hit": hit, "pos": from + dir * best, "target": tgt}


func seg_hit(a: Vector3, b: Vector3, r: float):
	for t in targets:
		if t.dead:
			continue
		var c: Vector3 = t.pos
		var rr: float = t.radius + r
		var p := Geometry3D.get_closest_point_to_segment(c, a, b)
		if p.distance_squared_to(c) < rr * rr:
			return {"target": t, "pos": p}
	return null


# ---------------------------------------------------------------- flow

func _enter_title() -> void:
	state = TITLE
	title_t = 0.0
	G.hud.snap_hidden()
	G.hud.show_title(true)
	G.hud.cross.visible = false
	G.fx.bars_target = 1.0
	G.audio.intensity = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func start_game() -> void:
	reset_game()
	state = PLAY
	end_t = 0.0
	cam_yaw = 0.0
	cam_pitch = 0.22
	G.hud.show_title(false)
	G.hud.show_end(false)
	G.hud.show_bars(true)
	G.hud.show_boss(false)
	G.hud.cross.visible = true
	G.fx.bars_target = 0.0
	G.fx.fade_v = 0.0
	G.audio.intensity = 1
	if not selftest:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(ev: InputEvent) -> void:
	if G.demo:
		if ev is InputEventKey and ev.pressed and ev.physical_keycode == KEY_ESCAPE:
			get_tree().quit()
		return
	if ev is InputEventMouseMotion and state == PLAY and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		cam_yaw -= ev.relative.x * 0.0026
		cam_pitch = clampf(cam_pitch + ev.relative.y * 0.0022, -0.45, 1.1)
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.physical_keycode == KEY_ESCAPE:
			if state == TITLE:
				get_tree().quit()
			else:
				reset_game()
				_enter_title()
		elif ev.physical_keycode == KEY_ENTER and state != PLAY:
			start_game()
		elif ev.physical_keycode == KEY_SPACE and state == PLAY:
			G.walker.cmd_nova = true


func _process(dt: float) -> void:
	# prune dead creatures, refresh target list
	var i := G.creatures.size() - 1
	while i >= 0:
		var c = G.creatures[i]
		if c.gone:
			c.queue_free()
			G.creatures.remove_at(i)
		i -= 1
	targets.clear()
	for c in G.creatures:
		if not c.dead:
			targets.append(c)
	if G.boss != null and not G.boss.dead:
		targets.append_array(G.boss.parts)
	if G.demo:
		return
	var w = G.walker
	if selftest:
		_selftest(dt)
	match state:
		TITLE:
			title_t += dt
			var a := title_t * 0.12 + 2.4
			var c: Vector3 = w.center()
			var p := c + Vector3(sin(a) * 15.0, 1.0 + sin(title_t * 0.2) * 0.8, cos(a) * 15.0)
			p.y = maxf(p.y, G.h(p.x, p.z) + 0.8)
			G.cam.fov = 50.0
			G.cam.look_at_from_position(p, c + Vector3(0, 5.0, 0))
		PLAY:
			_play(dt)
		WIN, LOSE:
			end_t += dt
			_camera(dt, false)
	G.fx.apply_shake(G.cam)


func _play(dt: float) -> void:
	var w = G.walker
	_camera(dt, true)
	# swarms guarding each core
	for k in CORES:
		if site_live[k] and G.flat(w.pos - CORE_SITES[k]).length() < 52.0:
			site_live[k] = false
			spawn_swarm(CORE_SITES[k], 6 + cores_got * 2, 8.0, 22.0, 1 if cores_got >= 2 else 0)
	trickle_t -= dt
	if trickle_t <= 0.0 and cores_got > 0 and G.boss == null:
		trickle_t = 13.0
		if G.creatures.size() < 12:
			spawn_swarm(w.pos + w.fwd() * 10.0, 3, 30.0, 42.0)
	if G.boss == null:
		G.audio.intensity = 2 if G.creatures.size() > 0 else 1
	if boss_pending > 0.0:
		boss_pending -= dt
		G.fx.shake(0.12 * dt * 8.0)
		if boss_pending <= 0.0:
			var at: Vector3 = w.pos + w.fwd() * 58.0
			var r := Vector2(at.x, at.z).length()
			if r > 165.0:
				at *= 165.0 / r
			spawn_boss(at, w.pos - at)
			G.hud.show_boss(true)
	if G.boss != null and G.boss.gone:
		G.boss.queue_free()
		G.boss = null
		state = WIN
		end_t = 0.0
		G.audio.intensity = 0
		G.world.mood_target = 0.0
		G.fx.heat_target = 0.0
		G.hud.show_end(true, true)
		G.hud.show_bars(false)
		G.hud.show_boss(false)
		G.hud.cross.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif w.dead:
		end_t += dt
		if end_t > 2.6:
			state = LOSE
			G.audio.intensity = 0
			G.hud.show_end(true, false)
			G.hud.show_bars(false)
			G.hud.show_boss(false)
			G.hud.cross.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _selftest(dt: float) -> void:
	var prev := test_t
	test_t += dt
	var marks := {2.0: "ui_title", 9.0: "ui_play", 19.0: "ui_boss", 31.5: "ui_win", 37.0: "ui_lose"}
	for k in marks:
		if prev < k and test_t >= k:
			DirAccess.make_dir_absolute("res://_shots")
			get_viewport().get_texture().get_image().save_png("res://_shots/%s.png" % marks[k])
			print("selftest ", marks[k], " state=", state, " creatures=", G.creatures.size(), " hp=", G.walker.hp)
	if prev < 2.5 and test_t >= 2.5:
		start_game()
	if prev < 10.0 and test_t >= 10.0:
		cores_got = CORES
		boss_pending = 0.5
	if prev < 20.0 and test_t >= 20.0 and G.boss != null:
		G.boss.hp = 0.0
		G.boss.die()
	if prev < 32.0 and test_t >= 32.0:
		start_game()
	if prev < 32.5 and test_t >= 32.5:
		G.walker.damage(999.0, G.walker.pos + Vector3(1, 0, 0))
	if test_t > 37.5:
		print(G.audio.report())
		get_tree().quit()


func _camera(dt: float, control: bool) -> void:
	var w = G.walker
	if not control:
		cam_yaw += dt * 0.15
	var tgt: Vector3 = w.center() + Vector3(0, 2.0, 0)
	var rot := Basis(Vector3.UP, cam_yaw) * Basis(Vector3.RIGHT, -cam_pitch)
	var back := rot * Vector3(0, 0, 1)
	var right := rot * Vector3(1, 0, 0)
	var want := tgt + back * 12.5 + right * 2.4
	want.y = maxf(want.y, G.h(want.x, want.z) + 1.0)
	cam_pos = want if cam_pos == Vector3.ZERO else G.damp(cam_pos, want, 18.0, dt)
	var fwd := -back
	G.cam.fov = 62.0
	G.cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), cam_pos)
	if not control:
		return
	if selftest:
		w.ai = true
		w.face_aim = true
		var goal := Vector3.ZERO
		for c in G.cores:
			if is_instance_valid(c) and not c.taken:
				goal = c.base
				break
		w.cmd_move = G.flat(goal - w.pos).normalized()
		cam_yaw = lerp_angle(cam_yaw, w.yaw, dt * 2.0)
		return
	var f := G.flat(fwd).normalized()
	var r := Vector3(-f.z, 0, f.x)
	var mv := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		mv += f
	if Input.is_physical_key_pressed(KEY_S):
		mv -= f
	if Input.is_physical_key_pressed(KEY_D):
		mv += r
	if Input.is_physical_key_pressed(KEY_A):
		mv -= r
	w.cmd_move = mv
	w.cmd_sprint = Input.is_physical_key_pressed(KEY_SHIFT)
	w.face_aim = true
	var from := cam_pos + fwd * 13.0
	var hit := ray_hit(from, fwd, 230.0, true)
	w.cmd_aim = hit.pos
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	w.cmd_fire = captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	w.cmd_beam = captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
