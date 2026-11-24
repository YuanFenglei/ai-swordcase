extends RefCounted
## Code-built meshes. Boxes share their 8 corners (flat normals come from screen-space derivatives in the shaders),
## UV = (part id, pivot y), UV2 = (pivot z, colour id) drive the vertex-shader animation.

const QUADS := [[0, 1, 3, 2], [4, 5, 7, 6], [0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6]]

var v := PackedVector3Array()
var uv := PackedVector2Array()
var uv2 := PackedVector2Array()
var col := PackedColorArray()
var idx := PackedInt32Array()
var xf := Transform3D.IDENTITY
var color := Color.WHITE


func tri(a: int, b: int, c: int, center: Vector3) -> void:
	var n := (v[b] - v[a]).cross(v[c] - v[a])
	var out := (v[a] + v[b] + v[c]) / 3.0 - center
	if n.dot(out) > 0.0:
		var t := b
		b = c
		c = t
	idx.append(a)
	idx.append(b)
	idx.append(c)


func box(c: Vector3, s: Vector3, part := 0.0, piv := Vector2.ZERO, cid := 0.0, top := 1.0, rx := 0.0, bot := 1.0) -> void:
	var b := v.size()
	var h := s * 0.5
	var bas := Basis(Vector3.RIGHT, rx)
	for i in 8:
		var sx := 1.0 if (i & 1) != 0 else -1.0
		var sz := 1.0 if (i & 2) != 0 else -1.0
		var sy := 1.0 if (i & 4) != 0 else -1.0
		var k := top if sy > 0.0 else bot
		var p := Vector3(sx * h.x * k, sy * h.y, sz * h.z * k)
		v.append(xf * (c + bas * p))
		uv.append(Vector2(part, piv.x))
		uv2.append(Vector2(piv.y, cid))
		col.append(color)
	var cc := xf * c
	for q: Array in QUADS:
		tri(b + q[0], b + q[1], b + q[2], cc)
		tri(b + q[0], b + q[2], b + q[3], cc)


func ring(r0: float, r1: float, y: float) -> void:
	var b := v.size()
	var n := 12
	for k in n:
		var a := TAU * float(k) / float(n)
		for r: float in [r0, r1]:
			v.append(Vector3(cos(a) * r, y, sin(a) * r))
			uv.append(Vector2(6.0, 0.0))
			uv2.append(Vector2(0.0, 7.0))
			col.append(color)
	for k in n:
		var i0 := b + k * 2
		var i1 := b + ((k + 1) % n) * 2
		tri(i0, i0 + 1, i1 + 1, Vector3(0, y - 1.0, 0))
		tri(i0, i1 + 1, i1, Vector3(0, y - 1.0, 0))


func build(with_col := false) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	if with_col:
		arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


static func infantry(banner: bool, with_ring: bool) -> ArrayMesh:
	var m := new()
	var sh := Vector2(1.38, 0.0)
	m.box(Vector3(-0.12, 0.41, 0), Vector3(0.18, 0.82, 0.21), 2, Vector2(0.82, 0), 3, 1.0, 0.0, 0.8)
	m.box(Vector3(0.12, 0.41, 0), Vector3(0.18, 0.82, 0.21), 3, Vector2(0.82, 0), 3, 1.0, 0.0, 0.8)
	m.box(Vector3(0, 0.86, 0), Vector3(0.46, 0.2, 0.31), 0, Vector2.ZERO, 8)
	m.box(Vector3(0, 1.15, 0), Vector3(0.40, 0.56, 0.26), 0, Vector2.ZERO, 0, 1.22)
	m.box(Vector3(0, 1.57, 0.01), Vector3(0.22, 0.24, 0.23), 0, Vector2.ZERO, 1)
	m.box(Vector3(0, 1.69, 0), Vector3(0.28, 0.15, 0.29), 0, Vector2.ZERO, 2, 0.7)
	m.box(Vector3(0, 1.82, -0.02), Vector3(0.06, 0.14, 0.3), 0, Vector2.ZERO, 4)
	m.box(Vector3(0, 1.6, 0.125), Vector3(0.17, 0.05, 0.02), 0, Vector2.ZERO, 3)
	m.box(Vector3(0, 1.17, 0.14), Vector3(0.15, 0.42, 0.03), 0, Vector2.ZERO, 4)
	m.box(Vector3(-0.33, 1.12, 0), Vector3(0.14, 0.56, 0.15), 4, sh, 0)
	m.box(Vector3(-0.43, 1.08, 0.14), Vector3(0.07, 0.7, 0.52), 4, sh, 4)
	m.box(Vector3(-0.475, 1.08, 0.14), Vector3(0.04, 0.22, 0.2), 4, sh, 2)
	m.box(Vector3(0.33, 1.12, 0), Vector3(0.14, 0.56, 0.15), 5, sh, 0)
	m.box(Vector3(0.33, 0.86, 0.5), Vector3(0.05, 0.08, 0.9), 5, sh, 2)
	if banner:
		m.box(Vector3(0.0, 2.3, -0.24), Vector3(0.07, 3.4, 0.07), 12, Vector2.ZERO, 6)
		m.box(Vector3(0.0, 3.35, -1.1), Vector3(0.03, 1.15, 1.7), 12, Vector2.ZERO, 0)
		m.box(Vector3(0.0, 3.35, -1.1), Vector3(0.045, 0.3, 1.7), 12, Vector2.ZERO, 4)
		m.box(Vector3(0.0, 4.08, -0.24), Vector3(0.14, 0.14, 0.14), 12, Vector2.ZERO, 4)
	if with_ring:
		m.ring(0.6, 0.78, 0.12)
	return m.build()


static func archer(with_ring: bool) -> ArrayMesh:
	var m := new()
	var sh := Vector2(1.36, 0.0)
	m.box(Vector3(-0.11, 0.41, 0), Vector3(0.16, 0.82, 0.19), 2, Vector2(0.82, 0), 6, 1.0, 0.0, 0.8)
	m.box(Vector3(0.11, 0.41, 0), Vector3(0.16, 0.82, 0.19), 3, Vector2(0.82, 0), 6, 1.0, 0.0, 0.8)
	m.box(Vector3(0, 0.98, 0), Vector3(0.40, 0.5, 0.26), 0, Vector2.ZERO, 0, 0.85, 0.0, 1.15)
	m.box(Vector3(0, 1.28, 0), Vector3(0.36, 0.3, 0.23), 0, Vector2.ZERO, 8, 1.15)
	m.box(Vector3(0, 1.55, 0.01), Vector3(0.21, 0.23, 0.22), 0, Vector2.ZERO, 1)
	m.box(Vector3(0, 1.67, -0.02), Vector3(0.27, 0.16, 0.3), 0, Vector2.ZERO, 0, 0.6)
	m.box(Vector3(0, 1.57, 0.125), Vector3(0.16, 0.05, 0.02), 0, Vector2.ZERO, 3)
	m.box(Vector3(0.09, 1.2, -0.2), Vector3(0.13, 0.55, 0.11), 0, Vector2.ZERO, 6, 1.0, 0.3)
	m.box(Vector3(0.11, 1.5, -0.3), Vector3(0.1, 0.1, 0.08), 0, Vector2.ZERO, 4, 1.0, 0.3)
	m.box(Vector3(-0.29, 1.1, 0), Vector3(0.12, 0.54, 0.13), 4, sh, 8)
	m.box(Vector3(-0.31, 0.84, 0), Vector3(0.05, 0.06, 0.5), 4, sh, 6)
	m.box(Vector3(-0.31, 0.91, 0.42), Vector3(0.045, 0.05, 0.44), 4, sh, 6, 1.0, -0.4)
	m.box(Vector3(-0.31, 0.91, -0.42), Vector3(0.045, 0.05, 0.44), 4, sh, 6, 1.0, 0.4)
	m.box(Vector3(0.29, 1.1, 0), Vector3(0.12, 0.54, 0.13), 5, sh, 8)
	if with_ring:
		m.ring(0.55, 0.72, 0.12)
	return m.build()


static func cavalry(with_ring: bool) -> ArrayMesh:
	var m := new()
	var fl := Vector2(0.95, 0.62)
	var hl := Vector2(0.95, -0.62)
	m.box(Vector3(-0.17, 0.48, 0.62), Vector3(0.14, 0.96, 0.17), 8, fl, 5, 1.2, 0.0, 0.7)
	m.box(Vector3(0.17, 0.48, 0.62), Vector3(0.14, 0.96, 0.17), 9, fl, 5, 1.2, 0.0, 0.7)
	m.box(Vector3(-0.17, 0.48, -0.62), Vector3(0.14, 0.96, 0.17), 10, hl, 5, 1.3, 0.0, 0.7)
	m.box(Vector3(0.17, 0.48, -0.62), Vector3(0.14, 0.96, 0.17), 11, hl, 5, 1.3, 0.0, 0.7)
	m.box(Vector3(0, 1.2, 0), Vector3(0.5, 0.56, 1.7), 7, Vector2.ZERO, 5, 0.9)
	m.box(Vector3(0, 1.14, -0.02), Vector3(0.58, 0.66, 1.5), 7, Vector2.ZERO, 0, 0.92)
	m.box(Vector3(0, 1.62, 0.92), Vector3(0.24, 0.8, 0.36), 7, Vector2.ZERO, 5, 0.8, 0.65)
	m.box(Vector3(0, 1.98, 1.3), Vector3(0.2, 0.25, 0.52), 7, Vector2.ZERO, 5, 0.85, 0.45)
	m.box(Vector3(0, 1.72, 0.86), Vector3(0.06, 0.6, 0.12), 7, Vector2.ZERO, 3, 1.0, 0.65)
	m.box(Vector3(0, 1.1, -0.98), Vector3(0.1, 0.7, 0.1), 7, Vector2.ZERO, 3, 1.0, -0.35)
	m.box(Vector3(-0.31, 1.3, 0.02), Vector3(0.14, 0.6, 0.2), 0, Vector2.ZERO, 3)
	m.box(Vector3(0.31, 1.3, 0.02), Vector3(0.14, 0.6, 0.2), 0, Vector2.ZERO, 3)
	m.box(Vector3(0, 1.85, -0.05), Vector3(0.4, 0.6, 0.27), 0, Vector2.ZERO, 0, 1.2)
	m.box(Vector3(0, 2.3, 0.085), Vector3(0.17, 0.05, 0.02), 0, Vector2.ZERO, 3)
	m.box(Vector3(0, 2.28, -0.04), Vector3(0.22, 0.24, 0.23), 0, Vector2.ZERO, 1)
	m.box(Vector3(0, 2.4, -0.05), Vector3(0.28, 0.16, 0.29), 0, Vector2.ZERO, 2, 0.7)
	m.box(Vector3(0, 2.56, -0.1), Vector3(0.06, 0.24, 0.3), 0, Vector2.ZERO, 4)
	m.box(Vector3(-0.38, 1.82, 0.1), Vector3(0.07, 0.62, 0.46), 0, Vector2.ZERO, 4)
	var rs := Vector2(2.08, -0.05)
	m.box(Vector3(0.33, 1.84, -0.05), Vector3(0.14, 0.52, 0.15), 5, rs, 2)
	m.box(Vector3(0.33, 1.62, 0.85), Vector3(0.055, 0.055, 2.9), 5, rs, 6)
	m.box(Vector3(0.33, 1.62, 2.36), Vector3(0.09, 0.09, 0.3), 5, rs, 2, 1.0, 0.0, 1.0)
	m.box(Vector3(0.33, 1.78, 1.95), Vector3(0.025, 0.24, 0.5), 5, rs, 4)
	if with_ring:
		m.ring(1.05, 1.28, 0.12)
	return m.build()


static func arrow() -> ArrayMesh:
	var m := new()
	m.box(Vector3(0, 0, -0.6), Vector3(0.045, 0.045, 1.2), 0)
	m.box(Vector3(0, 0, -1.12), Vector3(0.11, 0.11, 0.2), 1)
	return m.build()


static func rock(sd: int) -> ArrayMesh:
	var m := new()
	var t := (1.0 + sqrt(5.0)) / 2.0
	var base := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
		Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var pts: Array[Vector3] = []
	for p: Vector3 in base:
		pts.append(p.normalized())
	for it in 2:
		var cache := {}
		var nf := []
		for f: Array in faces:
			var mid := []
			for e in 3:
				var a: int = f[e]
				var b: int = f[(e + 1) % 3]
				var key := mini(a, b) * 100000 + maxi(a, b)
				if not cache.has(key):
					cache[key] = pts.size()
					pts.append(((pts[a] + pts[b]) * 0.5).normalized())
				mid.append(cache[key])
			nf.append([f[0], mid[0], mid[2]])
			nf.append([f[1], mid[1], mid[0]])
			nf.append([f[2], mid[2], mid[1]])
			nf.append([mid[0], mid[1], mid[2]])
		faces = nf
	var ns := FastNoiseLite.new()
	ns.seed = sd
	ns.frequency = 0.55
	ns.fractal_octaves = 3
	for p: Vector3 in pts:
		var q := p * (1.0 + ns.get_noise_3dv(p * 1.6) * 0.75 + ns.get_noise_3dv(p * 5.0) * 0.18)
		q.y = maxf(q.y, -0.2) * 0.85
		m.v.append(q)
		m.uv.append(Vector2.ZERO)
		m.uv2.append(Vector2.ZERO)
		m.col.append(Color.WHITE)
	for f: Array in faces:
		m.tri(f[0], f[1], f[2], Vector3(0, 0.1, 0))
	return m.build()


# ---- far LODs: same part / colour ids, a third of the vertices

static func infantry_far(banner: bool, with_ring: bool) -> ArrayMesh:
	var m := new()
	m.box(Vector3(0, 0.41, 0), Vector3(0.42, 0.82, 0.22), 0, Vector2.ZERO, 3, 1.0, 0.0, 0.8)
	m.box(Vector3(0, 1.13, 0), Vector3(0.52, 0.66, 0.28), 0, Vector2.ZERO, 0, 1.2)
	m.box(Vector3(0, 1.62, 0), Vector3(0.27, 0.36, 0.27), 0, Vector2.ZERO, 2, 0.8)
	m.box(Vector3(-0.43, 1.08, 0.14), Vector3(0.07, 0.7, 0.52), 0, Vector2.ZERO, 4)
	if banner:
		m.box(Vector3(0.0, 2.3, -0.24), Vector3(0.07, 3.4, 0.07), 12, Vector2.ZERO, 6)
		m.box(Vector3(0.0, 3.35, -1.1), Vector3(0.03, 1.15, 1.7), 12, Vector2.ZERO, 0)
	if with_ring:
		m.ring(0.6, 0.78, 0.12)
	return m.build()


static func archer_far(with_ring: bool) -> ArrayMesh:
	var m := new()
	m.box(Vector3(0, 0.41, 0), Vector3(0.38, 0.82, 0.2), 0, Vector2.ZERO, 6, 1.0, 0.0, 0.8)
	m.box(Vector3(0, 1.1, 0), Vector3(0.44, 0.64, 0.26), 0, Vector2.ZERO, 0, 1.1)
	m.box(Vector3(0, 1.6, 0), Vector3(0.26, 0.34, 0.28), 0, Vector2.ZERO, 0, 0.7)
	if with_ring:
		m.ring(0.55, 0.72, 0.12)
	return m.build()


static func cavalry_far(with_ring: bool) -> ArrayMesh:
	var m := new()
	m.box(Vector3(0, 0.48, 0.62), Vector3(0.46, 0.96, 0.17), 8, Vector2(0.95, 0.62), 5, 1.1, 0.0, 0.8)
	m.box(Vector3(0, 0.48, -0.62), Vector3(0.46, 0.96, 0.17), 10, Vector2(0.95, -0.62), 5, 1.1, 0.0, 0.8)
	m.box(Vector3(0, 1.17, -0.02), Vector3(0.58, 0.66, 1.6), 7, Vector2.ZERO, 0, 0.92)
	m.box(Vector3(0, 1.7, 1.0), Vector3(0.24, 0.95, 0.4), 7, Vector2.ZERO, 5, 0.8, 0.65)
	m.box(Vector3(0, 1.95, -0.05), Vector3(0.42, 0.85, 0.3), 0, Vector2.ZERO, 0, 0.8)
	m.box(Vector3(0.33, 1.62, 0.85), Vector3(0.055, 0.055, 2.9), 5, Vector2(2.08, -0.05), 6)
	if with_ring:
		m.ring(1.05, 1.28, 0.12)
	return m.build()
