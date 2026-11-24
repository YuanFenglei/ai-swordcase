shader_type sky;

uniform vec3 zenith : source_color = vec3(0.07, 0.17, 0.36);
uniform vec3 horizon_sun : source_color = vec3(1.0, 0.56, 0.27);
uniform vec3 horizon_far : source_color = vec3(0.52, 0.47, 0.60);
uniform float dim = 1.0;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);

float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vnoise2(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 5; i++) { s += a * vnoise2(p); p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + 7.3; a *= 0.5; }
	return s;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 sd = normalize(sun_dir);
	float y = d.y;
	float sun_d = clamp(dot(d, sd), 0.0, 1.0);
	float az = clamp(dot(normalize(d.xz + vec2(1e-5)), normalize(sd.xz)) * 0.5 + 0.5, 0.0, 1.0);
	vec3 hz = mix(horizon_far, horizon_sun, pow(az, 1.6));
	float t = pow(clamp(y, 0.0, 1.0), 0.42);
	vec3 col = mix(hz, zenith, t);
	col += vec3(1.0, 0.50, 0.20) * pow(sun_d, 5.0) * 0.55;
	col += vec3(1.0, 0.78, 0.50) * pow(sun_d, 48.0) * 1.1;
	if (y > 0.0) {
		vec2 uv = d.xz / (y + 0.14);
		float c = fbm(uv * vec2(0.55, 1.1) + vec2(3.0, 1.0));
		float c2 = fbm(uv * 2.3 + 11.0);
		float cov = smoothstep(0.50, 0.80, c + (c2 - 0.5) * 0.25);
		float shade = smoothstep(0.50, 0.95, c);
		vec3 lit = mix(vec3(0.95, 0.60, 0.50), vec3(1.0, 0.80, 0.55), pow(az, 2.0)) * (1.0 + pow(sun_d, 6.0) * 1.5);
		vec3 dark = vec3(0.30, 0.26, 0.40);
		vec3 cc = mix(lit, dark, shade * 0.75);
		col = mix(col, cc, cov * 0.85 * smoothstep(0.0, 0.12, y));
	} else {
		col = mix(hz, vec3(0.10, 0.15, 0.20), smoothstep(0.0, -0.35, y));
	}
	col += vec3(1.0, 0.86, 0.62) * smoothstep(0.9995, 0.9998, sun_d) * 8.0;
	COLOR = max(col * dim, vec3(0.0));
}
