extends Node3D
# Six-legged walker: procedural hull + turret, tripod gait on IK legs, spring-mounted hull, weapons.

const MB = preload("res://mb.gd")
const Leg = preload("res://leg.gd")

const RIDE := 1.95
const MAX_HP := 100.0
const MAX_EN := 100.0

var legs: Array = []
var hull: Node3D
var hull_mi: MeshInstance3D
var turret: Node3D
var barrels: Node3D
var barrel_mi: Array = []
var shield_mi: MeshInstance3D
var lamp: SpotLight3D
var glow: OmniLight3D
var muzzle_light: OmniLight3D
var beam: Node3D
var mat: ShaderMaterial
var mis: Array = []

var pos := Vector3.ZERO
var yaw := 0.0
var vel := Vector3.ZERO
var body_y := 0.0
var pitch := 0.0
var roll := 0.0
var spring := Vector3.ZERO
var spring_v := Vector3.ZERO
var kick := 0.0
var kick_v := 0.0
var t_yaw := 0.0
var t_pitch := 0.0
var recoil := [0.0, 0.0]

var cmd_move := Vector3.ZERO
var cmd_aim := Vector3(0, 0, -100)
var cmd_fire := false
var cmd_beam := false
var cmd_sprint := false
var face_aim := false
var ai := false
var ai_fire := true
var ai_target = null

var hp := MAX_HP
var energy := 50.0
var dead := false
var invuln := false
var fire_cd := 0.0
var barrel_i := 0
var beam_on := false
var beam_tick := 0.0
var flash_t := 0.0
var shield_t := 0.0
var step_count := 0
var idle_t := 0.0
var dissolve_t := 0.0
var hurt_t := 0.0
var nova_cd := 0.0
var cmd_nova := false


func build() -> void:
	mat = G.smat("surface", {"base_col": G.C_HULL, "accent_col": Color(1.0, 0.36, 0.06), "dark_col": G.C_HULL_DARK, "emit_col": G.C_CYAN,
		"emit_power": 5.0, "metal": 0.8, "rough": 0.38, "detail": 1.0, "rim_col": Color(0.25, 0.5, 0.7), "rim_power": 0.35})
	hull = Node3D.new()
	add_child(hull)
	hull_mi = _mi(hull, _hull_mesh())
	turret = Node3D.new()
	turret.position = Vector3(0, 0.66, 0.25)
	hull.add_child(turret)
	_mi(turret, _turret_mesh())
	barrels = Node3D.new()
	barrels.position = Vector3(0, 0.34, -0.25)
	turret.add_child(barrels)
	_mi(barrels, _emitter_mesh())
	var bm := _barrel_mesh()
	for s in [-1.0, 1.0]:
		var b := _mi(barrels, bm)
		b.position = Vector3(0.36 * s, 0, 0)
		barrel_mi.append(b)

	var lm := _leg_meshes()
	var mounts := [Vector3(0.88, -0.12, -1.35), Vector3(1.05, -0.12, 0.0), Vector3(0.88, -0.12, 1.35)]
	var rests := [Vector3(2.55, 0, -2.75), Vector3(3.25, 0, 0.05), Vector3(2.55, 0, 2.85)]
	for i in 3:
		for s in [-1.0, 1.0]:
			var l = Leg.new()
			l.setup(self, lm[0], lm[1], lm[2], mat)
			l.mount = mounts[i] * Vector3(s, 1, 1)
			l.rest = rests[i] * Vector3(s, 1, 1)
			l.side = s
			l.l0 = 0.55
			l.l1 = 1.9
			l.l2 = 2.7
			l.index = legs.size()
			# tripod: L-front, R-mid, L-rear vs R-front, L-mid, R-rear
			l.group = (i + (0 if s < 0.0 else 1)) % 2
			l.on_land = _on_land
			legs.append(l)
			mis.append_array(l.parts())

	shield_mi = MeshInstance3D.new()
	var sm := MB.new()
	sm.sphere(Vector3.ZERO, Vector3(3.3, 2.5, 3.9), 32, 20)
	shield_mi.mesh = sm.build()
	shield_mi.material_override = G.smat("shield", {"col": G.C_CYAN})
	shield_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shield_mi.visible = false
	add_child(shield_mi)

	lamp = SpotLight3D.new()
	lamp.position = Vector3(0, 0.05, -2.3)
	lamp.rotation.x = -0.28
	lamp.light_color = Color(0.7, 0.95, 1.0)
	lamp.light_energy = 5.0
	lamp.spot_range = 34.0
	lamp.spot_angle = 26.0
	lamp.spot_attenuation = 1.2
	lamp.light_volumetric_fog_energy = 3.0
	lamp.shadow_enabled = true
	hull.add_child(lamp)
	glow = OmniLight3D.new()
	glow.position = Vector3(0, -0.9, 0)
	glow.light_color = G.C_CYAN
	glow.light_energy = 1.6
	glow.omni_range = 6.0
	glow.light_volumetric_fog_energy = 0.0
	hull.add_child(glow)
	muzzle_light = OmniLight3D.new()
	muzzle_light.position = Vector3(0, 0, -2.2)
	muzzle_light.light_color = G.C_CYAN
	muzzle_light.light_energy = 0.0
	muzzle_light.omni_range = 14.0
	muzzle_light.light_volumetric_fog_energy = 0.5
	barrels.add_child(muzzle_light)
	beam = G.fx.make_beam(G.C_CYAN)
	reset(Vector3(0, 0, 60), 0.0)


func _mi(parent: Node3D, mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	mis.append(mi)
	return mi


func reset(p: Vector3, y: float) -> void:
	pos = G.ground(p)
	yaw = y
	vel = Vector3.ZERO
	hp = MAX_HP
	energy = 50.0
	dead = false
	dissolve_t = 0.0
	spring = Vector3.ZERO
	spring_v = Vector3.ZERO
	cmd_move = Vector3.ZERO
	cmd_fire = false
	cmd_beam = false
	ai_target = null
	body_y = pos.y + RIDE
	pitch = 0.0
	roll = 0.0
	var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, body_y, pos.z))
	for l in legs:
		var h: Vector3 = xf * l.rest
		l.foot = G.ground(h)
		l.stepping = false
	for m in mis:
		m.set_instance_shader_parameter(&"dissolve", 0.0)
		m.set_instance_shader_parameter(&"flash", 0.0)
		m.visible = true
	lamp.visible = true
	glow.visible = true
	cmd_aim = pos + Basis(Vector3.UP, yaw) * Vector3(0, 2, -60)
	_apply(0.016)


func fwd() -> Vector3:
	return Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)


func center() -> Vector3:
	return Vector3(pos.x, body_y, pos.z)


func _probe(p: Vector3) -> Vector3:
	return G.probe(p.x, p.z, body_y + 1.5, 9.0)


func _on_land(l) -> void:
	step_count += 1
	spring_v.y -= 0.55
	spring_v += (hull.global_basis.x * -l.side) * 0.12
	G.fx.burst("dust", l.foot + Vector3(0, 0.1, 0), Color(0.55, 0.36, 0.3, 0.5))
	G.audio.play("step", l.foot, -7.0, G.rng.randf_range(0.85, 1.15))


func damage(amount: float, from: Vector3) -> void:
	if dead:
		return
	shield_t = maxf(shield_t, 1.0 if amount >= 5.0 else 0.4)
	hurt_t = 0.0
	var d := (from - center()).normalized()
	shield_mi.set_instance_shader_parameter(&"hit_pos", global_basis.inverse() * d)
	spring_v -= d * 1.5
	if invuln:
		amount = minf(amount * 0.3, maxf(hp - 32.0, 0.0))
	hp -= amount
	flash_t = 0.6
	G.fx.hit_pulse(clampf(amount / 12.0, 0.25, 1.0))
	G.audio.play("hurt", center(), -4.0, G.rng.randf_range(0.9, 1.1))
	if hp <= 0.0:
		hp = 0.0
		dead = true
		G.fx.explode(center(), 3.0, G.C_CYAN)
		G.fx.explode(center() + Vector3(1, 0.5, 0), 2.0, G.C_ORANGE)
		lamp.visible = false
		glow.visible = false
		beam.visible = false
		G.audio.loop("beam", false)


func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(dt)
	G.prof["walker"] = G.prof.get("walker", 0) + Time.get_ticks_usec() - t0


func _tick(dt: float) -> void:
	if dt <= 0.0:
		return
	if ai and not dead:
		_think()
	if dead:
		cmd_move = Vector3.ZERO
		cmd_fire = false
		cmd_beam = false
		dissolve_t = minf(dissolve_t + dt * 0.3, 0.42)
		for m in mis:
			m.set_instance_shader_parameter(&"dissolve", dissolve_t)
	# --- locomotion
	var maxs := 13.5 if cmd_sprint else 8.5
	var want := G.flat(cmd_move)
	if want.length() > 1.0:
		want = want.normalized()
	want *= maxs
	vel = vel.move_toward(want, 26.0 * dt)
	var speed := vel.length()
	var want_yaw := yaw
	var aim_flat := G.flat(cmd_aim - pos)
	if (face_aim or cmd_fire or cmd_beam) and aim_flat.length() > 1.0:
		want_yaw = atan2(-aim_flat.x, -aim_flat.z)
	elif speed > 0.6:
		want_yaw = atan2(-vel.x, -vel.z)
	var dy := wrapf(want_yaw - yaw, -PI, PI)
	if not dead:
		yaw += clampf(dy, -2.2 * dt, 2.2 * dt)
	pos += vel * dt
	for o in G.obstacles:
		var dx: float = pos.x - o.x
		var dz: float = pos.z - o.y
		var rr: float = o.z + 1.6
		var d2 := dx * dx + dz * dz
		if d2 < rr * rr and d2 > 0.0001:
			var d := sqrt(d2)
			pos.x += dx / d * (rr - d)
			pos.z += dz / d * (rr - d)
	var r := Vector2(pos.x, pos.z).length()
	if r > G.ARENA_R:
		pos.x *= G.ARENA_R / r
		pos.z *= G.ARENA_R / r
	_apply(dt)
	_weapons(dt)


func _apply(dt: float) -> void:
	var speed := vel.length()
	var base := Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, body_y, pos.z))
	if not dead:
		var sp01 := clampf(speed / 13.5, 0.0, 1.0)
		var thr := lerpf(0.22, 1.25, clampf(speed / 3.0, 0.0, 1.0))
		Leg.schedule(legs, base, vel, thr, lerpf(0.27, 0.15, sp01), lerpf(0.55, 0.9, sp01), 1.5, _probe)
	var fy := 0.0
	var front := 0.0
	var back := 0.0
	var left := 0.0
	var right := 0.0
	for l in legs:
		l.advance(dt)
		var y: float = l.sto.y if l.stepping else l.foot.y
		fy += y
		if l.rest.z < -1.0:
			front += y * 0.5
		elif l.rest.z > 1.0:
			back += y * 0.5
		if l.side < 0.0:
			left += y / 3.0
		else:
			right += y / 3.0
	fy /= 6.0
	idle_t += dt
	var ride := RIDE + sin(idle_t * 1.7) * 0.04
	if dead:
		ride = 0.55
	var ty := maxf(fy + ride, G.h(pos.x, pos.z) + (0.5 if dead else 1.25))
	body_y = G.damp(body_y, ty, 3.0 if dead else 7.0, dt)
	var tp := atan2(front - back, 5.6) * 0.8
	var tr := atan2(right - left, 5.2) * 0.8
	# lean into acceleration
	var lv := Basis(Vector3.UP, -yaw) * vel
	tp += clampf(lv.z * 0.006, -0.08, 0.08)
	tr += clampf(-lv.x * 0.008, -0.08, 0.08)
	pitch = G.damp(pitch, tp, 6.0, dt)
	roll = G.damp(roll, tr, 6.0, dt)
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	global_transform = Transform3D(b, Vector3(pos.x, body_y, pos.z))
	# spring-mounted hull
	spring_v += (-spring * 90.0 - spring_v * 9.0) * dt
	spring += spring_v * dt
	spring = spring.limit_length(0.6)
	kick_v += (-kick * 120.0 - kick_v * 10.0) * dt
	kick += kick_v * dt
	hull.position = b.inverse() * spring
	hull.rotation = Vector3(kick, 0, spring.dot(b.x) * -0.25)
	var hx := hull.global_transform
	for l in legs:
		l.solve(hx)
	RenderingServer.global_shader_parameter_set(&"push_a", pos)


func _think() -> void:
	# pick the closest live target
	var best = null
	var bd := 95.0
	for t in G.main.targets:
		if t.dead:
			continue
		var d: float = (t.pos - pos).length() - t.prio
		if d < bd:
			bd = d
			best = t
	ai_target = best
	if ai_fire and nova_cd <= 0.0:
		var close := 0
		for t in G.main.targets:
			if not t.dead and not t.big and (t.pos - pos).length() < 9.0:
				close += 1
		if close >= 4:
			cmd_nova = true
	if best != null:
		var tp: Vector3 = best.pos
		var dist := (tp - center()).length()
		cmd_aim = tp + best.vel * (dist / 170.0)
		cmd_fire = ai_fire
		cmd_beam = ai_fire and energy > 15.0 and (best.big or dist < 28.0)
	else:
		cmd_fire = false
		cmd_beam = false
		if cmd_move.length() > 0.1:
			cmd_aim = center() + cmd_move.normalized() * 60.0 + Vector3(0, 1, 0)


func nova() -> void:
	# radial shock pulse: clears whatever is clinging to the hull
	if dead or nova_cd > 0.0 or energy < 30.0:
		return
	energy -= 30.0
	nova_cd = 4.0
	var c := center()
	G.fx.ring(G.ground(pos), 20.0, 0.55, G.C_CYAN, 3.0)
	G.fx.explode(c, 2.6, G.C_CYAN)
	G.fx.shock(c, 1.3)
	G.fx.white(0.1)
	shield_t = 1.0
	shield_mi.set_instance_shader_parameter(&"hit_pos", Vector3.UP)
	spring_v.y -= 3.5
	for t in G.main.targets.duplicate():
		if t.dead:
			continue
		var d: Vector3 = t.pos - c
		if d.length() < 15.0 + t.radius:
			t.damage(40.0 if t.big else 95.0, t.pos, d.normalized())


func muzzle(i: int) -> Vector3:
	return barrels.global_transform * Vector3((-0.36 if i == 0 else 0.36), 0.0, -2.15)


func _weapons(dt: float) -> void:
	# turret tracking
	var hb := hull.global_basis.orthonormalized()
	var local := hb.inverse() * (cmd_aim - turret.global_position)
	var ty := atan2(-local.x, -local.z)
	var tpch := clampf(atan2(local.y, Vector2(local.x, local.z).length()), -0.35, 0.9)
	t_yaw = lerp_angle(t_yaw, ty, 1.0 - exp(-9.0 * dt))
	t_pitch = lerpf(t_pitch, tpch, 1.0 - exp(-9.0 * dt))
	turret.rotation.y = t_yaw
	barrels.rotation.x = t_pitch
	for i in 2:
		recoil[i] = G.damp(recoil[i], 0.0, 14.0, dt)
		barrel_mi[i].position.z = recoil[i]
	muzzle_light.light_energy = G.damp(muzzle_light.light_energy, 0.0, 22.0, dt)
	flash_t = maxf(flash_t - dt * 3.0, 0.0)
	shield_t = maxf(shield_t - dt * 1.6, 0.0)
	shield_mi.visible = shield_t > 0.0
	if shield_t > 0.0:
		shield_mi.set_instance_shader_parameter(&"power", shield_t)
	hull_mi.set_instance_shader_parameter(&"flash", flash_t * 0.5)
	fire_cd -= dt
	nova_cd -= dt
	if dead:
		return
	if cmd_nova:
		cmd_nova = false
		nova()
	var aligned := absf(wrapf(ty - t_yaw, -PI, PI)) < 0.2
	if cmd_fire and fire_cd <= 0.0 and aligned:
		fire_cd = 0.14
		var m := muzzle(barrel_i)
		var dir := (cmd_aim - m).normalized()
		dir = (dir + Vector3(G.rng.randf_range(-1, 1), G.rng.randf_range(-1, 1), G.rng.randf_range(-1, 1)) * 0.008).normalized()
		G.fx.bolt(m, dir, 170.0, 12.0, true, G.C_CYAN)
		G.fx.burst("muzzle", m, G.C_CYAN, dir)
		recoil[barrel_i] = 0.45
		muzzle_light.light_energy = 9.0
		spring_v -= dir * 0.9
		kick_v += 1.1
		G.audio.play("shot", m, -6.0, G.rng.randf_range(0.94, 1.06))
		barrel_i = 1 - barrel_i
	# beam lance
	var want_beam := cmd_beam and energy > 0.5 and aligned
	if want_beam != beam_on:
		beam_on = want_beam
		G.audio.loop("beam", beam_on)
	beam.visible = beam_on
	if beam_on:
		energy = maxf(energy - 16.0 * dt, 0.0)
		var from := barrels.global_transform * Vector3(0, -0.02, -1.45)
		var dir := (cmd_aim - from).normalized()
		var hit: Dictionary = G.main.ray_hit(from, dir, 140.0, true)
		var endp: Vector3 = hit.pos
		beam.call(&"set_span", from, endp)
		muzzle_light.light_energy = maxf(muzzle_light.light_energy, 6.0)
		beam_tick -= dt
		if hit.target != null:
			hit.target.damage(70.0 * dt, endp, dir)
		if beam_tick <= 0.0:
			beam_tick = 0.045
			if hit.hit:
				G.fx.burst("spark", endp - dir * 0.3, G.C_CYAN, -dir)
				G.fx.flash(endp - dir * 2.2, G.C_CYAN, 1.1, 9.0, 0.12)
		spring_v -= dir * 2.0 * dt
	else:
		energy = minf(energy + 4.0 * dt, MAX_EN)
	hurt_t += dt
	if hurt_t > 5.0 and not invuln:
		hp = minf(hp + 2.0 * dt, MAX_HP)


# ---------------------------------------------------------------- meshes

func _sec(y: float, zoff: float, rz: float, rx: float, expo: float, m := 14) -> PackedVector3Array:
	return MB.ring(Vector3(0, y, zoff), Vector3(0, 0, 1), Vector3(1, 0, 0), rz, rx, m, expo)


func _leg_meshes() -> Array:
	var hullc := Color(0, 0, 0, 1)
	var dark := Color(0, 0, 1, 1)
	var acc := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	# coxa
	var c := MB.new()
	c.col = dark
	c.sphere(Vector3.ZERO, Vector3(0.3, 0.3, 0.3), 14, 9)
	c.col = hullc
	c.loft([_sec(0.1, 0.0, 0.2, 0.23, 4.0), _sec(0.3, 0.03, 0.25, 0.26, 4.0), _sec(0.5, 0.0, 0.19, 0.2, 4.0)], true, true)
	c.col = acc
	c.loft([_sec(0.24, 0.03, 0.262, 0.272, 4.0), _sec(0.36, 0.03, 0.26, 0.27, 4.0)], true, true)
	# femur
	var u := MB.new()
	u.col = dark
	u.sphere(Vector3.ZERO, Vector3(0.27, 0.27, 0.27), 14, 9)
	u.tube(PackedVector3Array([Vector3(0, 0.15, -0.22), Vector3(0, 1.6, -0.15)]), PackedFloat32Array([0.045, 0.045]), 8)
	u.tube(PackedVector3Array([Vector3(0, 0.15, -0.22), Vector3(0, 0.85, -0.19)]), PackedFloat32Array([0.075, 0.075]), 8)
	u.col = hullc
	u.loft([_sec(0.14, 0.0, 0.16, 0.14, 3.0), _sec(0.42, 0.07, 0.27, 0.2, 3.5), _sec(1.0, 0.08, 0.25, 0.185, 3.5),
		_sec(1.5, 0.04, 0.19, 0.15, 3.0), _sec(1.8, 0.0, 0.14, 0.125, 3.0)], true, true)
	u.col = acc
	u.loft([_sec(0.56, 0.075, 0.283, 0.212, 3.5), _sec(0.74, 0.08, 0.28, 0.21, 3.5)], true, true)
	u.col = emi
	u.tube(PackedVector3Array([Vector3(0, 0.92, 0.325), Vector3(0, 1.4, 0.245)]), PackedFloat32Array([0.03, 0.03]), 6)
	# tibia
	var t := MB.new()
	t.col = dark
	t.sphere(Vector3.ZERO, Vector3(0.24, 0.24, 0.24), 14, 9)
	t.col = acc
	t.loft([_sec(-0.2, 0.2, 0.1, 0.13, 3.0, 10), _sec(0.05, 0.27, 0.11, 0.17, 3.0, 10), _sec(0.32, 0.22, 0.07, 0.12, 3.0, 10)], true, true)
	t.col = hullc
	t.loft([_sec(0.1, 0.0, 0.15, 0.13, 3.0), _sec(0.5, 0.09, 0.21, 0.14, 3.0), _sec(1.2, 0.07, 0.15, 0.105, 3.0),
		_sec(2.0, 0.01, 0.085, 0.065, 2.5), _sec(2.5, -0.02, 0.045, 0.04, 2.0), _sec(2.7, 0.0, 0.012, 0.012, 2.0)], true, true)
	t.col = emi
	t.loft([_sec(1.28, 0.065, 0.158, 0.112, 3.0), _sec(1.38, 0.06, 0.15, 0.106, 3.0)], true, true)
	t.col = dark
	t.tube(PackedVector3Array([Vector3(0, 2.3, 0.03), Vector3(0, 2.52, 0.2), Vector3(0, 2.7, 0.3)]), PackedFloat32Array([0.04, 0.035, 0.008]), 6)
	t.tube(PackedVector3Array([Vector3(0, 2.3, -0.03), Vector3(0, 2.55, -0.16), Vector3(0, 2.7, -0.22)]), PackedFloat32Array([0.035, 0.03, 0.008]), 6)
	return [c.build(), u.build(), t.build()]


func _hsec(z: float, hw: float, hh: float, yc: float, expo: float) -> PackedVector3Array:
	return MB.ring(Vector3(0, yc, z), Vector3(1, 0, 0), Vector3(0, 1, 0), hw, hh, 28, expo)


func _hull_mesh() -> ArrayMesh:
	var mb := MB.new()
	var hullc := Color(0, 0, 0, 1)
	var dark := Color(0, 0, 1, 1)
	var acc := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	mb.col = hullc
	mb.loft([_hsec(-2.55, 0.2, 0.1, -0.06, 2.5), _hsec(-2.3, 0.5, 0.25, 0.0, 3.0), _hsec(-1.6, 0.92, 0.44, 0.05, 3.5),
		_hsec(-0.7, 1.1, 0.56, 0.1, 4.0), _hsec(0.4, 1.12, 0.6, 0.12, 4.0), _hsec(1.25, 0.96, 0.54, 0.1, 3.5),
		_hsec(1.85, 0.72, 0.42, 0.08, 3.0), _hsec(2.1, 0.45, 0.27, 0.06, 2.5)], true, true)
	# belly keel (dark)
	mb.col = dark
	mb.loft([_hsec(-1.9, 0.35, 0.2, -0.38, 3.0), _hsec(-0.8, 0.62, 0.3, -0.5, 3.0), _hsec(0.8, 0.62, 0.3, -0.5, 3.0), _hsec(1.7, 0.4, 0.2, -0.4, 3.0)], true, true)
	# dorsal armour plates
	mb.col = hullc
	mb.loft([_hsec(-1.5, 0.6, 0.12, 0.47, 5.0), _hsec(-0.9, 0.82, 0.14, 0.62, 5.0), _hsec(-0.45, 0.85, 0.14, 0.66, 5.0)], true, true)
	mb.loft([_hsec(0.95, 0.8, 0.13, 0.66, 5.0), _hsec(1.5, 0.7, 0.13, 0.58, 5.0), _hsec(1.95, 0.45, 0.1, 0.44, 5.0)], true, true)
	# accent stripes
	mb.col = acc
	mb.loft([_hsec(-1.25, 1.02, 0.5, 0.075, 3.7), _hsec(-1.05, 1.07, 0.53, 0.085, 3.8)], true, true)
	mb.loft([_hsec(1.42, 0.93, 0.52, 0.1, 3.4), _hsec(1.52, 0.9, 0.5, 0.095, 3.3)], true, true)
	# visor
	mb.col = emi
	for s in [-1.0, 1.0]:
		mb.xf = Transform3D(Basis(Vector3(0, 0, 1), -0.42 * s) * Basis(Vector3(0, 1, 0), -0.5 * s), Vector3(0.36 * s, 0.25, -2.02))
		mb.loft([MB.ring(Vector3(0, 0, -0.05), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.27, 0.035, 10, 3.0),
			MB.ring(Vector3(0, 0, 0.3), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.27, 0.045, 10, 3.0)], true, true)
	mb.xf = Transform3D.IDENTITY
	# shoulder pods + leg sockets
	for z in [-1.35, 0.0, 1.35]:
		for s in [-1.0, 1.0]:
			var x: float = (1.05 if z == 0.0 else 0.88) * s
			mb.col = hullc
			mb.sphere(Vector3(x * 0.93, 0.14, z), Vector3(0.36, 0.3, 0.46), 14, 9)
			mb.col = dark
			mb.sphere(Vector3(x, -0.12, z), Vector3(0.36, 0.36, 0.36), 12, 8)
	# rear thruster block with glowing slats, dorsal fin
	mb.col = dark
	mb.loft([_hsec(1.95, 0.66, 0.27, 0.2, 6.0), _hsec(2.42, 0.58, 0.22, 0.2, 6.0)], true, true)
	mb.col = emi
	for k in 3:
		var yy := 0.08 + k * 0.12
		mb.loft([MB.ring(Vector3(0, yy, 2.4), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.48, 0.026, 8, 6.0),
			MB.ring(Vector3(0, yy, 2.45), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.48, 0.026, 8, 6.0)], true, true)
	mb.col = acc
	mb.tube(PackedVector3Array([Vector3(0, 0.55, 0.9), Vector3(0, 1.05, 1.7), Vector3(0, 1.45, 2.5), Vector3(0, 1.6, 3.0)]),
		PackedFloat32Array([0.34, 0.26, 0.14, 0.02]), 8, true, true, true, 0.16, Vector3(1, 0, 0))
	# side vents
	mb.col = dark
	for s in [-1.0, 1.0]:
		for k in 3:
			var z0 := -0.7 + k * 0.28
			mb.loft([MB.ring(Vector3(1.09 * s, 0.28, z0), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.05, 0.16, 8, 6.0),
				MB.ring(Vector3(1.09 * s, 0.28, z0 + 0.14), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.05, 0.16, 8, 6.0)], true, true)
	# sensor mast + antennae
	mb.col = dark
	mb.tube(PackedVector3Array([Vector3(-0.55, 0.6, 1.5), Vector3(-0.6, 1.3, 1.7), Vector3(-0.68, 2.2, 2.05)]), PackedFloat32Array([0.035, 0.02, 0.008]), 6)
	mb.tube(PackedVector3Array([Vector3(0.55, 0.6, 1.5), Vector3(0.6, 1.1, 1.75), Vector3(0.66, 1.7, 2.1)]), PackedFloat32Array([0.035, 0.02, 0.008]), 6)
	mb.col = emi
	mb.sphere(Vector3(-0.68, 2.2, 2.05), Vector3(0.04, 0.04, 0.04), 6, 4)
	# nose prongs
	mb.col = dark
	for s in [-1.0, 1.0]:
		mb.tube(PackedVector3Array([Vector3(0.3 * s, -0.08, -2.2), Vector3(0.36 * s, -0.12, -2.7), Vector3(0.3 * s, -0.1, -3.05)]), PackedFloat32Array([0.07, 0.05, 0.012]), 7)
	return mb.build()


func _turret_mesh() -> ArrayMesh:
	var mb := MB.new()
	mb.col = Color(0, 0, 1, 1)
	mb.lathe(PackedVector2Array([Vector2(0.62, -0.1), Vector2(0.66, 0.0), Vector2(0.6, 0.1)]), 20, true, true, true)
	mb.col = Color(0, 0, 0, 1)
	var rings: Array = []
	for d in [[0.08, 0.58, 0.72], [0.3, 0.56, 0.7], [0.5, 0.42, 0.55], [0.6, 0.2, 0.3]]:
		rings.append(MB.ring(Vector3(0, d[0], 0.1), Vector3(0, 0, 1), Vector3(1, 0, 0), d[2], d[1], 20, 3.5))
	mb.loft(rings, true, true)
	mb.col = Color(1, 0, 0, 1)
	mb.loft([MB.ring(Vector3(0, 0.36, 0.1), Vector3(0, 0, 1), Vector3(1, 0, 0), 0.665, 0.535, 20, 3.5),
		MB.ring(Vector3(0, 0.42, 0.1), Vector3(0, 0, 1), Vector3(1, 0, 0), 0.62, 0.49, 20, 3.5)], true, true)
	mb.col = Color(0, 1, 0, 1)
	mb.sphere(Vector3(0, 0.62, 0.25), Vector3(0.09, 0.05, 0.09), 8, 5)
	return mb.build()


func _barrel_mesh() -> ArrayMesh:
	var mb := MB.new()
	mb.xf = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO)   # +Y -> -Z
	mb.col = Color(0, 0, 0, 1)
	mb.lathe(PackedVector2Array([Vector2(0.16, -0.5), Vector2(0.18, -0.4), Vector2(0.18, 0.5), Vector2(0.13, 0.6)]), 12, true, true, true)
	mb.col = Color(0, 0, 1, 1)
	mb.lathe(PackedVector2Array([Vector2(0.085, 0.6), Vector2(0.085, 1.85)]), 10)
	mb.lathe(PackedVector2Array([Vector2(0.11, 1.8), Vector2(0.135, 1.86), Vector2(0.135, 2.1), Vector2(0.09, 2.15), Vector2(0.06, 2.1)]), 10)
	mb.col = Color(0, 1, 0, 1)
	mb.lathe(PackedVector2Array([Vector2(0.105, 0.9), Vector2(0.105, 0.98)]), 10)
	mb.lathe(PackedVector2Array([Vector2(0.105, 1.3), Vector2(0.105, 1.38)]), 10)
	mb.lathe(PackedVector2Array([Vector2(0.06, 2.1), Vector2(0.005, 2.02)]), 10)
	return mb.build()


func _emitter_mesh() -> ArrayMesh:
	var mb := MB.new()
	mb.xf = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, -0.02, 0))
	mb.col = Color(0, 0, 1, 1)
	mb.lathe(PackedVector2Array([Vector2(0.2, -0.3), Vector2(0.24, 0.0), Vector2(0.2, 0.7), Vector2(0.14, 1.2), Vector2(0.17, 1.3), Vector2(0.17, 1.42), Vector2(0.1, 1.45)]), 12, true, true)
	mb.col = Color(0, 1, 0, 1)
	mb.lathe(PackedVector2Array([Vector2(0.1, 1.45), Vector2(0.005, 1.38)]), 12)
	mb.lathe(PackedVector2Array([Vector2(0.215, 0.3), Vector2(0.205, 0.5)]), 12)
	# cradle
	mb.xf = Transform3D.IDENTITY
	mb.col = Color(0, 0, 0, 1)
	mb.loft([MB.ring(Vector3(0, 0, 0.35), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.58, 0.2, 14, 4.0),
		MB.ring(Vector3(0, 0, -0.45), Vector3(1, 0, 0), Vector3(0, 1, 0), 0.58, 0.17, 14, 4.0)], true, true)
	return mb.build()
