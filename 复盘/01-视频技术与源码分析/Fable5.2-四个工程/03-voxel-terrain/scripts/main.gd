extends Node3D

const VoxelWorld := preload("res://scripts/voxel_world.gd")
const Fx := preload("res://scripts/fx.gd")
const Player := preload("res://scripts/player.gd")
const Director := preload("res://scripts/director.gd")
const Hud := preload("res://scripts/hud.gd")

const SUN_DIR := Vector3(-0.865, 0.342, -0.367)
const HEAT_N := 24

var world: RefCounted
var fx: Node3D
var hud: CanvasLayer
var mode := "play"
var terrain_mat: ShaderMaterial
var env: Environment
var sun: DirectionalLight3D
var bodies: Array[RigidBody3D] = []
var focus := Vector3(400, 60, 400)
var time_now := 0.0
var started := false
var demo_frames := false
var selftest := false
var no_heat := false
var actor: Node = null

var _heat_pos := PackedVector4Array()
var _heat_t0 := PackedFloat32Array()
var _heat_i := 0
var _overlay: ColorRect
var _bar: ProgressBar
var _block_mesh: BoxMesh
var _block_shape: BoxShape3D
var _block_mats: Array[StandardMaterial3D] = []

# frame timing
var _perf_on := false
var _perf_last := 0
var _perf_n := 0
var _perf_sum := 0
var _perf_worst := 0
var _perf_times := PackedInt32Array()
var _fog_base := 0.00045
var _water_mat: ShaderMaterial
var _sky_vis := 1.0
var _slow: Array = []
var _gpu_sum := 0.0
var _cpu_sum := 0.0
var glow_lights: Array[OmniLight3D] = []
var _key_lights := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--demo"):
		mode = "demo"
	elif args.has("--shots"):
		mode = "shots"
	elif args.has("--texshots"):
		mode = "texshots"
	demo_frames = args.has("--frames")
	selftest = args.has("--selftest")
	if args.has("--bench"):
		mode = "bench"
	if args.has("--bench2"):
		mode = "bench2"
	if mode == "shots" or mode == "bench" or mode == "bench2":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	get_window().title = "体素地形"
	_build_env()
	_build_overlay()

	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/terrain.gdshader")
	_heat_pos.resize(HEAT_N)
	_heat_t0.resize(HEAT_N)
	for i in HEAT_N:
		_heat_pos[i] = Vector4(0, -1000, 0, 1)
		_heat_t0[i] = -1000.0
	terrain_mat.set_shader_parameter("heat_pos", _heat_pos)
	terrain_mat.set_shader_parameter("heat_t0", _heat_t0)
	terrain_mat.set_shader_parameter("water_level", VoxelWorld.WATER)
	var t_tex := Time.get_ticks_msec()
	var stex: Array = load("res://scripts/surface_tex.gd").build_all()
	terrain_mat.set_shader_parameter("tex_rock", stex[0])
	terrain_mat.set_shader_parameter("tex_grass", stex[1])
	terrain_mat.set_shader_parameter("tex_soil", stex[2])
	print("surface tex ms: ", Time.get_ticks_msec() - t_tex)

	world = VoxelWorld.new()
	world.setup(get_world_3d().scenario, get_world_3d().space, terrain_mat)
	if not world.generate():
		push_error("world generation failed")
		get_tree().quit(1)
		return
	print("gen ms: ", world.gen_msec)
	world.queue_all(focus)

	fx = Fx.new()
	fx.main = self
	fx.world = world
	add_child(fx)
	hud = Hud.new()
	hud.main = self
	add_child(hud)

	_block_mesh = BoxMesh.new()
	_block_mesh.size = Vector3(2, 2, 2)
	_block_shape = BoxShape3D.new()
	_block_shape.size = Vector3(2, 2, 2)
	for c in [Color(0.86, 0.80, 0.68), Color(0.10, 0.42, 0.42), Color(0.80, 0.36, 0.14), Color(0.13, 0.14, 0.17)]:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.55
		_block_mats.append(m)


func _build_env() -> void:
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("sun_dir", SUN_DIR.normalized())
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 7.0
	env.ssao_enabled = true
	env.ssao_radius = 2.2
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.42
	env.glow_strength = 1.0
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.3
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.set_glow_level(1, 0.6)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 1.0)
	env.set_glow_level(4, 0.8)
	env.set_glow_level(5, 0.6)
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.52, 0.58)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.1
	env.fog_density = _fog_base
	env.fog_aerial_perspective = 0.8
	env.fog_sky_affect = 0.0
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0019
	env.volumetric_fog_albedo = Color(0.92, 0.84, 0.80)
	env.volumetric_fog_anisotropy = 0.62
	env.volumetric_fog_length = 260.0
	env.volumetric_fog_detail_spread = 2.2
	env.volumetric_fog_ambient_inject = 0.0
	env.volumetric_fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.07
	env.adjustment_saturation = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	add_child(sun)
	sun.look_at_from_position(SUN_DIR * 100.0, Vector3.ZERO, Vector3.UP)
	sun.light_color = Color(1.0, 0.80, 0.60)
	sun.light_energy = 3.0
	sun.light_angular_distance = 0.7
	sun.light_volumetric_fog_energy = 0.8
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 320.0
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_split_2 = 0.22
	sun.directional_shadow_split_3 = 0.5
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_LOW, true, 0.5, 1, 60.0, 320.0)
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.08
	sun.shadow_normal_bias = 2.2
	sun.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	var water := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(7000, 7000)
	water.mesh = pm
	var wm := ShaderMaterial.new()
	wm.shader = load("res://shaders/water.gdshader")
	wm.set_shader_parameter("sun_dir", SUN_DIR.normalized())
	_water_mat = wm
	water.material_override = wm
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.position = Vector3(256, VoxelWorld.WATER, 256)
	water.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(water)


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_overlay = ColorRect.new()
	_overlay.color = Color.BLACK
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_overlay)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(420, 4)
	_bar.set_anchors_preset(Control.PRESET_CENTER)
	_bar.position = Vector2(-210, -2)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.14, 0.13)
	var sf := StyleBoxFlat.new()
	sf.bg_color = Color(0.96, 0.62, 0.32)
	_bar.add_theme_stylebox_override("background", sb)
	_bar.add_theme_stylebox_override("fill", sf)
	_overlay.add_child(_bar)


func fade(to: float, dur: float) -> void:
	var tw := create_tween()
	tw.tween_property(_overlay, "color:a", to, dur)
	await tw.finished


func set_fade(a: float) -> void:
	_overlay.color.a = a


func _process(dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _perf_on:
		var ft := now - _perf_last
		_perf_n += 1
		_perf_sum += ft
		_perf_worst = maxi(_perf_worst, ft)
		_perf_times.append(ft)
		var vp := get_viewport().get_viewport_rid()
		_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		if ft > 12500:
			_slow.append([ft / 1000.0, world.apply_usec_frame / 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, RenderingServer.viewport_get_measured_render_time_gpu(vp), RenderingServer.viewport_get_measured_render_time_cpu(vp)])
	_perf_last = now
	if world == null:
		return
	time_now += dt
	terrain_mat.set_shader_parameter("time_now", time_now)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		focus = cam.global_position
		var under: bool = focus.y < VoxelWorld.WATER - 0.3 and not world.solid(focus + Vector3(0, 1.5, 0)) and world.surface_y(focus.x, focus.z, focus.y + 30.0) < VoxelWorld.WATER
		env.fog_density = 0.05 if under else _fog_base
		env.fog_light_color = Color(0.05, 0.32, 0.34) if under else Color(0.62, 0.52, 0.58)
		var roofed: bool = world.surface_y(focus.x, focus.z) > focus.y + 4.0 and world.surface_y(focus.x + 9.0, focus.z + 5.0) > focus.y + 4.0
		_sky_vis = lerpf(_sky_vis, 0.0 if roofed else 1.0, 1.0 - exp(-dt * 4.0))
		_water_mat.set_shader_parameter("sky_vis", _sky_vis)
	world.update(focus, 1300 if world.loaded else 30000)
	if world.woke:
		world.woke = false
		var box: AABB = world.woke_aabb
		for b in bodies:
			if b.sleeping and box.has_point(b.global_position):
				b.sleeping = false
	if not started:
		_bar.value = 100.0 * world.load_done / float(world.load_total)
		if world.loaded:
			started = true
			_bar.visible = false
			print("load: chunks ", world.active_chunks, " tris ", world.total_tris, " mesh ms/chunk(all incl. empty) ", world.load_mesh_ms, " load s ", Time.get_ticks_msec() / 1000.0)
			_place_glow_lights()
			_start()


func _start() -> void:
	if mode == "play":
		var p := Player.new()
		p.main = self
		add_child(p)
		actor = p
		spawn_block_field(Vector3(372, 0, 160), 7, 5, 4)
		fade(0.0, 1.2)
	else:
		var d := Director.new()
		d.main = self
		add_child(d)
		actor = d


func add_heat(pos: Vector3, r: float) -> void:
	if no_heat:
		return
	_heat_pos[_heat_i] = Vector4(pos.x, pos.y, pos.z, r)
	_heat_t0[_heat_i] = time_now
	_heat_i = (_heat_i + 1) % HEAT_N
	terrain_mat.set_shader_parameter("heat_pos", _heat_pos)
	terrain_mat.set_shader_parameter("heat_t0", _heat_t0)


func set_brush(pos: Vector3, r: float, col: Color = Color(1.0, 0.72, 0.3)) -> void:
	terrain_mat.set_shader_parameter("brush_pos", pos)
	terrain_mat.set_shader_parameter("brush_r", r)
	terrain_mat.set_shader_parameter("brush_col", col)


func spawn_block(pos: Vector3, mat_i: int) -> RigidBody3D:
	var b := RigidBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _block_mesh
	mi.material_override = _block_mats[mat_i % _block_mats.size()]
	b.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = _block_shape
	b.add_child(cs)
	b.collision_layer = 2
	b.collision_mask = 3
	b.mass = 2.0
	b.position = pos
	add_child(b)
	bodies.append(b)
	return b


func spawn_block_field(c: Vector3, cols: int, rows: int, height: int) -> void:
	for ix in cols:
		for iz in rows:
			var x := c.x + (ix - (cols - 1) * 0.5) * 6.0
			var z := c.z + (iz - (rows - 1) * 0.5) * 6.0
			var y: float = world.surface_y(x, z)
			var h := height + ((ix * 7 + iz * 3) % 3) - 1
			for k in h:
				spawn_block(Vector3(x, y + 1.05 + k * 2.02, z), ix + iz * 2 + k)


func clear_blocks() -> void:
	for b in bodies:
		if is_instance_valid(b):
			b.queue_free()
	bodies.clear()


func perf_begin() -> void:
	_perf_on = true
	_perf_n = 0
	_perf_sum = 0
	_perf_worst = 0
	_perf_times = PackedInt32Array()
	_slow = []
	_gpu_sum = 0.0
	_cpu_sum = 0.0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	world.reset_perf()


func perf_end() -> Dictionary:
	_perf_on = false
	var t := _perf_times.duplicate()
	t.sort()
	var n := t.size()
	return {
		"frames": _perf_n,
		"avg_fps": 1000000.0 * _perf_n / maxf(_perf_sum, 1.0),
		"worst_ms": _perf_worst / 1000.0,
		"p99_ms": (t[int(n * 0.99)] if n > 0 else 0) / 1000.0,
		"p999_ms": (t[mini(int(n * 0.999), n - 1)] if n > 0 else 0) / 1000.0,
		"over_16": _count_over(t, 16600),
		"gpu_ms": _gpu_sum / maxf(_perf_n, 1.0),
		"cpu_ms": _cpu_sum / maxf(_perf_n, 1.0),
		"slow": _slow,
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
	}


func _count_over(t: PackedInt32Array, lim: int) -> int:
	var c := 0
	for v in t:
		if v > lim:
			c += 1
	return c


func _exit_tree() -> void:
	if world != null:
		world.free_all()
		world = null


func _place_glow_lights() -> void:
	# small unshadowed lights on exposed ore / crystal inside the cave region
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pts: Array[Vector3] = []
	for i in 70000:
		if pts.size() >= 44:
			break
		var p := Vector3(rng.randi_range(110, 330), rng.randi_range(15, 62), rng.randi_range(225, 440))
		var m: int = world.material_at(p)
		if m != 4 and m != 5:
			continue
		var d: float = world.density(p)
		if d < 0.0 or d > 1.2:
			continue
		if world.surface_y(p.x, p.z) < p.y + 6.0:
			continue
		var g: Vector3 = world.gradient(p)
		var q := p + g * 2.6
		if world.solid(q):
			continue
		var ok := true
		for o in pts:
			if o.distance_squared_to(q) < (15.0 * 15.0 if m == 5 else 17.0 * 17.0):
				ok = false
				break
		if not ok:
			continue
		pts.append(q)
		var l := OmniLight3D.new()
		l.light_color = Color(0.75, 0.25, 1.0) if m == 5 else Color(0.1, 0.95, 0.75)
		l.light_energy = 2.4 if m == 5 else 1.5
		l.omni_range = 20.0 if m == 5 else 11.0
		l.omni_attenuation = 1.5
		l.shadow_enabled = false
		if m == 5 and _key_lights < 5 and q.distance_to(Vector3(232, 33, 285)) < 34.0:
			l.shadow_enabled = true
			l.shadow_bias = 0.3
			l.omni_range = 32.0
			l.light_energy = 8.0
			_key_lights += 1
		l.light_volumetric_fog_energy = 6.0 if m == 5 else 3.0
		l.position = q
		l.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(l)
		glow_lights.append(l)
	var fv := FogVolume.new()
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fv.size = Vector3(84, 40, 72)
	var fm := FogMaterial.new()
	fm.density = 0.016
	fm.albedo = Color(0.55, 0.75, 0.85)
	fm.edge_fade = 0.4
	fv.material = fm
	fv.position = Vector3(232, 33, 285)
	fv.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(fv)
	print("glow lights: ", glow_lights.size())
