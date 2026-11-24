shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, shadows_disabled;
instance uniform float life = 0.0;
instance uniform vec3 tint : source_color = vec3(1.0, 0.45, 0.12);
instance uniform float seed = 0.0;
varying vec3 op;

float h31(vec3 p) {
	ivec3 i = ivec3(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u ^ uint(i.z) * 2798796415u;
	n = (n ^ (n >> 16u)) * 2246822519u;
	n ^= n >> 13u;
	return float(n & 16777215u) / 16777216.0;
}
float n3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h31(i), h31(i + vec3(1, 0, 0)), f.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), f.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm3(vec3 p) {
	return n3(p) * 0.5 + n3(p * 2.1 + 3.7) * 0.3 + n3(p * 4.3 + 9.1) * 0.2;
}

void vertex() {
	op = VERTEX;
	float n = fbm3(VERTEX * 1.7 + seed + vec3(0.0, TIME * 0.7, 0.0));
	VERTEX *= 0.7 + n * 0.65;
}

void fragment() {
	float n = fbm3(op * 2.4 + seed + life * 1.6);
	float f = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float heat = clamp(n * 1.5 + f * 0.55 - life * 1.55, 0.0, 1.0);
	vec3 c = mix(tint * 0.7, vec3(1.0, 0.92, 0.75), smoothstep(0.45, 1.0, heat)) * (1.0 + 3.0 * heat);
	ALBEDO = c * 0.8;
	ALPHA = smoothstep(0.0, 0.3, heat) * (1.0 - life * life);
}
