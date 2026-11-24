shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
instance uniform vec3 tint : source_color = vec3(1.0, 0.2, 0.5);
instance uniform float life = 0.0;

void fragment() {
	float v = UV.y;
	float n = 0.55 + 0.45 * sin(UV.x * 240.0 + TIME * 25.0) * sin(UV.x * 70.0 - TIME * 9.0);
	float a = pow(1.0 - v, 2.5) * (1.0 - life) * smoothstep(0.0, 0.08, v);
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 up = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float glowline = 1.0 - clamp((-up.z / up.w + VERTEX.z) / 1.2, 0.0, 1.0);
	ALBEDO = tint * (3.0 + glowline * 8.0) * n;
	ALPHA = clamp(a + glowline * (1.0 - life) * 0.8, 0.0, 1.0);
}
