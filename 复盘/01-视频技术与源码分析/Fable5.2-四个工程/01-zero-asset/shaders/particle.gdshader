shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Procedural particle sprite: soft disc, optional noise erosion, soft depth intersection.
uniform float soft = 1.5;
uniform float intensity = 2.0;
uniform float noisy = 0.0;
uniform float depth_fade = 0.0;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
varying float rnd;

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

void vertex() {
	rnd = fract(float(INSTANCE_ID) * 0.6180339);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p);
	float a = pow(clamp(1.0 - d, 0.0, 1.0), soft);
	if (noisy > 0.0) {
		float n = vnoise(UV * 3.0 + rnd * 37.0) * 0.6 + vnoise(UV * 7.0 - rnd * 11.0) * 0.4;
		a *= smoothstep(0.2, 0.75, n + (1.0 - d) * 0.45);
	}
	if (depth_fade > 0.0) {
		float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
		vec4 up = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		float scene = -up.z / up.w;
		a *= clamp((scene + VERTEX.z) / depth_fade, 0.0, 1.0);
	}
	ALBEDO = COLOR.rgb * intensity;
	ALPHA = a * COLOR.a;
}
