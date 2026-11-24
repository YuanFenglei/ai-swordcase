extends Node3D
# Energy core pickup: floating bipyramid crystal, counter-rotating rings, sky beacon, rising motes.

const MB = preload("res://mb.gd")
const Beam = preload("res://beam.gd")

static var res := {}

var crystal: MeshInstance3D
var ring_a: MeshInstance3D
var ring_b: MeshInstance3D
var light: OmniLight3D
var beacon: Node3D
var motes: GPUParticles3D
var t := 0.0
var taken := false
var take_t := 0.0
var base := Vector3.ZERO


static func resources() -> Dictionary:
	if not res.is_empty():
		return res
	var mb := MB.new()
	mb.prism(Vector3(0, 0.0, 0), Vector3.UP, 0.62, 0.25, 1.25, 6)
	mb.prism(Vector3(0, 0.0, 0), Vector3.DOWN, 0.62, 0.25, 1.25, 6)
	res.crystal = mb.build()
	var rb := MB.new()
	var prof := PackedVector2Array()
	for i in 9:
		var a := TAU * i / 8.0
		prof.append(Vector2(1.5 + cos(a) * 0.045, sin(a) * 0.09))
	rb.lathe(prof, 48)
	res.ring = rb.build()
	var pb := MB.new()
	for i in 5:
		var a := TAU * i / 5.0
		pb.prism(Vector3(cos(a) * 1.3, -0.3, sin(a) * 1.3), Vector3(cos(a) * 0.5, 1, sin(a) * 0.5), 0.2, 0.7 + 0.3 * sin(i * 2.1), 0.5, 6)
	res.base = pb.build()
	res.mat = G.smat("crystal", {"col_a": Color(0.15, 0.85, 1.0), "col_b": Color(0.9, 1.0, 1.0), "glow": 3.0})
	return res


func build(p: Vector3) -> void:
	var r := resources()
	base = G.ground(p)
	position = base
	crystal = _mi(r.crystal)
	ring_a = _mi(r.ring)
	ring_b = _mi(r.ring)
	ring_b.scale = Vector3.ONE * 0.78
	var pedestal := _mi(r.base)
	pedestal.position = Vector3.ZERO
	light = OmniLight3D.new()
	light.light_color = G.C_CYAN
	light.light_energy = 5.0
	light.omni_range = 20.0
	light.position = Vector3(0, 3.2, 0)
	light.light_volumetric_fog_energy = 2.0
	add_child(light)
	beacon = Beam.new()
	add_child(beacon)
	beacon.build(G.C_CYAN)
	beacon.width = 2.2
	beacon.visible = true
	beacon.set_span(base + Vector3(0, 4.5, 0), base + Vector3(0, 90.0, 0))
	beacon.inner.set_instance_shader_parameter(&"power", 0.22)
	beacon.outer.set_instance_shader_parameter(&"power", 0.08)
	motes = GPUParticles3D.new()
	motes.amount = 60
	motes.lifetime = 3.0
	motes.local_coords = false
	motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	motes.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 16, 12))
	motes.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 2.4
	pm.emission_ring_inner_radius = 1.0
	pm.emission_ring_height = 0.3
	pm.direction = Vector3.UP
	pm.spread = 8.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.2
	pm.gravity = Vector3.ZERO
	pm.orbit_velocity_min = 0.2
	pm.orbit_velocity_max = 0.5
	pm.radial_accel_min = -1.2
	pm.radial_accel_max = -0.6
	pm.scale_min = 0.4
	pm.scale_max = 1.2
	pm.color = Color(0.4, 0.95, 1.0)
	pm.color_ramp = G.fx._ramp([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	motes.process_material = pm
	motes.draw_pass_1 = G.fx._quad(Vector2(0.22, 0.22), G.fx.sh_add, {"soft": 2.0, "intensity": 4.0})
	add_child(motes)


func _mi(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = res.mat
	mi.position = Vector3(0, 3.2, 0)
	add_child(mi)
	return mi


func _process(dt: float) -> void:
	t += dt
	var bob := sin(t * 1.6) * 0.3
	crystal.position.y = 3.2 + bob
	crystal.rotation.y = t * 1.2
	ring_a.position.y = 3.2 + bob
	ring_b.position.y = 3.2 + bob
	ring_a.rotation = Vector3(t * 0.9, t * 0.5, 0.4)
	ring_b.rotation = Vector3(1.2, t * -1.1, t * 0.7)
	light.light_energy = 5.0 + sin(t * 3.0) * 1.2
	if taken:
		take_t += dt
		var k := clampf(1.0 - take_t / 0.5, 0.0, 1.0)
		crystal.scale = Vector3.ONE * k
		ring_a.scale = Vector3.ONE * (1.0 + take_t * 5.0)
		ring_b.scale = Vector3.ONE * (0.78 + take_t * 8.0)
		light.light_energy = 14.0 * k
		if take_t > 0.5:
			queue_free()
		return
	var w = G.walker
	if w != null and not w.dead and G.flat(w.pos - base).length() < 4.6:
		collect()


func collect() -> void:
	if taken:
		return
	taken = true
	var c := base + Vector3(0, 3.2, 0)
	G.fx.burst("glow", c, G.C_CYAN)
	G.fx.burst("spark_big", c, Color(0.7, 1.0, 1.0))
	G.fx.flash(c, G.C_CYAN, 18.0, 30.0, 0.6)
	G.fx.ring(base, 16.0, 0.7, G.C_CYAN, 2.5)
	G.fx.shock(c, 0.7)
	G.fx.white(0.18)
	G.audio.play("pickup", c, 2.0)
	beacon.visible = false
	motes.emitting = false
	G.main.on_core(self)
