extends Node3D
# Noise heightfield: dense inner play mesh (with collision) + coarse outer mountain ring.

const CELL := 2.0
const N := 257
const HALF := 256.0
const OUT_CELL := 8.0
const OUT_HALF := 1024.0

var hm := PackedFloat32Array()
var n1 := FastNoiseLite.new()
var n2 := FastNoiseLite.new()
var n3 := FastNoiseLite.new()
var n4 := FastNoiseLite.new()
var mat: ShaderMaterial


func _init() -> void:
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n1.seed = 11
	n1.frequency = 0.0045
	n1.fractal_octaves = 4
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n2.seed = 23
	n2.frequency = 0.011
	n2.fractal_octaves = 2
	n3.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n3.seed = 37
	n3.frequency = 0.06
	n3.fractal_octaves = 3
	n4.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n4.seed = 51
	n4.frequency = 0.005
	n4.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	n4.fractal_octaves = 4


func raw(x: float, z: float) -> float:
	var r := sqrt(x * x + z * z)
	var base := n1.get_noise_2d(x, z) * 11.0
	var rd := 1.0 - absf(n2.get_noise_2d(x, z))
	var ridge := rd * rd * 5.0
	var small := n3.get_noise_2d(x, z) * 0.45
	var flatk := lerpf(0.45, 1.0, smoothstep(30.0, 120.0, r))
	var hh := (base + ridge - 3.0) * flatk + small
	var m := smoothstep(215.0, 520.0, r)
	var mr := n4.get_noise_2d(x, z) * 0.5 + 0.5
	# open the horizon toward the sun and the planet (-Z)
	mr *= lerpf(0.3, 1.0, smoothstep(-0.92, -0.2, z / maxf(r, 1.0)))
	hh += m * m * (25.0 + 190.0 * mr * mr) + smoothstep(205.0, 300.0, r) * 10.0 * mr
	if m > 0.0:
		var cr := 1.0 - absf(n2.get_noise_2d(x * 2.3 + 300.0, z * 2.3))
		hh += m * (cr * cr * 15.0 - 5.0) * (0.3 + mr) + m * n3.get_noise_2d(x * 0.4, z * 0.4) * 3.0
	return hh


func build() -> void:
	mat = G.smat("terrain")
	hm.resize(N * N)
	for j in N:
		var z := -HALF + j * CELL
		for i in N:
			hm[j * N + i] = raw(-HALF + i * CELL, z)
	# snap border to the 16 m outer grid so the two meshes meet without cracks
	var step := int(OUT_CELL / CELL)
	for k in N:
		if k % step == 0:
			continue
		var k0 := (k / step) * step
		var f := float(k - k0) / float(step)
		hm[k] = lerpf(hm[k0], hm[k0 + step], f)
		hm[(N - 1) * N + k] = lerpf(hm[(N - 1) * N + k0], hm[(N - 1) * N + k0 + step], f)
		hm[k * N] = lerpf(hm[k0 * N], hm[(k0 + step) * N], f)
		hm[k * N + N - 1] = lerpf(hm[k0 * N + N - 1], hm[(k0 + step) * N + N - 1], f)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(N * N)
	norms.resize(N * N)
	for j in N:
		for i in N:
			var idx := j * N + i
			verts[idx] = Vector3(-HALF + i * CELL, hm[idx], -HALF + j * CELL)
			var hl := hm[j * N + maxi(i - 1, 0)]
			var hr := hm[j * N + mini(i + 1, N - 1)]
			var hd := hm[maxi(j - 1, 0) * N + i]
			var hu := hm[mini(j + 1, N - 1) * N + i]
			norms[idx] = Vector3(hl - hr, 2.0 * CELL, hd - hu).normalized()
	var ind := PackedInt32Array()
	var faces := PackedVector3Array()
	ind.resize((N - 1) * (N - 1) * 6)
	faces.resize((N - 1) * (N - 1) * 6)
	var w := 0
	for j in N - 1:
		for i in N - 1:
			var a := j * N + i
			var b := a + 1
			var c := a + N
			var d := c + 1
			ind[w] = a; ind[w + 1] = b; ind[w + 2] = c
			ind[w + 3] = b; ind[w + 4] = d; ind[w + 5] = c
			faces[w] = verts[a]; faces[w + 1] = verts[b]; faces[w + 2] = verts[c]
			faces[w + 3] = verts[b]; faces[w + 4] = verts[d]; faces[w + 5] = verts[c]
			w += 6
	_add_mesh(verts, norms, ind, true)

	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

	# outer ring
	var m := int(OUT_HALF * 2.0 / OUT_CELL) + 1
	var ov := PackedVector3Array()
	var on := PackedVector3Array()
	ov.resize(m * m)
	on.resize(m * m)
	for j in m:
		var z := -OUT_HALF + j * OUT_CELL
		for i in m:
			var x := -OUT_HALF + i * OUT_CELL
			ov[j * m + i] = Vector3(x, raw(x, z), z)
	for j in m:
		for i in m:
			var hl := ov[j * m + maxi(i - 1, 0)].y
			var hr := ov[j * m + mini(i + 1, m - 1)].y
			var hd := ov[maxi(j - 1, 0) * m + i].y
			var hu := ov[mini(j + 1, m - 1) * m + i].y
			on[j * m + i] = Vector3(hl - hr, 2.0 * OUT_CELL, hd - hu).normalized()
	var oi := PackedInt32Array()
	for j in m - 1:
		for i in m - 1:
			var cx := -OUT_HALF + (i + 0.5) * OUT_CELL
			var cz := -OUT_HALF + (j + 0.5) * OUT_CELL
			if absf(cx) < HALF and absf(cz) < HALF:
				continue
			var a := j * m + i
			var b := a + 1
			var c := a + m
			var d := c + 1
			oi.append(a); oi.append(b); oi.append(c)
			oi.append(b); oi.append(d); oi.append(c)
	_add_mesh(ov, on, oi, false)


func _add_mesh(v: PackedVector3Array, n: PackedVector3Array, i: PackedInt32Array, shadows: bool) -> void:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_INDEX] = i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 10.0
	add_child(mi)


func height(x: float, z: float) -> float:
	var fx := (x + HALF) / CELL
	var fz := (z + HALF) / CELL
	if fx < 0.0 or fz < 0.0 or fx >= N - 1 or fz >= N - 1:
		return raw(x, z)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var a := j * N + i
	# match the triangle split used by the mesh
	if tx + tz <= 1.0:
		return hm[a] + (hm[a + 1] - hm[a]) * tx + (hm[a + N] - hm[a]) * tz
	return hm[a + N + 1] + (hm[a + N] - hm[a + N + 1]) * (1.0 - tx) + (hm[a + 1] - hm[a + N + 1]) * (1.0 - tz)


func normal(x: float, z: float) -> Vector3:
	var e := 1.5
	return Vector3(height(x - e, z) - height(x + e, z), 2.0 * e, height(x, z - e) - height(x, z + e)).normalized()
