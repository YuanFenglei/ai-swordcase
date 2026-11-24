extends RefCounted

# Density-field world: GPU generation, threaded marching cubes, threaded edits,
# budgeted mesh + collision apply.
#
# _d / _m are single shared byte arrays. They are only ever touched through the
# member itself (never copied into a local or passed as an argument), so the
# reference count stays at 1 and worker threads read/write them in place.

const MCTables := preload("res://scripts/mc_tables.gd")

const SX := 512
const SY := 160
const SZ := 512
const CS := 16
const CX := 32
const CY := 10
const CZ := 32
const NCH := CX * CY * CZ
const YS := SX
const ZS := SX * SY
const NV := SX * SY * SZ
const CD := CS + 1
const WATER := 24.0

const OP_DIG := 0
const OP_FILL := 1
const OP_SMOOTH := 2
const OP_BLAST := 3

const F_QUEUED := 1
const F_BUSY := 2
const F_REDO := 4

var _d: PackedByteArray
var _m: PackedByteArray

var _tri_off: PackedInt32Array
var _tri_n: PackedInt32Array
var _tri_e: PackedInt32Array
var _eoff: PackedInt32Array
var _ev0: PackedInt32Array
var _estep: PackedInt32Array
var _ecx: PackedInt32Array
var _ecy: PackedInt32Array
var _ecz: PackedInt32Array
var _eax: PackedInt32Array
var _max_out := 0

var material: ShaderMaterial
var _scenario: RID
var _space: RID

var _flags := PackedByteArray()
var _inst: Array[RID] = []
var _mesh: Array = []
var _body: Array[RID] = []
var _shape: Array[RID] = []
var _task := PackedInt64Array()
var _tris := PackedInt32Array()

var _mutex := Mutex.new()
var _results: Array = []
var _scratch_mutex := Mutex.new()
var _scratch: Array = []

var _hot := PackedInt32Array()
var _cold := PackedInt32Array()
var _cold_pos := 0
var _inflight := 0
var max_jobs := 20

var _edit_queue: Array = []
var _edit_busy := false
var _edit_task := -1
var _edit_reap := -1
var _reap := PackedInt64Array()
var phys_usec := 0
var _edit_done: Array = []
var _edit_finished := false
var _bx0 := 0
var _bx1 := 0
var _by0 := 0
var _by1 := 0
var _bz0 := 0
var _bz1 := 0

var loaded := false
var load_total := 1
var load_done := 0

# stats
var stat_tris := 0
var stat_chunks := 0
var total_tris := 0
var active_chunks := 0
var mesh_usec := 0
var mesh_jobs := 0
var mesh_usec_max := 0
var apply_usec_frame := 0
var apply_usec_max := 0
var apply_usec_sum := 0
var apply_frames := 0
var edit_usec := 0
var edit_ops := 0
var gen_msec := 0
var load_mesh_ms := 0.0
var woke := false
var woke_aabb := AABB()


class Scratch:
	var cache := PackedInt32Array()
	var upos := PackedVector3Array()
	var unrm := PackedVector3Array()
	var um := PackedInt32Array()
	var ua := PackedInt32Array()
	var ov := PackedVector3Array()
	var on := PackedVector3Array()
	var oc := PackedByteArray()
	var oi := PackedInt32Array()
	var rf := PackedByteArray()


func setup(scenario: RID, space: RID, mat: ShaderMaterial) -> void:
	_scenario = scenario
	_space = space
	material = mat
	var t: Dictionary = MCTables.build(YS, ZS, CD)
	_tri_off = t.tri_off
	_tri_n = t.tri_n
	_tri_e = t.tri_e
	_eoff = t.eoff
	_ev0 = t.ev0
	_estep = t.estep
	_ecx = t.ecx
	_ecy = t.ecy
	_ecz = t.ecz
	_eax = t.eax
	_max_out = CS * CS * CS * int(t.max_tris) * 3
	_flags.resize(NCH)
	_inst.resize(NCH)
	_mesh.resize(NCH)
	_body.resize(NCH)
	_shape.resize(NCH)
	_task.resize(NCH)
	_tris.resize(NCH)
	max_jobs = clampi(OS.get_processor_count() - 6, 3, 24)


func generate() -> bool:
	var t0 := Time.get_ticks_msec()
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("no local rendering device")
		return false
	var text := FileAccess.get_file_as_string("res://shaders/worldgen.glsl")
	text = text.replace("#[compute]", "").replace("\r", "")
	var shaders: Array[RID] = []
	for defs in ["#version 450\n#define PASS_HEIGHT\n", "#version 450\n"]:
		var src := RDShaderSource.new()
		src.source_compute = text.replace("#version 450\n", defs)
		var spirv := rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error(spirv.compile_error_compute)
			return false
		shaders.append(rd.shader_create_from_spirv(spirv))
	var pcb := PackedByteArray()
	pcb.resize(16)

	# pass 1: 2D height field
	var hm := 560
	var hfmt := RDTextureFormat.new()
	hfmt.width = hm
	hfmt.height = hm
	hfmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	hfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var tex_h := rd.texture_create(hfmt, RDTextureView.new(), [])
	var uh := RDUniform.new()
	uh.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uh.binding = 0
	uh.add_id(tex_h)
	var hset := rd.uniform_set_create([uh], shaders[0], 0)
	var hpipe := rd.compute_pipeline_create(shaders[0])
	var hl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(hl, hpipe)
	rd.compute_list_bind_uniform_set(hl, hset, 0)
	rd.compute_list_set_push_constant(hl, pcb, 16)
	rd.compute_list_dispatch(hl, hm / 8, hm / 8, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# pass 2: density + material volume
	var fmt := RDTextureFormat.new()
	fmt.width = SX
	fmt.height = SY
	fmt.depth = SZ
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UINT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var tex_d := rd.texture_create(fmt, RDTextureView.new(), [])
	var tex_m := rd.texture_create(fmt, RDTextureView.new(), [])
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u0.binding = 0
	u0.add_id(tex_d)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(tex_m)
	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var samp := rd.sampler_create(ss)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u2.binding = 2
	u2.add_id(samp)
	u2.add_id(tex_h)
	var uset := rd.uniform_set_create([u0, u1, u2], shaders[1], 0)
	var pipe := rd.compute_pipeline_create(shaders[1])
	var slab := 32
	for z in range(0, SZ, slab):
		pcb.encode_s32(8, z)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		rd.compute_list_set_push_constant(cl, pcb, 16)
		rd.compute_list_dispatch(cl, SX / 8, SY / 8, slab / 8)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
	_d = rd.texture_get_data(tex_d, 0)
	_m = rd.texture_get_data(tex_m, 0)
	for r in [pipe, uset, hpipe, hset, samp, tex_d, tex_m, tex_h, shaders[0], shaders[1]]:
		rd.free_rid(r)
	rd.free()
	gen_msec = Time.get_ticks_msec() - t0
	if _d.size() != NV or _m.size() != NV:
		push_error("unexpected volume size %d" % _d.size())
		return false
	return true


func queue_all(focus: Vector3) -> void:
	var keys := PackedInt64Array()
	keys.resize(NCH)
	for ci in NCH:
		keys[ci] = (_chunk_dist(ci, focus) << 20) | ci
		_flags[ci] = F_QUEUED
	keys.sort()
	_cold.resize(NCH)
	for i in NCH:
		_cold[i] = keys[i] & 0xFFFFF
	_cold_pos = 0
	load_total = NCH
	load_done = 0


func _chunk_dist(ci: int, f: Vector3) -> int:
	var cx := ci % CX
	var cy := (ci / CX) % CY
	var cz := ci / (CX * CY)
	var dx := cx * CS + 8 - f.x
	var dy := cy * CS + 8 - f.y
	var dz := cz * CS + 8 - f.z
	return int(dx * dx + dy * dy + dz * dz)


# ---------------------------------------------------------------- queries

func solid(p: Vector3) -> bool:
	var x := int(p.x + 0.5)
	var y := int(p.y + 0.5)
	var z := int(p.z + 0.5)
	if x < 0 or y < 0 or z < 0 or x >= SX or y >= SY or z >= SZ:
		return false
	return _d[x + y * YS + z * ZS] >= 128


func density(p: Vector3) -> float:
	# trilinear, in voxels (positive = inside)
	var x := clampf(p.x, 0.0, SX - 1.001)
	var y := clampf(p.y, 0.0, SY - 1.001)
	var z := clampf(p.z, 0.0, SZ - 1.001)
	var ix := int(x)
	var iy := int(y)
	var iz := int(z)
	var fx := x - ix
	var fy := y - iy
	var fz := z - iz
	var i := ix + iy * YS + iz * ZS
	var a := lerpf(lerpf(_d[i], _d[i + 1], fx), lerpf(_d[i + YS], _d[i + YS + 1], fx), fy)
	var b := lerpf(lerpf(_d[i + ZS], _d[i + ZS + 1], fx), lerpf(_d[i + ZS + YS], _d[i + ZS + YS + 1], fx), fy)
	return (lerpf(a, b, fz) - 127.5) / 32.0


func material_at(p: Vector3) -> int:
	var x := clampi(int(p.x + 0.5), 0, SX - 1)
	var y := clampi(int(p.y + 0.5), 0, SY - 1)
	var z := clampi(int(p.z + 0.5), 0, SZ - 1)
	return _m[x + y * YS + z * ZS]


func gradient(p: Vector3) -> Vector3:
	var e := 1.0
	var g := Vector3(
		density(p - Vector3(e, 0, 0)) - density(p + Vector3(e, 0, 0)),
		density(p - Vector3(0, e, 0)) - density(p + Vector3(0, e, 0)),
		density(p - Vector3(0, 0, e)) - density(p + Vector3(0, 0, e)))
	if g.length_squared() < 0.0001:
		return Vector3.UP
	return g.normalized()


func surface_y(x: float, z: float, from_y: float = SY - 2.0) -> float:
	var ix := clampi(int(x + 0.5), 1, SX - 2)
	var iz := clampi(int(z + 0.5), 1, SZ - 2)
	var y := clampi(int(from_y), 1, SY - 2)
	var i := ix + y * YS + iz * ZS
	while y > 1 and _d[i] < 128:
		y -= 1
		i -= YS
	var d0: float = _d[i]
	var d1: float = _d[i + YS]
	if d0 == d1:
		return float(y)
	return y + clampf((127.5 - d0) / (d1 - d0), 0.0, 1.0)


func raycast(from: Vector3, dir: Vector3, max_dist: float) -> Variant:
	var t := 0.0
	var prev := 0.0
	var inside0 := density(from) > 0.0
	if inside0:
		return from
	while t < max_dist:
		var p := from + dir * t
		if p.y > SY + 40.0 and dir.y >= 0.0:
			return null
		var dd := density(p)
		if dd > 0.0:
			var a := prev
			var b := t
			for k in 6:
				var m := (a + b) * 0.5
				if density(from + dir * m) > 0.0:
					b = m
				else:
					a = m
			return from + dir * b
		prev = t
		t += clampf(-dd * 0.8, 0.4, 3.0)
	return null


# ---------------------------------------------------------------- edits

func edit(op: int, c: Vector3, r: float, arg: float = 0.0) -> void:
	_edit_queue.append([op, c, r, arg, Vector3i.ZERO, Vector3i.ZERO])


func busy() -> bool:
	return _edit_busy or _edit_reap >= 0 or not _edit_queue.is_empty() or _inflight > 0 or _hot.size() > 0 or _cold_pos < _cold.size() or not _results.is_empty()


func _edit_job(ops: Array) -> void:
	var t0 := Time.get_ticks_usec()
	for op in ops:
		var c: Vector3 = op[1]
		var r: float = op[2]
		var kind: int = op[0]
		var pad := r + 2.6
		if kind == OP_BLAST:
			pad = r * 1.22 + 2.6
		elif kind == OP_SMOOTH:
			pad = r + 0.5
		var x0 := clampi(int(floor(c.x - pad)), 1, SX - 2)
		var x1 := clampi(int(ceil(c.x + pad)), 1, SX - 2)
		var y0 := clampi(int(floor(c.y - pad)), 2, SY - 2)
		var y1 := clampi(int(ceil(c.y + pad)), 2, SY - 2)
		var z0 := clampi(int(floor(c.z - pad)), 1, SZ - 2)
		var z1 := clampi(int(ceil(c.z + pad)), 1, SZ - 2)
		_bx0 = 99999
		_bx1 = -1
		_by0 = 99999
		_by1 = -1
		_bz0 = 99999
		_bz1 = -1
		match kind:
			OP_DIG:
				_op_dig(c, r, pad, x0, x1, y0, y1, z0, z1)
			OP_BLAST:
				_op_blast(c, r, pad, x0, x1, y0, y1, z0, z1)
			OP_FILL:
				_op_fill(c, r, pad, int(op[3]), x0, x1, y0, y1, z0, z1)
			OP_SMOOTH:
				_op_smooth(c, r, x0, x1, y0, y1, z0, z1)
		op[4] = Vector3i(_bx0, _by0, _bz0)
		op[5] = Vector3i(_bx1, _by1, _bz1)
	var dt := Time.get_ticks_usec() - t0
	_mutex.lock()
	_edit_done = ops
	_edit_finished = true
	edit_usec += dt
	edit_ops += ops.size()
	_mutex.unlock()


func _op_dig(c: Vector3, r: float, pad: float, _x0: int, _x1: int, y0: int, y1: int, z0: int, z1: int) -> void:
	var cx := c.x
	var p2 := pad * pad
	for z in range(z0, z1 + 1):
		var dz := z - c.z
		for y in range(y0, y1 + 1):
			var dy := y - c.y
			var dyz := dz * dz + dy * dy
			var rem := p2 - dyz
			if rem <= 0.0:
				continue
			var hw := sqrt(rem)
			var xa := maxi(int(ceil(cx - hw)), 1)
			var xb := mini(int(floor(cx + hw)), SX - 2)
			var i := xa + y * YS + z * ZS
			var dx := xa - cx
			var wr := false
			for x in range(xa, xb + 1):
				var v := int(127.5 + (sqrt(dx * dx + dyz) - r) * 32.0)
				if v < _d[i]:
					_d[i] = v if v > 0 else 0
					wr = true
				i += 1
				dx += 1.0
			if wr:
				if xa < _bx0:
					_bx0 = xa
				if xb > _bx1:
					_bx1 = xb
				if y < _by0:
					_by0 = y
				if y > _by1:
					_by1 = y
				if z < _bz0:
					_bz0 = z
				if z > _bz1:
					_bz1 = z


func _op_blast(c: Vector3, r: float, pad: float, _x0: int, _x1: int, y0: int, y1: int, z0: int, z1: int) -> void:
	var cx := c.x
	var p2 := pad * pad
	var ph := c.x * 0.37 + c.z * 0.71
	for z in range(z0, z1 + 1):
		var dz := z - c.z
		var sz := sin(z * 0.83 + ph)
		for y in range(y0, y1 + 1):
			var dy := y - c.y
			var dyz := dz * dz + dy * dy
			var rem := p2 - dyz
			if rem <= 0.0:
				continue
			var hw := sqrt(rem)
			var xa := maxi(int(ceil(cx - hw)), 1)
			var xb := mini(int(floor(cx + hw)), SX - 2)
			var i := xa + y * YS + z * ZS
			var dx := xa - cx
			var wr := false
			var syz := sz * sin(y * 0.97 + ph * 1.7) * 0.2 * r
			for x in range(xa, xb + 1):
				var v := int(127.5 + (sqrt(dx * dx + dyz) - r - syz * sin(x * 0.89 + ph)) * 32.0)
				if v < _d[i]:
					_d[i] = v if v > 0 else 0
					wr = true
				i += 1
				dx += 1.0
			if wr:
				if xa < _bx0:
					_bx0 = xa
				if xb > _bx1:
					_bx1 = xb
				if y < _by0:
					_by0 = y
				if y > _by1:
					_by1 = y
				if z < _bz0:
					_bz0 = z
				if z > _bz1:
					_bz1 = z


func _op_fill(c: Vector3, r: float, pad: float, mat: int, _x0: int, _x1: int, y0: int, y1: int, z0: int, z1: int) -> void:
	var cx := c.x
	var p2 := pad * pad
	for z in range(z0, z1 + 1):
		var dz := z - c.z
		for y in range(y0, y1 + 1):
			var dy := y - c.y
			var dyz := dz * dz + dy * dy
			var rem := p2 - dyz
			if rem <= 0.0:
				continue
			var hw := sqrt(rem)
			var xa := maxi(int(ceil(cx - hw)), 1)
			var xb := mini(int(floor(cx + hw)), SX - 2)
			var i := xa + y * YS + z * ZS
			var dx := xa - cx
			var wr := false
			for x in range(xa, xb + 1):
				var v := int(127.5 + (r - sqrt(dx * dx + dyz)) * 32.0)
				var o := _d[i]
				if v > o:
					if o < 128:
						_m[i] = mat
					_d[i] = v if v < 255 else 255
					wr = true
				i += 1
				dx += 1.0
			if wr:
				if xa < _bx0:
					_bx0 = xa
				if xb > _bx1:
					_bx1 = xb
				if y < _by0:
					_by0 = y
				if y > _by1:
					_by1 = y
				if z < _bz0:
					_bz0 = z
				if z > _bz1:
					_bz1 = z


func _op_smooth(c: Vector3, r: float, _x0: int, _x1: int, y0: int, y1: int, z0: int, z1: int) -> void:
	var cx := c.x
	var r2 := r * r
	var inv := 1.0 / r
	for z in range(z0, z1 + 1):
		var dz := z - c.z
		for y in range(y0, y1 + 1):
			var dy := y - c.y
			var dyz := dz * dz + dy * dy
			var rem := r2 - dyz
			if rem <= 0.0:
				continue
			var hw := sqrt(rem)
			var xa := maxi(int(ceil(cx - hw)), 1)
			var xb := mini(int(floor(cx + hw)), SX - 2)
			var i := xa + y * YS + z * ZS
			var dx := xa - cx
			var wr := false
			for x in range(xa, xb + 1):
				var w := (1.0 - sqrt(dx * dx + dyz) * inv) * 0.85
				var o := _d[i]
				var avg := (_d[i - 1] + _d[i + 1] + _d[i - YS] + _d[i + YS] + _d[i - ZS] + _d[i + ZS]) / 6.0
				var nv := clampi(int(o + (avg - o) * w + 0.5), 0, 255)
				if nv != o:
					_d[i] = nv
					wr = true
				i += 1
				dx += 1.0
			if wr:
				if xa < _bx0:
					_bx0 = xa
				if xb > _bx1:
					_bx1 = xb
				if y < _by0:
					_by0 = y
				if y > _by1:
					_by1 = y
				if z < _bz0:
					_bz0 = z
				if z > _bz1:
					_bz1 = z


func _mark_region(a: Vector3i, b: Vector3i) -> void:
	if a.x > b.x:
		return
	var cx0 := maxi((a.x - 2) >> 4, 0)
	var cy0 := maxi((a.y - 2) >> 4, 0)
	var cz0 := maxi((a.z - 2) >> 4, 0)
	var cx1 := mini((b.x + 1) >> 4, CX - 1)
	var cy1 := mini((b.y + 1) >> 4, CY - 1)
	var cz1 := mini((b.z + 1) >> 4, CZ - 1)
	for cz in range(cz0, cz1 + 1):
		for cy in range(cy0, cy1 + 1):
			for cx in range(cx0, cx1 + 1):
				_mark_dirty(cx + cy * CX + cz * CX * CY)


func _mark_dirty(ci: int) -> void:
	var f := _flags[ci]
	if f & F_BUSY:
		_flags[ci] = f | F_REDO
	elif not (f & F_QUEUED):
		_flags[ci] = f | F_QUEUED
		_hot.append(ci)


# ---------------------------------------------------------------- frame update

func update(focus: Vector3, budget_usec: int) -> void:
	var t0 := Time.get_ticks_usec()
	# finished edits -> dirty chunks
	if _edit_busy:
		_mutex.lock()
		var fin := _edit_finished
		var done := _edit_done
		if fin:
			_edit_finished = false
			_edit_done = []
		_mutex.unlock()
		if fin:
			_edit_reap = _edit_task
			_edit_busy = false
			for op in done:
				_mark_region(op[4], op[5])
	if _edit_reap >= 0 and WorkerThreadPool.is_task_completed(_edit_reap):
		WorkerThreadPool.wait_for_task_completion(_edit_reap)
		_edit_reap = -1
	if not _edit_busy and _edit_reap < 0 and not _edit_queue.is_empty():
		var ops := _edit_queue
		_edit_queue = []
		_edit_busy = true
		_edit_task = WorkerThreadPool.add_task(_edit_job.bind(ops), true)

	# apply finished meshes
	_mutex.lock()
	var res := _results
	_results = []
	_mutex.unlock()
	var n := res.size()
	var k := 0
	while k < n:
		_apply(res[k])
		k += 1
		if Time.get_ticks_usec() - t0 > budget_usec:
			break
	if k < n:
		var rest := res.slice(k)
		_mutex.lock()
		rest.append_array(_results)
		_results = rest
		_mutex.unlock()

	if not _reap.is_empty():
		var keep := PackedInt64Array()
		for tid in _reap:
			if WorkerThreadPool.is_task_completed(tid):
				WorkerThreadPool.wait_for_task_completion(tid)
			else:
				keep.append(tid)
		_reap = keep

	# dispatch
	var cap := max_jobs if loaded else 160
	var slots := cap - _inflight
	if slots > 0 and _hot.size() > 0:
		if _hot.size() <= slots:
			for ci in _hot:
				_dispatch(ci)
			_hot = PackedInt32Array()
		else:
			var keys := PackedInt64Array()
			keys.resize(_hot.size())
			for i in _hot.size():
				keys[i] = (_chunk_dist(_hot[i], focus) << 20) | _hot[i]
			keys.sort()
			var nh := PackedInt32Array()
			for i in keys.size():
				var ci := keys[i] & 0xFFFFF
				if i < slots:
					_dispatch(ci)
				else:
					nh.append(ci)
			_hot = nh
	slots = cap - _inflight
	while slots > 0 and _cold_pos < _cold.size():
		var ci := _cold[_cold_pos]
		_cold_pos += 1
		if _flags[ci] & F_QUEUED:
			_dispatch(ci)
			slots -= 1
	if not loaded and _cold_pos >= _cold.size() and _inflight == 0 and _results.is_empty():
		loaded = true
		load_mesh_ms = mesh_usec / 1000.0 / maxi(mesh_jobs, 1)
		stat_tris = 0
		stat_chunks = 0
		mesh_usec = 0
		mesh_jobs = 0
		mesh_usec_max = 0
		apply_usec_max = 0
		apply_usec_sum = 0
		apply_frames = 0
	apply_usec_frame = Time.get_ticks_usec() - t0
	if loaded:
		apply_usec_max = maxi(apply_usec_max, apply_usec_frame)
		apply_usec_sum += apply_usec_frame
		apply_frames += 1


func reset_perf() -> void:
	mesh_usec = 0
	mesh_jobs = 0
	mesh_usec_max = 0
	apply_usec_max = 0
	apply_usec_sum = 0
	apply_frames = 0
	edit_usec = 0
	edit_ops = 0
	phys_usec = 0


func _dispatch(ci: int) -> void:
	_flags[ci] = (_flags[ci] & ~F_QUEUED) | F_BUSY
	_inflight += 1
	_task[ci] = WorkerThreadPool.add_task(_mesh_job.bind(ci))


func _apply(r: Array) -> void:
	var ci: int = r[0]
	_reap.append(_task[ci])
	_inflight -= 1
	if not loaded:
		load_done += 1
	var mesh: ArrayMesh = r[1]
	var faces: PackedVector3Array = r[2]
	var nt: int = faces.size() / 3
	total_tris += nt - _tris[ci]
	_tris[ci] = nt
	stat_tris += nt
	stat_chunks += 1
	mesh_usec += r[3]
	mesh_jobs += 1
	mesh_usec_max = maxi(mesh_usec_max, r[3])
	if mesh != null:
		if not _inst[ci].is_valid():
			_inst[ci] = RenderingServer.instance_create2(mesh.get_rid(), _scenario)
			active_chunks += 1
		else:
			RenderingServer.instance_set_base(_inst[ci], mesh.get_rid())
		_mesh[ci] = mesh
		var tp := Time.get_ticks_usec()
		var data := {"faces": faces, "backface_collision": false}
		if not _shape[ci].is_valid():
			var sh := PhysicsServer3D.concave_polygon_shape_create()
			PhysicsServer3D.shape_set_data(sh, data)
			var b := PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_mode(b, PhysicsServer3D.BODY_MODE_STATIC)
			PhysicsServer3D.body_set_collision_layer(b, 1)
			PhysicsServer3D.body_set_collision_mask(b, 0)
			PhysicsServer3D.body_add_shape(b, sh)
			PhysicsServer3D.body_set_space(b, _space)
			_shape[ci] = sh
			_body[ci] = b
		else:
			PhysicsServer3D.shape_set_data(_shape[ci], data)
			PhysicsServer3D.body_set_space(_body[ci], _space)
		phys_usec += Time.get_ticks_usec() - tp
	else:
		if _inst[ci].is_valid():
			RenderingServer.free_rid(_inst[ci])
			_inst[ci] = RID()
			_mesh[ci] = null
			active_chunks -= 1
		if _body[ci].is_valid():
			PhysicsServer3D.body_set_space(_body[ci], RID())
	if loaded:
		var cx := ci % CX
		var cy := (ci / CX) % CY
		var cz := ci / (CX * CY)
		var box := AABB(Vector3(cx * CS - 3, cy * CS - 3, cz * CS - 3), Vector3(CS + 6, CS + 6, CS + 6))
		woke_aabb = box if not woke else woke_aabb.merge(box)
		woke = true
	var f := _flags[ci] & ~F_BUSY
	if f & F_REDO:
		f = (f & ~F_REDO) | F_QUEUED
		_hot.append(ci)
	_flags[ci] = f


func free_all() -> void:
	# wait for workers before the arrays go away
	while _inflight > 0 or _edit_busy:
		OS.delay_msec(2)
		_mutex.lock()
		var res := _results
		_results = []
		var fin := _edit_finished
		_edit_finished = false
		_mutex.unlock()
		for r in res:
			_reap.append(_task[r[0]])
			_inflight -= 1
		if fin:
			_edit_reap = _edit_task
			_edit_busy = false
	for tid in _reap:
		WorkerThreadPool.wait_for_task_completion(tid)
	_reap = PackedInt64Array()
	if _edit_reap >= 0:
		WorkerThreadPool.wait_for_task_completion(_edit_reap)
		_edit_reap = -1
	for ci in NCH:
		if _inst[ci].is_valid():
			RenderingServer.free_rid(_inst[ci])
		if _body[ci].is_valid():
			PhysicsServer3D.free_rid(_body[ci])
		if _shape[ci].is_valid():
			PhysicsServer3D.free_rid(_shape[ci])
	_mesh.clear()


# ---------------------------------------------------------------- meshing (worker threads)

func _take_scratch() -> Scratch:
	var s: Scratch = null
	_scratch_mutex.lock()
	if not _scratch.is_empty():
		s = _scratch.pop_back()
	_scratch_mutex.unlock()
	if s == null:
		s = Scratch.new()
		s.cache.resize(CD * CD * CD * 3)
		s.upos.resize(CD * CD * CD * 3)
		s.unrm.resize(CD * CD * CD * 3)
		s.um.resize(CD * CD * CD * 3)
		s.ua.resize(CD * CD * CD * 3)
		s.ov.resize(_max_out)
		s.on.resize(_max_out)
		s.oc.resize(_max_out * 4)
		s.oi.resize(_max_out)
		s.rf.resize(CD * CD)
	return s


func _mesh_job(ci: int) -> void:
	var t0 := Time.get_ticks_usec()
	var ccx := ci % CX
	var ccy := (ci / CX) % CY
	var ccz := ci / (CX * CY)
	var x0 := maxi(ccx * CS, 1)
	var x1 := mini(ccx * CS + CS, SX - 2)
	var y0 := maxi(ccy * CS, 1)
	var y1 := mini(ccy * CS + CS, SY - 2)
	var z0 := maxi(ccz * CS, 1)
	var z1 := mini(ccz * CS + CS, SZ - 2)
	var nx := x1 - x0
	var ny := y1 - y0
	var nz := z1 - z0

	var s := _take_scratch()
	# move the arrays out of the pool object so writes stay in place
	var rf := s.rf
	s.rf = PackedByteArray()

	# classify corner rows: 0 = all air, 1 = all solid, 2 = mixed
	var any0 := false
	var any1 := false
	var any2 := false
	var seg_n := nx + 1
	for lz in range(nz + 1):
		for ly in range(ny + 1):
			var a := x0 + (y0 + ly) * YS + (z0 + lz) * ZS
			var b0 := _d[a]
			var f := 2
			if b0 == 0:
				if _d.slice(a, a + seg_n).count(0) == seg_n:
					f = 0
			elif b0 == 255:
				if _d.slice(a, a + seg_n).count(255) == seg_n:
					f = 1
			rf[ly + lz * CD] = f
			if f == 0:
				any0 = true
			elif f == 1:
				any1 = true
			else:
				any2 = true
	if not any2 and not (any0 and any1):
		s.rf = rf
		_scratch_mutex.lock()
		_scratch.append(s)
		_scratch_mutex.unlock()
		var e := [ci, null, PackedVector3Array(), Time.get_ticks_usec() - t0]
		_mutex.lock()
		_results.append(e)
		_mutex.unlock()
		return

	var cache := s.cache
	s.cache = PackedInt32Array()
	var upos := s.upos
	s.upos = PackedVector3Array()
	var unrm := s.unrm
	s.unrm = PackedVector3Array()
	var um := s.um
	s.um = PackedInt32Array()
	var ua := s.ua
	s.ua = PackedInt32Array()
	var ov := s.ov
	s.ov = PackedVector3Array()
	var on := s.on
	s.on = PackedVector3Array()
	var oc := s.oc
	s.oc = PackedByteArray()
	var oi := s.oi
	s.oi = PackedInt32Array()
	cache.fill(-1)

	var nu := 0
	var n := 0
	var n4 := 0
	var last := NV - 1
	var a0 := 0
	var a1 := 0
	var a2 := 0
	for lz in range(nz):
		var z := z0 + lz
		for ly in range(ny):
			var r := ly + lz * CD
			var f0 := rf[r]
			if f0 != 2 and f0 == rf[r + 1] and f0 == rf[r + CD] and f0 == rf[r + CD + 1]:
				continue
			var y := y0 + ly
			var i := x0 + y * YS + z * ZS
			var a := (_d[i] >> 7) | ((_d[i + YS] >> 7) << 1) | ((_d[i + ZS] >> 7) << 2) | ((_d[i + YS + ZS] >> 7) << 3)
			var cb := 3 * (CD * ly + CD * CD * lz) - 3
			for lx in range(nx):
				i += 1
				cb += 3
				var b := (_d[i] >> 7) | ((_d[i + YS] >> 7) << 1) | ((_d[i + ZS] >> 7) << 2) | ((_d[i + YS + ZS] >> 7) << 3)
				var cs := a | (b << 4)
				a = b
				if cs == 0 or cs == 255:
					continue
				var ti := _tri_off[cs]
				var te := ti + _tri_n[cs]
				var vi := i - 1
				var x := x0 + lx
				var k := 0
				while ti < te:
					var e := _tri_e[ti]
					ti += 1
					var ck := cb + _eoff[e]
					var u := cache[ck]
					if u < 0:
						var j0 := vi + _ev0[e]
						var st := _estep[e]
						var j1 := j0 + st
						var d0 := _d[j0]
						var d1 := _d[j1]
						var t := (127.5 - d0) / (d1 - d0)
						var px := float(x + _ecx[e])
						var py := float(y + _ecy[e])
						var pz := float(z + _ecz[e])
						if st == 1:
							px += t
						elif st == YS:
							py += t
						else:
							pz += t
						var gx: float = _d[j0 - 1] - _d[j0 + 1]
						var gy: float = _d[j0 - YS] - _d[j0 + YS]
						var gz: float = _d[j0 - ZS] - _d[j0 + ZS]
						gx += (_d[j1 - 1] - _d[j1 + 1] - gx) * t
						gy += (_d[j1 - YS] - _d[j1 + YS] - gy) * t
						gz += (_d[j1 - ZS] - _d[j1 + ZS] - gz) * t
						var inv := 1.0 / sqrt(gx * gx + gy * gy + gz * gz + 0.0001)
						gx *= inv
						gy *= inv
						gz *= inv
						u = nu
						nu += 1
						cache[ck] = u
						upos[u] = Vector3(px, py, pz)
						unrm[u] = Vector3(gx, gy, gz)
						um[u] = _m[j0] if d0 >= 128 else _m[j1]
						# large-scale occlusion from the density field along the normal
						var q1 := clampi(int(px + gx * 3.0 + 0.5) + int(py + gy * 3.0 + 0.5) * YS + int(pz + gz * 3.0 + 0.5) * ZS, 0, last)
						var q2 := clampi(int(px + gx * 6.5 + 0.5) + int(py + gy * 6.5 + 0.5) * YS + int(pz + gz * 6.5 + 0.5) * ZS, 0, last)
						var q3 := clampi(int(px + gx * 12.0 + 0.5) + int(py + gy * 12.0 + 0.5) * YS + int(pz + gz * 12.0 + 0.5) * ZS, 0, last)
						var occ := _d[q1] * 0.4 + _d[q2] * 0.33 + _d[q3] * 0.27
						# anything overhead counts as a roof: caves and tunnels lose the sky
						var qb := int(px + 0.5) + int(pz + 0.5) * ZS
						var roof := (_d[clampi(qb + int(py + 7.5) * YS, 0, last)] >> 7) + (_d[clampi(qb + int(py + 18.5) * YS, 0, last)] >> 7) + (_d[clampi(qb + int(py + 40.5) * YS, 0, last)] >> 7)
						if roof > 0:
							occ = minf(occ + 70.0 + roof * 50.0, 255.0)
						ua[u] = (63 - int(occ * 0.24705)) << 26
					if k == 0:
						a0 = u
						k = 1
					elif k == 1:
						a1 = u
						k = 2
					else:
						a2 = u
						k = 0
						var base := um[a0] | (um[a1] << 8) | (um[a2] << 16)
						ov[n] = upos[a0]
						on[n] = unrm[a0]
						oc.encode_u32(n4, base | ua[a0])
						ov[n + 1] = upos[a1]
						on[n + 1] = unrm[a1]
						oc.encode_u32(n4 + 4, base | ua[a1] | 0x1000000)
						ov[n + 2] = upos[a2]
						on[n + 2] = unrm[a2]
						oc.encode_u32(n4 + 8, base | ua[a2] | 0x2000000)
						oi[n] = a0
						oi[n + 1] = a1
						oi[n + 2] = a2
						n += 3
						n4 += 12

	var mesh: ArrayMesh = null
	var faces := PackedVector3Array()
	if n > 0:
		faces = ov.slice(0, n)
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = faces
		arr[Mesh.ARRAY_NORMAL] = on.slice(0, n)
		arr[Mesh.ARRAY_CUSTOM0] = oc.slice(0, n4)
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		mesh.surface_set_material(0, material)
		# welded, position-only copy for the shadow and depth passes (6x fewer vertices)
		var sarr := []
		sarr.resize(Mesh.ARRAY_MAX)
		sarr[Mesh.ARRAY_VERTEX] = upos.slice(0, nu)
		sarr[Mesh.ARRAY_INDEX] = oi.slice(0, n)
		var sm := ArrayMesh.new()
		sm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarr)
		mesh.shadow_mesh = sm

	s.rf = rf
	s.cache = cache
	s.upos = upos
	s.unrm = unrm
	s.um = um
	s.ua = ua
	s.ov = ov
	s.on = on
	s.oc = oc
	s.oi = oi
	_scratch_mutex.lock()
	_scratch.append(s)
	_scratch_mutex.unlock()
	var res := [ci, mesh, faces, Time.get_ticks_usec() - t0]
	_mutex.lock()
	_results.append(res)
	_mutex.unlock()
