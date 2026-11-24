
extends RefCounted
## MLS-MPM fluid on the main RenderingDevice. Every method marked [RT] must run on the render thread.

const MAX_COL := 16
const MAX_PROBES := 256
const PARTICLE_BYTES := 80
const SIM_RATE := 24.0          # sim time units per second
const DT := 0.2
const REST := 4.0
const SPACING := 0.63           # lattice spacing (cells) that gives rest density

var rd: RenderingDevice
var grid := Vector3i(120, 48, 48)
var capacity := 0
var count := 0                  # active particles (main thread bookkeeping)
var dx := 1.0 / 6.0
var origin := Vector3.ZERO
var generation := 0
var ok := false

var dt := 0.2
var gravity := Vector3(0, -0.1, 0)
var stiffness := 6.0
var viscosity := 0.08
var damping := 1.0
var use_dye := false
var profile := false
var foam_speed := 0.75
var foam_gain := 0.3
var foam_decay := 0.02
var mouse_origin := Vector3.ZERO
var mouse_dir := Vector3.FORWARD
var mouse_force := Vector3.ZERO
var mouse_radius := 5.0
var mouse_active := false
var colliders: Array = []       # {xf: Transform3D, half: Vector3, type: int, lin: Vector3, ang: Vector3}
var probes := PackedVector3Array()
var probe_results := PackedFloat32Array()
var probe_count_sent := 0
var time := 0.0
var frame := 0

var _shaders := {}
var _pipes := {}
var _sets := {}
var buf_particles: RID
var buf_grid: RID
var buf_dye: RID
var buf_ubo: RID
var buf_probe_in: RID
var buf_probe_out: RID
var tex_density: RID
var tex_column: RID
var column_tex := Texture2DRD.new()
var _pending_spawns: Array = []


static func load_source(name: String) -> String:
	var src := FileAccess.get_file_as_string("res://shaders/" + name)
	for inc in ["common.inc", "env.inc"]:
		var tag := "#include \"%s\"" % inc
		if src.contains(tag):
			src = src.replace(tag, FileAccess.get_file_as_string("res://shaders/" + inc))
	return src


static func compile_compute(p_rd: RenderingDevice, name: String) -> RID:
	var s := RDShaderSource.new()
	s.source_compute = load_source(name)
	var spirv := p_rd.shader_compile_spirv_from_source(s)
	if spirv.compile_error_compute != "":
		push_error("shader %s: %s" % [name, spirv.compile_error_compute])
		print("SHADER ERROR ", name, ": ", spirv.compile_error_compute)
		return RID()
	return p_rd.shader_create_from_spirv(spirv, name)


func init_rt() -> void:  # [RT]
	rd = RenderingServer.get_rendering_device()
	for n in ["spawn", "p2g1", "grid", "g2p", "probes", "column"]:
		var sh := compile_compute(rd, n + ".glsl")
		if not sh.is_valid():
			return
		_shaders[n] = sh
		_pipes[n] = rd.compute_pipeline_create(sh)
	var ubo_size := 16 * 8 + 128 * MAX_COL
	var z := PackedByteArray()
	z.resize(ubo_size)
	buf_ubo = rd.uniform_buffer_create(ubo_size, z)
	z.resize(MAX_PROBES * 16)
	buf_probe_in = rd.storage_buffer_create(z.size(), z)
	buf_probe_out = rd.storage_buffer_create(z.size(), z)
	ok = true


func _free_sized() -> void:
	column_tex.texture_rd_rid = RID()
	for r in [buf_particles, buf_grid, buf_dye, tex_density, tex_column]:
		if r.is_valid():
			rd.free_rid(r)
	_sets.clear()


func resize_rt(p_grid: Vector3i, p_capacity: int) -> void:  # [RT]
	if not ok:
		return
	_free_sized()
	grid = p_grid
	capacity = p_capacity
	var cells := grid.x * grid.y * grid.z
	buf_particles = rd.storage_buffer_create(capacity * PARTICLE_BYTES)
	buf_grid = rd.storage_buffer_create(cells * 16)
	buf_dye = rd.storage_buffer_create(cells * 4)
	rd.buffer_clear(buf_particles, 0, capacity * PARTICLE_BYTES)
	rd.buffer_clear(buf_grid, 0, cells * 16)
	rd.buffer_clear(buf_dye, 0, cells * 4)
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.width = grid.x
	tf.height = grid.y
	tf.depth = grid.z
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	tex_density = rd.texture_create(tf, RDTextureView.new())
	rd.texture_clear(tex_density, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var t2 := RDTextureFormat.new()
	t2.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	t2.width = grid.x
	t2.height = grid.z
	t2.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	tex_column = rd.texture_create(t2, RDTextureView.new())
	rd.texture_clear(tex_column, Color(0, 0, 0, 0), 0, 1, 0, 1)
	column_tex.texture_rd_rid = tex_column
	_sets["spawn"] = _make_set("spawn", [[1, buf_particles]])
	_sets["p2g1"] = _make_set("p2g1", [[0, buf_ubo], [1, buf_particles], [2, buf_grid], [3, buf_dye]])
	_sets["grid"] = _make_set("grid", [[0, buf_ubo], [2, buf_grid], [3, buf_dye], [4, tex_density]])
	_sets["g2p"] = _make_set("g2p", [[0, buf_ubo], [1, buf_particles], [2, buf_grid]])
	_sets["probes"] = _make_set("probes", [[0, buf_ubo], [2, buf_grid], [5, buf_probe_in], [6, buf_probe_out]])
	_sets["column"] = _make_set("column", [[0, buf_ubo], [2, buf_grid], [7, tex_column]])
	generation += 1


func _make_set(shader: String, items: Array) -> RID:
	var arr: Array[RDUniform] = []
	for it in items:
		var u := RDUniform.new()
		u.binding = it[0]
		if it[0] == 0:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		elif it[0] == 4 or it[0] == 7:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id(it[1])
		arr.append(u)
	return rd.uniform_set_create(arr, _shaders[shader], 0)


# ---------------------------------------------------------------- main-thread API

func world_to_grid(p: Vector3) -> Vector3:
	return (p - origin) / dx


func clear_particles() -> void:
	count = 0
	_pending_spawns.clear()


## Fill a world-space box with a jittered lattice. Returns particles added.
func fill_box(wmin: Vector3, wmax: Vector3, dye := 0.0, vel := Vector3.ZERO, limit := -1) -> int:
	var lo := world_to_grid(wmin).max(Vector3(2.2, 2.2, 2.2))
	var hi := world_to_grid(wmax).min(Vector3(grid) - Vector3(2.2, 2.2, 2.2))
	var n := Vector3i(((hi - lo) / SPACING).floor())
	if n.x <= 0 or n.y <= 0 or n.z <= 0:
		return 0
	var total := n.x * n.y * n.z
	if limit >= 0:
		total = mini(total, limit)
	total = mini(total, capacity - count)
	if total <= 0:
		return 0
	var pc := StreamPeerBuffer.new()
	_put4(pc, lo.x, lo.y, lo.z, SPACING)
	_put4(pc, vel.x, vel.y, vel.z, dye)
	_put4(pc, 0, 0, 0, 0.7)
	_puti4(pc, count, total, n.x, n.y)
	_puti4(pc, 0, randi() % 100000, 0, 0)
	_put4(pc, 2.05, 2.05, 2.05, 0)
	_put4(pc, grid.x - 2.05, grid.y - 2.05, grid.z - 2.05, 0)
	_pending_spawns.append([pc.data_array, total])
	count += total
	return total


## Emit a slab of particles from a disc (grid-space units for radius/speed handled here from world values).
func emit_disc(wcenter: Vector3, dir: Vector3, wradius: float, speed_ws: float, dye: float, sim_time: float, dense := 1.05, foam := 0.0) -> int:
	if sim_time <= 0.0:
		return 0
	var c := world_to_grid(wcenter)
	var r := wradius / dx
	var sp := speed_ws / dx / SIM_RATE
	var thick := sp * sim_time
	var n := int(PI * r * r * thick * REST * dense)
	n = mini(n, capacity - count)
	if n <= 0:
		return 0
	var v := dir.normalized() * sp
	var pc := StreamPeerBuffer.new()
	_put4(pc, c.x, c.y, c.z, r)
	_put4(pc, v.x, v.y, v.z, dye)
	_put4(pc, dir.x, dir.y, dir.z, thick)
	_puti4(pc, count, n, 1, 1)
	_puti4(pc, 1, randi() % 100000, int(clampf(foam, 0.0, 0.99) * 1000.0), 0)
	_put4(pc, 2.05, 2.05, 2.05, 0)
	_put4(pc, grid.x - 2.05, grid.y - 2.05, grid.z - 2.05, 0)
	_pending_spawns.append([pc.data_array, n])
	count += n
	return n


func _put4(b: StreamPeerBuffer, x: float, y: float, z: float, w: float) -> void:
	b.put_float(x); b.put_float(y); b.put_float(z); b.put_float(w)


func _puti4(b: StreamPeerBuffer, x: int, y: int, z: int, w: int) -> void:
	b.put_32(x); b.put_32(y); b.put_32(z); b.put_32(w)


func _build_ubo() -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	_puti4(b, grid.x, grid.y, grid.z, count)
	_put4(b, gravity.x, gravity.y, gravity.z, dt)
	_put4(b, stiffness, REST, viscosity, time)
	var mo := world_to_grid(mouse_origin)
	_put4(b, mo.x, mo.y, mo.z, mouse_radius)
	_put4(b, mouse_dir.x, mouse_dir.y, mouse_dir.z, 1.0 if mouse_active else 0.0)
	_put4(b, mouse_force.x, mouse_force.y, mouse_force.z, 0)
	var nc := mini(colliders.size(), MAX_COL)
	var np := mini(probes.size(), MAX_PROBES)
	_puti4(b, nc, np, frame, 1 if use_dye else 0)
	_put4(b, foam_speed, foam_gain, foam_decay, damping)
	for i in MAX_COL:
		if i < nc:
			var c: Dictionary = colliders[i]
			var xf: Transform3D = c.xf
			var g := Transform3D(xf.basis.orthonormalized(), world_to_grid(xf.origin))
			var inv := g.affine_inverse()
			_put4(b, inv.basis.x.x, inv.basis.x.y, inv.basis.x.z, 0)
			_put4(b, inv.basis.y.x, inv.basis.y.y, inv.basis.y.z, 0)
			_put4(b, inv.basis.z.x, inv.basis.z.y, inv.basis.z.z, 0)
			_put4(b, inv.origin.x, inv.origin.y, inv.origin.z, 1)
			var h: Vector3 = c.half / dx
			_put4(b, h.x, h.y, h.z, float(c.type))
			var lv: Vector3 = c.get("lin", Vector3.ZERO) / dx / SIM_RATE
			var av: Vector3 = c.get("ang", Vector3.ZERO) / SIM_RATE
			_put4(b, lv.x, lv.y, lv.z, 0)
			_put4(b, av.x, av.y, av.z, 0)
			_put4(b, g.origin.x, g.origin.y, g.origin.z, 0)
		else:
			for k in 8:
				_put4(b, 0, 0, 0, 0)
	return b.data_array


## Main-thread entry: snapshot state and queue a GPU step.
func step(substeps: int) -> void:
	if not ok:
		return
	frame += 1
	time += substeps * dt
	var ubo := _build_ubo()
	var pb := PackedByteArray()
	var np := mini(probes.size(), MAX_PROBES)
	if np > 0:
		var fa := PackedFloat32Array()
		fa.resize(np * 4)
		for i in np:
			var g := world_to_grid(probes[i])
			fa[i * 4] = g.x; fa[i * 4 + 1] = g.y; fa[i * 4 + 2] = g.z
		pb = fa.to_byte_array()
	var spawns := _pending_spawns
	_pending_spawns = []
	RenderingServer.call_on_render_thread(_step_rt.bind(ubo, pb, np, spawns, substeps, count))


func _step_rt(ubo: PackedByteArray, pb: PackedByteArray, np: int, spawns: Array, substeps: int, n: int) -> void:  # [RT]
	if not buf_particles.is_valid():
		return
	rd.capture_timestamp("fluid_sim_begin")
	rd.buffer_update(buf_ubo, 0, ubo.size(), ubo)
	for s in spawns:
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipes["spawn"])
		rd.compute_list_bind_uniform_set(cl, _sets["spawn"], 0)
		rd.compute_list_set_push_constant(cl, s[0], s[0].size())
		rd.compute_list_dispatch(cl, int(ceil(s[1] / 256.0)), 1, 1)
		rd.compute_list_end()
	var cells := grid.x * grid.y * grid.z
	var pg := int(ceil(n / 256.0))
	if n > 0:
		for i in substeps:
			rd.buffer_clear(buf_grid, 0, cells * 16)
			rd.buffer_clear(buf_dye, 0, cells * 4)
			if profile and i == 0: rd.capture_timestamp("p_clear")
			_dispatch("p2g1", pg, 1, 1)
			if profile and i == 0: rd.capture_timestamp("p_p2g")
			_dispatch("grid", int(ceil(grid.x / 4.0)), int(ceil(grid.y / 4.0)), int(ceil(grid.z / 4.0)))
			if profile and i == 0: rd.capture_timestamp("p_grid")
			_dispatch("g2p", pg, 1, 1)
			if profile and i == 0: rd.capture_timestamp("p_g2p")
	elif substeps > 0:
		rd.buffer_clear(buf_grid, 0, cells * 16)
		rd.texture_clear(tex_density, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if substeps > 0:
		_dispatch("column", int(ceil(grid.x / 8.0)), int(ceil(grid.z / 8.0)), 1)
	if np > 0:
		rd.buffer_update(buf_probe_in, 0, pb.size(), pb)
		_dispatch("probes", int(ceil(np / 64.0)), 1, 1)
		probe_count_sent = np
		rd.buffer_get_data_async(buf_probe_out, _on_probes.bind(np), 0, np * 16)
	rd.capture_timestamp("fluid_sim_end")


func _dispatch(name: String, x: int, y: int, z: int) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipes[name])
	rd.compute_list_bind_uniform_set(cl, _sets[name], 0)
	rd.compute_list_dispatch(cl, x, y, z)
	rd.compute_list_end()


func _on_probes(data: PackedByteArray, np: int) -> void:
	var f := data.to_float32_array()
	if f.size() >= np * 4:
		probe_results = f


## Fluid state near probe i: [velocity (world m/s), submerged fraction]
func probe(i: int) -> Array:
	if i * 4 + 3 >= probe_results.size():
		return [Vector3.ZERO, 0.0]
	var v := Vector3(probe_results[i * 4], probe_results[i * 4 + 1], probe_results[i * 4 + 2]) * dx * SIM_RATE
	return [v, probe_results[i * 4 + 3]]


func free_rt() -> void:  # [RT]
	if rd == null:
		return
	_free_sized()
	for r in [buf_ubo, buf_probe_in, buf_probe_out]:
		if r.is_valid():
			rd.free_rid(r)
	for k in _pipes:
		rd.free_rid(_pipes[k])
	for k in _shaders:
		rd.free_rid(_shaders[k])
	_pipes.clear()
	_shaders.clear()
	ok = false
