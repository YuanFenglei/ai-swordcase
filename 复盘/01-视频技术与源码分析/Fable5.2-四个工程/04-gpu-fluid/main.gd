extends Node3D
## GPU MLS-MPM fluid showcase: game, sandbox, --demo, --shots.

const FluidSim = preload("res://fluid_sim.gd")
const FluidFX = preload("res://fluid_fx.gd")

const TANK := Vector3(20.0, 8.0, 8.0)     # inner size of the sim domain in metres
const GLASS_H := 5.6
const SUN_DIR := Vector3(-0.38, 0.62, -0.68)
const WATER_ABS := Color(0.62, 0.10, 0.05, 0.9)
const WATER_SCAT := Color(0.02, 0.22, 0.30)
const DYE_ABS := Color(0.07, 1.0, 0.32, 1.3)
const DYE_SCAT := Color(0.60, 0.05, 0.30)
const HONEY_ABS := Color(0.35, 1.25, 5.0, 1.4)
const HONEY_SCAT := Color(0.58, 0.27, 0.015)
const GRAVITY := 0.1

enum Mode { GAME, SANDBOX, DEMO, SHOTS }

var mode := Mode.GAME
var sim := FluidSim.new()
var fx: FluidFX
var cam: Camera3D
var sun: DirectionalLight3D
var env: Environment
var level: Node3D
var floor_mat: ShaderMaterial

# sim driving
var paused := false
var fixed_substeps := 0
var sim_seconds := 0.0
var real_delta := 0.016
var dir_delta := 0.016
var autoshots := false
var _autoshot_t := 0.0
var _autoshot_i := 0
var _last_usec := 0
var frame_times := PackedFloat32Array()
var collect_frames := false
var sim_ms := 0.0
var fx_ms := 0.0
var fps_smooth := 60.0

# level objects
var kinematic: Array = []      # {node, half, type, prev: Vector3, vel: Vector3}
var bodies: Array = []         # {body, half, type}  rigid bodies that push the fluid
var floaters: Array = []       # {body, pts, start, buoy, drag}
var emitters: Array = []       # {pos, dir, radius, speed, dye}
var boat: RigidBody3D
var gate: AnimatableBody3D
var gate_base_y := 0.0
var gate_open := 0.0
var gate_target := 0.0
var paddle: AnimatableBody3D
var paddle_on := true
var paddle_x := 0.0
var buoys: Array = []
var gravity_dir := Vector3.DOWN
var gravity_mode := 0
var honey := false
var honey_mix := 0.0
var two_color := false
var slowmo := false
var wipe_target := 1.2
var res_x := 116

# game
var score := 0
var buoy_total := 8
var time_left := 75.0
var gate_timer := 12.0
var game_state := 0            # 0 playing, 1 won, 2 lost
var capsize_t := 0.0
var autopilot := false
var route: Array = []
var route_i := 0
var end_text := ""

# camera
var cam_keys: Array = []
var cam_t := 0.0
var cam_follow: Node3D
var cam_follow_pos := Vector3.ZERO
var orbit_yaw := 0.5
var orbit_pitch := 0.45
var orbit_dist := 24.0
var orbit_target := Vector3(0, 1.5, 0)
var dragging_orbit := false
var dragging_force := false

# ui
var ui: CanvasLayer
var lbl_particles: Label
var lbl_fps: Label
var lbl_score: Label
var lbl_time: Label
var lbl_gate: Label
var lbl_title: Label
var lbl_big: Label
var lbl_big_sub: Label
var end_panel: Control
var lbl_end: Label
var sandbox_panel: Control
var fade: ColorRect
var btns := {}


func _ready() -> void:
	var particles_arg := 0
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			mode = Mode.DEMO
		elif a == "--autoshots":
			autoshots = true
		elif a == "--shots":
			mode = Mode.SHOTS
		elif a.begins_with("--particles="):
			particles_arg = int(a.get_slice("=", 1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if mode == Mode.GAME else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_build_world()
	_build_ui()
	RenderingServer.call_on_render_thread(sim.init_rt)
	if particles_arg > 0:
		res_x = clampi(int(round(120.0 * pow(particles_arg / 308000.0, 1.0 / 3.0))) + 4, 60, 260)
	_last_usec = Time.get_ticks_usec()
	match mode:
		Mode.DEMO:
			_run_demo()
		Mode.SHOTS:
			_run_shots()
		_ when OS.get_cmdline_user_args().has("--selftest"):
			_start_game()
			_selftest()
		_:
			_start_game()


func _exit_tree() -> void:
	fx.sim = null
	RenderingServer.call_on_render_thread(sim.free_rt)


# ------------------------------------------------------------------ world

func _prop_mat(kind: int, tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://props.gdshader")
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("tint", tint)
	return m


func _box(parent: Node, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _static_box(parent: Node, size: Vector3, pos: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	sb.position = pos
	parent.add_child(sb)
	return sb


func _build_world() -> void:
	env = Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://sky.gdshader")
	sky.sky_material = sm
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.92
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.12
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.ssao_enabled = true
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.60, 0.73, 0.90)
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 30.0
	env.fog_depth_end = 320.0
	env.fog_depth_curve = 0.6
	env.fog_density = 1.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	fx = FluidFX.new()
	fx.sim = sim
	fx.sun_dir = SUN_DIR
	var comp := Compositor.new()
	comp.compositor_effects = [fx]
	we.compositor = comp
	add_child(we)

	sun = DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(SUN_DIR * 30.0, Vector3.ZERO)
	sun.light_energy = 2.4
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_blur = 1.5

	cam = Camera3D.new()
	cam.fov = 45.0
	cam.near = 0.1
	cam.far = 400.0
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 9, 22), Vector3(0, 1.5, 0))

	# ground + plinth
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	ground.mesh = pm
	ground.material_override = _prop_mat(3, Color(0.30, 0.31, 0.33))
	ground.position.y = -0.6
	add_child(ground)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.09, 0.10, 0.12)
	dark.metallic = 0.7
	dark.roughness = 0.35
	_box(self, Vector3(TANK.x + 0.7, 0.6, TANK.z + 0.7), Vector3(0, -0.3, 0), dark)

	# tank floor
	var fl := MeshInstance3D.new()
	var fpm := PlaneMesh.new()
	fpm.size = Vector2(TANK.x, TANK.z)
	fl.mesh = fpm
	floor_mat = ShaderMaterial.new()
	floor_mat.shader = preload("res://floor.gdshader")
	floor_mat.set_shader_parameter("column_tex", sim.column_tex)
	fl.material_override = floor_mat
	fl.position.y = 0.001
	add_child(fl)

	# glass panes: single sided, facing outwards, so panes behind the water are culled
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.75, 0.92, 1.0, 0.09)
	glass.rim_enabled = true
	glass.rim = 0.6
	glass.roughness = 0.03
	glass.metallic_specular = 0.9
	glass.cull_mode = BaseMaterial3D.CULL_BACK
	var hx := TANK.x * 0.5
	var hz := TANK.z * 0.5
	for i in 4:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(TANK.x if i < 2 else TANK.z, GLASS_H)
		q.mesh = qm
		q.material_override = glass
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		match i:
			0: q.position = Vector3(0, GLASS_H * 0.5, hz + 0.02)
			1:
				q.position = Vector3(0, GLASS_H * 0.5, -hz - 0.02)
				q.rotation.y = PI
			2:
				q.position = Vector3(hx + 0.02, GLASS_H * 0.5, 0)
				q.rotation.y = PI * 0.5
			3:
				q.position = Vector3(-hx - 0.02, GLASS_H * 0.5, 0)
				q.rotation.y = -PI * 0.5
		add_child(q)
	# frame
	var fr := 0.14
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(self, Vector3(fr, GLASS_H + 0.1, fr), Vector3(sx * (hx + fr * 0.5), GLASS_H * 0.5, sz * (hz + fr * 0.5)), dark)
		_box(self, Vector3(fr, fr, TANK.z + fr * 2.0), Vector3(sx * (hx + fr * 0.5), GLASS_H + fr * 0.5, 0), dark)
		_box(self, Vector3(TANK.x + fr * 2.0, fr, fr), Vector3(0, GLASS_H + fr * 0.5, sx * (hz + fr * 0.5)), dark)
		_box(self, Vector3(TANK.x + fr * 2.0, fr, fr), Vector3(0, fr * 0.5 - 0.02, sx * (hz + fr * 0.5)), dark)
		_box(self, Vector3(fr, fr, TANK.z + fr * 2.0), Vector3(sx * (hx + fr * 0.5), fr * 0.5 - 0.02, 0), dark)

	# physics walls for rigid bodies
	_static_box(self, Vector3(TANK.x + 4, 2, TANK.z + 4), Vector3(0, -1, 0))
	_static_box(self, Vector3(2, 30, TANK.z + 4), Vector3(hx + 1, 14, 0))
	_static_box(self, Vector3(2, 30, TANK.z + 4), Vector3(-hx - 1, 14, 0))
	_static_box(self, Vector3(TANK.x + 4, 30, 2), Vector3(0, 14, hz + 1))
	_static_box(self, Vector3(TANK.x + 4, 30, 2), Vector3(0, 14, -hz - 1))

	level = Node3D.new()
	add_child(level)


# ------------------------------------------------------------------ sim config / levels

func _configure(p_res_x: int, capacity: int) -> void:
	res_x = p_res_x
	var dx := TANK.x / float(res_x - 4)
	var g := Vector3i(res_x, int(ceil(TANK.y / dx)) + 4, int(round(TANK.z / dx)) + 4)
	sim.dx = dx
	sim.origin = Vector3(-TANK.x * 0.5 - 2.0 * dx, -2.0 * dx, -TANK.z * 0.5 - 2.0 * dx)
	sim.clear_particles()
	sim.grid = g
	sim.capacity = capacity
	RenderingServer.call_on_render_thread(sim.resize_rt.bind(g, capacity))
	floor_mat.set_shader_parameter("grid_origin", sim.origin)
	floor_mat.set_shader_parameter("grid_size_m", Vector2(g.x, g.z) * dx)
	floor_mat.set_shader_parameter("cell", dx)
	floor_mat.set_shader_parameter("column_tex", sim.column_tex)


func _clear_level() -> void:
	for c in level.get_children():
		c.queue_free()
	kinematic.clear()
	bodies.clear()
	floaters.clear()
	emitters.clear()
	buoys.clear()
	boat = null
	route = []
	gate = null
	paddle = null
	gate_open = 0.0
	gate_target = 0.0
	sim.clear_particles()
	sim.mouse_active = false
	_set_gravity(Vector3.DOWN)
	honey = false
	honey_mix = 0.0
	two_color = false
	sim.viscosity = 0.08
	sim.damping = 1.0
	sim.stiffness = 6.0
	Engine.time_scale = 1.0
	slowmo = false
	paused = false


func _set_gravity(dir: Vector3) -> void:
	gravity_dir = dir
	sim.gravity = dir * GRAVITY
	PhysicsServer3D.area_set_param(get_world_3d().space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, dir.normalized() if dir.length() > 0.01 else Vector3.DOWN)
	PhysicsServer3D.area_set_param(get_world_3d().space, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.8 * dir.length())


func _per_m3() -> float:
	return FluidSim.REST / pow(sim.dx, 3.0)


func _add_kinematic(node: Node3D, half: Vector3, type := 1) -> void:
	kinematic.append({"node": node, "half": half, "type": type, "prev": node.global_position, "vel": Vector3.ZERO})


func _solid(size: Vector3, pos: Vector3, mat: Material, animatable := false) -> PhysicsBody3D:
	var b: PhysicsBody3D = AnimatableBody3D.new() if animatable else StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	_box(b, size, Vector3.ZERO, mat)
	b.position = pos
	level.add_child(b)
	_add_kinematic(b, size * 0.5)
	return b


func _add_floater(body: RigidBody3D, pts: PackedVector3Array, buoy: float, drag: float) -> void:
	floaters.append({"body": body, "pts": pts, "start": 0, "buoy": buoy, "drag": drag, "sub": 0.0})


func _make_crate(pos: Vector3, s := 0.75) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.mass = 55.0
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3.ONE * s
	cs.shape = sh
	b.add_child(cs)
	_box(b, Vector3.ONE * s, Vector3.ZERO, _prop_mat(1, Color(0.78, 0.55, 0.30)))
	b.position = pos
	b.rotation = Vector3(randf(), randf(), randf()) * 0.6
	level.add_child(b)
	var pts := PackedVector3Array()
	var h := s * 0.42
	for x in [-h, h]:
		for y in [-h, h]:
			for z in [-h, h]:
				pts.append(Vector3(x, y, z))
	_add_floater(b, pts, 2.3, 3.0)
	bodies.append({"body": b, "half": Vector3.ONE * s * 0.5, "type": 1})
	return b


func _boat_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := [Vector3(-1.15, 0.28, -0.52), Vector3(0.35, 0.28, -0.55), Vector3(1.35, 0.34, 0.0), Vector3(0.35, 0.28, 0.55), Vector3(-1.15, 0.28, 0.52)]
	var bot := [Vector3(-1.0, -0.3, -0.3), Vector3(0.3, -0.32, -0.34), Vector3(1.0, -0.2, 0.0), Vector3(0.3, -0.32, 0.34), Vector3(-1.0, -0.3, 0.3)]
	var n := top.size()
	for i in n:
		var j := (i + 1) % n
		for v in [top[i], top[j], bot[j], top[i], bot[j], bot[i]]:
			st.add_vertex(v)
	for i in range(1, n - 1):
		for v in [top[0], top[i + 1], top[i]]:
			st.add_vertex(v)
		for v in [bot[0], bot[i], bot[i + 1]]:
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _make_boat(pos: Vector3) -> void:
	boat = RigidBody3D.new()
	boat.mass = 260.0
	boat.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	boat.center_of_mass = Vector3(0, -0.22, 0)
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(2.3, 0.6, 1.0)
	cs.shape = sh
	boat.add_child(cs)
	var hull := MeshInstance3D.new()
	hull.mesh = _boat_mesh()
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(0.85, 0.12, 0.10)
	hm.roughness = 0.3
	hm.metallic_specular = 0.7
	hull.material_override = hm
	boat.add_child(hull)
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.95, 0.95, 0.93)
	white.roughness = 0.35
	var darkm := StandardMaterial3D.new()
	darkm.albedo_color = Color(0.05, 0.07, 0.1)
	darkm.roughness = 0.1
	_box(boat, Vector3(2.2, 0.05, 1.0), Vector3(-0.1, 0.3, 0), white).scale = Vector3(1, 1, 0.92)
	_box(boat, Vector3(0.8, 0.42, 0.66), Vector3(-0.35, 0.53, 0), white)
	_box(boat, Vector3(0.82, 0.16, 0.68), Vector3(-0.35, 0.60, 0), darkm)
	_box(boat, Vector3(0.9, 0.05, 0.76), Vector3(-0.35, 0.76, 0), hm)
	_box(boat, Vector3(0.05, 0.5, 0.05), Vector3(-0.6, 1.0, 0), darkm)
	boat.position = pos
	boat.can_sleep = false
	level.add_child(boat)
	var pts := PackedVector3Array()
	for x in [-0.95, -0.3, 0.35, 1.0]:
		for z in [-0.4, 0.4]:
			pts.append(Vector3(x, -0.12, z if x < 0.9 else z * 0.4))
	_add_floater(boat, pts, 2.6, 2.2)
	bodies.append({"body": boat, "half": Vector3(1.1, 0.3, 0.46), "type": 1})


func _make_buoy(pos: Vector3) -> void:
	var b := RigidBody3D.new()
	b.mass = 6.0
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.3
	cs.shape = sh
	b.add_child(cs)
	b.collision_layer = 2
	b.collision_mask = 1
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.45, 0.02)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.35, 0.02)
	m.emission_energy_multiplier = 1.6
	m.roughness = 0.3
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.3
	sp.height = 0.6
	mi.mesh = sp
	mi.material_override = m
	b.add_child(mi)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.97, 0.97, 0.97)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.26
	tm.outer_radius = 0.36
	ring.mesh = tm
	ring.material_override = wm
	b.add_child(ring)
	var pole := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.025
	cm.bottom_radius = 0.025
	cm.height = 0.9
	pole.mesh = cm
	pole.material_override = wm
	pole.position.y = 0.6
	b.add_child(pole)
	var flag := _box(b, Vector3(0.3, 0.2, 0.02), Vector3(0.16, 0.95, 0), m)
	flag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	b.center_of_mass = Vector3(0, -0.2, 0)
	b.position = pos
	b.angular_damp = 2.0
	level.add_child(b)
	_add_floater(b, PackedVector3Array([Vector3(0, -0.05, 0)]), 3.0, 4.0)
	buoys.append(b)


func _concrete() -> ShaderMaterial:
	return _prop_mat(0, Color(0.62, 0.63, 0.64))


func _level_game() -> void:
	_clear_level()
	var hx := TANK.x * 0.5
	var hz := TANK.z * 0.5
	var dam_x := -4.6
	var gate_w := 3.0
	var side_w := (TANK.z - gate_w) * 0.5
	var dam_h := 5.3
	for s in [-1.0, 1.0]:
		_solid(Vector3(0.7, dam_h, side_w), Vector3(dam_x, dam_h * 0.5, s * (gate_w * 0.5 + side_w * 0.5)), _concrete())
	_box(level, Vector3(0.9, 0.5, TANK.z), Vector3(dam_x, dam_h + 0.25, 0), _concrete())
	gate = _solid(Vector3(0.5, dam_h, gate_w + 0.1), Vector3(dam_x, dam_h * 0.5, 0), _prop_mat(2, Color(0.95, 0.68, 0.05)), true)
	gate_base_y = dam_h * 0.5
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.55, 0.58, 0.62)
	steel.metallic = 0.85
	steel.roughness = 0.32
	paddle_x = hx - 1.0
	paddle = _solid(Vector3(0.45, 5.3, TANK.z - 0.1), Vector3(paddle_x, 2.65, 0), steel, true)
	# water
	sim.fill_box(Vector3(-hx, 0, -hz), Vector3(dam_x - 0.4, 4.9, hz))
	sim.fill_box(Vector3(dam_x + 0.4, 0, -hz), Vector3(paddle_x - 0.3, 1.8, hz))
	_make_boat(Vector3(1.0, 2.1, 0.5))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 5:
		_make_crate(Vector3(rng.randf_range(-2.5, 6.5), 2.2 + i * 0.3, rng.randf_range(-3.0, 3.0)))
	var spots := [Vector3(-2.2, 2, -2.6), Vector3(-1.5, 2, 2.7), Vector3(2.6, 2, -2.9), Vector3(4.0, 2, 2.4),
			Vector3(5.8, 2, -1.2), Vector3(7.4, 2, 2.8), Vector3(7.8, 2, -2.9), Vector3(3.6, 2, 0.0)]
	for p in spots:
		_make_buoy(p)
	buoy_total = spots.size()
	paddle_on = true
	_apply_colors()


func _level_dambreak(limit := -1, with_pillars := true) -> void:
	_clear_level()
	var hx := TANK.x * 0.5
	var hz := TANK.z * 0.5
	if with_pillars:
		for p in [Vector3(1.5, 0, -2.2), Vector3(3.6, 0, 0.6), Vector3(1.0, 0, 2.6)]:
			_solid(Vector3(0.9, 4.2, 0.9), p + Vector3(0, 2.1, 0), _concrete())
	sim.fill_box(Vector3(-hx, 0, -hz), Vector3(-4.0, 5.5, hz), 0.0, Vector3.ZERO, limit)
	paddle_on = false
	_apply_colors()


func _level_mix() -> void:
	_clear_level()
	var hx := TANK.x * 0.5
	var hz := TANK.z * 0.5
	two_color = true
	sim.fill_box(Vector3(-hx, 0, -hz), Vector3(-5.2, 4.3, hz), 0.0)
	sim.fill_box(Vector3(5.2, 0, -hz), Vector3(hx, 4.3, hz), 1.0)
	_apply_colors()


func _level_honey() -> void:
	_clear_level()
	honey = true
	honey_mix = 1.0
	sim.viscosity = 1.6
	sim.damping = 0.975
	sim.fill_box(Vector3(-TANK.x * 0.5, 0, -TANK.z * 0.5), Vector3(-5.0, 4.6, TANK.z * 0.5))
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 1.5
	cs.shape = sh
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 1.5
	sp.height = 3.0
	mi.mesh = sp
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.93, 0.93, 0.95)
	m.roughness = 0.18
	m.metallic = 0.0
	mi.material_override = m
	sb.add_child(mi)
	sb.position = Vector3(0, 1.5, 0)
	level.add_child(sb)
	_add_kinematic(sb, Vector3(1.5, 1.5, 1.5), 2)
	emitters.append({"pos": Vector3(0.3, 7.0, 0.1), "dir": Vector3.DOWN, "radius": 0.6, "speed": 5.0, "dye": 0.0})
	_apply_colors()


func _level_pool(depth: float) -> void:
	_clear_level()
	sim.fill_box(Vector3(-TANK.x * 0.5, 0, -TANK.z * 0.5), Vector3(TANK.x * 0.5, depth, TANK.z * 0.5))
	_apply_colors()


func _apply_colors() -> void:
	var a_abs := WATER_ABS.lerp(HONEY_ABS, honey_mix)
	var a_sc := WATER_SCAT.lerp(HONEY_SCAT, honey_mix)
	fx.absorb_a = a_abs
	fx.scat_a = a_sc
	fx.absorb_b = DYE_ABS
	fx.scat_b = DYE_SCAT
	fx.foam_strength = 1.0 - honey_mix
	fx.min_thick = 0.55 * honey_mix
	floor_mat.set_shader_parameter("caustic_strength", 1.0 - honey_mix)
	sim.use_dye = two_color


# ------------------------------------------------------------------ per-frame

func _physics_process(delta: float) -> void:
	# kinematic movers
	if gate:
		gate_open = move_toward(gate_open, gate_target, delta * 0.55)
		gate.position.y = gate_base_y + gate_open * 3.4
	if paddle:
		var px := paddle_x + (sin(sim_seconds * 1.9) * 0.28 if paddle_on else 0.0)
		paddle.position.x = lerpf(paddle.position.x, px, 0.2)
	for k in kinematic:
		var n: Node3D = k.node
		if not is_instance_valid(n):
			continue
		var p := n.global_position
		k.vel = (p - k.prev) / maxf(delta, 1e-4)
		k.prev = p
	# fluid -> bodies
	var idx := 0
	var up := -gravity_dir
	for fl in floaters:
		if not is_instance_valid(fl.body):
			idx += fl.pts.size()
			continue
		var b: RigidBody3D = fl.body
		var n: int = fl.pts.size()
		var sub := 0.0
		var xf := b.global_transform
		for i in n:
			var res := sim.probe(idx + i)
			var frac: float = res[1]
			if frac > 0.01:
				var rel: Vector3 = xf.basis * fl.pts[i]
				var pv := b.linear_velocity + b.angular_velocity.cross(rel - xf.basis * b.center_of_mass)
				var rise := clampf(1.0 - pv.dot(up) / 3.5, 0.0, 1.0)
				var f: Vector3 = up * (b.mass * 9.8 * fl.buoy / n) * frac * rise
				f += (res[0] - pv) * (b.mass * fl.drag / n) * frac
				b.apply_force(f, rel)
				sub += frac / n
		fl.sub = sub
		b.angular_damp = 0.4 + 5.0 * sub
		b.linear_damp = 0.02 + 0.3 * sub
		idx += n
	if boat and is_instance_valid(boat):
		_drive_boat(delta)


func _boat_sub() -> float:
	for fl in floaters:
		if is_instance_valid(fl.body) and fl.body == boat:
			return fl.sub
	return 0.0


func _drive_boat(delta: float) -> void:
	var thrust := 0.0
	var steer := 0.0
	if autopilot:
		var target := Vector3.ZERO
		var best := 1e9
		for b in buoys:
			if is_instance_valid(b):
				var d: float = b.global_position.distance_to(boat.global_position)
				if d < best:
					best = d
					target = b.global_position
		if not route.is_empty():
			target = route[route_i % route.size()]
			if Vector2(target.x - boat.global_position.x, target.z - boat.global_position.z).length() < 1.6:
				route_i += 1
		elif best > 1e8:
			target = Vector3(sin(sim_seconds * 0.5) * 6.0 + 2.0, 0, cos(sim_seconds * 0.5) * 2.5)
		var to := target - boat.global_position
		to.y = 0
		var fwd := boat.global_transform.basis.x
		var ang := atan2(-(fwd.x * to.z - fwd.z * to.x), fwd.x * to.x + fwd.z * to.z)
		steer = clampf(ang * 2.0, -1.0, 1.0)
		thrust = clampf(1.0 - absf(ang) / 1.1, 0.15, 0.75 if not route.is_empty() else 1.0)
	elif mode == Mode.GAME and game_state == 0:
		thrust = Input.get_axis("ui_down", "ui_up") + (1.0 if Input.is_physical_key_pressed(KEY_W) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_S) else 0.0)
		steer = Input.get_axis("ui_right", "ui_left") + (1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0)
		thrust = clampf(thrust, -1, 1)
		steer = clampf(steer, -1, 1)
	var sub := clampf(_boat_sub() * 2.5, 0.0, 1.0)
	var basis := boat.global_transform.basis
	var fwd := basis.x
	fwd.y = 0
	fwd = fwd.normalized()
	boat.apply_central_force(fwd * thrust * 2300.0 * sub)
	boat.apply_torque(Vector3.UP * steer * 1500.0 * sub)
	# keel: resist sideways slip
	var right := basis.z
	var side := boat.linear_velocity.dot(right)
	boat.apply_central_force(-right * side * boat.mass * 2.5 * sub)
	# self-righting
	var tilt := basis.y.cross(Vector3.UP)
	boat.apply_torque(tilt * 2600.0)
	# pickups
	for b in buoys:
		if is_instance_valid(b) and b.global_position.distance_to(boat.global_position) < 1.35:
			b.queue_free()
			score += 1
	if basis.y.y < 0.15:
		capsize_t += delta
	else:
		capsize_t = 0.0


func _collect_colliders() -> void:
	var cols: Array = []
	for k in kinematic:
		if is_instance_valid(k.node):
			cols.append({"xf": k.node.global_transform, "half": k.half, "type": k.type, "lin": k.vel, "ang": Vector3.ZERO})
	for b in bodies:
		if is_instance_valid(b.body):
			var rb: RigidBody3D = b.body
			cols.append({"xf": rb.global_transform, "half": b.half, "type": b.type, "lin": rb.linear_velocity, "ang": rb.angular_velocity})
	sim.colliders = cols
	var pr := PackedVector3Array()
	for fl in floaters:
		var ok := is_instance_valid(fl.body)
		var xf: Transform3D = fl.body.global_transform if ok else Transform3D()
		for p in fl.pts:
			pr.append(xf * p if ok else Vector3(0, -50, 0))
	sim.probes = pr


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	real_delta = minf((now - _last_usec) / 1.0e6, 0.1)
	_last_usec = now
	if collect_frames:
		frame_times.append(real_delta)
	fps_smooth = lerpf(fps_smooth, 1.0 / maxf(real_delta, 1e-4), 0.08)
	_read_gpu_times()

	# sim step
	var total := 0.0
	var n := 0
	if not paused:
		if fixed_substeps > 0:
			n = fixed_substeps
			total = n * FluidSim.DT
		else:
			total = minf(delta * FluidSim.SIM_RATE, 0.4)
			n = int(ceil(total / FluidSim.DT - 0.001))
	sim.dt = total / n if n > 0 else FluidSim.DT
	for e in emitters:
		sim.emit_disc(e.pos, e.dir, e.radius, e.speed, e.dye, total, e.get("dense", 1.05), e.get("foam", 0.0))
	_collect_colliders()
	sim.step(n)
	sim_seconds += total / FluidSim.SIM_RATE
	dir_delta = real_delta if (paused or n == 0 or fixed_substeps > 0) else minf(total / FluidSim.SIM_RATE / maxf(Engine.time_scale, 0.05), 0.05)
	if autoshots:
		_autoshot_t += dir_delta
		if _autoshot_t >= 3.0:
			_autoshot_t = 0.0
			_autoshot_i += 1
			get_viewport().get_texture().get_image().save_png("res://_shots/demo_%02d.png" % _autoshot_i)

	# look
	fx.wipe = move_toward(fx.wipe, wipe_target, real_delta * 1.4 * 0.55)
	fx.time += real_delta
	var hm := 1.0 if honey else 0.0
	if absf(honey_mix - hm) > 0.001:
		honey_mix = move_toward(honey_mix, hm, real_delta * 0.7)
		_apply_colors()
	_update_camera(dir_delta)
	_update_game(delta)
	_update_ui()


func _read_gpu_times() -> void:
	var rd := RenderingServer.get_rendering_device()
	var t := {}
	for i in rd.get_captured_timestamps_count():
		t[rd.get_captured_timestamp_name(i)] = rd.get_captured_timestamp_gpu_time(i)
	if t.has("fluid_sim_begin") and t.has("fluid_sim_end"):
		sim_ms = lerpf(sim_ms, (t["fluid_sim_end"] - t["fluid_sim_begin"]) / 1.0e6, 0.1)
	if sim.profile and Engine.get_frames_drawn() % 120 == 0:
		var names := ["fluid_sim_begin", "p_clear", "p_p2g", "p_grid", "p_g2p", "fluid_sim_end", "fluid_fx_begin", "f_raster", "f_smooth", "fluid_fx_end"]
		var out := ""
		for i in range(1, names.size()):
			if t.has(names[i]) and t.has(names[i - 1]):
				out += "%s=%.2f " % [names[i], (t[names[i]] - t[names[i - 1]]) / 1.0e6]
		print("PROFILE ", out)
	if t.has("fluid_fx_begin") and t.has("fluid_fx_end"):
		fx_ms = lerpf(fx_ms, (t["fluid_fx_end"] - t["fluid_fx_begin"]) / 1.0e6, 0.1)


# ------------------------------------------------------------------ camera

func _set_cam(keys: Array, follow: Node3D = null) -> void:
	cam_keys = keys
	cam_t = 0.0
	cam_follow = follow
	if follow:
		cam_follow_pos = follow.global_position


func _update_camera(dt: float) -> void:
	if mode == Mode.SANDBOX:
		var dir := Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch))
		cam.look_at_from_position(orbit_target + dir * orbit_dist, orbit_target)
		return
	if mode == Mode.GAME:
		if boat and is_instance_valid(boat):
			var bp := boat.global_position
			var tx := clampf(bp.x, -5.0, 6.0)
			var want := Vector3(tx * 0.5, 10.5, 15.0)
			var look := Vector3(tx * 0.6 + 0.5, 0.8, bp.z * 0.3)
			cam_follow_pos = cam_follow_pos.lerp(look, 1.0 - exp(-dt * 2.5))
			cam.position = cam.position.lerp(want, 1.0 - exp(-dt * 2.5))
			cam.look_at(cam_follow_pos)
			cam.fov = 48.0
		return
	if cam_keys.is_empty():
		return
	cam_t += dt
	var a: Array = cam_keys[0]
	var b: Array = cam_keys[cam_keys.size() - 1]
	for i in cam_keys.size() - 1:
		if cam_t >= cam_keys[i][0]:
			a = cam_keys[i]
			b = cam_keys[i + 1]
	var u := clampf((cam_t - a[0]) / maxf(b[0] - a[0], 0.001), 0.0, 1.0)
	if cam_keys.size() <= 2:
		u = u * u * (3.0 - 2.0 * u)
	var pos: Vector3 = a[1].lerp(b[1], u)
	var look: Vector3 = a[2].lerp(b[2], u)
	var fov: float = lerpf(a[3], b[3], u) if a.size() > 3 else 45.0
	if cam_follow and is_instance_valid(cam_follow):
		cam_follow_pos = cam_follow_pos.lerp(cam_follow.global_position, 1.0 - exp(-dt * 3.0))
		pos.x += cam_follow_pos.x * 0.6
		look += Vector3(cam_follow_pos.x, cam_follow_pos.y * 0.5, cam_follow_pos.z * 0.6)
	cam.fov = fov
	cam.look_at_from_position(pos, look)


# ------------------------------------------------------------------ game

func _start_game() -> void:
	mode = Mode.GAME
	autopilot = false
	_configure(res_x, _capacity_for(res_x))
	_restart_game()


func _restart_game() -> void:
	_level_game()
	score = 0
	time_left = 75.0
	gate_timer = 12.0
	game_state = 0
	capsize_t = 0.0
	wipe_target = 1.2
	fx.wipe = 1.2
	cam.position = Vector3(0, 10.5, 14.5)
	cam_follow_pos = Vector3(1, 0.8, 0)


func _update_game(delta: float) -> void:
	if mode != Mode.GAME or game_state != 0:
		return
	time_left -= delta
	if gate_target < 0.5:
		gate_timer -= delta
		if gate_timer <= 0.0:
			gate_target = 1.0
	if score >= buoy_total:
		game_state = 1
		end_text = "通关"
	elif capsize_t > 2.5:
		game_state = 2
		end_text = "翻船"
	elif time_left <= 0.0:
		game_state = 2
		end_text = "超时"


func _enter_sandbox() -> void:
	mode = Mode.SANDBOX
	game_state = 0
	autopilot = true


func _unhandled_input(ev: InputEvent) -> void:
	if mode == Mode.DEMO or mode == Mode.SHOTS:
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			get_tree().quit()
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_ESCAPE: get_tree().quit()
			KEY_TAB:
				if mode == Mode.GAME:
					_enter_sandbox()
				else:
					mode = Mode.GAME
					autopilot = false
					_restart_game()
			KEY_R: _on_reset()
			KEY_SPACE: _toggle_gate()
			KEY_P: _toggle_view()
			KEY_V: _toggle_honey()
			KEY_G: _cycle_gravity()
			KEY_T: _toggle_slowmo()
			KEY_F: _toggle_fountain()
			KEY_C: _toggle_two_color()
			KEY_M: _toggle_paddle()
			KEY_1: _preset(116)
			KEY_2: _preset(145)
			KEY_3: _preset(182)
	if mode != Mode.SANDBOX:
		return
	if ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_RIGHT:
			dragging_orbit = ev.pressed
		elif ev.button_index == MOUSE_BUTTON_LEFT:
			dragging_force = ev.pressed
			if not ev.pressed:
				sim.mouse_active = false
		elif ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_dist = maxf(orbit_dist * 0.92, 5.0)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_dist = minf(orbit_dist * 1.08, 60.0)
	elif ev is InputEventMouseMotion:
		if dragging_orbit:
			orbit_yaw -= ev.relative.x * 0.005
			orbit_pitch = clampf(orbit_pitch + ev.relative.y * 0.005, 0.03, 1.5)
		elif dragging_force:
			sim.mouse_origin = cam.project_ray_origin(ev.position)
			sim.mouse_dir = cam.project_ray_normal(ev.position)
			var f: Vector3 = (cam.global_transform.basis.x * ev.relative.x - cam.global_transform.basis.y * ev.relative.y) * 0.02
			sim.mouse_force = f.limit_length(0.5)
			sim.mouse_radius = 1.2 / sim.dx
			sim.mouse_active = true


func _on_reset() -> void:
	if mode == Mode.GAME:
		_restart_game()
	else:
		_level_game()


func _toggle_gate() -> void:
	gate_target = 1.0 if gate_target < 0.5 else 0.0


func _toggle_view() -> void:
	wipe_target = -0.2 if wipe_target > 0.5 else 1.2


func _toggle_honey() -> void:
	honey = not honey
	sim.viscosity = 1.6 if honey else 0.08
	sim.damping = 0.975 if honey else 1.0


func _cycle_gravity() -> void:
	gravity_mode = (gravity_mode + 1) % 5
	_set_gravity([Vector3.DOWN, Vector3(0.75, -0.66, 0), Vector3(-0.75, -0.66, 0), Vector3(0, -0.66, 0.75), Vector3(0, 0.6, 0)][gravity_mode])


func _toggle_slowmo() -> void:
	slowmo = not slowmo
	Engine.time_scale = 0.25 if slowmo else 1.0


func _toggle_fountain() -> void:
	if emitters.is_empty():
		emitters.append({"pos": Vector3(4.0, 0.3, 0.0), "dir": Vector3(0.0, 1.0, 0.0), "radius": 0.45, "speed": 11.0, "dye": 1.0 if two_color else 0.0, "foam": 0.6})
	else:
		emitters.clear()


func _toggle_two_color() -> void:
	two_color = not two_color
	sim.use_dye = two_color
	if two_color:
		emitters.clear()
		emitters.append({"pos": Vector3(6.0, 6.5, 0.0), "dir": Vector3(-0.3, -1.0, 0.0), "radius": 0.6, "speed": 6.0, "dye": 1.0})
	else:
		emitters.clear()


func _toggle_paddle() -> void:
	paddle_on = not paddle_on


func _preset(rx: int) -> void:
	res_x = rx
	_configure(res_x, _capacity_for(res_x))
	if mode == Mode.GAME:
		_restart_game()
	else:
		_level_game()


# ------------------------------------------------------------------ ui

func _label(size: int, parent: Control = null) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0.02, 0.06, 0.12, 0.85))
	l.add_theme_constant_override("outline_size", maxi(4, size / 6))
	if parent:
		parent.add_child(l)
	return l


func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	var tr := VBoxContainer.new()
	tr.anchor_left = 1.0
	tr.anchor_right = 1.0
	tr.offset_left = -460
	tr.offset_right = -40
	tr.offset_top = 28
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(tr)
	lbl_particles = _label(34, tr)
	lbl_particles.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl_fps = _label(34, tr)
	lbl_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var tl := VBoxContainer.new()
	tl.position = Vector2(40, 28)
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(tl)
	lbl_score = _label(44, tl)
	lbl_time = _label(44, tl)
	lbl_gate = _label(44, tl)

	lbl_title = _label(110, root)
	lbl_title.anchor_top = 1.0
	lbl_title.anchor_bottom = 1.0
	lbl_title.offset_left = 70
	lbl_title.offset_top = -230
	lbl_title.offset_bottom = -60

	var cb := VBoxContainer.new()
	cb.anchor_left = 0.5
	cb.anchor_right = 0.5
	cb.offset_left = -700
	cb.offset_right = 700
	cb.offset_top = 40
	cb.add_theme_constant_override("separation", -20)
	cb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cb)
	lbl_big = _label(170, cb)
	lbl_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_big_sub = _label(60, cb)
	lbl_big_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	end_panel = VBoxContainer.new()
	end_panel.anchor_left = 0.5
	end_panel.anchor_right = 0.5
	end_panel.anchor_top = 0.5
	end_panel.anchor_bottom = 0.5
	end_panel.offset_left = -220
	end_panel.offset_right = 220
	end_panel.offset_top = -200
	root.add_child(end_panel)
	lbl_end = _label(150, end_panel)
	lbl_end.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var rb := Button.new()
	rb.text = "重来"
	rb.add_theme_font_size_override("font_size", 44)
	rb.custom_minimum_size = Vector2(0, 80)
	rb.pressed.connect(_restart_game)
	end_panel.add_child(rb)

	sandbox_panel = VBoxContainer.new()
	sandbox_panel.position = Vector2(40, 120)
	sandbox_panel.add_theme_constant_override("separation", 8)
	root.add_child(sandbox_panel)
	var defs := [["view", "液体", _toggle_view], ["honey", "蜂蜜", _toggle_honey], ["gate", "闸门", _toggle_gate],
			["paddle", "造浪", _toggle_paddle], ["fountain", "喷泉", _toggle_fountain], ["color", "双色", _toggle_two_color],
			["grav", "重力", _cycle_gravity], ["slow", "慢动作", _toggle_slowmo], ["reset", "重置", _on_reset],
			["p1", "25 万", _preset.bind(116)], ["p2", "50 万", _preset.bind(145)], ["p3", "100 万", _preset.bind(182)]]
	for d in defs:
		var b := Button.new()
		b.text = d[1]
		b.add_theme_font_size_override("font_size", 28)
		b.custom_minimum_size = Vector2(170, 52)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(d[2])
		sandbox_panel.add_child(b)
		btns[d[0]] = b

	fade = ColorRect.new()
	fade.color = Color(1, 1, 1, 0)
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fade)


func _update_ui() -> void:
	lbl_particles.text = "粒子 " + _fmt(sim.count)
	lbl_fps.text = "FPS %d" % int(round(fps_smooth))
	var g := mode == Mode.GAME
	lbl_score.visible = g
	lbl_time.visible = g
	lbl_gate.visible = g and gate_target < 0.5 and game_state == 0
	if g:
		lbl_score.text = "浮标 %d/%d" % [score, buoy_total]
		lbl_time.text = "时间 %d" % int(ceil(maxf(time_left, 0.0)))
		lbl_gate.text = "开闸 %d" % int(ceil(maxf(gate_timer, 0.0)))
	end_panel.visible = g and game_state != 0
	lbl_end.text = end_text
	sandbox_panel.visible = mode == Mode.SANDBOX
	if mode == Mode.SANDBOX:
		btns["view"].text = "液体" if wipe_target > 0.5 else "粒子"
		btns["honey"].text = "蜂蜜" if honey else "水"
	var demo := mode == Mode.DEMO or mode == Mode.SHOTS
	lbl_title.visible = demo
	lbl_big.visible = demo and lbl_big.text != ""
	lbl_big_sub.visible = lbl_big.visible
	var small := mode == Mode.DEMO and lbl_big.text != ""
	lbl_particles.visible = not small
	lbl_fps.visible = not small


# ------------------------------------------------------------------ director helpers

func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await get_tree().process_frame
		t += dir_delta


func _wait_sim(sec: float) -> void:
	var t0 := sim_seconds
	var guard := 0
	while sim_seconds - t0 < sec and guard < 20000:
		await get_tree().process_frame
		guard += 1


func _fade(to: float, sec: float) -> void:
	var from := fade.color.a
	var t := 0.0
	while t < sec:
		await get_tree().process_frame
		t += real_delta
		fade.color.a = lerpf(from, to, clampf(t / sec, 0.0, 1.0))
	fade.color.a = to


func _cut(setup: Callable) -> void:
	await _fade(1.0, 0.3)
	setup.call()
	await _wait(0.12)
	await _fade(0.0, 0.45)


func _shot_png(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_shots/%s.png" % name)
	print("saved ", name)


func _capacity_for(rx: int) -> int:
	return int(pow((rx - 4) / 120.0, 3.0) * 310000.0 * 1.3) + 20000


# ------------------------------------------------------------------ demo

func _run_demo() -> void:
	mode = Mode.DEMO
	autopilot = true
	await get_tree().process_frame
	while true:
		# ---- A. dam break, particles -> liquid
		_configure(124, _capacity_for(124))
		_level_dambreak()
		fx.wipe = -0.2
		wipe_target = -0.2
		paused = true
		lbl_big.text = ""
		lbl_title.text = "粒子"
		_set_cam([[0.0, Vector3(-3.0, 4.2, 9.5), Vector3(-6.5, 2.6, 0.0), 40.0], [2.2, Vector3(-1.5, 3.6, 11.0), Vector3(-5.5, 2.4, 0.0), 42.0],
				[6.0, Vector3(4.0, 3.2, 13.0), Vector3(1.0, 1.6, 0.0), 46.0], [11.0, Vector3(9.0, 5.5, 13.5), Vector3(2.5, 1.2, 0.0), 46.0],
				[17.0, Vector3(13.5, 7.5, 9.0), Vector3(2.0, 1.0, 0.0), 48.0]])
		await _fade(0.0, 0.5)
		await _wait(1.6)
		paused = false
		await _wait(2.6)
		Engine.time_scale = 0.35
		wipe_target = 1.2
		await _wait(0.5)
		lbl_title.text = "液体"
		await _wait(2.2)
		Engine.time_scale = 1.0
		await _wait(9.5)

		# ---- B. boat, crates, gate
		await _cut(func():
			_level_game()
			lbl_title.text = "浮力"
			route = [Vector3(4.5, 0, 2.2), Vector3(5.5, 0, -1.8), Vector3(2.5, 0, -2.4), Vector3(-0.5, 0, 0.0), Vector3(1.5, 0, 2.4)]
			route_i = 0
			_set_cam([[0.0, Vector3(-3.0, 2.6, 7.0), Vector3(0.5, 0.6, 0.0), 44.0], [6.0, Vector3(-1.0, 3.2, 7.5), Vector3(1.0, 0.5, 0.0), 44.0],
					[12.0, Vector3(2.0, 4.5, 8.5), Vector3(0.0, 0.4, 0.0), 46.0]], boat))
		await _wait(11.5)
		lbl_title.text = "开闸"
		_set_cam([[0.0, Vector3(-0.5, 2.4, 6.5), Vector3(-4.6, 1.6, 0.0), 40.0], [4.5, Vector3(1.5, 3.4, 9.0), Vector3(-3.0, 1.2, 0.0), 44.0]])
		await _wait(0.8)
		gate_target = 1.0
		await _wait(1.4)
		Engine.time_scale = 0.4
		await _wait(1.6)
		Engine.time_scale = 1.0
		await _wait(1.0)
		_set_cam([[0.0, Vector3(-3.0, 5.0, 9.0), Vector3(1.5, 0.0, 0.0), 46.0], [7.0, Vector3(1.0, 8.5, 11.0), Vector3(0.0, -0.5, 0.0), 48.0],
				[13.0, Vector3(3.0, 6.0, 10.0), Vector3(-1.0, -0.2, 0.0), 46.0]], boat)
		await _wait(12.5)

		# ---- C. two colours
		await _cut(func():
			_level_mix()
			paused = true
			lbl_title.text = "混色"
			_set_cam([[0.0, Vector3(0.0, 6.5, 17.5), Vector3(0.0, 1.9, 0.0), 44.0], [3.0, Vector3(0.0, 5.0, 14.5), Vector3(0.0, 1.6, 0.0), 42.0],
					[8.0, Vector3(-6.0, 9.5, 11.0), Vector3(0.0, 0.8, 0.0), 44.0], [16.0, Vector3(6.0, 12.0, 8.0), Vector3(0.0, 0.5, 0.0), 46.0]]))
		await _wait(0.7)
		paused = false
		await _wait(2.3)
		Engine.time_scale = 0.3
		await _wait(2.4)
		Engine.time_scale = 1.0
		await _wait(2.5)
		_set_gravity(Vector3(0.0, -0.85, 0.55))
		await _wait(1.8)
		_set_gravity(Vector3(0.0, -0.85, -0.55))
		await _wait(2.4)
		_set_gravity(Vector3.DOWN)
		await _wait(3.5)

		# ---- D. honey <-> water
		await _cut(func():
			_level_honey()
			lbl_title.text = "蜂蜜"
			_set_cam([[0.0, Vector3(5.5, 4.2, 7.5), Vector3(0.0, 2.3, 0.0), 40.0], [9.0, Vector3(-4.5, 3.6, 8.0), Vector3(0.0, 1.6, 0.0), 42.0],
					[17.0, Vector3(-7.5, 5.5, 9.5), Vector3(0.0, 1.0, 0.0), 46.0]]))
		await _wait(9.0)
		lbl_title.text = "水"
		_toggle_honey()
		await _wait(7.5)

		# ---- E. ramp to a million
		await _cut(func():
			_configure(200, 1050000)
			_level_pool(0.55)
			lbl_title.text = ""
			lbl_big.text = _fmt(sim.count)
			for x in [-6.5, -2.2, 2.2, 6.5]:
				emitters.append({"pos": Vector3(x, 5.4, 1.6 if int(x) % 2 == 0 else -1.6), "dir": Vector3.DOWN, "radius": 0.6, "speed": 7.5, "dye": 0.0, "dense": 1.0, "foam": 0.55})
			_set_cam([[0.0, Vector3(-13.0, 6.5, 15.0), Vector3(-1.0, 2.2, 0.0), 44.0], [14.0, Vector3(4.0, 8.5, 18.5), Vector3(0.0, 2.0, 0.0), 44.0],
					[30.0, Vector3(15.0, 7.5, 12.5), Vector3(0.0, 1.5, 0.0), 46.0]]))
		var t := 0.0
		var tilted := false
		while t < 27.0:
			await get_tree().process_frame
			t += dir_delta
			lbl_big.text = _fmt(sim.count)
			lbl_big_sub.text = "粒子   FPS %d" % int(round(fps_smooth))
			if sim.count >= 1000000 and not emitters.is_empty():
				emitters.clear()
			if emitters.is_empty() and not tilted:
				tilted = true
				_slosh()
		lbl_big.text = ""
		await _fade(1.0, 0.5)
		if autoshots:
			get_tree().quit()
			return


func _slosh() -> void:
	_set_gravity(Vector3(0.55, -0.85, 0.0))
	await _wait(2.4)
	_set_gravity(Vector3(-0.55, -0.85, 0.0))
	await _wait(3.4)
	_set_gravity(Vector3.DOWN)


# ------------------------------------------------------------------ shots + benchmark

func _bench(n: int, seconds: float) -> Dictionary:
	var dxn := pow(264.0 * FluidSim.REST / float(n), 1.0 / 3.0) * 0.985
	var rx := int(ceil(TANK.x / dxn)) + 4
	_configure(rx, n)
	_level_dambreak(n, true)
	fx.wipe = 1.2
	wipe_target = 1.2
	_set_cam([[0.0, Vector3(2.0, 7.0, 19.0), Vector3(0.0, 1.6, 0.0), 46.0], [1.0, Vector3(2.0, 7.0, 19.0), Vector3(0.0, 1.6, 0.0), 46.0]])
	fixed_substeps = 2
	for i in 90:
		await get_tree().process_frame
	frame_times.clear()
	collect_frames = true
	var gs := 0.0
	var gf := 0.0
	var gn := 0
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += real_delta
		gs += sim_ms
		gf += fx_ms
		gn += 1
	collect_frames = false
	fixed_substeps = 0
	var sum := 0.0
	var worst := 0.0
	var sorted := frame_times.duplicate()
	sorted.sort()
	for f in frame_times:
		sum += f
		worst = maxf(worst, f)
	var p99: float = sorted[int(sorted.size() * 0.99)] if sorted.size() > 0 else 0.0
	var p10: float = sorted[int(sorted.size() * 0.10)] if sorted.size() > 0 else 0.0
	var r := {"n": sim.count, "grid": sim.grid, "avg": frame_times.size() / maxf(sum, 1e-6), "low1": 1.0 / maxf(p99, 1e-6),
			"min": 1.0 / maxf(worst, 1e-6), "best": 1.0 / maxf(p10, 1e-6), "sim_ms": gs / maxi(gn, 1), "fx_ms": gf / maxi(gn, 1)}
	print("BENCH particles=%d grid=%s avg_fps=%.1f 1%%low=%.1f min_fps=%.1f fastest10%%_fps=%.1f sim_gpu_ms=%.2f render_gpu_ms=%.2f" % [r.n, str(r.grid), r.avg, r.low1, r.min, r.best, r.sim_ms, r.fx_ms])
	return r


func _run_shots() -> void:
	mode = Mode.SHOTS
	autopilot = true
	lbl_title.text = ""
	lbl_big.text = ""
	var bench_list := [200000, 500000, 1000000]
	var only_bench := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bench="):
			bench_list = []
			only_bench = true
			for s in a.get_slice("=", 1).split(","):
				bench_list.append(int(s))
	await get_tree().process_frame
	var quick := OS.get_cmdline_user_args().has("--quick")
	sim.profile = OS.get_cmdline_user_args().has("--profile")
	if quick:
		_configure(124, _capacity_for(124))
		_level_dambreak()
		_set_cam([[0.0, Vector3(6.0, 3.4, 12.5), Vector3(1.5, 1.6, 0.0), 46.0], [1.0, Vector3(6.0, 3.4, 12.5), Vector3(1.5, 1.6, 0.0), 46.0]])
		await _wait_sim(2.5)
		await _shot_png("q1")
		await _wait_sim(3.0)
		await _shot_png("q2")
		await _wait_sim(6.0)
		await _shot_png("q3")
		only_bench = true
		bench_list = [200000]
	if not only_bench:
		# 1-3 dam break
		_configure(124, _capacity_for(124))
		_level_dambreak()
		fx.wipe = -0.2
		wipe_target = -0.2
		_set_cam([[0.0, Vector3(1.0, 3.6, 12.5), Vector3(-2.5, 2.0, 0.0), 44.0], [1.0, Vector3(1.0, 3.6, 12.5), Vector3(-2.5, 2.0, 0.0), 44.0]])
		await _wait_sim(1.5)
		await _shot_png("01_dambreak_particles")
		fx.wipe = 0.5
		wipe_target = 0.5
		await _wait_sim(0.25)
		await _shot_png("02_particles_to_liquid")
		fx.wipe = 1.2
		wipe_target = 1.2
		_set_cam([[0.0, Vector3(6.0, 3.4, 12.5), Vector3(1.5, 1.6, 0.0), 46.0], [1.0, Vector3(6.0, 3.4, 12.5), Vector3(1.5, 1.6, 0.0), 46.0]])
		await _wait_sim(1.0)
		await _shot_png("03_dambreak_liquid")
		await _wait_sim(2.5)
		await _shot_png("03b_dambreak_splash")
		# 4-5 game level
		_level_game()
		route = [Vector3(4.5, 0, 2.2), Vector3(5.5, 0, -1.8), Vector3(2.5, 0, -2.4), Vector3(-0.5, 0, 0.0), Vector3(1.5, 0, 2.4)]
		_set_cam([[0.0, Vector3(-3.0, 2.8, 7.2), Vector3(0.5, 0.5, 0.0), 44.0], [1.0, Vector3(-3.0, 2.8, 7.2), Vector3(0.5, 0.5, 0.0), 44.0]], boat)
		await _wait_sim(5.0)
		await _shot_png("04_boat_crates")
		_set_cam([[0.0, Vector3(0.5, 3.0, 8.0), Vector3(-3.6, 1.4, 0.0), 42.0], [1.0, Vector3(0.5, 3.0, 8.0), Vector3(-3.6, 1.4, 0.0), 42.0]])
		gate_target = 1.0
		await _wait_sim(2.6)
		await _shot_png("05_gate_flood")
		_set_cam([[0.0, Vector3(0.0, 9.5, 14.5), Vector3(0.0, 0.5, 0.0), 48.0], [1.0, Vector3(0.0, 9.5, 14.5), Vector3(0.0, 0.5, 0.0), 48.0]])
		await _wait_sim(3.0)
		await _shot_png("05b_flood_wide")
		print("boat pos=%s up=%.2f sub=%.2f score=%d" % [str(boat.global_position), boat.global_transform.basis.y.y, _boat_sub(), score])
		# 6 mix
		_level_mix()
		_set_cam([[0.0, Vector3(0.0, 5.5, 15.0), Vector3(0.0, 1.6, 0.0), 44.0], [1.0, Vector3(0.0, 5.5, 15.0), Vector3(0.0, 1.6, 0.0), 44.0]])
		await _wait_sim(2.3)
		await _shot_png("06_mix_collide")
		_set_cam([[0.0, Vector3(-5.0, 10.0, 10.0), Vector3(0.0, 0.6, 0.0), 44.0], [1.0, Vector3(-5.0, 10.0, 10.0), Vector3(0.0, 0.6, 0.0), 44.0]])
		await _wait_sim(3.5)
		await _shot_png("06b_mix_swirl")
		# 7 honey
		_level_honey()
		_set_cam([[0.0, Vector3(4.5, 4.0, 7.5), Vector3(0.0, 2.2, 0.0), 40.0], [1.0, Vector3(4.5, 4.0, 7.5), Vector3(0.0, 2.2, 0.0), 40.0]])
		await _wait_sim(7.0)
		await _shot_png("07_honey")
		# 8 ramp
		_configure(200, 1050000)
		_level_pool(0.55)
		for x in [-6.5, -2.2, 2.2, 6.5]:
			emitters.append({"pos": Vector3(x, 5.4, 1.6 if int(x) % 2 == 0 else -1.6), "dir": Vector3.DOWN, "radius": 0.6, "speed": 7.5, "dye": 0.0, "dense": 1.0, "foam": 0.55})
		_set_cam([[0.0, Vector3(-9.0, 7.0, 16.5), Vector3(0.0, 2.0, 0.0), 44.0], [1.0, Vector3(-9.0, 7.0, 16.5), Vector3(0.0, 2.0, 0.0), 44.0]])
		mode = Mode.DEMO
		var guard := 0
		while sim.count < 1000000 and guard < 6000:
			await get_tree().process_frame
			guard += 1
			lbl_big.text = _fmt(sim.count)
			lbl_big_sub.text = "粒子   FPS %d" % int(round(fps_smooth))
			if guard == 240:
				await _shot_png("08_ramp_mid")
		emitters.clear()
		lbl_big.text = _fmt(sim.count)
		_set_gravity(Vector3(0.55, -0.85, 0.0))
		await _wait_sim(2.2)
		await _shot_png("08b_million_slosh")
		lbl_big.text = ""
		mode = Mode.SHOTS
	for n in bench_list:
		await _bench(n, 5.0)
	get_tree().quit()


func _selftest() -> void:
	autopilot = true
	await _wait_sim(2.0)
	_enter_sandbox()
	for f in [_toggle_view, _toggle_honey, _toggle_gate, _toggle_paddle, _toggle_fountain, _toggle_two_color, _cycle_gravity, _toggle_slowmo,
			_toggle_slowmo, _toggle_view, _toggle_honey, _cycle_gravity, _on_reset]:
		f.call()
		await _wait(0.4)
	sim.mouse_origin = cam.global_position
	sim.mouse_dir = -cam.global_transform.basis.z
	sim.mouse_force = Vector3(0.4, 0.2, 0.0)
	sim.mouse_radius = 1.2 / sim.dx
	sim.mouse_active = true
	await _wait(1.0)
	sim.mouse_active = false
	await _shot_png("t_sandbox")
	_preset(145)
	await _wait(1.0)
	mode = Mode.GAME
	autopilot = true
	_restart_game()
	await _wait_sim(14.0)
	await _shot_png("t_game")
	print("SELFTEST OK state=%d score=%d boat_up=%.2f" % [game_state, score, boat.global_transform.basis.y.y])
	get_tree().quit()
