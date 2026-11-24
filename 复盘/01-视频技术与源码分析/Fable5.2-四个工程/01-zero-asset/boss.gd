extends Node3D
# The brood-mother: a 16-segment centipede on 28 IK legs. The body is a drag chain behind the head,
# every leg raycasts its own footholds and steps in a metachronal wave.

const MB = preload("res://mb.gd")
const Leg = preload("res://leg.gd")

const SEGS := 16
const K := 1.55
const SPACING := 3.25
const BODY_H := 3.5

static var res := {}
const MAX_HP := 4200.0

class Part:
	var boss
	var idx := 0
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var radius := 2.0
	var dead := false
	var big := true
	var prio := 0.0
	func damage(amount: float, point: Vector3, dir: Vector3) -> void:
		boss.hit(idx, amount, point, dir)

var mat: ShaderMaterial
var seg_mi: Array = []
var seg_pos: Array = []
var seg_prev: Array = []
var seg_xf: Array = []
var seg_scale: Array = []
var seg_flash: Array = []
var seg_diss: Array = []
var seg_alive: Array = []
var seg_sag: Array = []
var legs: Array = []
var parts: Array = []
var mand: Array = []
var shield_mi: MeshInstance3D
var eye_light: OmniLight3D
var belly_lights: Array = []

var hp := MAX_HP
var state := "emerge"
var st := 0.0
var t := 0.0
var dir := Vector3(0, 0, 1)
var speed := 0.0
var rear := 0.0
var jaw := 0.0
var emerge_t := 0.0
var enraged := false
var dead := false
var gone := false
var invuln := false
var atk_cd := 4.0
var spit_n := 0
var spit_t := 0.0
var orbit_sign := 1.0
var die_i := 0
var die_t := 0.0
var contact_cd := 0.0
var stomp_n := 0
var shield_p := 0.0
var passive := false          # demo: no attacks unless told
var force_attack := ""
var path_target = null        # demo: steer toward this point instead of the walker


func build(at: Vector3, heading: Vector3) -> void:
	mat = G.smat("surface", {"base_col": Color(0.055, 0.035, 0.075), "accent_col": Color(0.66, 0.54, 0.44), "dark_col": Color(0.02, 0.018, 0.03),
		"emit_col": G.C_MAGENTA, "emit_power": 3.4, "metal": 0.55, "rough": 0.3, "organic": 1.0, "detail": 0.55, "rim_col": Color(0.45, 0.2, 0.9), "rim_power": 0.2})
	dir = G.flat(heading).normalized()
	var r := resources()
	var meshes: Array = r.meshes
	var lm: Array = r.legs
	for i in SEGS:
		var sc := 1.0
		if i == 0:
			sc = 1.0
		elif i > SEGS - 7:
			sc = lerpf(1.0, 0.5, float(i - (SEGS - 7)) / 6.0)
		sc *= K
		seg_scale.append(sc)
		var p := at - dir * SPACING * K * i
		p.y = G.h(p.x, p.z) - 12.0 * K
		seg_pos.append(p)
		seg_prev.append(p)
		seg_xf.append(Transform3D(Basis.IDENTITY, p))
		seg_flash.append(0.0)
		seg_diss.append(0.0)
		seg_alive.append(true)
		seg_sag.append(0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[0] if i == 0 else (meshes[3] if i == SEGS - 1 else meshes[1 + i % 2])
		mi.material_override = mat
		mi.top_level = true
		mi.set_instance_shader_parameter(&"seed", i * 3.7)
		add_child(mi)
		seg_mi.append(mi)
		var part := Part.new()
		part.boss = self
		part.idx = i
		part.radius = (2.9 if i == 0 else 2.2) * sc
		part.prio = 10.0 if i == 0 else 0.0
		parts.append(part)
		if i >= 1 and i <= SEGS - 2:
			for s in [-1.0, 1.0]:
				var l = Leg.new()
				l.setup(self, lm[0], lm[1], lm[2], mat)
				l.mount = Vector3(1.2 * s, -0.35, 0.0) * sc
				l.rest = Vector3(6.3 * s, 0, -0.9) * sc
				l.side = s
				l.l0 = 0.9
				l.l1 = 4.4
				l.l2 = 6.4
				l.index = i
				l.on_land = _on_land
				l.set_visible(false)
				l.set_param(&"seed", i * 1.3 + s)
				legs.append(l)
	# mandibles
	for s in [-1.0, 1.0]:
		var m := MeshInstance3D.new()
		m.mesh = r.mand[0 if s < 0.0 else 1]
		m.material_override = mat
		m.position = Vector3(0.85 * s, -0.45, -2.3)
		seg_mi[0].add_child(m)
		mand.append(m)
	shield_mi = MeshInstance3D.new()
	var sm := MB.new()
	sm.sphere(Vector3.ZERO, Vector3(17, 14, 17), 36, 22)
	shield_mi.mesh = sm.build()
	shield_mi.material_override = G.smat("shield", {"col": G.C_MAGENTA, "tile": 9.0})
	shield_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shield_mi.visible = false
	shield_mi.top_level = true
	add_child(shield_mi)
	eye_light = OmniLight3D.new()
	eye_light.light_color = G.C_MAGENTA
	eye_light.light_energy = 4.0
	eye_light.omni_range = 26.0
	eye_light.position = Vector3(0, -0.6, -2.6)
	seg_mi[0].add_child(eye_light)
	for i in [3, 7, 11]:
		var bl := OmniLight3D.new()
		bl.light_color = G.C_MAGENTA
		bl.light_energy = 3.0
		bl.omni_range = 12.0
		bl.position = Vector3(0, -1.6, 0)
		bl.light_volumetric_fog_energy = 0.3
		seg_mi[i].add_child(bl)
		belly_lights.append(bl)
	_update_body(0.016)


static func resources() -> Dictionary:
	if res.is_empty():
		res.meshes = [_head_mesh(), _seg_mesh(0), _seg_mesh(1), _tail_mesh()]
		res.legs = _leg_meshes()
		res.mand = [_mandible_mesh(-1.0), _mandible_mesh(1.0)]
	return res


func head() -> Vector3:
	return seg_pos[0]


func mouth() -> Vector3:
	return seg_xf[0] * (Vector3(0, -0.5, -3.0) * K)


func hit(i: int, amount: float, point: Vector3, _d: Vector3) -> void:
	if dead:
		return
	seg_flash[i] = maxf(seg_flash[i], clampf(amount / 30.0, 0.08, 0.45))
	if invuln or state == "emerge":
		shield_p = maxf(shield_p, 0.5 if invuln else 0.25)
		shield_mi.set_instance_shader_parameter(&"hit_pos", (point - shield_mi.global_position).normalized())
		return
	hp -= amount * (1.6 if i == 0 else 1.0)
	if G.rng.randf() < 0.25:
		G.fx.burst("glow", point, G.C_MAGENTA)
	if hp <= 0.0:
		hp = 0.0
		die()


func die() -> void:
	if dead:
		return
	dead = true
	state = "dying"
	st = 0.0
	die_i = SEGS - 1
	die_t = 0.6
	for p in parts:
		p.dead = true
	G.audio.play("roar", head(), 4.0, 0.7)
	G.fx.shake(0.6)


func _on_land(l) -> void:
	stomp_n += 1
	G.fx.burst("dust_big", l.foot + Vector3(0, 0.3, 0), Color(0.5, 0.32, 0.28, 0.55))
	if stomp_n % 2 == 0:
		G.audio.play("stomp", l.foot, -4.0, G.rng.randf_range(0.8, 1.1))
	G.fx.shake(0.07, l.foot)


func _probe(p: Vector3) -> Vector3:
	return G.probe(p.x, p.z, G.h(p.x, p.z) + 8.0, 16.0)


func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(dt)
	G.prof["boss"] = G.prof.get("boss", 0) + Time.get_ticks_usec() - t0


func _tick(dt: float) -> void:
	if dt <= 0.0:
		return
	t += dt
	st += dt
	var w = G.walker
	var hpos: Vector3 = seg_pos[0]
	var to_w: Vector3 = G.flat(w.pos - hpos)
	var dist := to_w.length()
	var want_dir := dir
	var want_speed := 0.0
	var turn := 0.9
	var base_speed := 12.0 if enraged else 9.0
	contact_cd -= dt
	var rear_target := 0.0
	var jaw_target := 0.25 + 0.15 * sin(t * 3.0)
	match state:
		"emerge":
			emerge_t += dt
			want_speed = 6.0
			jaw_target = 1.0
			if st < 0.1:
				pass
			if emerge_t > 5.2:
				_set_state("stalk")
		"stalk":
			want_speed = base_speed
			var tgt: Vector3 = w.pos
			if path_target != null:
				tgt = path_target
				to_w = G.flat(tgt - hpos)
				dist = to_w.length()
			if dist > 0.5:
				var dn := to_w / dist
				var side := Vector3(dn.z, 0, -dn.x) * orbit_sign
				var k := smoothstep(60.0, 30.0, dist) if path_target == null else 0.0
				want_dir = (dn * (1.0 - k * 0.85) + side * k).normalized()
				if dist < 20.0 and path_target == null:
					want_dir = (side - dn * 0.4).normalized()
			atk_cd -= dt
			var pick := force_attack
			force_attack = ""
			if pick == "" and atk_cd <= 0.0 and not passive and not w.dead:
				var r := G.rng.randf()
				if dist < 34.0 and r < 0.4:
					pick = "slam"
				elif r < 0.75:
					pick = "spit"
				else:
					pick = "charge"
			if pick != "":
				atk_cd = (3.2 if enraged else 4.6) + G.rng.randf() * 2.0
				_set_state(pick)
				if pick == "spit":
					spit_n = 7 if enraged else 5
					spit_t = 0.5
		"spit":
			want_speed = base_speed * 0.6
			if dist > 0.5:
				want_dir = to_w / dist
			jaw_target = 1.0
			rear_target = 0.35
			spit_t -= dt
			if spit_t <= 0.0 and spit_n > 0:
				spit_t = 0.22
				spit_n -= 1
				var from := mouth()
				var tp: Vector3 = w.center() + w.vel * 1.0 + Vector3(G.rng.randf_range(-5, 5), 0, G.rng.randf_range(-5, 5))
				var ft := clampf(from.distance_to(tp) / 30.0, 0.9, 2.4)
				var v := (tp - from) / ft + Vector3(0, 0.5 * 16.0 * ft, 0)
				G.fx.glob(from, v, 9.0, 0.6)
				G.fx.burst("glow", from, G.C_MAGENTA, v.normalized())
				G.audio.play("spit", from, 0.0, G.rng.randf_range(0.85, 1.15))
			if spit_n <= 0 and st > 2.0:
				_set_state("stalk")
		"charge":
			want_speed = base_speed * 1.75
			turn = 1.5
			jaw_target = 0.9
			if dist > 6.0:
				want_dir = to_w / dist
			if st > 4.5 or (st > 1.2 and dist < 7.0):
				orbit_sign = -orbit_sign
				_set_state("stalk")
		"slam":
			want_speed = 0.0
			if st < 1.3:
				rear_target = 1.0
				jaw_target = 1.0
			else:
				rear_target = 0.0
			if st >= 1.5 and st - dt < 1.5:
				var c: Vector3 = G.ground(hpos + dir * 2.0)
				G.fx.ring(c, 46.0, 1.1, G.C_MAGENTA if not enraged else G.C_ORANGE, 4.0)
				G.fx.explode(c + Vector3(0, 1, 0), 3.0, G.C_MAGENTA)
				G.fx.shock(c, 1.6)
				G.fx.shake(0.8, c)
				for k in 10:
					var a := TAU * k / 10.0
					G.fx.burst("dust_big", G.ground(c + Vector3(cos(a), 0, sin(a)) * 7.0, 0.5), Color(0.5, 0.32, 0.28, 0.6))
				var d := G.flat(w.pos - c).length()
				if d < 30.0:
					w.damage(16.0 * (1.0 - d / 34.0), c)
			if st > 2.4:
				_set_state("stalk")
		"enrage":
			want_speed = 0.0
			rear_target = 0.75
			jaw_target = 1.0
			invuln = true
			shield_p = maxf(shield_p, 0.3 + 0.12 * sin(t * 9.0))
			if st > 3.4:
				invuln = false
				_set_state("stalk")
				atk_cd = 1.5
		"dying":
			want_speed = 0.0
			jaw_target = 1.0
			die_t -= dt
			if die_t <= 0.0 and die_i >= 0:
				var p: Vector3 = seg_pos[die_i]
				seg_alive[die_i] = false
				if die_i == 0:
					G.fx.explode(p, 4.5, G.C_MAGENTA)
					G.fx.explode(p + Vector3(2, 1, 1), 3.0, G.C_ORANGE)
					G.fx.white(0.85)
					G.fx.shake(1.0)
					eye_light.visible = false
				else:
					G.fx.explode(p + Vector3(0, 0.5, 0), 2.6 if die_i % 3 == 0 else 1.9, G.C_MAGENTA if die_i % 2 == 0 else G.C_ORANGE)
				die_i -= 1
				die_t = 0.2
			if die_i < 0 and st > 7.0:
				gone = true
	# phase change
	if not enraged and not dead and hp < MAX_HP * 0.5 and state == "stalk":
		enraged = true
		_set_state("enrage")
		G.audio.play("roar", hpos, 6.0, 0.85)
		G.fx.shake(0.7)
		G.fx.shock(hpos, 1.2)
		G.fx.ring(G.ground(hpos), 45.0, 1.4, G.C_ORANGE, 5.0)
		mat.set_shader_parameter("emit_col", Color(1.0, 0.3, 0.08))
		mat.set_shader_parameter("emit_power", 4.6)
		eye_light.light_color = Color(1.0, 0.35, 0.1)
		for bl in belly_lights:
			bl.light_color = Color(1.0, 0.35, 0.1)
		G.main.on_boss_enrage()
	# steering
	var ang := dir.signed_angle_to(want_dir, Vector3.UP)
	dir = dir.rotated(Vector3.UP, clampf(ang, -turn * dt, turn * dt)).normalized()
	speed = move_toward(speed, want_speed, 9.0 * dt)
	rear = G.damp(rear, rear_target, 3.0 if rear_target > rear else 14.0, dt)
	jaw = G.damp(jaw, jaw_target, 8.0, dt)
	var hp2: Vector3 = seg_pos[0]
	var wig := Vector3(dir.z, 0, -dir.x) * sin(t * 1.4) * 0.35
	hp2 += (dir * speed + wig * speed * 0.12) * dt
	var rr := Vector2(hp2.x, hp2.z).length()
	if rr > G.ARENA_R + 20.0:
		hp2.x *= (G.ARENA_R + 20.0) / rr
		hp2.z *= (G.ARENA_R + 20.0) / rr
	seg_pos[0] = hp2
	_update_body(dt)
	# contact with the walker
	if not dead and state != "emerge" and not w.dead:
		for i in SEGS:
			var sp: Vector3 = seg_pos[i]
			var dx: Vector3 = G.flat(w.pos - sp)
			var lim: float = 2.4 * seg_scale[i] + 1.8
			if dx.length() < lim and absf(w.body_y - sp.y) < 5.0:
				w.pos += dx.normalized() * (lim - dx.length())
				if contact_cd <= 0.0:
					contact_cd = 0.5
					w.damage(7.0 if i == 0 else 3.5, sp)
	shield_p = maxf(shield_p - dt * 1.5, 0.0)
	shield_mi.visible = shield_p > 0.01
	if shield_mi.visible:
		shield_mi.global_position = seg_pos[1]
		shield_mi.set_instance_shader_parameter(&"power", shield_p)
	RenderingServer.global_shader_parameter_set(&"push_b", seg_pos[0])


func _set_state(s: String) -> void:
	state = s
	st = 0.0


func _update_body(dt: float) -> void:
	var moving := speed > 0.3
	# drag chain
	for i in range(1, SEGS):
		var a: Vector3 = seg_pos[i - 1]
		var b: Vector3 = seg_pos[i]
		var d := G.flat(b - a)
		if d.length() < 0.01:
			d = -dir
		var sp: float = SPACING * (seg_scale[i] + seg_scale[i - 1]) * 0.5
		var np := a + d.normalized() * sp
		seg_pos[i] = Vector3(np.x, b.y, np.z)
	# heights
	for i in SEGS:
		var p: Vector3 = seg_pos[i]
		var e := smoothstep(0.0, 1.0, clampf((emerge_t - i * 0.24) / 1.3, 0.0, 1.0))
		var sc: float = seg_scale[i]
		var bh := BODY_H * K * lerpf(0.75, 1.0, sc / K)
		if not seg_alive[i]:
			seg_sag[i] = minf(seg_sag[i] + dt * 1.6, 1.0)
		bh = lerpf(bh, 1.4, seg_sag[i])
		var ty := G.h(p.x, p.z) + bh + sin(t * 2.2 - i * 0.7) * 0.22 * (1.0 if moving else 0.4)
		if i < 7:
			ty += rear * pow(1.0 - i / 7.0, 1.4) * 14.0
		if state == "emerge":
			# arc out of the ground like a breaching whale
			ty += sin(e * PI) * 7.0 * (1.0 - i / float(SEGS)) - (1.0 - e) * 12.0 * K
			p.y = ty
		else:
			p.y = G.damp(p.y, ty, 6.0, dt)
		seg_pos[i] = p
	# transforms
	for i in SEGS:
		var p: Vector3 = seg_pos[i]
		var f: Vector3
		if i == 0:
			f = (p - seg_pos[1])
			f = (f.normalized() + dir * 1.2).normalized()
		elif i == SEGS - 1:
			f = seg_pos[i - 1] - p
		else:
			f = seg_pos[i - 1] - seg_pos[i + 1]
		f = f.normalized()
		var z := -f
		var x := Vector3.UP.cross(z)
		if x.length_squared() < 1e-4:
			x = Vector3.RIGHT
		x = x.normalized()
		var y := z.cross(x)
		var b := Basis(x, y, z)
		seg_xf[i] = Transform3D(b, p)
		var mi: MeshInstance3D = seg_mi[i]
		var sc: float = seg_scale[i]
		mi.global_transform = Transform3D(b * sc, p)
		var part: Part = parts[i]
		part.pos = p
		part.vel = (p - seg_prev[i]) / maxf(dt, 0.001)
		seg_prev[i] = p
		seg_flash[i] = maxf(seg_flash[i] - dt * 6.0, 0.0)
		mi.set_instance_shader_parameter(&"flash", seg_flash[i] * 0.6)
		if not seg_alive[i] and seg_diss[i] < 1.0:
			seg_diss[i] = minf(seg_diss[i] + dt * 0.45, 1.0)
			mi.set_instance_shader_parameter(&"dissolve", seg_diss[i])
			if i == 0:
				for m in mand:
					m.set_instance_shader_parameter(&"dissolve", seg_diss[i])
	for k in 2:
		mand[k].rotation = Vector3(0, (-0.75 * jaw + 0.15) * (-1.0 if k == 0 else 1.0), 0)
	# legs
	var n := legs.size()
	for li in n:
		var l = legs[li]
		var i: int = l.index
		var sc: float = seg_scale[i]
		var xf: Transform3D = seg_xf[i]
		var e := clampf((emerge_t - i * 0.24) / 1.3, 0.0, 1.0)
		var vis := e > 0.55
		var was: bool = l.upper_mi.visible
		if vis != was:
			l.set_visible(vis)
			if vis:
				l.foot = _probe(xf * l.rest)
				l.stepping = false
				if state == "emerge":
					G.fx.burst("dust_big", G.ground(xf.origin, 0.6), Color(0.5, 0.32, 0.28, 0.7))
					G.fx.burst("debris", G.ground(xf.origin, 0.6), Color.WHITE)
					G.fx.shake(0.25, xf.origin)
		if not vis:
			continue
		var pvel: Vector3 = parts[i].vel
		pvel.y = 0.0
		if not seg_alive[i]:
			l.set_param(&"dissolve", seg_diss[i])
			l.solve(xf, sc)
			continue
		var lifted: bool = i < 6 and rear > 0.25
		if lifted:
			# raised legs claw at the air
			var ph := t * 5.0 + i * 1.1 + (0.0 if l.side < 0.0 else PI)
			var air: Vector3 = xf * (Vector3(l.rest.x * 0.75, -1.0 + sin(ph) * 1.6, -3.5 + cos(ph) * 1.6))
			l.foot = l.foot.lerp(air, 1.0 - exp(-10.0 * dt))
			l.stepping = false
			l.free_t = 1.0
		else:
			if l.free_t > 0.0:
				l.free_t = -1.0
				l.begin_step(_probe(xf * l.rest), 0.14, 0.2)
			var home: Vector3 = xf * l.rest
			var err := Vector2(l.foot.x - home.x, l.foot.z - home.z).length()
			if not l.stepping and err > (2.5 if moving else 0.9) * sc:
				var ok := true
				# neighbours on the same side and the opposite leg must be planted
				if li >= 2 and legs[li - 2].stepping:
					ok = false
				if li + 2 < n and legs[li + 2].stepping:
					ok = false
				var opp: int = li + 1 if li % 2 == 0 else li - 1
				if legs[opp].stepping:
					ok = false
				if ok or err > 5.5 * sc:
					var sp := pvel.length()
					var lead := pvel * 0.3
					if sp > 0.1:
						lead += pvel / sp * minf(sp * 0.3, 2.6) * sc
					l.begin_step(_probe(home + lead), 0.24, 2.2 * sc)
			l.advance(dt)
		l.solve(xf, sc)
		if seg_flash[i] > 0.0:
			l.set_param(&"flash", seg_flash[i] * 0.4)


# ---------------------------------------------------------------- meshes

static func _zsec(z: float, hw: float, hh: float, yc: float, expo := 2.6, m := 18) -> PackedVector3Array:
	return MB.ring(Vector3(0, yc, z), Vector3(1, 0, 0), Vector3(0, 1, 0), hw, hh, m, expo)


static func _seg_mesh(variant: int) -> ArrayMesh:
	var mb := MB.new()
	var base := Color(0, 0, 0, 1)
	var plate := Color(0.22, 0, 0, 1)
	var bone := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	var dark := Color(0, 0, 1, 1)
	mb.col = dark
	mb.loft([_zsec(-1.9, 0.85, 0.7, -0.1), _zsec(-1.0, 1.2, 0.98, -0.05), _zsec(0.6, 1.25, 1.0, -0.05), _zsec(1.9, 0.9, 0.72, -0.1)], true, true)
	mb.col = plate
	mb.loft([_zsec(-2.15, 1.05, 0.34, 0.5, 2.4), _zsec(-1.2, 1.7, 0.6, 0.72, 2.4), _zsec(0.3, 1.85, 0.66, 0.78, 2.4),
		_zsec(1.5, 1.55, 0.5, 0.66, 2.4), _zsec(2.2, 0.95, 0.26, 0.42, 2.4)], true, true)
	mb.col = bone
	var hs := [1.5, 2.3, 1.3] if variant == 0 else [2.2, 3.4, 1.8]
	for k in 3:
		mb.prism(Vector3(0, 1.15, -1.0 + k * 1.0), Vector3(0, 1, 0.55), 0.22, hs[k] * 0.55, hs[k] * 0.6, 5)
	for s in [-1.0, 1.0]:
		mb.prism(Vector3(1.6 * s, 0.75, -0.5), Vector3(s, 0.55, 0.3), 0.17, 0.7, 0.9, 5)
		mb.prism(Vector3(1.55 * s, 0.7, 0.8), Vector3(s, 0.4, 0.5), 0.14, 0.5, 0.7, 5)
		# plate rim
		mb.tube(PackedVector3Array([Vector3(1.0 * s, 0.38, -2.1), Vector3(1.72 * s, 0.42, -1.1), Vector3(1.88 * s, 0.45, 0.3), Vector3(1.56 * s, 0.4, 1.5), Vector3(0.95 * s, 0.3, 2.15)]),
			PackedFloat32Array([0.07, 0.1, 0.11, 0.1, 0.06]), 6)
	mb.col = emi
	for s in [-1.0, 1.0]:
		mb.sphere(Vector3(1.12 * s, -0.42, 0.75), Vector3(0.42, 0.42, 0.52), 10, 7)
		mb.sphere(Vector3(1.0 * s, -0.5, -0.9), Vector3(0.3, 0.3, 0.36), 10, 7)
	mb.sphere(Vector3(0, -0.98, 0.0), Vector3(0.5, 0.3, 0.9), 10, 7)
	mb.col = dark
	for s in [-1.0, 1.0]:
		mb.sphere(Vector3(1.2 * s, -0.35, 0.0), Vector3(0.62, 0.62, 0.62), 10, 7)
	return mb.build()


static func _tail_mesh() -> ArrayMesh:
	var mb := MB.new()
	mb.col = Color(0, 0, 1, 1)
	mb.loft([_zsec(-1.9, 0.85, 0.7, -0.1), _zsec(-0.5, 1.15, 0.95, 0.0), _zsec(1.2, 0.8, 0.7, 0.2), _zsec(2.6, 0.3, 0.3, 0.6)], true, true)
	mb.col = Color(0.22, 0, 0, 1)
	mb.loft([_zsec(-2.1, 1.05, 0.34, 0.5, 2.4), _zsec(-0.8, 1.6, 0.58, 0.75, 2.4), _zsec(1.0, 1.2, 0.45, 0.8, 2.4), _zsec(2.4, 0.5, 0.2, 0.8, 2.4)], true, true)
	mb.col = Color(1, 0, 0, 1)
	for s in [-1.0, 1.0]:
		mb.tube(PackedVector3Array([Vector3(0.5 * s, 0.5, 2.0), Vector3(1.3 * s, 1.6, 4.2), Vector3(1.0 * s, 3.6, 6.4), Vector3(0.3 * s, 5.2, 6.6)]),
			PackedFloat32Array([0.32, 0.26, 0.16, 0.02]), 7)
	mb.prism(Vector3(0, 1.1, 0.0), Vector3(0, 1, 0.6), 0.25, 1.5, 1.6, 5)
	mb.col = Color(0, 1, 0, 1)
	mb.sphere(Vector3(0, 0.3, 2.5), Vector3(0.5, 0.5, 0.6), 10, 7)
	return mb.build()


static func _head_mesh() -> ArrayMesh:
	var mb := MB.new()
	var bone := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	mb.col = Color(0, 0, 1, 1)
	mb.loft([_zsec(-2.7, 0.5, 0.3, -0.5), _zsec(-1.6, 1.25, 0.7, -0.35), _zsec(0.0, 1.5, 0.95, -0.1), _zsec(1.8, 1.0, 0.8, -0.1)], true, true)
	mb.col = Color(0.22, 0, 0, 1)
	mb.loft([_zsec(-3.5, 0.2, 0.12, -0.15, 2.4), _zsec(-2.8, 0.95, 0.42, 0.05, 2.4), _zsec(-1.6, 1.65, 0.72, 0.35, 2.4), _zsec(-0.2, 2.0, 0.9, 0.62, 2.4),
		_zsec(1.1, 1.8, 0.8, 0.7, 2.4), _zsec(2.1, 1.2, 0.45, 0.55, 2.4)], true, true)
	mb.col = bone
	# crown of swept horns
	var horns := [[0.0, 3.6, 0.3], [0.75, 3.0, 0.26], [-0.75, 3.0, 0.26], [1.45, 2.2, 0.22], [-1.45, 2.2, 0.22]]
	for h in horns:
		var x: float = h[0]
		var ln: float = h[1]
		mb.tube(PackedVector3Array([Vector3(x, 1.0, 0.2), Vector3(x * 1.25, 1.0 + ln * 0.4, 0.9), Vector3(x * 1.45, 1.0 + ln * 0.75, 2.2), Vector3(x * 1.5, 1.0 + ln * 0.85, 3.6)]),
			PackedFloat32Array([h[2], h[2] * 0.85, h[2] * 0.5, 0.02]), 7)
	for s in [-1.0, 1.0]:
		mb.prism(Vector3(1.75 * s, 0.4, -0.6), Vector3(s, 0.2, 0.5), 0.2, 0.9, 1.3, 5)
		# antennae
		mb.tube(PackedVector3Array([Vector3(0.5 * s, 0.5, -2.6), Vector3(1.2 * s, 2.2, -4.2), Vector3(2.4 * s, 3.2, -6.5), Vector3(3.6 * s, 2.6, -8.6)]),
			PackedFloat32Array([0.1, 0.07, 0.045, 0.01]), 6)
	mb.col = emi
	for s in [-1.0, 1.0]:
		mb.sphere(Vector3(0.95 * s, 0.38, -2.25), Vector3(0.26, 0.2, 0.3), 10, 6)
		mb.sphere(Vector3(1.35 * s, 0.55, -1.6), Vector3(0.22, 0.17, 0.26), 10, 6)
		mb.sphere(Vector3(1.6 * s, 0.7, -0.9), Vector3(0.17, 0.14, 0.2), 8, 5)
		mb.sphere(Vector3(0.45 * s, 0.22, -2.9), Vector3(0.14, 0.11, 0.16), 8, 5)
	mb.sphere(Vector3(0, -0.6, -2.0), Vector3(0.6, 0.35, 0.9), 12, 7)
	return mb.build()


static func _mandible_mesh(s: float) -> ArrayMesh:
	var mb := MB.new()
	mb.xf = Transform3D(Basis.from_scale(Vector3(s, 1, 1)), Vector3.ZERO)
	mb.col = Color(0, 0, 1, 1)
	mb.sphere(Vector3.ZERO, Vector3(0.5, 0.45, 0.5), 10, 7)
	mb.col = Color(1, 0, 0, 1)
	mb.tube(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.9, -0.1, -1.3), Vector3(1.0, -0.25, -2.8), Vector3(0.35, -0.4, -4.0), Vector3(-0.3, -0.45, -4.4)]),
		PackedFloat32Array([0.42, 0.4, 0.3, 0.16, 0.02]), 8, true, true, true, 0.7)
	for k in 3:
		var z := -1.4 - k * 0.8
		mb.prism(Vector3(0.75 - k * 0.12, -0.2, z), Vector3(-1, -0.2, -0.3), 0.1, 0.25, 0.4, 5)
	return mb.build()


static func _leg_meshes() -> Array:
	var base := Color(0, 0, 0, 1)
	var bone := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	var dark := Color(0, 0, 1, 1)
	var c := MB.new()
	c.col = dark
	c.sphere(Vector3.ZERO, Vector3(0.6, 0.6, 0.6), 10, 7)
	c.col = base
	c.tube(PackedVector3Array([Vector3(0, 0.1, 0), Vector3(0, 0.5, 0.05), Vector3(0, 0.9, 0)]), PackedFloat32Array([0.42, 0.5, 0.36]), 9)
	var u := MB.new()
	u.col = dark
	u.sphere(Vector3.ZERO, Vector3(0.5, 0.5, 0.5), 10, 7)
	u.col = base
	u.tube(PackedVector3Array([Vector3(0, 0.2, 0), Vector3(0, 1.0, 0.12), Vector3(0, 2.4, 0.16), Vector3(0, 3.7, 0.08), Vector3(0, 4.4, 0)]),
		PackedFloat32Array([0.36, 0.5, 0.4, 0.3, 0.34]), 9, true, true, true, 0.8)
	u.col = bone
	for k in 4:
		var y := 0.9 + k * 0.85
		u.prism(Vector3(0, y, 0.42 - k * 0.04), Vector3(0, 0.5, 1), 0.11, 0.3, 0.55 - k * 0.06, 5)
	u.col = emi
	for k in 3:
		u.sphere(Vector3(0, 1.3 + k * 0.9, -0.36 + k * 0.03), Vector3(0.14, 0.2, 0.1), 7, 5)
	var t := MB.new()
	t.col = dark
	t.sphere(Vector3.ZERO, Vector3(0.44, 0.44, 0.44), 10, 7)
	t.col = bone
	t.prism(Vector3(0, -0.1, 0.25), Vector3(0, -0.6, 1), 0.2, 0.5, 1.1, 5)
	t.col = base
	t.tube(PackedVector3Array([Vector3(0, 0.15, 0), Vector3(0, 1.2, 0.22), Vector3(0, 3.0, 0.3), Vector3(0, 4.6, 0.18)]),
		PackedFloat32Array([0.32, 0.36, 0.25, 0.17]), 9, true, false, true, 0.75)
	t.col = bone
	t.tube(PackedVector3Array([Vector3(0, 4.6, 0.18), Vector3(0, 5.6, 0.08), Vector3(0, 6.4, 0)]), PackedFloat32Array([0.172, 0.11, 0.015]), 9, false, true, true, 0.75)
	t.col = emi
	t.tube(PackedVector3Array([Vector3(0, 2.2, 0.28), Vector3(0, 2.45, 0.3)]), PackedFloat32Array([0.305, 0.295]), 9, true, true, true, 0.78)
	return [c.build(), u.build(), t.build()]
