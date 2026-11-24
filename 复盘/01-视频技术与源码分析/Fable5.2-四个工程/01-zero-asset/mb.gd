extends RefCounted
# Procedural mesh builder: lofts, tubes, lathes, icospheres -> one ArrayMesh surface.
# Vertex colour is a material mask: R = accent paint, G = emission, B = dark joint / flex weight.

var V := PackedVector3Array()
var NN := PackedVector3Array()
var C := PackedColorArray()
var UV := PackedVector2Array()
var I := PackedInt32Array()
var xf := Transform3D.IDENTITY
var col := Color(0, 0, 0, 1)


func _commit(pv: PackedVector3Array, puv: PackedVector2Array, pi: PackedInt32Array, smooth: bool) -> void:
	var n := pv.size()
	var flip := xf.basis.determinant() < 0.0
	var tv := PackedVector3Array()
	tv.resize(n)
	for i in n:
		tv[i] = xf * pv[i]
	var base := V.size()
	var t := 0
	var cnt := pi.size()
	if smooth:
		var nn := PackedVector3Array()
		nn.resize(n)
		while t < cnt:
			var a := pi[t]
			var b := pi[t + 1]
			var c := pi[t + 2]
			if flip:
				var tmp := b
				b = c
				c = tmp
			var fn := (tv[c] - tv[a]).cross(tv[b] - tv[a])
			nn[a] += fn
			nn[b] += fn
			nn[c] += fn
			I.append(base + a)
			I.append(base + b)
			I.append(base + c)
			t += 3
		for i in n:
			V.append(tv[i])
			var nv := nn[i]
			NN.append(nv.normalized() if nv.length_squared() > 1e-16 else Vector3.UP)
			C.append(col)
			UV.append(puv[i])
	else:
		while t < cnt:
			var a := pi[t]
			var b := pi[t + 1]
			var c := pi[t + 2]
			if flip:
				var tmp := b
				b = c
				c = tmp
			var fn := (tv[c] - tv[a]).cross(tv[b] - tv[a])
			if fn.length_squared() > 1e-16:
				fn = fn.normalized()
				var k := V.size()
				V.append(tv[a]); V.append(tv[b]); V.append(tv[c])
				NN.append(fn); NN.append(fn); NN.append(fn)
				C.append(col); C.append(col); C.append(col)
				UV.append(puv[a]); UV.append(puv[b]); UV.append(puv[c])
				I.append(k); I.append(k + 1); I.append(k + 2)
			t += 3


static func ring(center: Vector3, x: Vector3, y: Vector3, rx: float, ry: float, m: int, expo := 2.0, phase := 0.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(m)
	var e := 2.0 / expo
	for i in m:
		var a := TAU * float(i) / float(m) + phase
		var ca := cos(a)
		var sa := sin(a)
		var px := signf(ca) * pow(absf(ca), e) * rx
		var py := signf(sa) * pow(absf(sa), e) * ry
		out[i] = center + x * px + y * py
	return out


func loft(rings: Array, cap0 := false, cap1 := false, smooth := true) -> void:
	var first: PackedVector3Array = rings[0]
	var m := first.size()
	var r := rings.size()
	var pv := PackedVector3Array()
	var puv := PackedVector2Array()
	var pi := PackedInt32Array()
	for j in r:
		var rg: PackedVector3Array = rings[j]
		for i in m:
			pv.append(rg[i])
			puv.append(Vector2(float(i) / float(m), float(j) / float(maxi(r - 1, 1))))
	for j in r - 1:
		for i in m:
			var a := j * m + i
			var b := j * m + (i + 1) % m
			var c := (j + 1) * m + i
			var d := (j + 1) * m + (i + 1) % m
			pi.append(a); pi.append(c); pi.append(b)
			pi.append(b); pi.append(c); pi.append(d)
	_commit(pv, puv, pi, smooth)
	if cap0:
		_cap(rings[0], false)
	if cap1:
		_cap(rings[r - 1], true)


func _cap(rg: PackedVector3Array, at_end: bool) -> void:
	var m := rg.size()
	var pv := PackedVector3Array(rg)
	var puv := PackedVector2Array()
	var ctr := Vector3.ZERO
	for p in rg:
		ctr += p
		puv.append(Vector2(0.5, 1.0 if at_end else 0.0))
	ctr /= float(m)
	pv.append(ctr)
	puv.append(Vector2(0.5, 1.0 if at_end else 0.0))
	var pi := PackedInt32Array()
	for i in m:
		var j := (i + 1) % m
		if at_end:
			pi.append(m); pi.append(j); pi.append(i)
		else:
			pi.append(m); pi.append(i); pi.append(j)
	_commit(pv, puv, pi, false)


func tube(path: PackedVector3Array, radii: PackedFloat32Array, sides := 8, cap0 := true, cap1 := true, smooth := true, squash := 1.0, up_hint := Vector3.UP, expo := 2.0) -> void:
	var n := path.size()
	var rings: Array = []
	var x := Vector3.ZERO
	for i in n:
		var t: Vector3
		if i == 0:
			t = path[1] - path[0]
		elif i == n - 1:
			t = path[n - 1] - path[n - 2]
		else:
			t = path[i + 1] - path[i - 1]
		t = t.normalized()
		if i == 0:
			x = up_hint - t * up_hint.dot(t)
			if x.length_squared() < 1e-6:
				x = Vector3.RIGHT - t * t.x
		else:
			x = x - t * x.dot(t)
		x = x.normalized()
		var y := t.cross(x)
		rings.append(ring(path[i], x, y, radii[i], radii[i] * squash, sides, expo))
	loft(rings, cap0, cap1, smooth)


func lathe(profile: PackedVector2Array, sides := 12, smooth := true, cap0 := false, cap1 := false) -> void:
	var rings: Array = []
	for p in profile:
		rings.append(ring(Vector3(0, p.y, 0), Vector3(0, 0, 1), Vector3(1, 0, 0), p.x, p.x, sides))
	loft(rings, cap0, cap1, smooth)


func sphere(center: Vector3, rad: Vector3, segs := 12, rows := 8) -> void:
	var rings: Array = []
	for j in rows + 1:
		var a := PI * float(j) / float(rows)
		var rr := maxf(sin(a), 0.002)
		var yy := -cos(a)
		rings.append(ring(center + Vector3(0, yy * rad.y, 0), Vector3(0, 0, 1), Vector3(1, 0, 0), rr * rad.z, rr * rad.x, segs))
	loft(rings, false, false, true)


func ico(radius: float, subdiv: int, displace: Callable, scl := Vector3.ONE, smooth := true) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var pts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in pts.size():
		pts[i] = pts[i].normalized()
	var tris: Array[int] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
	for s in subdiv:
		var cache := {}
		var nt: Array[int] = []
		var k := 0
		while k < tris.size():
			var a := tris[k]
			var b := tris[k + 1]
			var c := tris[k + 2]
			var ab := _mid(pts, cache, a, b)
			var bc := _mid(pts, cache, b, c)
			var ca := _mid(pts, cache, c, a)
			nt.append(a); nt.append(ab); nt.append(ca)
			nt.append(b); nt.append(bc); nt.append(ab)
			nt.append(c); nt.append(ca); nt.append(bc)
			nt.append(ab); nt.append(bc); nt.append(ca)
			k += 3
		tris = nt
	var pv := PackedVector3Array()
	var puv := PackedVector2Array()
	for p in pts:
		var d: float = 1.0
		if displace.is_valid():
			d = displace.call(p)
		pv.append(p * radius * d * scl)
		puv.append(Vector2(atan2(p.x, p.z) / TAU + 0.5, p.y * 0.5 + 0.5))
	var pi := PackedInt32Array()
	var k2 := 0
	while k2 < tris.size():
		var a := tris[k2]
		var b := tris[k2 + 1]
		var c := tris[k2 + 2]
		var fn := (pv[c] - pv[a]).cross(pv[b] - pv[a])
		if fn.dot(pv[a] + pv[b] + pv[c]) < 0.0:
			var tmp := b
			b = c
			c = tmp
		pi.append(a); pi.append(b); pi.append(c)
		k2 += 3
	_commit(pv, puv, pi, smooth)


func _mid(pts: Array[Vector3], cache: Dictionary, a: int, b: int) -> int:
	var key := mini(a, b) * 100000 + maxi(a, b)
	if cache.has(key):
		return cache[key]
	pts.append(((pts[a] + pts[b]) * 0.5).normalized())
	cache[key] = pts.size() - 1
	return pts.size() - 1


func prism(base: Vector3, axis: Vector3, radius: float, length: float, tip: float, sides := 6) -> void:
	var a := axis.normalized()
	tube(PackedVector3Array([base, base + a * length, base + a * (length + tip)]),
		PackedFloat32Array([radius * 0.75, radius, radius * 0.02]), sides, true, false, false)


func build() -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V
	arr[Mesh.ARRAY_NORMAL] = NN
	arr[Mesh.ARRAY_COLOR] = C
	arr[Mesh.ARRAY_TEX_UV] = UV
	arr[Mesh.ARRAY_INDEX] = I
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
