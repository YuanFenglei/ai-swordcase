shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, shadows_disabled;
instance uniform vec3 tint : source_color = vec3(0.2, 0.9, 1.0);
instance uniform float power = 6.0;

void fragment() {
	float f = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO = mix(tint, vec3(1.0), f * f * 0.8) * power * (0.25 + f);
	ALPHA = pow(f, 1.3);
}
