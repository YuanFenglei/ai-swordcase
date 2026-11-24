extends RefCounted
# Surface detail maps generated at startup: seamless height in A, tangent-space slope in RG.
# Sampled with mipmaps and anisotropic filtering, so detail stays crisp close up and stable far away.

const SIZE := 512

enum { ROCK, GRASS, SOIL }


static func build_all() -> Array:
	var out: Array = [null, null, null]
	var imgs: Array = [null, null, null]
	var tasks: Array = []
	for k in 3:
		tasks.append(WorkerThreadPool.add_task(_build.bind(k, imgs)))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	for k in 3:
		out[k] = ImageTexture.create_from_image(imgs[k])
	return out


static func _noise(type: int, freq: float, octaves: int, fractal: int, gain: float, seed_v: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.seed = seed_v
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.fractal_gain = gain
	n.fractal_lacunarity = 2.1
	return n


static func _layer(n: FastNoiseLite) -> PackedByteArray:
	return n.get_seamless_image(SIZE, SIZE, false, false, 0.25, true).get_data()


static func _build(kind: int, imgs: Array) -> void:
	var a: PackedByteArray
	var b: PackedByteArray
	var c: PackedByteArray
	var wa := 0.0
	var wb := 0.0
	var wc := 0.0
	var bump := 1.0
	if kind == ROCK:
		# weathered stone: ridged creases, broad pitting, fine grit
		a = _layer(_noise(FastNoiseLite.TYPE_SIMPLEX, 0.011, 6, FastNoiseLite.FRACTAL_RIDGED, 0.55, 3))
		var cell := _noise(FastNoiseLite.TYPE_CELLULAR, 0.024, 3, FastNoiseLite.FRACTAL_FBM, 0.5, 9)
		cell.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		b = _layer(cell)
		c = _layer(_noise(FastNoiseLite.TYPE_SIMPLEX, 0.09, 4, FastNoiseLite.FRACTAL_FBM, 0.6, 21))
		wa = 0.50
		wb = 0.30
		wc = 0.20
		bump = 7.0
	elif kind == GRASS:
		# turf: soft clumps broken into tufts and blade-scale grain
		a = _layer(_noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.018, 4, FastNoiseLite.FRACTAL_FBM, 0.55, 5))
		var cell := _noise(FastNoiseLite.TYPE_CELLULAR, 0.07, 2, FastNoiseLite.FRACTAL_FBM, 0.5, 13)
		cell.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		cell.cellular_jitter = 1.0
		b = _layer(cell)
		c = _layer(_noise(FastNoiseLite.TYPE_SIMPLEX, 0.16, 3, FastNoiseLite.FRACTAL_FBM, 0.65, 31))
		wa = 0.30
		wb = -0.40
		wc = 0.30
		bump = 9.0
	else:
		# packed earth: pebbles pressed into fine dirt, with shrinkage cracks
		var cell := _noise(FastNoiseLite.TYPE_CELLULAR, 0.045, 2, FastNoiseLite.FRACTAL_FBM, 0.45, 17)
		cell.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		cell.cellular_jitter = 0.9
		a = _layer(cell)
		var crack := _noise(FastNoiseLite.TYPE_CELLULAR, 0.016, 1, FastNoiseLite.FRACTAL_NONE, 0.5, 23)
		crack.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		b = _layer(crack)
		c = _layer(_noise(FastNoiseLite.TYPE_SIMPLEX, 0.12, 4, FastNoiseLite.FRACTAL_FBM, 0.6, 41))
		wa = -0.45
		wb = 0.25
		wc = 0.30
		bump = 8.0

	var n := SIZE * SIZE
	var h := PackedFloat32Array()
	h.resize(n)
	var lo := 1e9
	var hi := -1e9
	for i in n:
		var v := (a[i] * wa + b[i] * wb + c[i] * wc) / 255.0
		h[i] = v
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var inv := 1.0 / maxf(hi - lo, 1e-5)
	for i in n:
		h[i] = (h[i] - lo) * inv

	var data := PackedByteArray()
	data.resize(n * 4)
	var m := SIZE - 1
	for y in SIZE:
		var row := y * SIZE
		var up := ((y - 1) & m) * SIZE
		var dn := ((y + 1) & m) * SIZE
		for x in SIZE:
			var xl := (x - 1) & m
			var xr := (x + 1) & m
			var dx := (h[row + xr] - h[row + xl]) * bump
			var dy := (h[dn + x] - h[up + x]) * bump
			var il := 1.0 / sqrt(dx * dx + dy * dy + 1.0)
			var o := (row + x) * 4
			data[o] = int(clampf((-dx * il * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			data[o + 1] = int(clampf((-dy * il * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			data[o + 2] = int(il * 255.0)
			data[o + 3] = int(h[row + x] * 255.0)
	var img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	imgs[kind] = img
