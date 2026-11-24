extends CompositorEffect
const FluidSim = preload("res://fluid_sim.gd")
## Screen-space fluid: sphere impostor depth -> narrow-range smoothing -> shaded composite into the scene colour buffer.

var sim: FluidSim
var rd: RenderingDevice
var ok := false

# parameters written by the main thread
var wipe := 1.2                 # <-0.19 raw particles everywhere, >1.19 liquid everywhere
var radius_scale := 0.85
var cull_interior := true
var sun_dir := Vector3(0.4, 0.8, 0.3)
var sun_energy := 1.0
var absorb_a := Color(0.55, 0.085, 0.045, 0.9)
var absorb_b := Color(0.06, 0.95, 0.30, 1.2)
var scat_a := Color(0.02, 0.22, 0.30)
var scat_b := Color(0.55, 0.05, 0.28)
var foam_strength := 1.0
var min_thick := 0.0
var refraction := 1.0
var smooth_iters := 2
var time := 0.0

var _sh_particles: RID
var _sh_smooth: RID
var _sh_copy: RID
var _sh_comp: RID
var _pipe_particles: RID
var _pipe_smooth: RID
var _pipe_copy: RID
var _pipe_comp: RID
var _samp_nearest: RID
var _samp_linear: RID
var _ubo_cam: RID
var _ubo_fx: RID
var _size := Vector2i.ZERO
var _tex_depth_a: RID
var _tex_depth_b: RID
var _tex_depth_c: RID
var _tex_aux: RID
var _tex_z: RID
var _tex_copy: RID
var _fb: RID
var _fb_format := -1


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_rt)


func _init_rt() -> void:
	rd = RenderingServer.get_rendering_device()
	var src := FluidSim.load_source("particles.glsl")
	var parts := src.split("//@fragment")
	var s := RDShaderSource.new()
	s.source_vertex = parts[0].replace("//@vertex", "")
	s.source_fragment = parts[1]
	var spirv := rd.shader_compile_spirv_from_source(s)
	if spirv.compile_error_vertex != "" or spirv.compile_error_fragment != "":
		print("SHADER ERROR particles: ", spirv.compile_error_vertex, spirv.compile_error_fragment)
		return
	_sh_particles = rd.shader_create_from_spirv(spirv, "particles")
	_sh_smooth = FluidSim.compile_compute(rd, "smooth.glsl")
	_sh_copy = FluidSim.compile_compute(rd, "copy.glsl")
	_sh_comp = FluidSim.compile_compute(rd, "composite.glsl")
	if not (_sh_smooth.is_valid() and _sh_copy.is_valid() and _sh_comp.is_valid()):
		return
	_pipe_smooth = rd.compute_pipeline_create(_sh_smooth)
	_pipe_copy = rd.compute_pipeline_create(_sh_copy)
	_pipe_comp = rd.compute_pipeline_create(_sh_comp)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_samp_nearest = rd.sampler_create(ss)
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_samp_linear = rd.sampler_create(ss)
	var z := PackedByteArray()
	z.resize(160)
	_ubo_cam = rd.uniform_buffer_create(160, z)
	z.resize(288)
	_ubo_fx = rd.uniform_buffer_create(288, z)
	ok = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for r in [_fb, _tex_depth_a, _tex_depth_b, _tex_depth_c, _tex_aux, _tex_z, _tex_copy, _ubo_cam, _ubo_fx,
				_samp_nearest, _samp_linear, _pipe_particles, _pipe_smooth, _pipe_copy, _pipe_comp,
				_sh_particles, _sh_smooth, _sh_copy, _sh_comp]:
			if r.is_valid():
				rd.free_rid(r)


func _make_tex(size: Vector2i, fmt: int, usage: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.format = fmt
	tf.width = size.x
	tf.height = size.y
	tf.usage_bits = usage
	return rd.texture_create(tf, RDTextureView.new())


func _ensure_targets(size: Vector2i) -> void:
	if size == _size:
		return
	for r in [_fb, _tex_depth_a, _tex_depth_b, _tex_depth_c, _tex_aux, _tex_z, _tex_copy]:
		if r.is_valid():
			rd.free_rid(r)
	_size = size
	var S := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var C := RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	var ST := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_tex_depth_a = _make_tex(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT, S | C)
	_tex_depth_b = _make_tex(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT, S | ST)
	_tex_depth_c = _make_tex(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT, S | ST)
	_tex_aux = _make_tex(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, S | C)
	_tex_z = _make_tex(size, RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
	_tex_copy = _make_tex(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, S | ST)
	_fb = rd.framebuffer_create([_tex_depth_a, _tex_aux, _tex_z])
	var fmt := rd.framebuffer_get_format(_fb)
	if fmt != _fb_format or not _pipe_particles.is_valid():
		_fb_format = fmt
		if _pipe_particles.is_valid():
			rd.free_rid(_pipe_particles)
		var ds := RDPipelineDepthStencilState.new()
		ds.enable_depth_test = true
		ds.enable_depth_write = true
		ds.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER
		var bs := RDPipelineColorBlendState.new()
		bs.attachments = [RDPipelineColorBlendStateAttachment.new(), RDPipelineColorBlendStateAttachment.new()]
		_pipe_particles = rd.render_pipeline_create(_sh_particles, fmt, RenderingDevice.INVALID_FORMAT_ID,
				RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(),
				RDPipelineMultisampleState.new(), ds, bs)


func _u(binding: int, type: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = type
	for i in ids:
		u.add_id(i)
	return u


func _put_mat(b: StreamPeerBuffer, t: Transform3D) -> void:
	for c in [t.basis.x, t.basis.y, t.basis.z]:
		b.put_float(c.x); b.put_float(c.y); b.put_float(c.z); b.put_float(0.0)
	b.put_float(t.origin.x); b.put_float(t.origin.y); b.put_float(t.origin.z); b.put_float(1.0)


func _put4(b: StreamPeerBuffer, x: float, y: float, z: float, w: float) -> void:
	b.put_float(x); b.put_float(y); b.put_float(z); b.put_float(w)


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not ok or sim == null or not sim.ok or not sim.buf_particles.is_valid():
		return
	var sb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var sd := render_data.get_render_scene_data()
	if sb == null or sd == null:
		return
	var size := sb.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var n := sim.count
	_ensure_targets(size)
	rd.capture_timestamp("fluid_fx_begin")
	var cam_xf := sd.get_cam_transform()
	var view := cam_xf.affine_inverse()
	var proj := sd.get_cam_projection()
	var radius := sim.dx * radius_scale

	var b := StreamPeerBuffer.new()
	_put_mat(b, view)
	for c in [proj.x, proj.y, proj.z, proj.w]:
		b.put_float(c.x); b.put_float(c.y); b.put_float(c.z); b.put_float(c.w)
	_put4(b, sim.origin.x, sim.origin.y, sim.origin.z, sim.dx)
	_put4(b, radius, 1.0 if (cull_interior and wipe > -0.19) else 0.0, 0.26, 0.0)
	rd.buffer_update(_ubo_cam, 0, 160, b.data_array)

	b = StreamPeerBuffer.new()
	_put_mat(b, view)
	_put_mat(b, cam_xf)
	_put4(b, proj.x.x, proj.y.y, proj.z.z, proj.w.z)
	_put4(b, size.x, size.y, time, wipe)
	_put4(b, sim.origin.x, sim.origin.y, sim.origin.z, sim.dx)
	_put4(b, sim.grid.x, sim.grid.y, sim.grid.z, FluidSim.REST)
	var sdn := sun_dir.normalized()
	_put4(b, sdn.x, sdn.y, sdn.z, sun_energy)
	_put4(b, absorb_a.r, absorb_a.g, absorb_a.b, absorb_a.a)
	_put4(b, absorb_b.r, absorb_b.g, absorb_b.b, absorb_b.a)
	_put4(b, scat_a.r, scat_a.g, scat_a.b, 0)
	_put4(b, scat_b.r, scat_b.g, scat_b.b, 0)
	_put4(b, foam_strength, refraction, radius, min_thick)
	rd.buffer_update(_ubo_fx, 0, 288, b.data_array)

	# 1. particle impostors -> linear depth + aux
	var set_p := UniformSetCacheRD.get_cache(_sh_particles, 0, [
		_u(0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, [sim.buf_particles]),
		_u(1, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, [_ubo_cam])])
	var dl := rd.draw_list_begin(_fb, RenderingDevice.DRAW_CLEAR_ALL, PackedColorArray([Color(1.0e5, 0, 0, 0), Color(0, 0, 0, 0)]), 0.0, 0)
	if n > 0:
		rd.draw_list_bind_render_pipeline(dl, _pipe_particles)
		rd.draw_list_bind_uniform_set(dl, set_p, 0)
		rd.draw_list_draw(dl, false, n, 6)
	rd.draw_list_end()
	if sim.profile: rd.capture_timestamp("f_raster")

	var gx := int(ceil(size.x / 8.0))
	var gy := int(ceil(size.y / 8.0))
	# 2. narrow-range depth smoothing (separable), a -> b -> c
	var px_at_1 := radius * 3.2 * absf(proj.y.y) * size.y * 0.5
	var delta := radius * 5.0
	var src := _tex_depth_a
	if wipe > -0.19:
		for it in smooth_iters:
			for pass_i in 2:
				var dst := _tex_depth_b if pass_i == 0 else _tex_depth_c
				var pc := StreamPeerBuffer.new()
				_put4(pc, 1.0 if pass_i == 0 else 0.0, 0.0 if pass_i == 0 else 1.0, px_at_1 / (1.0 + it * 0.8), delta)
				_put4(pc, 28.0, 2.0 if it == 0 else 1.0, 0, 0)
				var set_s := UniformSetCacheRD.get_cache(_sh_smooth, 0, [
					_u(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, src]),
					_u(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [dst])])
				var cl := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(cl, _pipe_smooth)
				rd.compute_list_bind_uniform_set(cl, set_s, 0)
				rd.compute_list_set_push_constant(cl, pc.data_array, 32)
				rd.compute_list_dispatch(cl, gx, gy, 1)
				rd.compute_list_end()
				src = dst

	if sim.profile: rd.capture_timestamp("f_smooth")
	# 3. copy scene colour, then composite into it
	var color := sb.get_color_layer(0)
	var depth := sb.get_depth_layer(0)
	var set_c := UniformSetCacheRD.get_cache(_sh_copy, 0, [
		_u(0, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, color]),
		_u(1, RenderingDevice.UNIFORM_TYPE_IMAGE, [_tex_copy])])
	var cl2 := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl2, _pipe_copy)
	rd.compute_list_bind_uniform_set(cl2, set_c, 0)
	rd.compute_list_dispatch(cl2, gx, gy, 1)
	rd.compute_list_end()

	var set_f := UniformSetCacheRD.get_cache(_sh_comp, 0, [
		_u(0, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, [_ubo_fx]),
		_u(1, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, src]),
		_u(2, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, _tex_depth_a]),
		_u(3, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, _tex_aux]),
		_u(4, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_linear, _tex_copy]),
		_u(5, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_nearest, depth]),
		_u(6, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_samp_linear, sim.tex_density]),
		_u(7, RenderingDevice.UNIFORM_TYPE_IMAGE, [color])])
	var cl3 := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl3, _pipe_comp)
	rd.compute_list_bind_uniform_set(cl3, set_f, 0)
	rd.compute_list_dispatch(cl3, gx, gy, 1)
	rd.compute_list_end()
	rd.capture_timestamp("fluid_fx_end")
