extends Node3D
## Procedural battlefield: height map, cost field, terrain / water / rocks / bridges / keeps, lighting.

const MB := preload("res://scripts/meshes.gd")
const HALF := 320.0
const SIZE := 640.0
const HT := 1024
const FW := 256
const FCELL := 2.5
const WATER_Y := -1.6
const DECK_Y := 0.7
const RW := 12.0
const BRIDGES: Array[float] = [-150.0, 150.0]
const BRIDGE_HW := 11.0
const FORD_Z := 0.0
const FORD_HW := 32.0
const EDGE_H := 9.0

var cost := PackedByteArray()
var hdata := PackedFloat32Array()
var height_tex: ImageTexture
var noise_tex: NoiseTexture2D
var stain_tex: ImageTexture
var minimap_base: ImageTexture
var rocks: Array[Vector3] = []
var sun: DirectionalLight3D
var env: Environment
var terrain_mat: ShaderMaterial
var n1 := FastNoiseLite.new()
var n2 := FastNoiseLite.new()


static func river_x(z: float) -> float:
	return -48.0 + 18.0 * sin(z * 0.011 + 0.6) + 7.0 * sin(z * 0.029)


func _hrow(r: int) -> void:
	var z := (float(r) + 0.5) * (SIZE / HT) - HALF
	var rx := river_x(z)
	var o := r * HT * 2
	var fm := smoothstep(FORD_HW + 7.0, FORD_HW - 5.0, absf(z - FORD_Z))
	var bz := 1e9
	for b in BRIDGES:
		bz = minf(bz, absf(z - b))
	var bm := smoothstep(BRIDGE_HW + 0.8, BRIDGE_HW - 0.4, bz)
	var bm2 := smoothstep(BRIDGE_HW + 5.0, BRIDGE_HW + 1.0, bz)
	for c in HT:
		var x := (float(c) + 0.5) * (SIZE / HT) - HALF
		var e := maxf(absf(x), absf(z))
		var nb := n2.get_noise_2d(x, z)
		var h := n1.get_noise_2d(x, z) * 3.2 + nb * 0.45
		var edge := smoothstep(262.0, 319.0, e)
		var d := absf(x - rx)
		var bank := smoothstep(RW + 13.0, RW + 1.0, d)
		h = lerpf(h, -1.25 + nb * 0.2, bank)
		var bed := smoothstep(RW + 1.0, RW - 5.0, d)
		h = lerpf(h, lerpf(-4.8, -1.98 + nb * 0.12, fm), bed)
		var g := h
		# bridge: abutments on the banks (render height), deck level for walking
		var ab := bm2 * smoothstep(RW + 15.0, RW + 9.0, d) * smoothstep(RW + 2.5, RW + 6.0, d)
		h = lerpf(h, DECK_Y - 0.25, ab)
		g = lerpf(maxf(g, h), DECK_Y, bm * smoothstep(RW + 15.0, RW + 8.0, d))
		h = lerpf(h, EDGE_H, edge)
		g = lerpf(g, EDGE_H, edge)
		hdata[o + c * 2] = h
		hdata[o + c * 2 + 1] = g


func h_at(x: float, z: float) -> float:
	var c := clampi(int((x + HALF) * (HT / SIZE)), 0, HT - 1)
	var r := clampi(int((z + HALF) * (HT / SIZE)), 0, HT - 1)
	return hdata[(r * HT + c) * 2 + 1]


func build() -> void:
	n1.seed = 7
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n1.frequency = 0.0045
	n1.fractal_octaves = 4
	n2.seed = 21
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n2.frequency = 0.03
	n2.fractal_octaves = 3
	hdata.resize(HT * HT * 2)
	var g := WorkerThreadPool.add_group_task(_hrow, HT, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(g)
	_place_rocks()
	_build_cost()
	var img := Image.create_from_data(HT, HT, false, Image.FORMAT_RGF, hdata.to_byte_array())
	height_tex = ImageTexture.create_from_image(img)

	var fn := FastNoiseLite.new()
	fn.seed = 3
	fn.frequency = 0.012
	fn.fractal_octaves = 5
	noise_tex = NoiseTexture2D.new()
	noise_tex.width = 512
	noise_tex.height = 512
	noise_tex.seamless = true
	noise_tex.generate_mipmaps = true
	noise_tex.noise = fn

	var simg := Image.create_empty(HT, HT, false, Image.FORMAT_RG8)
	stain_tex = ImageTexture.create_from_image(simg)

	_build_terrain()
	_build_props()
	_build_env()
	_build_minimap_base()


func _place_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var tries := 0
	while rocks.size() < 40 and tries < 6000:
		tries += 1
		var x := rng.randf_range(-272.0, 272.0)
		var z := rng.randf_range(-280.0, 280.0)
		var central := x > 44.0 and x < 100.0
		var r := rng.randf_range(3.5, 8.0)
		if central and rng.randf() < 0.3:
			r = rng.randf_range(9.0, 13.0)
		if absf(x - river_x(z)) < RW + 22.0 + r:
			continue
		if (x < 44.0 and x > -150.0) or (x > 100.0 and x < 165.0) or absf(x) > 252.0:
			continue
		if not central and rng.randf() < 0.6:
			continue
		var ok := true
		for b in BRIDGES:
			if absf(z - b) < BRIDGE_HW + 12.0 + r and absf(x - river_x(z)) < 80.0:
				ok = false
		if absf(z - FORD_Z) < FORD_HW + r and absf(x - river_x(z)) < 70.0:
			ok = false
		if Vector2(absf(x) - 248.0, z).length() < 30.0 + r:
			ok = false
		for q in rocks:
			if Vector2(q.x - x, q.y - z).length() < q.z + r + 11.0:
				ok = false
		if ok:
			rocks.append(Vector3(x, z, r))
	# gentle mounds under the rocks
	for q in rocks:
		var c0 := int((q.x - q.z * 1.5 + HALF) * 1.6)
		var c1 := int((q.x + q.z * 1.5 + HALF) * 1.6)
		var r0 := int((q.y - q.z * 1.5 + HALF) * 1.6)
		var r1 := int((q.y + q.z * 1.5 + HALF) * 1.6)
		for r in range(r0, r1 + 1):
			for c in range(c0, c1 + 1):
				var x := (float(c) + 0.5) * 0.625 - HALF
				var z := (float(r) + 0.5) * 0.625 - HALF
				var dd := Vector2(x - q.x, z - q.y).length()
				var b := smoothstep(q.z * 1.5, q.z * 0.5, dd) * q.z * 0.12
				var i := (r * HT + c) * 2
				hdata[i] += b
				hdata[i + 1] += b


func keep_pos(team: int) -> Vector2:
	return Vector2(-248.0 if team == 0 else 248.0, 0.0)


func _build_cost() -> void:
	cost.resize(FW * FW)
	cost.fill(1)
	for r in FW:
		var z := (float(r) + 0.5) * FCELL - HALF
		var rx := river_x(z)
		var on_bridge := false
		for b in BRIDGES:
			if absf(z - b) < BRIDGE_HW - 1.2:
				on_bridge = true
		var on_ford := absf(z - FORD_Z) < FORD_HW - 3.0
		for c in FW:
			var x := (float(c) + 0.5) * FCELL - HALF
			var i := r * FW + c
			if maxf(absf(x), absf(z)) > 296.0:
				cost[i] = 255
				continue
			var d := absf(x - rx)
			if d < RW + 1.5:
				if on_bridge:
					cost[i] = 1
				elif on_ford:
					cost[i] = 2
				else:
					cost[i] = 255
			elif d < RW + 9.0 and not on_ford:
				# keep the parapet line solid on the approaches
				for b in BRIDGES:
					var bz := absf(z - b)
					if bz > BRIDGE_HW - 1.2 and bz < BRIDGE_HW + 1.4:
						cost[i] = 255
	for q in rocks:
		_block_disc(q.x, q.y, q.z)
	for t in 2:
		var k := keep_pos(t)
		for r in FW:
			var z := (float(r) + 0.5) * FCELL - HALF
			if absf(z - k.y) > 15.0:
				continue
			for c in FW:
				var x := (float(c) + 0.5) * FCELL - HALF
				if absf(x - k.x) <= 15.0:
					cost[r * FW + c] = 255
	# cells touching an obstacle cost more, so streams keep a little clearance
	var near := PackedInt32Array()
	for r in range(1, FW - 1):
		for c in range(1, FW - 1):
			var i := r * FW + c
			if cost[i] == 1 and (cost[i - 1] == 255 or cost[i + 1] == 255 or cost[i - FW] == 255 or cost[i + FW] == 255):
				near.append(i)
	for i in near:
		cost[i] = 3


func _block_disc(x: float, z: float, rad: float) -> void:
	var c0 := int((x - rad + HALF) / FCELL)
	var c1 := int((x + rad + HALF) / FCELL)
	var r0 := int((z - rad + HALF) / FCELL)
	var r1 := int((z + rad + HALF) / FCELL)
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			var cx := (float(c) + 0.5) * FCELL - HALF
			var cz := (float(r) + 0.5) * FCELL - HALF
			if Vector2(cx - x, cz - z).length() < rad:
				cost[r * FW + c] = 255


func _shader_mat(path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	m.set_shader_parameter("height_tex", height_tex)
	m.set_shader_parameter("noise_tex", noise_tex)
	return m


func _build_terrain() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(SIZE, SIZE)
	pm.subdivide_width = 383
	pm.subdivide_depth = 383
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	terrain_mat = _shader_mat("res://shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("stain_tex", stain_tex)
	mi.material_override = terrain_mat
	mi.custom_aabb = AABB(Vector3(-HALF, -10, -HALF), Vector3(SIZE, 40, SIZE))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	var om := PlaneMesh.new()
	om.size = Vector2(4800, 4800)
	om.subdivide_width = 119
	om.subdivide_depth = 119
	var oi := MeshInstance3D.new()
	oi.mesh = om
	oi.material_override = _shader_mat("res://shaders/outer.gdshader")
	oi.custom_aabb = AABB(Vector3(-2400, -50, -2400), Vector3(4800, 400, 4800))
	oi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(oi)

	var wm := PlaneMesh.new()
	wm.size = Vector2(SIZE, SIZE)
	var wi := MeshInstance3D.new()
	wi.mesh = wm
	wi.position.y = WATER_Y
	wi.material_override = _shader_mat("res://shaders/water.gdshader")
	wi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(wi)


func _build_props() -> void:
	# rocks
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var xfs: Array[Transform3D] = []
	for q in rocks:
		var y := h_at(q.x, q.y)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(q.z * 1.08, q.z * rng.randf_range(0.5, 0.85), q.z * 1.08))
		xfs.append(Transform3D(b, Vector3(q.x, y - 0.3, q.y)))
		for k in rng.randi_range(2, 5):
			var a := rng.randf() * TAU
			var rr := q.z * rng.randf_range(0.75, 1.0)
			var s := q.z * rng.randf_range(0.18, 0.4)
			var px := q.x + cos(a) * rr
			var pz := q.y + sin(a) * rr
			xfs.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.6, 1.1), s)), Vector3(px, h_at(px, pz) - 0.1, pz)))
	# ford stepping stones
	for k in 46:
		var z := FORD_Z + rng.randf_range(-FORD_HW - 6.0, FORD_HW + 6.0)
		var x := river_x(z) + rng.randf_range(-RW - 4.0, RW + 4.0)
		var s := rng.randf_range(0.25, 0.7)
		xfs.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * 0.6, s)), Vector3(x, h_at(x, z) - 0.05, z)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = MB.rock(11)
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var rm := _shader_mat("res://shaders/prop.gdshader")
	rm.set_shader_parameter("base", Color(0.44, 0.41, 0.37))
	mmi.material_override = rm
	add_child(mmi)

	# bridges, towers, keeps
	var m := MB.new()
	var stone := Color(0.56, 0.52, 0.46)
	var stone_d := Color(0.40, 0.37, 0.33)
	var wood := Color(0.30, 0.20, 0.12)
	var tcol: Array[Color] = [Color(0.10, 0.25, 0.62), Color(0.60, 0.10, 0.06)]
	for bz in BRIDGES:
		var cx := river_x(bz)
		var ln := 2.0 * (RW + 9.0)
		m.color = stone
		m.box(Vector3(cx, DECK_Y - 0.45, bz), Vector3(ln, 0.8, BRIDGE_HW * 2.0 + 1.6))
		m.color = stone_d
		for s: float in [-1.0, 1.0]:
			m.box(Vector3(cx, DECK_Y + 0.45, bz + s * (BRIDGE_HW + 0.35)), Vector3(ln + 8.0, 1.1, 0.8))
			for k in 9:
				m.box(Vector3(cx - ln * 0.5 - 3.0 + float(k) * (ln + 6.0) / 8.0, DECK_Y + 1.2, bz + s * (BRIDGE_HW + 0.35)), Vector3(1.2, 0.5, 0.9))
		for px: float in [-8.0, 0.0, 8.0]:
			m.box(Vector3(cx + px, -2.4, bz), Vector3(2.4, 5.6, BRIDGE_HW * 2.0 + 3.0), 0, Vector2.ZERO, 0, 1.0, 0.0, 1.25)
		# gate towers
		for sx: float in [-1.0, 1.0]:
			for s: float in [-1.0, 1.0]:
				_tower(m, Vector3(cx + sx * (RW + 13.0), 0.0, bz + s * (BRIDGE_HW + 2.6)), 3.4, 8.5, stone, stone_d, tcol[0 if sx < 0.0 else 1])
	for t in 2:
		var k := keep_pos(t)
		var y := h_at(k.x, k.y) - 0.5
		m.color = stone
		for s: float in [-1.0, 1.0]:
			m.box(Vector3(k.x + s * 13.0, y + 3.5, k.y), Vector3(2.4, 7.0, 26.0))
			m.box(Vector3(k.x, y + 3.5, k.y + s * 13.0), Vector3(26.0, 7.0, 2.4))
			for j in 7:
				m.color = stone_d
				m.box(Vector3(k.x + s * 13.0, y + 7.5, k.y - 10.5 + float(j) * 3.5), Vector3(2.6, 1.0, 1.6))
				m.box(Vector3(k.x - 10.5 + float(j) * 3.5, y + 7.5, k.y + s * 13.0), Vector3(1.6, 1.0, 2.6))
				m.color = stone
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				_tower(m, Vector3(k.x + sx * 13.0, y, k.y + sz * 13.0), 5.2, 11.5, stone, stone_d, tcol[t])
		_tower(m, Vector3(k.x, y, k.y), 10.0, 17.0, stone, stone_d, tcol[t])
		m.color = wood
		m.box(Vector3(k.x, y + 26.0, k.y), Vector3(0.3, 9.0, 0.3))
		m.color = tcol[t] * 1.5
		m.box(Vector3(k.x, y + 28.6, k.y + 2.2), Vector3(0.12, 2.6, 4.2))
	var pi := MeshInstance3D.new()
	pi.mesh = m.build(true)
	var pmat := _shader_mat("res://shaders/prop.gdshader")
	pmat.set_shader_parameter("use_vcol", 1.0)
	pi.material_override = pmat
	add_child(pi)


func _tower(m: RefCounted, p: Vector3, w: float, h: float, stone: Color, dark: Color, roof: Color) -> void:
	var y := h_at(p.x, p.z) - 0.5 if p.y == 0.0 else p.y
	m.color = stone
	m.box(Vector3(p.x, y + h * 0.5, p.z), Vector3(w, h, w), 0, Vector2.ZERO, 0, 0.9, 0.0, 1.08)
	m.color = dark
	m.box(Vector3(p.x, y + h + 0.4, p.z), Vector3(w * 1.2, 0.8, w * 1.2))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			m.box(Vector3(p.x + sx * w * 0.5, y + h + 1.2, p.z + sz * w * 0.5), Vector3(w * 0.3, 0.9, w * 0.3))
	m.color = roof
	m.box(Vector3(p.x, y + h + 0.8 + w * 0.45, p.z), Vector3(w * 0.95, w * 0.9, w * 0.95), 0, Vector2.ZERO, 0, 0.04)


func _build_env() -> void:
	sun = DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.90, 0.76)
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 400.0
	sun.directional_shadow_blend_splits = false
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.2
	sun.light_angular_distance = 0.6
	add_child(sun)
	sun.look_at_from_position(Vector3(0.52, 0.5, 0.7) * 100.0, Vector3.ZERO, Vector3.UP)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.17, 0.33, 0.60)
	sky_mat.sky_horizon_color = Color(0.80, 0.72, 0.62)
	sky_mat.sky_curve = 0.09
	sky_mat.ground_bottom_color = Color(0.20, 0.17, 0.14)
	sky_mat.ground_horizon_color = Color(0.80, 0.72, 0.62)
	sky_mat.sun_angle_max = 12.0
	sky_mat.sun_curve = 0.08
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.25
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.70, 0.64)
	env.fog_density = 0.0006
	env.fog_sun_scatter = 0.25
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.25
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.6
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_minimap_base() -> void:
	var img := Image.create_empty(FW, FW, false, Image.FORMAT_RGB8)
	for r in FW:
		for c in FW:
			var x := (float(c) + 0.5) * FCELL - HALF
			var z := (float(r) + 0.5) * FCELL - HALF
			var cv := cost[r * FW + c]
			var h := hdata[((r * 4 + 2) * HT + c * 4 + 2) * 2]
			var col := Color(0.25, 0.25, 0.14).lerp(Color(0.36, 0.33, 0.18), clampf(h * 0.15 + 0.5, 0.0, 1.0))
			if h < WATER_Y:
				col = Color(0.10, 0.30, 0.33) if cv == 255 else Color(0.22, 0.40, 0.38)
			elif cv == 255:
				col = Color(0.42, 0.39, 0.35) if maxf(absf(x), absf(z)) < 296.0 else Color(0.17, 0.16, 0.11)
			var on_b := false
			for b in BRIDGES:
				if absf(z - b) < BRIDGE_HW and absf(x - river_x(z)) < RW + 8.0:
					on_b = true
			if on_b:
				col = Color(0.55, 0.52, 0.46)
			img.set_pixel(c, r, col)
	minimap_base = ImageTexture.create_from_image(img)
