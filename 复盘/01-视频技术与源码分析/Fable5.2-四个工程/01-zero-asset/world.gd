extends Node3D
# Sky, sun, environment and post settings.

const SUN_COL := Color(1.0, 0.76, 0.54)
const FOG_COL := Color(0.40, 0.29, 0.40)

var env: Environment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var mood := 0.0
var mood_target := 0.0
var fill: DirectionalLight3D


func build() -> void:
	get_tree().node_added.connect(_on_node_added)
	sun = DirectionalLight3D.new()
	var sd := Vector3(-0.62, 0.50, -0.72).normalized()
	add_child(sun)
	sun.look_at_from_position(sd * 100.0, Vector3.ZERO, Vector3.UP)
	sun.light_color = SUN_COL
	sun.light_energy = 3.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 260.0
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 2.4
	sun.light_angular_distance = 1.1
	sun.light_volumetric_fog_energy = 0.55
	# cool skylight from the side opposite the sun: lifts the backlit faces without flattening them
	fill = DirectionalLight3D.new()
	add_child(fill)
	fill.look_at_from_position(Vector3(0.55, 0.62, 0.66).normalized() * 100.0, Vector3.ZERO, Vector3.UP)
	fill.light_color = Color(0.42, 0.62, 1.0)
	fill.light_energy = 0.55
	fill.light_specular = 0.25
	fill.shadow_enabled = false
	fill.light_volumetric_fog_energy = 0.0
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY

	sky_mat = G.smat("sky")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.35
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.15
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.set("glow_levels/2", 0.4)
	env.set("glow_levels/3", 1.0)
	env.set("glow_levels/4", 0.6)
	env.set("glow_levels/5", 1.0)
	env.set("glow_levels/6", 0.4)
	env.set("glow_levels/7", 0.3)
	env.ssao_enabled = true
	env.ssao_radius = 2.2
	env.ssao_intensity = 1.5
	env.ssao_power = 1.4
	env.ssil_enabled = true
	env.ssil_radius = 6.0
	env.ssil_intensity = 1.1
	env.sdfgi_enabled = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.5
	env.sdfgi_use_occlusion = true
	env.sdfgi_bounce_feedback = 0.55
	env.sdfgi_read_sky_light = true
	env.sdfgi_energy = 1.0
	env.sdfgi_normal_bias = 1.1
	env.sdfgi_probe_bias = 1.1
	env.fog_enabled = true
	env.fog_light_color = FOG_COL
	env.fog_light_energy = 1.0
	env.fog_density = 0.00045
	env.fog_aerial_perspective = 0.45
	env.fog_sun_scatter = 0.08
	env.fog_sky_affect = 0.0
	env.fog_height = 6.0
	env.fog_height_density = 0.004
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0016
	env.volumetric_fog_albedo = Color(0.82, 0.70, 0.86)
	env.volumetric_fog_emission = Color(0.03, 0.10, 0.12)
	env.volumetric_fog_emission_energy = 0.35
	env.volumetric_fog_anisotropy = 0.6
	env.volumetric_fog_length = 200.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.35
	env.volumetric_fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.04
	env.adjustment_saturation = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _process(dt: float) -> void:
	if absf(mood - mood_target) > 0.001:
		mood = move_toward(mood, mood_target, dt * 0.35)
		sky_mat.set_shader_parameter("mood", mood)
		sun.light_color = SUN_COL.lerp(Color(1.0, 0.46, 0.34), mood)
		env.fog_light_color = FOG_COL.lerp(Color(0.42, 0.12, 0.2), mood)
		env.volumetric_fog_emission = Color(0.03, 0.10, 0.12).lerp(Color(0.16, 0.02, 0.05), mood)
		G.terrain.mat.set_shader_parameter("vein_col", Color(0.08, 0.95, 0.8).lerp(Color(1.0, 0.15, 0.3), mood))


# SDFGI voxelises static geometry only. Terrain and props stay static; everything that moves
# (walker, creatures, boss, effects) is flagged dynamic so it receives bounce light without smearing the field.
func _on_node_added(n: Node) -> void:
	if n is GeometryInstance3D:
		var is_static: bool = (G.terrain != null and G.terrain.is_ancestor_of(n)) or (G.scatter != null and G.scatter.is_ancestor_of(n))
		n.gi_mode = GeometryInstance3D.GI_MODE_STATIC if is_static else GeometryInstance3D.GI_MODE_DYNAMIC
