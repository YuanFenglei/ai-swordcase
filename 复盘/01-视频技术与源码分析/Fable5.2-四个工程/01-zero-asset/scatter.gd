extends Node3D
# Procedural props: rocks, bone ribs, monolith spires, crystal clusters, reeds, bulb trees.

const MB = preload("res://mb.gd")

var rng := RandomNumberGenerator.new()
var nz := FastNoiseLite.new()
var rock_mat: ShaderMaterial
var bone_mat: ShaderMaterial
var crystal_mat: ShaderMaterial
var tree_mat: ShaderMaterial
var keep_clear: Array = []   # Vector3(x, z, r)


func build() -> void:
	rng.seed = 4242
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX
	nz.frequency = 1.0
	rock_mat = G.smat("terrain", {"rock_mode": 1.0, "bump_gain": 1.2})
	bone_mat = G.smat("terrain", {"rock_mode": 1.0, "rock_a": Color(0.20, 0.16, 0.15), "rock_b": Color(0.42, 0.33, 0.28), "peak_col": Color(0.5, 0.4, 0.36), "bump_gain": 0.8})
	crystal_mat = G.smat("crystal")
	tree_mat = G.smat("surface", {"base_col": Color(0.05, 0.07, 0.09), "accent_col": Color(0.12, 0.1, 0.16), "emit_col": Color(1.0, 0.55, 0.15),
		"emit_power": 2.2, "metal": 0.1, "rough": 0.55, "organic": 1.0, "detail": 1.6, "rim_col": Color(0.1, 0.5, 0.5), "rim_power": 0.5, "sway": 0.004})
	_rocks()
	_ribs()
	_spires()
	_arches()
	_pools()
	_pebbles()
	_crystals()
	_trees()
	_reeds()


func _clear_ok(x: float, z: float, pad: float) -> bool:
	for k in keep_clear:
		var dx: float = x - k.x
		var dz: float = z - k.y
		if dx * dx + dz * dz < (k.z + pad) * (k.z + pad):
			return false
	return true


func _rock_mesh(seed_v: float, subdiv: int, rough: float, scl: Vector3, smooth: bool) -> ArrayMesh:
	var mb := MB.new()
	var f := func(p: Vector3) -> float:
		var a := nz.get_noise_3d(p.x * 1.1 + seed_v, p.y * 1.1, p.z * 1.1)
		var b := 1.0 - absf(nz.get_noise_3d(p.x * 2.3, p.y * 2.3 + seed_v, p.z * 2.3))
		return 1.0 + a * 0.35 * rough + (b - 0.6) * 0.3 * rough
	mb.ico(1.0, subdiv, f, scl, smooth)
	return mb.build()


func _rocks() -> void:
	var variants := 5
	var xforms: Array = []
	for v in variants:
		xforms.append([])
	var body := StaticBody3D.new()
	add_child(body)
	var meshes: Array = []
	for v in variants:
		meshes.append(_rock_mesh(v * 13.7, 3, 1.0, Vector3(1.0, rng.randf_range(0.55, 0.85), rng.randf_range(0.8, 1.2)), true))
	var count := 0
	var tries := 0
	while count < 260 and tries < 6000:
		tries += 1
		var x := rng.randf_range(-250.0, 250.0)
		var z := rng.randf_range(-250.0, 250.0)
		var mask := nz.get_noise_2d(x * 0.012, z * 0.012)
		if mask < 0.05 and rng.randf() > 0.12:
			continue
		var s := 0.5 + pow(rng.randf(), 2.6) * 4.2
		if not _clear_ok(x, z, s + 3.0):
			continue
		_add_rock(x, z, s, meshes, xforms, body)
		count += 1
	# a rock garden along the demo path so feet visibly plant on boulders
	for k in 20:
		for sgn in [-1.0, 1.0]:
			if rng.randf() < 0.8:
				_add_rock(-30.0 + sgn * rng.randf_range(2.2, 3.7), 54.0 - k * 3.1 + rng.randf_range(-0.8, 0.8), rng.randf_range(0.9, 1.5), meshes, xforms, body)
	for v in variants:
		_multimesh(meshes[v], xforms[v], rock_mat, true)


func _add_rock(x: float, z: float, s: float, meshes: Array, xforms: Array, body: StaticBody3D) -> void:
	var v := rng.randi() % meshes.size()
	var b := Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3)))
	b = b.scaled(Vector3(s, s * rng.randf_range(0.7, 1.2), s))
	var t := Transform3D(b, Vector3(x, G.h(x, z) - s * 0.22, z))
	xforms[v].append(t)
	if s > 0.85:
		var cs := CollisionShape3D.new()
		var shape := ConvexPolygonShape3D.new()
		var src: PackedVector3Array = meshes[v].surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var pts := PackedVector3Array()
		var i := 0
		while i < src.size():
			pts.append(t * src[i])
			i += 6
		shape.points = pts
		cs.shape = shape
		body.add_child(cs)
	if s > 2.4:
		G.obstacles.append(Vector3(x, z, s * 0.85))


func _multimesh(mesh: Mesh, xf: Array, mat: Material, shadows: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


func _rib_mesh(hgt: float, wid: float, r0: float) -> ArrayMesh:
	var mb := MB.new()
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	var n := 14
	for i in n:
		var t := float(i) / float(n - 1)
		var a := t * 2.0
		var p := Vector3(wid * (1.0 - cos(a)) + sin(t * 9.0) * 0.15, hgt * sin(a * 0.86) - 1.5, sin(t * 5.0) * 0.4)
		path.append(p)
		radii.append(r0 * pow(1.0 - t, 0.75) + 0.04 + 0.12 * r0 * sin(t * 23.0))
	mb.tube(path, radii, 9, true, true, true, 0.7, Vector3(0, 0, 1))
	return mb.build()


func _ribs() -> void:
	var mesh_a := _rib_mesh(17.0, 9.0, 1.25)
	var mesh_b := _rib_mesh(12.0, 6.5, 0.9)
	var xa: Array = []
	var xb: Array = []
	var cages := [[Vector3(-62, 0, -150), 0.5, 7], [Vector3(150, 0, 40), 2.1, 6], [Vector3(-150, 0, 95), -0.6, 5], [Vector3(60, 0, 170), 1.2, 5]]
	for cg in cages:
		var c: Vector3 = cg[0]
		var yaw: float = cg[1]
		var cnt: int = cg[2]
		var fwd := Vector3(sin(yaw), 0, cos(yaw))
		var side := Vector3(fwd.z, 0, -fwd.x)
		for i in cnt:
			var along := (i - (cnt - 1) * 0.5) * 8.5
			var sc := 1.0 - absf(i - (cnt - 1) * 0.5) / float(cnt) * 0.7
			for sgn in [-1.0, 1.0]:
				var p: Vector3 = c + fwd * along + side * sgn * 10.0 * sc
				p = G.ground(p)
				# rib mesh curls toward +X: point +X at the spine
				var bx: Vector3 = -side * sgn
				var b := Basis(bx, Vector3.UP, bx.cross(Vector3.UP)).rotated(Vector3.UP, rng.randf_range(-0.12, 0.12))
				b = b.scaled(Vector3.ONE * sc * rng.randf_range(0.9, 1.1))
				(xa if i % 2 == 0 else xb).append(Transform3D(b, p))
				G.obstacles.append(Vector3(p.x, p.z, 1.6))
				keep_clear.append(Vector3(p.x, p.z, 2.0))
	for i in 16:
		var a := rng.randf() * TAU
		var r := rng.randf_range(70.0, 235.0)
		var p := G.ground(Vector3(cos(a) * r, 0, sin(a) * r))
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.25, 0.25), rng.randf() * TAU, rng.randf_range(-0.25, 0.25))).scaled(Vector3.ONE * rng.randf_range(0.6, 1.5))
		xb.append(Transform3D(b, p))
		G.obstacles.append(Vector3(p.x, p.z, 1.4))
	_multimesh(mesh_a, xa, bone_mat, true)
	_multimesh(mesh_b, xb, bone_mat, true)


func _spires() -> void:
	var meshes: Array = []
	for v in 3:
		meshes.append(_rock_mesh(100.0 + v * 7.0, 3, 1.5, Vector3(1.0, 4.6, 1.0), false))
	var xf: Array = [[], [], []]
	var placed := 0
	while placed < 26:
		var a := rng.randf() * TAU
		var r := rng.randf_range(120.0, 420.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var s := rng.randf_range(4.0, 9.0) * (1.0 + maxf(r - 220.0, 0.0) / 120.0)
		if not _clear_ok(x, z, s + 6.0):
			continue
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.22, 0.22), rng.randf() * TAU, rng.randf_range(-0.22, 0.22))).scaled(Vector3(s, s * rng.randf_range(0.8, 1.4), s))
		xf[placed % 3].append(Transform3D(b, G.ground(Vector3(x, 0, z), s * 1.2)))
		if r < 250.0:
			G.obstacles.append(Vector3(x, z, s * 0.95))
			keep_clear.append(Vector3(x, z, s))
		placed += 1
	for v in 3:
		_multimesh(meshes[v], xf[v], rock_mat, true)


func crystal_cluster_mesh(seed_v: int, count: int) -> ArrayMesh:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	var mb := MB.new()
	for i in count:
		var tilt := 0.15 + 0.75 * float(i) / float(count)
		var az := r.randf() * TAU
		var axis := Vector3(sin(az) * sin(tilt), cos(tilt), cos(az) * sin(tilt))
		var rad := r.randf_range(0.14, 0.4) * (1.3 - tilt)
		var ln := r.randf_range(0.9, 2.6) * (1.25 - tilt * 0.7)
		mb.prism(Vector3(sin(az), 0, cos(az)) * tilt * 0.35 - Vector3(0, 0.3, 0), axis, rad, ln, rad * 2.2, 6)
	return mb.build()


func _crystals() -> void:
	var meshes: Array = []
	var xf: Array = [[], [], []]
	for v in 3:
		meshes.append(crystal_cluster_mesh(900 + v, 6 + v * 2))
	var placed := 0
	var lights := 0
	while placed < 85:
		var x := rng.randf_range(-245.0, 245.0)
		var z := rng.randf_range(-245.0, 245.0)
		var s := rng.randf_range(0.7, 1.6) + pow(rng.randf(), 5.0) * 3.0
		if not _clear_ok(x, z, s + 2.0):
			continue
		var nrm: Vector3 = G.terrain.normal(x, z)
		var b := Basis(Quaternion(Vector3.UP, nrm)).rotated(nrm, rng.randf() * TAU).scaled(Vector3.ONE * s)
		xf[placed % 3].append(Transform3D(b, G.ground(Vector3(x, 0, z))))
		if s > 2.0:
			G.obstacles.append(Vector3(x, z, s * 0.7))
			if lights < 12:
				lights += 1
				var l := OmniLight3D.new()
				l.light_color = G.C_MAGENTA
				l.light_energy = 3.0
				l.omni_range = 7.0 * s
				l.omni_attenuation = 1.4
				l.position = G.ground(Vector3(x, 0, z), s * 1.2)
				l.light_volumetric_fog_energy = 0.0
				add_child(l)
		placed += 1
	for v in 3:
		_multimesh(meshes[v], xf[v], crystal_mat, false)


func _tree_mesh(seed_v: int) -> ArrayMesh:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	var mb := MB.new()
	var hgt := r.randf_range(5.0, 8.0)
	var bend := Vector3(r.randf_range(-1.0, 1.0), 0, r.randf_range(-1.0, 1.0)) * 1.3
	var trunk := PackedVector3Array()
	var radii := PackedFloat32Array()
	var n := 9
	for i in n:
		var t := float(i) / float(n - 1)
		trunk.append(Vector3(0, hgt * t - 0.4, 0) + bend * t * t + Vector3(sin(t * 6.0), 0, cos(t * 5.0)) * 0.12)
		radii.append(lerpf(0.42, 0.10, pow(t, 0.7)) + 0.05 * sin(t * 20.0))
	mb.col = Color(0, 0, 0, 1)
	mb.tube(trunk, radii, 8, true, true)
	# crown bulb
	mb.col = Color(0, 1, 0, 1)
	mb.sphere(trunk[n - 1] + Vector3(0, 0.2, 0), Vector3(0.28, 0.4, 0.28), 10, 7)
	var branches := r.randi_range(3, 5)
	for bi in branches:
		var t0 := r.randf_range(0.35, 0.85)
		var start: Vector3 = trunk[int(t0 * (n - 1))]
		var az := TAU * float(bi) / float(branches) + r.randf_range(-0.4, 0.4)
		var out := Vector3(sin(az), 0, cos(az))
		var ln := r.randf_range(1.6, 3.2)
		var bp := PackedVector3Array()
		var br := PackedFloat32Array()
		for k in 6:
			var u := float(k) / 5.0
			bp.append(start + out * ln * u + Vector3(0, sin(u * 2.4) * ln * 0.55 - u * u * ln * 0.25, 0))
			br.append(lerpf(0.13, 0.045, u))
		mb.col = Color(0, 0, 0, 1)
		mb.tube(bp, br, 6, false, false)
		mb.col = Color(0, 1, 0, 1)
		var rr := r.randf_range(0.14, 0.26)
		mb.sphere(bp[5] - Vector3(0, rr * 0.9, 0), Vector3(rr, rr * 1.4, rr), 8, 6)
	# root flare fins
	mb.col = Color(1, 0, 0, 1)
	for k in 5:
		var az := TAU * k / 5.0 + 0.3
		var o := Vector3(sin(az), 0, cos(az))
		mb.tube(PackedVector3Array([Vector3(0, 1.1, 0) + o * 0.2, Vector3(0, 0.25, 0) + o * 0.75, Vector3(0, -0.4, 0) + o * 1.3]),
			PackedFloat32Array([0.1, 0.16, 0.07]), 5, true, true)
	return mb.build()


func _trees() -> void:
	var meshes: Array = []
	var xf: Array = [[], [], [], []]
	for v in 4:
		meshes.append(_tree_mesh(300 + v))
	var placed := 0
	while placed < 110:
		var x := rng.randf_range(-240.0, 240.0)
		var z := rng.randf_range(-240.0, 240.0)
		if nz.get_noise_2d(x * 0.009 + 40.0, z * 0.009) < -0.05 and rng.randf() > 0.1:
			continue
		if not _clear_ok(x, z, 3.0):
			continue
		# keep the demo stage and its camera lines open
		if Vector2(x - 6.0, z + 30.0).length() < 44.0 or (absf(x + 30.0) < 12.0 and z > 0.0 and z < 75.0):
			continue
		var s := rng.randf_range(0.7, 1.7)
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.1, 0.1), rng.randf() * TAU, rng.randf_range(-0.1, 0.1))).scaled(Vector3.ONE * s)
		xf[placed % 4].append(Transform3D(b, G.ground(Vector3(x, 0, z))))
		G.obstacles.append(Vector3(x, z, 0.6 * s))
		placed += 1
	for v in 4:
		_multimesh(meshes[v], xf[v], tree_mat, true)


func _reeds() -> void:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var nrm := PackedVector3Array()
	var idx := PackedInt32Array()
	var hs := [0.0, 0.35, 0.7, 1.0]
	var ws := [0.02, 0.018, 0.012, 0.0]
	for q in 2:
		var ax := Vector3(1, 0, 0) if q == 0 else Vector3(0, 0, 1)
		var b0 := v.size()
		for k in 4:
			v.append(ax * -ws[k] + Vector3(0, hs[k], 0))
			v.append(ax * ws[k] + Vector3(0, hs[k], 0))
			uv.append(Vector2(0, hs[k]))
			uv.append(Vector2(1, hs[k]))
			nrm.append(Vector3.UP)
			nrm.append(Vector3.UP)
		for k in 3:
			var a := b0 + k * 2
			idx.append_array(PackedInt32Array([a, a + 1, a + 2, a + 1, a + 3, a + 2]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var xf: Array = []
	var tries := 0
	while xf.size() < 90000 and tries < 400000:
		tries += 1
		var x := rng.randf_range(-250.0, 250.0)
		var z := rng.randf_range(-250.0, 250.0)
		var m := nz.get_noise_2d(x * 0.02 + 90.0, z * 0.02) + 0.35 * nz.get_noise_2d(x * 0.09, z * 0.09 + 30.0)
		if m < 0.2:
			continue
		if G.terrain.normal(x, z).y < 0.93:
			continue
		var s := (0.22 + rng.randf() * 0.34) * clampf((m - 0.1) * 5.0, 0.4, 1.3)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(1.3, s * 1.5, 1.3))
		xf.append(Transform3D(b, Vector3(x, G.h(x, z) - 0.05, z)))
	var mmi := _multimesh(mesh, xf, G.smat("reed"), false)
	mmi.extra_cull_margin = 4.0


func _stage_clear(x: float, z: float, pad: float) -> bool:
	# the demo stage and its camera lines stay open
	if Vector2(x - 6.0, z + 30.0).length() < 44.0 + pad:
		return false
	if absf(x + 30.0) < 12.0 + pad and z > -pad and z < 75.0 + pad:
		return false
	return Vector2(x, z - 70.0).length() > 14.0 + pad


func _arch_mesh(seed_v: float, span: float, hgt: float, r0: float) -> ArrayMesh:
	var mb := MB.new()
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	var n := 18
	for i in n:
		var t := float(i) / float(n - 1)
		var a := PI * t
		var wob := nz.get_noise_2d(t * 3.0 + seed_v, seed_v * 1.7)
		var lean := nz.get_noise_2d(seed_v * 2.3, t * 2.0)
		var px := -cos(a) * span * (1.0 + 0.25 * wob)
		var py := pow(sin(a), 0.75) * hgt * (1.0 + 0.18 * sin(t * 4.0 + seed_v)) - 2.5
		path.append(Vector3(px, py, lean * span * 0.35))
		var foot := pow(absf(cos(a)), 1.6)
		radii.append(r0 * (0.62 + 0.9 * foot) * (1.0 + 0.3 * nz.get_noise_2d(t * 9.0, seed_v * 5.0)))
	mb.tube(path, radii, 9, true, true, false, 0.78, Vector3(0, 0, 1), 2.6)
	# broken slabs leaning against the feet
	for sgn in [-1.0, 1.0]:
		for k in 3:
			var base := Vector3(sgn * span * (0.85 + 0.2 * k), -1.5, (k - 1.0) * r0 * 1.2)
			var ax := Vector3(-sgn * 0.35, 1.0, 0.25 * (k - 1.0)).normalized()
			mb.prism(base, ax, r0 * (0.55 - 0.1 * k), r0 * (2.4 - 0.5 * k), r0 * 0.5, 5)
	return mb.build()


func _arches() -> void:
	var meshes: Array = []
	var dims := [[13.0, 15.0, 2.6], [19.0, 12.0, 3.2], [10.0, 21.0, 2.2]]
	for v in 3:
		meshes.append(_arch_mesh(40.0 + v * 9.3, dims[v][0], dims[v][1], dims[v][2]))
	var xf: Array = [[], [], []]
	var placed := 0
	var tries := 0
	while placed < 9 and tries < 4000:
		tries += 1
		var a := rng.randf() * TAU
		var r := rng.randf_range(62.0, 215.0)
		var x := cos(a) * r
		var z := sin(a) * r
		var v := placed % 3
		var sc := rng.randf_range(0.85, 1.5)
		var span: float = dims[v][0] * sc
		if not _clear_ok(x, z, span + 8.0) or not _stage_clear(x, z, span + 4.0):
			continue
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc)
		var c := G.ground(Vector3(x, 0, z))
		# sit on the lower of the two feet so neither floats
		var fa: Vector3 = c + b * Vector3(-dims[v][0], 0, 0)
		var fb: Vector3 = c + b * Vector3(dims[v][0], 0, 0)
		c.y = minf(G.h(fa.x, fa.z), G.h(fb.x, fb.z))
		xf[v].append(Transform3D(b, c))
		for f in [fa, fb]:
			G.obstacles.append(Vector3(f.x, f.z, dims[v][2] * sc * 1.5))
			keep_clear.append(Vector3(f.x, f.z, dims[v][2] * sc * 1.8))
		placed += 1
	for v in 3:
		_multimesh(meshes[v], xf[v], rock_mat, true)


func _pools() -> void:
	# lowest hollows of the play area, spaced apart
	var cand: Array = []
	for i in 5000:
		var x := rng.randf_range(-225.0, 225.0)
		var z := rng.randf_range(-225.0, 225.0)
		if Vector2(x, z).length() > 225.0:
			continue
		cand.append(Vector3(x, G.h(x, z), z))
	cand.sort_custom(func(a, b): return a.y < b.y)
	var picked: Array = []
	for c in cand:
		if picked.size() >= 11:
			break
		if not _clear_ok(c.x, c.z, 10.0) or not _stage_clear(c.x, c.z, 6.0):
			continue
		var ok := true
		for q in picked:
			if Vector2(c.x - q.x, c.z - q.z).length() < 48.0:
				ok = false
				break
		if ok:
			picked.append(c)
	var mat := G.smat("pool")
	var lights := 0
	for c in picked:
		var half := rng.randf_range(16.0, 26.0)
		var level: float = c.y + rng.randf_range(0.55, 0.95)
		var n := 44
		var v := PackedVector3Array()
		var uv := PackedVector2Array()
		var nrm := PackedVector3Array()
		var idx := PackedInt32Array()
		var wet := false
		for j in n + 1:
			for i in n + 1:
				var x: float = c.x - half + 2.0 * half * i / n
				var z: float = c.z - half + 2.0 * half * j / n
				var edge := 1.0 - Vector2(float(i) / n - 0.5, float(j) / n - 0.5).length() * 2.0
				# sink the level toward the patch border so the square outline never shows
				var d: float = level - G.h(x, z) - (1.0 - smoothstep(0.0, 0.55, edge)) * 9.0
				wet = wet or d > 0.0
				v.append(Vector3(x, level, z))
				uv.append(Vector2(d, 0.0))
				nrm.append(Vector3.UP)
		if not wet:
			continue
		for j in n:
			for i in n:
				var a := j * (n + 1) + i
				idx.append_array(PackedInt32Array([a, a + 1, a + n + 1, a + 1, a + n + 2, a + n + 1]))
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = nrm
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		if lights < 8:
			lights += 1
			var l := OmniLight3D.new()
			l.light_color = G.C_TEAL
			l.light_energy = 1.6
			l.omni_range = 20.0
			l.omni_attenuation = 1.2
			l.position = Vector3(c.x, level + 2.5, c.z)
			l.light_volumetric_fog_energy = 1.5
			add_child(l)


func _pebbles() -> void:
	var meshes: Array = []
	var xf: Array = [[], [], []]
	for v in 3:
		meshes.append(_rock_mesh(200.0 + v * 5.1, 1, 1.3, Vector3(1.0, rng.randf_range(0.45, 0.7), rng.randf_range(0.7, 1.3)), false))
	var count := 0
	var tries := 0
	while count < 7000 and tries < 120000:
		tries += 1
		var x := rng.randf_range(-240.0, 240.0)
		var z := rng.randf_range(-240.0, 240.0)
		# gathered in drifts, thin elsewhere
		var m := nz.get_noise_2d(x * 0.03 + 12.0, z * 0.03 - 7.0) + 0.5 * nz.get_noise_2d(x * 0.17, z * 0.17)
		if m < 0.15 and rng.randf() > 0.06:
			continue
		var s := 0.07 + pow(rng.randf(), 3.0) * 0.42
		var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)).scaled(Vector3.ONE * s)
		xf[count % 3].append(Transform3D(b, Vector3(x, G.h(x, z) + s * 0.15, z)))
		count += 1
	for v in 3:
		var mmi := _multimesh(meshes[v], xf[v], rock_mat, false)
		mmi.visibility_range_end = 140.0
