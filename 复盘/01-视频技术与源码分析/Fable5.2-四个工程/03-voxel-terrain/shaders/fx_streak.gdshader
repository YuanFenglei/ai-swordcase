shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

void fragment() {
	float across = pow(max(1.0 - abs(UV.x - 0.5) * 2.0, 0.0), 2.5);
	float along = pow(UV.y, 2.2);
	float a = across * along;
	ALBEDO = mix(vec3(1.0, 0.25, 0.04), vec3(1.0, 0.85, 0.6), along * along) * 12.0;
	ALPHA = a;
}
