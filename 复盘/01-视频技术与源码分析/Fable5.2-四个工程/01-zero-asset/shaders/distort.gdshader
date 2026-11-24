shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled;
// Refractive shock bubble: bends the rendered scene near its silhouette.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
instance uniform float life = 0.0;

void fragment() {
	float f = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float ring = smoothstep(0.45, 0.8, f) * (1.0 - smoothstep(0.8, 1.0, f));
	float k = 1.0 - life;
	vec2 off = normalize(NORMAL.xy + vec2(1e-5)) * ring * 0.035 * k;
	ALBEDO = texture(screen_tex, SCREEN_UV - off).rgb * (1.0 + ring * 0.25 * k);
	ALPHA = ring * smoothstep(0.0, 0.3, k);
}
