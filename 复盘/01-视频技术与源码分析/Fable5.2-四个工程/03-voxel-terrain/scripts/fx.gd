extends Node3D

# Explosions, debris, dust, meteors. Everything is pooled.

const VoxelWorld := preload("res://scripts/voxel_world.gd")

const DUST_N := 28
const SPARK_N := 16
const LIGHT_N := 8
const BALL_N := 14
const DEBRIS_N := 220
const SMOKE_N := 22

var main: Node3D
var world: RefCounted
var trauma := 0.0
var no_dust := false
var no_light := false
var no_debris := false
var no_spark := false

var _dust: Array[GPUParticles3D] = []
var _dust_i := 0
var _smoke: Array[GPUParticles3D] = []
var _smoke_t := PackedFloat32Array()
var _smoke_i := 0
var _spark: Array[GPUParticles3D] = []
var _spark_i := 0
var _lights: Array[OmniLight3D] = []
var _light_i := 0
var _balls: Array[MeshInstance3D] = []
var _ball_t := PackedFloat32Array()
var _ball_s := PackedFloat32Array()
var _ball_i := 0
var _debris: Array[RigidBody3D] = []
var _debris_t := PackedFloat32Array()
var _debris_i := 0
var _debris_s: Array[Vector3] = []
var _meteors: Array = []
var _rng := RandomNumberGenerator.new()
var _glow_shader: Shader
var _trail_pm: ParticleProcessMaterial
var _trail_mesh: QuadMesh
var _head_mesh: QuadMesh
var _streak_mesh: QuadMesh
var _shake_t := 0.0


func _ready() -> void:
	_rng.seed = 20261111
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_glow_shader = load("res://shaders/fx_glow.gdshader")
	var dust_shader: Shader = load("res://shaders/fx_dust.gdshader")

	# dust
	var dm := ShaderMaterial.new()
	dm.shader = dust_shader
	var dq := QuadMesh.new()
	dq.size = Vector2(1, 1)
	dq.material = dm
	var dpm := ParticleProcessMaterial.new()
	dpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	dpm.emission_sphere_radius = 3.0
	dpm.direction = Vector3(0, 1, 0)
	dpm.spread = 75.0
	dpm.initial_velocity_min = 5.0
	dpm.initial_velocity_max = 22.0
	dpm.gravity = Vector3(0, -1.5, 0)
	dpm.damping_min = 5.0
	dpm.damping_max = 9.0
	dpm.scale_min = 5.0
	dpm.scale_max = 10.0
	dpm.angle_min = 0.0
	dpm.angle_max = 360.0
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.25))
	sc.add_point(Vector2(0.25, 0.8))
	sc.add_point(Vector2(1, 1.25))
	var sct := CurveTexture.new()
	sct.curve = sc
	dpm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(0.20, 0.14, 0.10, 0.0))
	g.set_color(1, Color(0.62, 0.50, 0.40, 0.0))
	g.add_point(0.06, Color(0.26, 0.18, 0.13, 0.85))
	g.add_point(0.45, Color(0.50, 0.38, 0.29, 0.55))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	dpm.color_ramp = gt
	for i in DUST_N:
		var p := GPUParticles3D.new()
		p.process_material = dpm
		p.draw_pass_1 = dq
		p.amount = 22
		p.lifetime = 2.8
		p.one_shot = true
		p.explosiveness = 0.92
		p.emitting = false
		p.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_dust.append(p)

	# lingering smoke column
	var kpm := ParticleProcessMaterial.new()
	kpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	kpm.emission_sphere_radius = 3.5
	kpm.direction = Vector3(0, 1, 0)
	kpm.spread = 28.0
	kpm.initial_velocity_min = 3.0
	kpm.initial_velocity_max = 9.0
	kpm.gravity = Vector3(1.2, 1.6, 0.5)
	kpm.damping_min = 0.6
	kpm.damping_max = 1.2
	kpm.scale_min = 7.0
	kpm.scale_max = 13.0
	kpm.angle_min = 0.0
	kpm.angle_max = 360.0
	var kc := Curve.new()
	kc.add_point(Vector2(0, 0.35))
	kc.add_point(Vector2(0.3, 0.9))
	kc.add_point(Vector2(1, 1.7))
	var kct := CurveTexture.new()
	kct.curve = kc
	kpm.scale_curve = kct
	var kg := Gradient.new()
	kg.set_color(0, Color(0.9, 0.35, 0.08, 0.0))
	kg.set_color(1, Color(0.30, 0.26, 0.27, 0.0))
	kg.add_point(0.05, Color(0.16, 0.10, 0.08, 0.8))
	kg.add_point(0.5, Color(0.17, 0.14, 0.15, 0.5))
	var kgt := GradientTexture1D.new()
	kgt.gradient = kg
	kpm.color_ramp = kgt
	_smoke_t.resize(SMOKE_N)
	for i in SMOKE_N:
		var p := GPUParticles3D.new()
		p.process_material = kpm
		p.draw_pass_1 = dq
		p.amount = 12
		p.lifetime = 6.5
		p.one_shot = true
		p.explosiveness = 0.55
		p.emitting = false
		p.visibility_aabb = AABB(Vector3(-80, -40, -80), Vector3(160, 200, 160))
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_smoke.append(p)
		_smoke_t[i] = -100.0

	# sparks
	var sm := ShaderMaterial.new()
	sm.shader = _glow_shader
	sm.set_shader_parameter("tint", Color(1.0, 0.55, 0.18, 1.0))
	sm.set_shader_parameter("energy", 14.0)
	sm.set_shader_parameter("sharp", 1.5)
	var sq := QuadMesh.new()
	sq.size = Vector2(1, 1)
	sq.material = sm
	var spm := ParticleProcessMaterial.new()
	spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	spm.emission_sphere_radius = 1.5
	spm.direction = Vector3(0, 1, 0)
	spm.spread = 80.0
	spm.initial_velocity_min = 22.0
	spm.initial_velocity_max = 75.0
	spm.gravity = Vector3(0, -30, 0)
	spm.damping_min = 1.0
	spm.damping_max = 3.0
	spm.scale_min = 0.25
	spm.scale_max = 0.7
	var sg := Gradient.new()
	sg.set_color(0, Color(1, 1, 1, 1))
	sg.set_color(1, Color(1, 0.25, 0.05, 0))
	var sgt := GradientTexture1D.new()
	sgt.gradient = sg
	spm.color_ramp = sgt
	for i in SPARK_N:
		var p := GPUParticles3D.new()
		p.process_material = spm
		p.draw_pass_1 = sq
		p.amount = 64
		p.lifetime = 1.3
		p.one_shot = true
		p.explosiveness = 0.97
		p.emitting = false
		p.visibility_aabb = AABB(Vector3(-70, -70, -70), Vector3(140, 140, 140))
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_spark.append(p)

	for i in LIGHT_N:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.55, 0.22)
		l.light_energy = 0.0
		l.omni_range = 40.0
		l.omni_attenuation = 1.4
		l.shadow_enabled = false
		l.light_volumetric_fog_energy = 2.0
		l.visible = false
		add_child(l)
		_lights.append(l)

	_ball_t.resize(BALL_N)
	_ball_s.resize(BALL_N)
	for i in BALL_N:
		var bm := ShaderMaterial.new()
		bm.shader = _glow_shader
		bm.set_shader_parameter("tint", Color(1.0, 0.62, 0.25, 1.0))
		bm.set_shader_parameter("energy", 10.0)
		bm.set_shader_parameter("sharp", 2.2)
		var q := QuadMesh.new()
		q.size = Vector2(1, 1)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = bm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_balls.append(mi)
		_ball_t[i] = 0.0

	# debris
	var meshes: Array[Mesh] = []
	for v in 3:
		var sp := SphereMesh.new()
		sp.radial_segments = 5 + v
		sp.rings = 2 + v
		sp.radius = 0.5
		sp.height = 0.8 + v * 0.15
		meshes.append(sp)
	var mats: Array[StandardMaterial3D] = []
	for c in [Color(0.50, 0.24, 0.14), Color(0.62, 0.42, 0.24), Color(0.20, 0.16, 0.15), Color(0.36, 0.22, 0.13), Color(0.08, 0.05, 0.04)]:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		mats.append(m)
	mats[4].emission_enabled = true
	mats[4].emission = Color(1.0, 0.32, 0.06)
	mats[4].emission_energy_multiplier = 3.5
	var dshape := SphereShape3D.new()
	dshape.radius = 0.42
	_debris_t.resize(DEBRIS_N)
	for i in DEBRIS_N:
		var b := RigidBody3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[i % 3]
		mi.material_override = mats[i % 5]
		var s := 0.7 + 1.5 * _rng.randf()
		mi.scale = Vector3(s, s * (0.7 + 0.5 * _rng.randf()), s * (0.8 + 0.4 * _rng.randf()))
		_debris_s.append(mi.scale)
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		cs.shape = dshape
		cs.scale = Vector3.ONE * s
		b.add_child(cs)
		b.collision_layer = 4
		b.collision_mask = 1
		b.mass = 0.5
		b.freeze = true
		b.visible = false
		b.position = Vector3(0, -500, 0)
		add_child(b)
		_debris.append(b)
		_debris_t[i] = 0.0

	# meteor parts
	_trail_pm = ParticleProcessMaterial.new()
	_trail_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_trail_pm.emission_sphere_radius = 1.2
	_trail_pm.direction = Vector3(0, 1, 0)
	_trail_pm.spread = 180.0
	_trail_pm.initial_velocity_min = 0.5
	_trail_pm.initial_velocity_max = 4.0
	_trail_pm.gravity = Vector3(0, 1.0, 0)
	_trail_pm.scale_min = 2.5
	_trail_pm.scale_max = 5.0
	var tg := Gradient.new()
	tg.set_color(0, Color(1.0, 0.9, 0.7, 1.0))
	tg.set_color(1, Color(0.5, 0.08, 0.02, 0.0))
	tg.add_point(0.25, Color(1.0, 0.45, 0.12, 0.7))
	var tgt := GradientTexture1D.new()
	tgt.gradient = tg
	_trail_pm.color_ramp = tgt
	var tc := Curve.new()
	tc.add_point(Vector2(0, 1.0))
	tc.add_point(Vector2(1, 0.15))
	var tct := CurveTexture.new()
	tct.curve = tc
	_trail_pm.scale_curve = tct
	var tm := ShaderMaterial.new()
	tm.shader = _glow_shader
	tm.set_shader_parameter("tint", Color(1.0, 0.6, 0.3, 1.0))
	tm.set_shader_parameter("energy", 5.0)
	tm.set_shader_parameter("sharp", 1.6)
	_trail_mesh = QuadMesh.new()
	_trail_mesh.size = Vector2(1, 1)
	_trail_mesh.material = tm
	var hm := ShaderMaterial.new()
	hm.shader = _glow_shader
	hm.set_shader_parameter("tint", Color(1.0, 0.8, 0.55, 1.0))
	hm.set_shader_parameter("energy", 30.0)
	hm.set_shader_parameter("sharp", 2.4)
	var stm := ShaderMaterial.new()
	stm.shader = load("res://shaders/fx_streak.gdshader")
	_streak_mesh = QuadMesh.new()
	_streak_mesh.size = Vector2(1, 70)
	_streak_mesh.material = stm
	_head_mesh = QuadMesh.new()
	_head_mesh.size = Vector2(1, 1)
	_head_mesh.material = hm


func cam_pos() -> Vector3:
	var c := get_viewport().get_camera_3d()
	return c.global_position if c != null else Vector3.ZERO


func explode(pos: Vector3, r: float, heat := true) -> void:
	var nrm: Vector3 = world.gradient(pos)
	world.edit(VoxelWorld.OP_BLAST, pos, r)
	if heat:
		main.add_heat(pos, r * 1.08)
	burst(pos, r, nrm)
	# push loose bodies
	var reach := r * 2.4
	for b in main.bodies:
		var dv: Vector3 = b.global_position - pos
		var dl := dv.length()
		if dl < reach:
			b.sleeping = false
			b.apply_central_impulse((dv / maxf(dl, 0.5) + Vector3(0, 0.6, 0)) * (1.0 - dl / reach) * 34.0 * b.mass)
	var cd := cam_pos().distance_to(pos)
	trauma = minf(trauma + r * r * 1.6 / (cd * cd * 0.012 + 30.0) * 0.3, 1.0)


func burst(pos: Vector3, r: float, nrm: Vector3) -> void:
	var s := r / 7.0
	var d := _dust[_dust_i]
	_dust_i = (_dust_i + 1) % DUST_N
	d.global_transform = Transform3D(_basis_up(nrm).scaled(Vector3(s, s, s)), pos + nrm * r * 0.3)
	if not no_dust:
		d.restart()
		d.emitting = true
	if not no_dust and _shake_t - _smoke_t[_smoke_i] > 6.6:
		var k := _smoke[_smoke_i]
		_smoke_t[_smoke_i] = _shake_t
		_smoke_i = (_smoke_i + 1) % SMOKE_N
		k.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)), pos + nrm * r * 0.4)
		k.restart()
		k.emitting = true
	var sp := _spark[_spark_i]
	_spark_i = (_spark_i + 1) % SPARK_N
	sp.global_transform = Transform3D(_basis_up(nrm).scaled(Vector3(s, s, s)), pos + nrm * 1.0)
	if not no_spark:
		sp.restart()
		sp.emitting = true
	var l := _lights[_light_i]
	_light_i = (_light_i + 1) % LIGHT_N
	l.global_position = pos + nrm * (r * 0.6 + 1.0)
	l.omni_range = r * 8.0
	l.light_energy = 26.0
	l.visible = not no_light
	var b := _balls[_ball_i]
	_ball_t[_ball_i] = 1.0
	_ball_s[_ball_i] = r * 2.6
	_ball_i = (_ball_i + 1) % BALL_N
	b.global_position = pos + nrm * r * 0.25
	b.scale = Vector3.ONE * r
	b.visible = true
	# debris
	var nd := clampi(int(r * 1.5), 5, 15)
	if no_debris:
		nd = 0
	var bs := _basis_up(nrm)
	for i in nd:
		var a := _rng.randf() * TAU
		var e := 0.25 + 0.75 * _rng.randf()
		var dir := (bs * Vector3(cos(a) * (1.0 - e * 0.6), e, sin(a) * (1.0 - e * 0.6))).normalized()
		var body := _debris[_debris_i]
		(body.get_child(0) as Node3D).scale = _debris_s[_debris_i]
		_debris_t[_debris_i] = 3.2 + _rng.randf() * 1.6
		_debris_i = (_debris_i + 1) % DEBRIS_N
		body.freeze = true
		body.global_position = pos + dir * (1.5 + r * 0.35 * _rng.randf())
		body.reset_physics_interpolation()
		body.visible = true
		body.freeze = false
		body.sleeping = false
		body.linear_velocity = dir * (12.0 + (12.0 + r * 2.4) * _rng.randf())
		body.angular_velocity = Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) * 16.0


func puff(pos: Vector3, r: float, nrm: Vector3) -> void:
	var s := r / 7.0
	var d := _dust[_dust_i]
	_dust_i = (_dust_i + 1) % DUST_N
	d.global_transform = Transform3D(_basis_up(nrm).scaled(Vector3(s, s, s)), pos)
	d.restart()
	d.emitting = true


func _basis_up(n: Vector3) -> Basis:
	var t := n.cross(Vector3(0.31, 0.2, 0.93))
	if t.length_squared() < 0.001:
		t = n.cross(Vector3.RIGHT)
	t = t.normalized()
	return Basis(t, n, t.cross(n).normalized())


func meteor(target: Vector3, r: float, dir := Vector3(-0.52, -0.80, 0.30), speed := 150.0, dist := 260.0) -> void:
	dir = dir.normalized()
	var node := Node3D.new()
	node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(node)
	node.global_position = target - dir * dist
	var head := MeshInstance3D.new()
	head.mesh = _head_mesh
	head.scale = Vector3.ONE * r * 1.6
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(head)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.6, 0.3)
	l.light_energy = 6.0
	l.omni_range = 70.0
	l.light_volumetric_fog_energy = 3.0
	node.add_child(l)
	for k in 2:
		var st := MeshInstance3D.new()
		st.mesh = _streak_mesh
		st.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(st)
		st.scale = Vector3(r * 1.3, 1.0, 1.0)
		st.rotation = Vector3(0, k * PI * 0.5, 0)
		st.position = Vector3(0, 34.0, 0)
	node.basis = _basis_up(-dir)
	head.top_level = false
	var p := GPUParticles3D.new()
	p.process_material = _trail_pm
	p.draw_pass_1 = _trail_mesh
	p.amount = 220
	p.lifetime = 1.3
	p.fixed_fps = 0
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-300, -300, -300), Vector3(600, 600, 600))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(p)
	_meteors.append({"node": node, "dir": dir, "speed": speed, "r": r, "head": head, "light": l, "trail": p, "dead": -1.0, "floor": target.y - r})


func meteor_shower(center: Vector3, radius: float, count: int, span: float) -> void:
	for i in count:
		var a := _rng.randf() * TAU
		var rr := sqrt(_rng.randf()) * radius
		var x := clampf(center.x + cos(a) * rr, 20.0, 492.0)
		var z := clampf(center.z + sin(a) * rr, 20.0, 492.0)
		var y: float = world.surface_y(x, z)
		var r := 7.0 + 5.0 * _rng.randf()
		var delay := span * (i + _rng.randf() * 0.6) / count
		get_tree().create_timer(delay, false).timeout.connect(meteor.bind(Vector3(x, y, z), r))


func shake_offset() -> Vector3:
	var t := trauma * trauma
	return Vector3(sin(_shake_t * 47.0), sin(_shake_t * 61.0 + 1.3), sin(_shake_t * 53.0 + 2.1)) * t


func _process(dt: float) -> void:
	_shake_t += dt
	trauma = maxf(trauma - dt * 1.5, 0.0)
	for l in _lights:
		if l.visible:
			l.light_energy *= exp(-dt * 6.5)
			if l.light_energy < 0.05:
				l.visible = false
	for i in BALL_N:
		if _ball_t[i] > 0.0:
			_ball_t[i] -= dt * 5.0
			var b := _balls[i]
			if _ball_t[i] <= 0.0:
				b.visible = false
			else:
				var k := 1.0 - _ball_t[i]
				b.scale = Vector3.ONE * lerpf(_ball_s[i] * 0.35, _ball_s[i], sqrt(k))
				(b.material_override as ShaderMaterial).set_shader_parameter("energy", 16.0 * _ball_t[i] * _ball_t[i])
	for i in DEBRIS_N:
		if _debris_t[i] > 0.0:
			_debris_t[i] -= dt
			var b := _debris[i]
			if _debris_t[i] <= 0.0 or b.position.y < -10.0:
				_debris_t[i] = 0.0
				b.freeze = true
				b.visible = false
				b.position = Vector3(0, -500, 0)
			elif _debris_t[i] < 0.5:
				(b.get_child(0) as Node3D).scale *= exp(-dt * 5.0)
	var k := 0
	while k < _meteors.size():
		var m: Dictionary = _meteors[k]
		var node: Node3D = m.node
		if m.dead >= 0.0:
			m.dead += dt
			(m.light as OmniLight3D).light_energy *= exp(-dt * 8.0)
			if m.dead > 1.2:
				node.queue_free()
				_meteors.remove_at(k)
				continue
		else:
			var step: float = m.speed * dt
			var sub := int(ceil(step / 2.0))
			var hit := false
			for s in sub:
				node.position += m.dir * (step / sub)
				if world.solid(node.position) or node.position.y < m.floor or node.position.y < 3.0:
					hit = true
					break
			if hit:
				m.dead = 0.0
				(m.head as Node3D).visible = false
				for ch in node.get_children():
					if ch is MeshInstance3D:
						ch.visible = false
				(m.trail as GPUParticles3D).emitting = false
				var pos := node.position
				explode(pos, m.r)
				var e := _rng.randf() * 3.0
				burst(pos + Vector3(e, 2, -e), m.r * 0.7, Vector3.UP)
		k += 1
