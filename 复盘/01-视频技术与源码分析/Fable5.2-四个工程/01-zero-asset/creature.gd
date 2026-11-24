extends Node3D
# Swarm creature: four IK legs on a trot gait, flocking chase, lunge bite, dissolve death.

const MB = preload("res://mb.gd")
const Leg = preload("res://leg.gd")

static var res := {}

var pos := Vector3.ZERO
var vel := Vector3.ZERO
var radius := 1.45
var dead := false
var big := false
var prio := 0.0
var hp := 30.0
var legs: Array = []
var body: MeshInstance3D
var yaw := 0.0
var state := "emerge"
var st := 0.0
var flash := 0.0
var orbit := 0.0
var speed := 7.5
var hop := 0.0
var bite_cd := 0.0
var chirp_t := 0.0
var gone := false
var scl := 1.3


static func resources() -> Dictionary:
	if not res.is_empty():
		return res
	var base := Color(0, 0, 0, 1)
	var bone := Color(1, 0, 0, 1)
	var emi := Color(0, 1, 0, 1)
	var dark := Color(0, 0, 1, 1)
	var mb := MB.new()
	mb.col = base
	var secs := [[-1.0, 0.1, 0.07, 0.0], [-0.7, 0.36, 0.2, 0.03], [-0.15, 0.56, 0.3, 0.08], [0.35, 0.5, 0.32, 0.1], [0.75, 0.3, 0.24, 0.08], [0.95, 0.1, 0.1, 0.05]]
	var rings: Array = []
	for s in secs:
		rings.append(MB.ring(Vector3(0, s[3], s[0]), Vector3(1, 0, 0), Vector3(0, 1, 0), s[1], s[2], 14, 2.6))
	mb.loft(rings, true, true)
	mb.col = emi
	mb.sphere(Vector3(0, 0.2, 0.72), Vector3(0.34, 0.3, 0.44), 12, 8)
	for sx in [-1.0, 1.0]:
		mb.sphere(Vector3(0.2 * sx, 0.16, -0.78), Vector3(0.07, 0.06, 0.07), 6, 4)
		mb.sphere(Vector3(0.3 * sx, 0.18, -0.6), Vector3(0.05, 0.05, 0.05), 6, 4)
	mb.col = bone
	for k in 4:
		var z := -0.5 + k * 0.3
		mb.prism(Vector3(0, 0.3, z), Vector3(0, 1, 0.5), 0.07, 0.25 + 0.12 * sin(k * 1.3 + 1.0), 0.3, 5)
	for sx in [-1.0, 1.0]:
		mb.tube(PackedVector3Array([Vector3(0.22 * sx, -0.02, -0.8), Vector3(0.42 * sx, -0.06, -1.2), Vector3(0.24 * sx, -0.08, -1.55), Vector3(0.08 * sx, -0.08, -1.62)]),
			PackedFloat32Array([0.08, 0.07, 0.045, 0.01]), 6)
		mb.prism(Vector3(0.45 * sx, 0.15, 0.1), Vector3(sx, 0.5, 0.3), 0.06, 0.2, 0.3, 5)
	res.body = mb.build()
	var u := MB.new()
	u.col = dark
	u.sphere(Vector3.ZERO, Vector3(0.13, 0.13, 0.13), 8, 6)
	u.col = base
	u.tube(PackedVector3Array([Vector3(0, 0.05, 0), Vector3(0, 0.4, 0.05), Vector3(0, 0.85, 0)]), PackedFloat32Array([0.09, 0.12, 0.07]), 7, true, true, true, 0.8)
	res.upper = u.build()
	var lw := MB.new()
	lw.col = dark
	lw.sphere(Vector3.ZERO, Vector3(0.1, 0.1, 0.1), 8, 6)
	lw.col = bone
	lw.tube(PackedVector3Array([Vector3(0, 0.04, 0), Vector3(0, 0.45, 0.06), Vector3(0, 1.15, 0)]), PackedFloat32Array([0.075, 0.06, 0.008]), 6, true, true, true, 0.75)
	res.lower = lw.build()
	res.mat = G.smat("surface", {"base_col": Color(0.06, 0.04, 0.08), "accent_col": Color(0.62, 0.5, 0.42), "dark_col": Color(0.02, 0.02, 0.03),
		"emit_col": G.C_MAGENTA, "emit_power": 3.6, "metal": 0.45, "rough": 0.3, "organic": 1.0, "detail": 2.2, "rim_col": Color(0.6, 0.2, 0.8), "rim_power": 0.3})
	return res


func spawn(p: Vector3, big_one := false) -> void:
	var r := resources()
	if big_one:
		scl = 2.3
		hp = 130.0
		radius = 2.4
		speed = 6.0
	if G.demo:
		speed *= 0.8
	pos = G.ground(p)
	yaw = G.rng.randf() * TAU
	orbit = G.rng.randf_range(-1.0, 1.0)
	speed *= G.rng.randf_range(0.85, 1.15)
	body = MeshInstance3D.new()
	body.mesh = r.body
	body.material_override = r.mat
	body.scale = Vector3.ONE * scl
	add_child(body)
	var sd := G.rng.randf() * 20.0
	body.set_instance_shader_parameter(&"seed", sd)
	for i in 2:
		for s in [-1.0, 1.0]:
			var l = Leg.new()
			l.setup(self, null, r.upper, r.lower, r.mat)
			var z: float = -0.4 if i == 0 else 0.4
			l.mount = Vector3(0.36 * s, -0.02, z) * scl
			l.rest = Vector3(1.3 * s, 0, z * 2.1) * scl
			l.side = s
			l.l1 = 0.85
			l.l2 = 1.15
			l.group = (i + (0 if s < 0.0 else 1)) % 2
			legs.append(l)
	var xf := Transform3D(Basis(Vector3.UP, yaw), pos)
	for l in legs:
		l.foot = G.ground(xf * l.rest)
	G.fx.burst("dust", pos + Vector3(0, 0.2, 0), Color(0.5, 0.33, 0.28, 0.6))
	_place(0.016)


func center() -> Vector3:
	return pos


func damage(amount: float, point: Vector3, dir: Vector3) -> void:
	if dead:
		return
	hp -= amount
	flash = 1.0
	vel += G.flat(dir) * minf(amount * 0.35, 6.0)
	if hp <= 0.0:
		dead = true
		state = "dying"
		st = 0.0
		G.fx.burst("glow", pos, G.C_MAGENTA)
		G.fx.burst("spark", pos, G.C_MAGENTA.lerp(Color.WHITE, 0.4))
		G.fx.burst("smoke", pos, Color(0.12, 0.04, 0.1, 0.6))
		G.fx.flash(pos + Vector3(0, 1, 0), G.C_MAGENTA, 6.0, 9.0, 0.25)
		G.audio.play("squish", pos, -3.0, G.rng.randf_range(0.8, 1.25))
		if scl > 1.6:
			G.fx.explode(pos, 1.5, G.C_MAGENTA)
		elif G.rng.randf() < 0.45:
			G.fx.burst("fire", pos, G.C_MAGENTA.lerp(G.C_ORANGE, 0.5))
			G.fx.burst("debris", pos, Color.WHITE)
	elif G.rng.randf() < 0.3:
		G.fx.burst("glow", point, G.C_MAGENTA)


func _probe(p: Vector3) -> Vector3:
	return G.ground(p)


func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(dt)
	G.prof["creature"] = G.prof.get("creature", 0) + Time.get_ticks_usec() - t0


func _tick(dt: float) -> void:
	if dt <= 0.0:
		return
	st += dt
	flash = maxf(flash - dt * 5.0, 0.0)
	bite_cd -= dt
	var w = G.walker
	var to: Vector3 = G.flat(w.pos - pos)
	var dist := to.length()
	var want := Vector3.ZERO
	match state:
		"emerge":
			if st > 0.5:
				state = "chase"
		"chase":
			if dist > 0.1 and not w.dead:
				var dirn := to / dist
				var side := Vector3(dirn.z, 0, -dirn.x)
				var k := clampf((dist - 4.0) / 14.0, 0.0, 1.0)
				want = (dirn + side * orbit * 0.9 * k).normalized() * speed
				if dist < 4.2 * scl and bite_cd <= 0.0:
					state = "lunge"
					st = 0.0
					vel = dirn * 15.0
					hop = 5.0
			elif w.dead:
				want = Vector3(sin(yaw), 0, cos(yaw)) * 3.0
			chirp_t -= dt
			if chirp_t <= 0.0:
				chirp_t = G.rng.randf_range(2.0, 6.0)
				G.audio.play("chirp", pos, -12.0, G.rng.randf_range(0.8, 1.4))
		"lunge":
			want = vel
			if dist < 2.6 * scl and bite_cd <= 0.0:
				bite_cd = 1.4
				w.damage(2.2 * scl, pos)
				vel = -to.normalized() * 6.0
			if st > 0.45:
				state = "chase"
				bite_cd = maxf(bite_cd, 0.7)
		"dying":
			want = Vector3.ZERO
			var k := st / 0.5
			body.set_instance_shader_parameter(&"dissolve", k)
			for l in legs:
				l.set_param(&"dissolve", k)
			if k >= 1.0:
				gone = true
				return
	if state == "chase":
		# separation
		var push := Vector3.ZERO
		for c in G.creatures:
			if c == self or c.dead:
				continue
			var d: Vector3 = pos - c.pos
			d.y = 0.0
			var l2 := d.length_squared()
			if l2 < 11.0 and l2 > 0.001:
				push += d / l2
		want += push * 9.0
	vel = vel.move_toward(want, (30.0 if state != "lunge" else 4.0) * dt)
	pos += vel * dt
	for o in G.obstacles:
		var dx: float = pos.x - o.x
		var dz: float = pos.z - o.y
		var rr: float = o.z + 0.6
		var d2 := dx * dx + dz * dz
		if d2 < rr * rr and d2 > 0.0001:
			var d := sqrt(d2)
			pos.x += dx / d * (rr - d)
			pos.z += dz / d * (rr - d)
	if vel.length() > 0.5:
		yaw = lerp_angle(yaw, atan2(-vel.x, -vel.z), 1.0 - exp(-8.0 * dt))
	hop = maxf(hop - 18.0 * dt, -6.0)
	_place(dt)


func _place(dt: float) -> void:
	var gy := G.h(pos.x, pos.z)
	var ride := 0.72 * scl
	if state == "emerge":
		ride = lerpf(-0.9, ride, clampf(st / 0.5, 0.0, 1.0))
	elif state == "dying":
		ride *= 1.0 - st
	var ty := gy + ride
	if state == "lunge":
		pos.y = maxf(pos.y + hop * dt, ty)
	else:
		pos.y = lerpf(pos.y, ty, 1.0 - exp(-14.0 * dt))
	var n: Vector3 = G.terrain.normal(pos.x, pos.z)
	var b := Basis(Quaternion(Vector3.UP, n)) * Basis(Vector3.UP, yaw)
	global_transform = Transform3D(b, pos)
	var base := Transform3D(Basis(Vector3.UP, yaw), pos)
	if state != "dying":
		Leg.schedule(legs, base, vel, 0.55 * scl, 0.11, 0.3 * scl, 0.6, _probe)
	body.set_instance_shader_parameter(&"flash", flash)
	var gx := global_transform
	for l in legs:
		l.advance(dt)
		l.solve(gx, scl)
		if flash > 0.0 or dead:
			l.set_param(&"flash", flash)
