shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.2, 0.9, 1.0);
uniform float core = 1.0;
instance uniform float len = 10.0;
instance uniform float power = 1.0;

float h21(vec2 p) {
	ivec2 i = ivec2(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u;
	n = (n ^ (n >> 16u)) * 2246822519u;
	n ^= n >> 13u;
	return float(n & 16777215u) / 16777216.0;
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	float f = abs(dot(NORMAL, VIEW));
	float c = pow(f, 3.0);
	float n = vnoise(vec2(UV.y * len * 0.5 - TIME * 34.0, UV.x * 5.0));
	float n2 = vnoise(vec2(UV.y * len * 2.2 - TIME * 70.0, UV.x * 9.0 + 3.0));
	float fl = 0.85 + 0.15 * sin(TIME * 90.0);
	ALBEDO = (tint * (0.6 + n * 1.2 + n2 * 0.8) + vec3(1.0) * c * 2.0 * core) * power * 1.7 * fl;
	ALPHA = clamp(c * core + f * 0.4 * (0.4 + n), 0.0, 1.0);
}
