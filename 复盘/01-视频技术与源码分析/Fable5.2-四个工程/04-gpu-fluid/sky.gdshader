shader_type sky;
// Mirrors shaders/env.inc so the fluid's reflections match the sky.

float env_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float env_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(env_hash(i), env_hash(i + vec2(1.0, 0.0)), f.x), mix(env_hash(i + vec2(0.0, 1.0)), env_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float env_fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * env_noise(p);
		p = p * 2.03 + 17.1;
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 zen = vec3(0.07, 0.22, 0.58);
	vec3 hor = vec3(0.60, 0.73, 0.90);
	vec3 gnd = vec3(0.30, 0.31, 0.33);
	vec3 c;
	if (d.y > 0.0) {
		c = mix(hor, zen, pow(d.y, 0.5));
		vec2 cp = d.xz / (d.y + 0.12) * 1.3;
		float cl = smoothstep(0.52, 0.85, env_fbm(cp + vec2(3.7, 1.3)));
		c = mix(c, vec3(1.05, 1.03, 1.0), cl * 0.75 * smoothstep(0.02, 0.25, d.y));
	} else {
		c = mix(hor, gnd, smoothstep(0.0, -0.12, d.y));
	}
	float s = max(dot(d, LIGHT0_DIRECTION), 0.0);
	c += vec3(1.0, 0.85, 0.6) * pow(s, 24.0) * 0.35;
	if (AT_CUBEMAP_PASS == false) {
		c += vec3(1.0, 0.92, 0.8) * smoothstep(0.9994, 0.9998, s) * 30.0;
	}
	COLOR = c;
}
