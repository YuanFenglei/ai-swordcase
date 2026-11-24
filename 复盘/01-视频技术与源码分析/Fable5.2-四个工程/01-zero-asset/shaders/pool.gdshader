shader_type spatial;
render_mode cull_back, diffuse_burley;
// Luminous liquid pooled in the hollows. UV.x carries water depth baked per vertex,
// so the shoreline follows the terrain and brightens where it gets shallow.
uniform vec3 deep_col : source_color = vec3(0.01, 0.10, 0.12);
uniform vec3 glow_col : source_color = vec3(0.10, 0.95, 0.80);
varying vec3 wp;

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
float flow(vec2 p, float t) {
	return vnoise(p * 0.9 + vec2(t * 0.11, -t * 0.07)) * 0.6 + vnoise(p * 2.3 - vec2(t * 0.16, t * 0.09)) * 0.4;
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float depth = UV.x;
	if (depth < 0.0) {
		discard;
	}
	float t = TIME;
	vec2 p = wp.xz;
	float e = 0.25;
	float f0 = flow(p, t);
	vec2 grad = vec2(flow(p + vec2(e, 0.0), t) - f0, flow(p + vec2(0.0, e), t) - f0) / e;
	float shore = 1.0 - smoothstep(0.0, 0.22, depth);
	float deepk = smoothstep(0.2, 2.2, depth);
	// slow drifting filaments of light under the surface
	float fil = smoothstep(0.52, 0.62, vnoise(p * 0.7 + grad * 2.0 + vec2(t * 0.05, 0.0))) * (0.5 + 0.5 * sin(t * 1.3 + f0 * 12.0));
	ALBEDO = mix(glow_col * 0.18, deep_col, deepk);
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.8;
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(vec3(-grad.x * 0.35, 1.0, -grad.y * 0.35)), 0.0)).xyz);
	EMISSION = glow_col * (0.10 + shore * 0.7 + fil * 0.55 * (1.0 - deepk * 0.5) + f0 * 0.12);
}
