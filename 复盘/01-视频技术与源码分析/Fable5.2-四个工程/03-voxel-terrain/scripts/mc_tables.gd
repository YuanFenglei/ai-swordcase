extends RefCounted

# Builds the full 256-case marching cubes table at startup.
# Each case is derived by tracing the iso-contour across the six cube faces
# (ambiguous faces always isolate the solid corners, so neighbouring cells
# agree on every shared face and the surface is watertight), then fan
# triangulating each closed loop.
#
# Corner index bits: bit0 = +y, bit1 = +z, bit2 = +x  (so the -x face is the
# low nibble and the +x face is the high nibble of the case index).

static func build(ys: int, zs: int, cdim: int) -> Dictionary:
	var cpos: Array[Vector3i] = []
	for c in 8:
		cpos.append(Vector3i((c >> 2) & 1, c & 1, (c >> 1) & 1))
	var axis_bit := [4, 1, 2]
	var e_c0 := PackedInt32Array()
	var e_c1 := PackedInt32Array()
	var e_ax := PackedInt32Array()
	var emap := {}
	for ax in 3:
		var bit: int = axis_bit[ax]
		for c in 8:
			if (c & bit) == 0:
				emap[c * 8 + (c | bit)] = e_c0.size()
				emap[(c | bit) * 8 + c] = e_c0.size()
				e_c0.append(c)
				e_c1.append(c | bit)
				e_ax.append(ax)
	var faces: Array = []
	for ax in 3:
		var bit: int = axis_bit[ax]
		var u: int = axis_bit[(ax + 1) % 3]
		var v: int = axis_bit[(ax + 2) % 3]
		for s in 2:
			var b: int = bit if s == 1 else 0
			faces.append([b, b | u, b | u | v, b | v])

	var tri_off := PackedInt32Array()
	var tri_n := PackedInt32Array()
	var tri_e := PackedInt32Array()
	tri_off.resize(256)
	tri_n.resize(256)
	var max_tris := 0
	for mask in 256:
		tri_off[mask] = tri_e.size()
		var nb := {}
		for f in faces:
			var cross: Array = []
			for k in 4:
				var a: int = f[k]
				var b2: int = f[(k + 1) % 4]
				if ((mask >> a) & 1) != ((mask >> b2) & 1):
					cross.append(k)
			if cross.size() == 2:
				var ea: int = emap[f[cross[0]] * 8 + f[(cross[0] + 1) % 4]]
				var eb: int = emap[f[cross[1]] * 8 + f[(cross[1] + 1) % 4]]
				_link(nb, ea, eb)
			elif cross.size() == 4:
				var e0: int = emap[f[0] * 8 + f[1]]
				var e1: int = emap[f[1] * 8 + f[2]]
				var e2: int = emap[f[2] * 8 + f[3]]
				var e3: int = emap[f[3] * 8 + f[0]]
				if ((mask >> f[1]) & 1) == 1:
					_link(nb, e0, e1)
					_link(nb, e2, e3)
				else:
					_link(nb, e1, e2)
					_link(nb, e3, e0)
		var seen := {}
		var count := 0
		for start in nb.keys():
			if seen.has(start):
				continue
			var loop: Array = []
			var prev := -1
			var cur: int = start
			while not seen.has(cur):
				seen[cur] = true
				loop.append(cur)
				var n2: Array = nb[cur]
				var nx: int = n2[0] if n2[0] != prev else n2[1]
				prev = cur
				cur = nx
			# orientation
			var nrm := Vector3.ZERO
			var ref := Vector3.ZERO
			for i in loop.size():
				var ea2: int = loop[i]
				var eb2: int = loop[(i + 1) % loop.size()]
				var pa := (Vector3(cpos[e_c0[ea2]]) + Vector3(cpos[e_c1[ea2]])) * 0.5
				var pb := (Vector3(cpos[e_c0[eb2]]) + Vector3(cpos[e_c1[eb2]])) * 0.5
				nrm += Vector3((pa.y - pb.y) * (pa.z + pb.z), (pa.z - pb.z) * (pa.x + pb.x), (pa.x - pb.x) * (pa.y + pb.y))
				var c0: int = e_c0[ea2]
				var c1: int = e_c1[ea2]
				if ((mask >> c0) & 1) == 1:
					ref += Vector3(cpos[c1] - cpos[c0])
				else:
					ref += Vector3(cpos[c0] - cpos[c1])
			if nrm.dot(ref) > 0.0:
				loop.reverse()
			for i in range(1, loop.size() - 1):
				tri_e.append(loop[0])
				tri_e.append(loop[i])
				tri_e.append(loop[i + 1])
				count += 3
		tri_n[mask] = count
		max_tris = maxi(max_tris, count / 3)

	var eoff := PackedInt32Array()
	var ev0 := PackedInt32Array()
	var estep := PackedInt32Array()
	var ecx := PackedInt32Array()
	var ecy := PackedInt32Array()
	var ecz := PackedInt32Array()
	var steps := [1, ys, zs]
	for e in 12:
		var cp: Vector3i = cpos[e_c0[e]]
		eoff.append(3 * (cp.x + cdim * cp.y + cdim * cdim * cp.z) + e_ax[e])
		ev0.append(cp.x + cp.y * ys + cp.z * zs)
		estep.append(steps[e_ax[e]])
		ecx.append(cp.x)
		ecy.append(cp.y)
		ecz.append(cp.z)
	return {
		"tri_off": tri_off, "tri_n": tri_n, "tri_e": tri_e, "eoff": eoff, "ev0": ev0,
		"estep": estep, "ecx": ecx, "ecy": ecy, "ecz": ecz, "eax": e_ax, "max_tris": max_tris,
	}


static func _link(nb: Dictionary, a: int, b: int) -> void:
	if not nb.has(a):
		nb[a] = []
	if not nb.has(b):
		nb[b] = []
	nb[a].append(b)
	nb[b].append(a)
