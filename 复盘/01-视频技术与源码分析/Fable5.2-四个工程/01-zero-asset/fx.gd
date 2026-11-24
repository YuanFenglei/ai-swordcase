extends Node3D
# All transient effects: pooled GPU particle bursts with code-built process materials, bolts, globs,
# fireballs, refraction shock bubbles, ground rings, light flashes, camera shake, screen post pass.

const MB = preload("res://mb.gd")
const Beam = preload("res://beam.gd")

var pools := {}
var bolt_mesh: ArrayMesh
var orb_mesh: ArrayMesh
var bolt_mat: ShaderMaterial
var bolts: Array = []
var globs: Array = []
var lights: Array = []
var fireballs: Array = []
var distorts: Array = []
var rings: Array = []
var shocks: Array = []
var trauma := 0.0
var shake_t := 0.0
var post: ShaderMaterial
var post_rect: ColorRect
var hit_v := 0.0
var flash_v := 0.0
var fade_v := 0.0
var bars_v := 0.0
var bars_target := 0.0
var heat_v := 0.0
var heat_target := 0.0
var spores: GPUParticles3D
var sh_add: Shader
var warm_n := 0
var sh_mix: Shader


func build() -> void:
	sh_add = G.shader("particle")
	sh_mix = Shader.new()
	sh_mix.code = sh_add.code.replace("blend_add", "blend_mix")
	var up := Vector3(0, 1, 0)
	var q_spark := _quad(Vector2(0.07, 0.55), sh_add, {"soft": 0.8, "intensity": 5.0})
	var q_muzzle := _quad(Vector2(0.22, 1.3), sh_add, {"soft": 1.2, "intensity": 6.0})
	var q_glow := _quad(Vector2(0.3, 0.3), sh_add, {"soft": 2.0, "intensity": 4.0})
	var q_dust := _quad(Vector2(1.6, 1.6), sh_mix, {"soft": 0.9, "intensity": 1.0, "noisy": 1.0, "depth_fade": 0.8})
	var q_smoke := _quad(Vector2(2.4, 2.4), sh_mix, {"soft": 0.8, "intensity": 1.0, "noisy": 1.0, "depth_fade": 1.2})
	var q_fire := _quad(Vector2(1.6, 1.6), sh_add, {"soft": 1.0, "intensity": 3.0, "noisy": 1.0, "depth_fade": 0.8})
	var white := [Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)]
	var hot := [Color(2.5, 2.5, 2.5, 1), Color(1, 1, 1, 1), Color(0.6, 0.6, 0.6, 0)]
	var puff := [Color(1, 1, 1, 0), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)]
	_kind("spark", 18, {"amount": 22, "life": 0.55, "spread": 55.0, "v0": 5.0, "v1": 22.0, "grav": Vector3(0, -16, 0), "damp": 2.0,
		"s0": 0.5, "s1": 1.3, "grow": [1.0, 0.2], "ramp": hot, "rad": 0.1, "mesh": q_spark, "align": GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY})
	_kind("spark_big", 8, {"amount": 70, "life": 1.2, "spread": 180.0, "v0": 8.0, "v1": 42.0, "grav": Vector3(0, -18, 0), "damp": 2.5,
		"s0": 0.8, "s1": 2.2, "grow": [1.0, 0.2], "ramp": hot, "rad": 0.5, "mesh": q_spark, "align": GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY})
	_kind("muzzle", 4, {"amount": 7, "life": 0.09, "spread": 16.0, "v0": 6.0, "v1": 30.0, "grav": Vector3.ZERO, "damp": 0.0,
		"s0": 0.6, "s1": 1.3, "grow": [1.0, 0.4], "ramp": white, "rad": 0.05, "mesh": q_muzzle, "align": GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY})
	_kind("glow", 12, {"amount": 26, "life": 1.3, "spread": 180.0, "v0": 1.0, "v1": 7.0, "grav": Vector3(0, 2.5, 0), "damp": 2.0,
		"s0": 0.4, "s1": 1.6, "grow": [1.0, 0.0], "ramp": white, "rad": 0.5, "mesh": q_glow})
	_kind("dust", 28, {"amount": 9, "life": 1.3, "spread": 80.0, "v0": 0.8, "v1": 3.2, "grav": Vector3(0, 0.4, 0), "damp": 2.0,
		"s0": 0.5, "s1": 1.1, "grow": [0.35, 1.0], "ramp": puff, "rad": 0.25, "mesh": q_dust})
	_kind("dust_big", 20, {"amount": 9, "life": 2.4, "spread": 85.0, "v0": 2.0, "v1": 7.0, "grav": Vector3(0, 0.5, 0), "damp": 2.2,
		"s0": 1.6, "s1": 3.4, "grow": [0.3, 1.0], "ramp": puff, "rad": 0.9, "mesh": q_dust})
	_kind("smoke", 12, {"amount": 16, "life": 2.4, "spread": 70.0, "v0": 1.5, "v1": 7.0, "grav": Vector3(0, 1.6, 0), "damp": 2.2,
		"s0": 0.8, "s1": 2.0, "grow": [0.3, 1.0], "ramp": puff, "rad": 0.6, "mesh": q_smoke})
	_kind("smoke_big", 6, {"amount": 22, "life": 4.0, "spread": 90.0, "v0": 3.0, "v1": 14.0, "grav": Vector3(0, 2.0, 0), "damp": 2.4,
		"s0": 2.0, "s1": 4.6, "grow": [0.25, 1.0], "ramp": puff, "rad": 2.0, "mesh": q_smoke})
	_kind("fire", 8, {"amount": 14, "life": 0.7, "spread": 180.0, "v0": 2.0, "v1": 11.0, "grav": Vector3(0, 3.0, 0), "damp": 3.0,
		"s0": 0.8, "s1": 2.2, "grow": [0.4, 1.0], "ramp": [Color(2, 2, 2, 1), Color(1, 0.8, 0.6, 0.8), Color(0.5, 0.1, 0.05, 0)], "rad": 0.6, "mesh": q_fire})
	var rk := MB.new()
	rk.ico(0.14, 0, Callable(), Vector3(1, 0.7, 1.2), false)
	var rmesh := rk.build()
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.08, 0.06, 0.07)
	rmat.roughness = 0.8
	rmesh.surface_set_material(0, rmat)
	_kind("debris", 8, {"amount": 16, "life": 1.8, "spread": 60.0, "v0": 6.0, "v1": 20.0, "grav": Vector3(0, -24, 0), "damp": 0.3,
		"s0": 0.5, "s1": 2.2, "grow": [1.0, 0.6], "ramp": [Color.WHITE, Color.WHITE], "rad": 0.6, "mesh": rmesh, "align": GPUParticles3D.TRANSFORM_ALIGN_Y_TO_VELOCITY})

	# bolts and globs
	var bm := MB.new()
	bm.tube(PackedVector3Array([Vector3(0, 0, 0.9), Vector3(0, 0, 0.3), Vector3(0, 0, -1.2), Vector3(0, 0, -2.6)]), PackedFloat32Array([0.01, 0.11, 0.08, 0.01]), 8, false, false)
	bolt_mesh = bm.build()
	var om := MB.new()
	om.sphere(Vector3.ZERO, Vector3.ONE, 14, 10)
	orb_mesh = om.build()
	bolt_mat = G.smat("glow")
	for i in 64:
		bolts.append({"mi": _glow_mi(bolt_mesh), "on": false, "p": Vector3.ZERO, "v": Vector3.ZERO, "life": 0.0, "dmg": 0.0, "friendly": true, "col": Color.WHITE})
	for i in 28:
		globs.append({"mi": _glow_mi(orb_mesh), "on": false, "p": Vector3.ZERO, "v": Vector3.ZERO, "life": 0.0, "dmg": 0.0, "tr": 0.0, "r": 0.5})
	for i in 10:
		var l := OmniLight3D.new()
		l.visible = false
		l.light_volumetric_fog_energy = 1.0
		add_child(l)
		lights.append({"l": l, "t": 0.0, "dur": 0.1, "e": 0.0})
	var fb := MB.new()
	fb.ico(1.0, 3, Callable())
	var fbm := fb.build()
	for i in 10:
		var mi := MeshInstance3D.new()
		mi.mesh = fbm
		mi.material_override = G.smat("fireball")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		fireballs.append({"mi": mi, "t": 0.0, "dur": 1.0, "size": 1.0, "on": false})
	var dsm := MB.new()
	dsm.sphere(Vector3.ZERO, Vector3.ONE, 28, 18)
	var dmesh := dsm.build()
	for i in 5:
		var mi := MeshInstance3D.new()
		mi.mesh = dmesh
		mi.material_override = G.smat("distort")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		distorts.append({"mi": mi, "t": 0.0, "dur": 1.0, "size": 1.0, "on": false})
	var rg := MB.new()
	rg.lathe(PackedVector2Array([Vector2(1, 0), Vector2(1, 1)]), 96)
	var rmesh2 := rg.build()
	for i in 4:
		var mi := MeshInstance3D.new()
		mi.mesh = rmesh2
		mi.material_override = G.smat("ringwave")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		mi.extra_cull_margin = 50.0
		add_child(mi)
		rings.append({"mi": mi, "t": 0.0, "dur": 1.0, "r": 1.0, "h": 3.0, "on": false})

	# ambient drifting spores around the camera
	spores = GPUParticles3D.new()
	spores.amount = 700
	spores.lifetime = 9.0
	spores.preprocess = 9.0
	spores.local_coords = false
	spores.visibility_aabb = AABB(Vector3(-80, -40, -80), Vector3(160, 80, 160))
	spores.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(48, 9, 48)
	pm.direction = Vector3(1, 0.15, 0.4)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0, 0.05, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.2
	pm.turbulence_noise_scale = 6.0
	pm.scale_min = 0.25
	pm.scale_max = 1.0
	pm.color = Color(0.5, 1.0, 0.9, 1.0)
	pm.hue_variation_min = -0.12
	pm.hue_variation_max = 0.3
	pm.color_ramp = _ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	spores.process_material = pm
	spores.draw_pass_1 = _quad(Vector2(0.16, 0.16), sh_add, {"soft": 2.0, "intensity": 3.0})
	spores.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	add_child(spores)

	# screen post pass
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	post_rect = ColorRect.new()
	post_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post = G.smat("post")
	post_rect.material = post
	layer.add_child(post_rect)


func _quad(size: Vector2, sh: Shader, params: Dictionary) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = size
	var m := ShaderMaterial.new()
	m.shader = sh
	for k in params:
		m.set_shader_parameter(k, params[k])
	q.material = m
	return q


func _ramp(cols: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cc := PackedColorArray()
	for i in cols.size():
		offs.append(float(i) / float(cols.size() - 1))
		cc.append(cols[i])
	g.offsets = offs
	g.colors = cc
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 64
	return t


func _curve(a: float, b: float) -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0, a))
	c.add_point(Vector2(1, b))
	var t := CurveTexture.new()
	t.curve = c
	t.width = 32
	return t


func _kind(kind: String, n: int, cfg: Dictionary) -> void:
	var items: Array = []
	for i in n:
		var p := GPUParticles3D.new()
		p.amount = cfg.amount
		p.lifetime = cfg.life
		p.one_shot = true
		p.explosiveness = 0.96
		p.emitting = false
		p.local_coords = false
		p.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 80, 80))
		p.transform_align = cfg.get("align", GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD)
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := ParticleProcessMaterial.new()
		m.direction = Vector3.UP
		m.spread = cfg.spread
		m.initial_velocity_min = cfg.v0
		m.initial_velocity_max = cfg.v1
		m.gravity = cfg.grav
		m.damping_min = cfg.damp
		m.damping_max = cfg.damp
		m.scale_min = cfg.s0
		m.scale_max = cfg.s1
		m.scale_curve = _curve(cfg.grow[0], cfg.grow[1])
		m.color_ramp = _ramp(cfg.ramp)
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		m.emission_sphere_radius = cfg.rad
		m.lifetime_randomness = 0.4
		if not cfg.has("align"):
			m.angle_min = -180.0
			m.angle_max = 180.0
		p.process_material = m
		p.draw_pass_1 = cfg.mesh
		add_child(p)
		items.append(p)
	pools[kind] = {"items": items, "i": 0}


func _glow_mi(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = bolt_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


func make_beam(col: Color) -> Node3D:
	var b := Beam.new()
	add_child(b)
	b.build(col)
	return b


func burst(kind: String, pos: Vector3, col := Color.WHITE, dir := Vector3.UP) -> void:
	if G.cam != null and pos.distance_squared_to(G.cam.global_position) > 260.0 * 260.0:
		return
	var pool: Dictionary = pools[kind]
	var p: GPUParticles3D = pool.items[pool.i]
	pool.i = (pool.i + 1) % pool.items.size()
	p.global_position = pos
	var m: ParticleProcessMaterial = p.process_material
	m.color = col
	m.direction = dir
	p.restart()
	p.emitting = true


func flash(pos: Vector3, col: Color, energy: float, rng: float, dur: float) -> void:
	var best: Dictionary = lights[0]
	for l in lights:
		if l.t >= l.dur:
			best = l
			break
		if l.dur - l.t < best.dur - best.t:
			best = l
	var ol: OmniLight3D = best.l
	ol.global_position = pos
	ol.light_color = col
	ol.omni_range = rng
	ol.light_energy = energy
	ol.visible = true
	best.t = 0.0
	best.dur = dur
	best.e = energy


func bolt(from: Vector3, dir: Vector3, speed: float, dmg: float, friendly: bool, col: Color) -> void:
	for b in bolts:
		if not b.on:
			b.on = true
			b.p = from
			b.v = dir * speed
			b.life = 1.6
			b.dmg = dmg
			b.friendly = friendly
			b.col = col
			var mi: MeshInstance3D = b.mi
			mi.visible = true
			mi.set_instance_shader_parameter(&"tint", col)
			mi.set_instance_shader_parameter(&"power", 7.0)
			_place_bolt(b)
			return


func _place_bolt(b: Dictionary) -> void:
	var mi: MeshInstance3D = b.mi
	var z: Vector3 = -(b.v as Vector3).normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 1e-5:
		x = Vector3.RIGHT
	x = x.normalized()
	mi.global_transform = Transform3D(Basis(x, z.cross(x), z), b.p)


func glob(from: Vector3, v: Vector3, dmg: float, radius := 0.55) -> void:
	for g in globs:
		if not g.on:
			g.on = true
			g.p = from
			g.v = v
			g.life = 6.0
			g.dmg = dmg
			g.r = radius
			var mi: MeshInstance3D = g.mi
			mi.visible = true
			mi.scale = Vector3.ONE * radius
			mi.set_instance_shader_parameter(&"tint", G.C_MAGENTA)
			mi.set_instance_shader_parameter(&"power", 9.0)
			mi.global_position = from
			return


func ring(pos: Vector3, radius: float, dur: float, col: Color, height := 3.5) -> void:
	for r in rings:
		if not r.on:
			r.on = true
			r.t = 0.0
			r.dur = dur
			r.r = radius
			r.h = height
			var mi: MeshInstance3D = r.mi
			mi.visible = true
			mi.global_position = pos - Vector3(0, 0.6, 0)
			mi.set_instance_shader_parameter(&"tint", col)
			return


func prewarm() -> void:
	# draw every effect once (below ground, in view) so pipelines compile before they are needed
	var cam := G.cam
	var p: Vector3 = cam.global_position - cam.global_basis.z * 35.0
	p = G.ground(p, -45.0)
	for k in pools:
		burst(k, p)
	explode(p, 3.0, G.C_MAGENTA, true)
	ring(p, 5.0, 0.3, G.C_CYAN)
	bolt(p, Vector3.DOWN, 10.0, 0.0, true, G.C_CYAN)
	glob(p, Vector3.DOWN, 0.0)
	trauma = 0.0
	shocks.clear()


func explode(pos: Vector3, size: float, col: Color, silent := false) -> void:
	for f in fireballs:
		if not f.on:
			f.on = true
			f.t = 0.0
			f.dur = 0.55 + 0.25 * size
			f.size = size * 1.5
			var mi: MeshInstance3D = f.mi
			mi.visible = true
			mi.global_position = pos
			mi.rotation = Vector3(randf() * TAU, randf() * TAU, 0)
			mi.set_instance_shader_parameter(&"tint", col.lerp(G.C_ORANGE, 0.5))
			mi.set_instance_shader_parameter(&"seed", randf() * 50.0)
			break
	if size >= 1.4:
		for d in (distorts if size >= 2.4 else []):
			if not d.on:
				d.on = true
				d.t = 0.0
				d.dur = 0.45 + 0.12 * size
				d.size = size * 5.0
				d.mi.visible = true
				d.mi.global_position = pos
				break
		burst("spark_big", pos, col.lerp(Color.WHITE, 0.3))
		burst("smoke_big" if size >= 2.5 else "smoke", pos + Vector3(0, size * 0.4, 0), Color(0.09, 0.07, 0.09, 0.8))
		burst("debris", pos, Color.WHITE)
		burst("fire", pos, col.lerp(G.C_ORANGE, 0.6))
	else:
		burst("spark", pos, col.lerp(Color.WHITE, 0.3))
		burst("smoke", pos, Color(0.1, 0.07, 0.1, 0.6))
		burst("glow", pos, col)
	if size >= 2.5:
		ring(G.ground(pos, 0.0), size * 9.0, 0.7, col, 2.5)
		shock(pos, size * 0.35)
	flash(pos + Vector3(0, 1, 0), col.lerp(Color(1, 0.8, 0.6), 0.5), 5.0 * size, 9.0 * size + 6.0, 0.25 + 0.1 * size)
	shake(0.22 * size, pos)
	if G.audio != null and not silent:
		G.audio.play("boom_big" if size >= 2.5 else "boom", pos, -3.0 + size, randf_range(0.85, 1.15))


func shake(amount: float, pos = null) -> void:
	var k := 1.0
	if pos != null and G.cam != null:
		k = clampf(1.0 - G.cam.global_position.distance_to(pos) / 140.0, 0.0, 1.0)
		k *= k
	trauma = minf(trauma + amount * k, 1.0)


func shock(pos: Vector3, strength: float) -> void:
	if shocks.size() >= 3:
		shocks.pop_front()
	shocks.append({"p": pos, "t": 0.0, "s": strength})


func hit_pulse(a: float) -> void:
	hit_v = maxf(hit_v, a)


func white(a: float) -> void:
	flash_v = maxf(flash_v, a)


func apply_shake(cam: Camera3D) -> void:
	var a := trauma * trauma
	cam.h_offset = sin(shake_t * 47.0) * cos(shake_t * 31.0) * a * 0.5
	cam.v_offset = sin(shake_t * 53.0 + 1.7) * cos(shake_t * 29.0) * a * 0.5
	cam.rotate_object_local(Vector3.BACK, sin(shake_t * 41.0) * a * 0.035)


func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(dt)
	G.prof["fx"] = G.prof.get("fx", 0) + Time.get_ticks_usec() - t0


func _tick(dt: float) -> void:
	shake_t += dt
	warm_n += 1
	if warm_n == 3 and G.cam != null:
		prewarm()
	trauma = maxf(trauma - dt * 1.3, 0.0)
	var walker = G.walker
	# bolts
	for b in bolts:
		if not b.on:
			continue
		var prev: Vector3 = b.p
		b.p = prev + b.v * dt
		b.life -= dt
		var np: Vector3 = b.p
		var done: bool = b.life <= 0.0
		var hitp := np
		if b.friendly:
			var h = G.main.seg_hit(prev, np, 0.25)
			if h != null:
				h.target.damage(b.dmg, h.pos, (b.v as Vector3).normalized())
				hitp = h.pos
				done = true
				burst("spark", hitp, b.col, -(b.v as Vector3).normalized())
				flash(hitp - (b.v as Vector3).normalized() * 1.8, b.col, 1.5, 8.0, 0.1)
		elif walker != null and not walker.dead:
			var c: Vector3 = walker.center()
			if Geometry3D.get_closest_point_to_segment(c, prev, np).distance_to(c) < 2.3:
				walker.damage(b.dmg, prev)
				done = true
				burst("spark", np, b.col)
		if not done and np.y < G.h(np.x, np.z):
			done = true
			hitp = G.ground(np, 0.1)
			burst("spark", hitp, b.col, Vector3.UP)
			burst("dust", hitp, Color(0.5, 0.33, 0.28, 0.5))
			flash(hitp + Vector3(0, 0.5, 0), b.col, 3.0, 6.0, 0.1)
		if done:
			b.on = false
			b.mi.visible = false
		else:
			_place_bolt(b)
	# globs
	for g in globs:
		if not g.on:
			continue
		g.v.y -= 16.0 * dt
		g.p += g.v * dt
		g.life -= dt
		g.tr -= dt
		var p: Vector3 = g.p
		var mi: MeshInstance3D = g.mi
		mi.global_position = p
		mi.scale = Vector3.ONE * g.r * (1.0 + 0.15 * sin(shake_t * 30.0))
		if g.tr <= 0.0:
			g.tr = 0.07
			burst("glow", p, G.C_MAGENTA, -(g.v as Vector3).normalized())
		var boom := false
		if walker != null and not walker.dead and p.distance_to(walker.center()) < 2.6:
			boom = true
		if p.y < G.h(p.x, p.z) + 0.2 or g.life <= 0.0:
			boom = true
		if boom:
			g.on = false
			mi.visible = false
			if g.dmg <= 0.0:
				continue
			explode(p + Vector3(0, 0.4, 0), 1.0 + g.r, G.C_MAGENTA)
			if walker != null and not walker.dead:
				var d := p.distance_to(walker.center())
				if d < 5.5:
					walker.damage(g.dmg * clampf(1.4 - d / 5.5, 0.3, 1.0), p)
	# lights
	for l in lights:
		if l.t < l.dur:
			l.t += dt
			var ol: OmniLight3D = l.l
			var k: float = clampf(1.0 - l.t / l.dur, 0.0, 1.0)
			ol.light_energy = l.e * k * k
			if l.t >= l.dur:
				ol.visible = false
	for f in fireballs:
		if f.on:
			f.t += dt
			var k: float = f.t / f.dur
			var mi: MeshInstance3D = f.mi
			mi.scale = Vector3.ONE * f.size * (0.35 + 0.65 * (1.0 - pow(1.0 - minf(k, 1.0), 3.0)))
			mi.set_instance_shader_parameter(&"life", k)
			if k >= 1.0:
				f.on = false
				mi.visible = false
	for d in distorts:
		if d.on:
			d.t += dt
			var k: float = d.t / d.dur
			var mi: MeshInstance3D = d.mi
			mi.scale = Vector3.ONE * d.size * (0.15 + 0.85 * sqrt(minf(k, 1.0)))
			mi.set_instance_shader_parameter(&"life", k)
			if k >= 1.0:
				d.on = false
				mi.visible = false
	for r in rings:
		if r.on:
			r.t += dt
			var k: float = r.t / r.dur
			var mi: MeshInstance3D = r.mi
			var rr: float = r.r * (0.05 + 0.95 * (1.0 - pow(1.0 - minf(k, 1.0), 2.0)))
			mi.scale = Vector3(rr, r.h, rr)
			mi.set_instance_shader_parameter(&"life", k)
			if k >= 1.0:
				r.on = false
				mi.visible = false
	# post pass
	hit_v = maxf(hit_v - dt * 1.8, 0.0)
	flash_v = maxf(flash_v - dt * 1.6, 0.0)
	bars_v = move_toward(bars_v, bars_target, dt * 1.5)
	heat_v = move_toward(heat_v, heat_target, dt * 0.6)
	post.set_shader_parameter(&"hit", hit_v)
	post.set_shader_parameter(&"flash", flash_v)
	post.set_shader_parameter(&"fade", fade_v)
	post.set_shader_parameter(&"bars", bars_v)
	post.set_shader_parameter(&"heat", heat_v + trauma * 0.6)
	var cam := G.cam
	if cam != null:
		spores.global_position = cam.global_position + Vector3(0, 3, 0)
		var vs := get_viewport().get_visible_rect().size
		post.set_shader_parameter(&"aspect", vs.x / vs.y)
		for i in 3:
			var val := Vector4.ZERO
			if i < shocks.size():
				var s: Dictionary = shocks[i]
				s.t += dt
				var sp: Vector3 = s.p
				if s.t < 1.2 and not cam.is_position_behind(sp):
					var uv := cam.unproject_position(sp) / vs
					var dist := maxf(cam.global_position.distance_to(sp), 4.0)
					var focal := 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
					val = Vector4(uv.x, uv.y, s.t * 34.0 * focal / dist, s.s * (1.0 - s.t / 1.2))
			post.set_shader_parameter("shock%d" % i, val)


func clear() -> void:
	for b in bolts:
		b.on = false
		b.mi.visible = false
	for g in globs:
		g.on = false
		g.mi.visible = false
	shocks.clear()
	trauma = 0.0
	hit_v = 0.0
