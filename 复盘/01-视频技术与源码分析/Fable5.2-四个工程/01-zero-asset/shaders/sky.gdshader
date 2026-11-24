shader_type sky;
// Dusk atmosphere, sun, stars, banded ringed planet with ring shadow, drifting cirrus.

uniform vec3 planet_dir = vec3(0.42, 0.40, -0.80);
uniform float planet_size = 0.21;
uniform vec3 ring_axis = vec3(0.32, 0.9, 0.28);
uniform float mood = 0.0;

float h21(vec2 p) {
	ivec2 i = ivec2(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u;
	n = (n ^ (n >> 16u)) * 2246822519u;
	n ^= n >> 13u;
	return float(n & 16777215u) / 16777216.0;
}
float h31(vec3 p) {
	ivec3 i = ivec3(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u ^ uint(i.z) * 2798796415u;
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
float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 3.3);
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 sun = normalize(LIGHT0_DIRECTION);
	float up = max(d.y, 0.0);
	float sd = max(dot(d, sun), 0.0);
	float warm = pow(0.5 + 0.5 * dot(normalize(d.xz + vec2(1e-5)), normalize(sun.xz)), 3.0);

	vec3 zen = vec3(0.022, 0.045, 0.14);
	vec3 midc = mix(vec3(0.15, 0.13, 0.36), vec3(0.26, 0.06, 0.16), mood);
	vec3 hor_cool = mix(vec3(0.16, 0.44, 0.52), vec3(0.40, 0.14, 0.24), mood);
	vec3 hor_warm = mix(vec3(1.05, 0.40, 0.14), vec3(1.2, 0.2, 0.1), mood);
	vec3 col = mix(zen, midc, pow(1.0 - up, 2.6));
	col = mix(col, mix(hor_cool, hor_warm, warm), pow(1.0 - up, 6.0));
	col += hor_warm * pow(sd, 12.0) * 0.22;
	col += vec3(1.6, 0.75, 0.4) * pow(sd, 120.0) * 0.5;

	// stars
	float night = smoothstep(0.02, 0.35, d.y) * (1.0 - pow(sd, 3.0));
	vec3 g = d * 190.0;
	vec3 cell = floor(g);
	float hs = h31(cell);
	float st = step(0.9955, hs) * smoothstep(0.42, 0.05, length(fract(g) - 0.5));
	st *= 0.6 + 0.4 * sin(TIME * (2.0 + hs * 30.0) + hs * 100.0);
	vec3 starc = mix(vec3(0.7, 0.85, 1.0), vec3(1.0, 0.8, 0.6), fract(hs * 91.7));
	col += starc * st * night * 2.2;
	// faint galactic band
	float band = exp(-pow(dot(d, normalize(vec3(0.5, 0.3, 0.8))) * 4.0, 2.0));
	col += vec3(0.10, 0.07, 0.20) * band * fbm(d.xz * 6.0 + d.y * 3.0) * night * 0.6;

	// planet
	vec3 pc = normalize(planet_dir);
	float R = planet_size;
	float b = dot(d, pc);
	float disc = b * b - (1.0 - R * R);
	float tp = 1e9;
	vec3 pre = col;
	if (disc > 0.0 && b > 0.0) {
		tp = b - sqrt(disc);
		vec3 pn = normalize(d * tp - pc);
		vec3 ax = normalize(ring_axis);
		float lat = dot(pn, ax);
		float lon = atan(dot(pn, normalize(cross(ax, vec3(1.0, 0.0, 0.0)))), dot(pn, normalize(cross(ax, cross(ax, vec3(1.0, 0.0, 0.0))))));
		float turb = fbm(vec2(lon * 2.0 + TIME * 0.004, lat * 9.0));
		float bands = 0.5 + 0.5 * sin(lat * 26.0 + turb * 5.0);
		vec3 pcol = mix(vec3(0.75, 0.32, 0.22), vec3(0.95, 0.72, 0.5), bands);
		pcol = mix(pcol, vec3(0.35, 0.2, 0.45), smoothstep(0.55, 0.9, abs(lat)));
		float lit = smoothstep(-0.12, 0.5, dot(pn, sun));
		float rim = pow(1.0 - max(dot(pn, -d), 0.0), 3.0);
		float edge = smoothstep(0.0, 0.0006, disc);
		vec3 shade = pre * 0.85 + pcol * lit * 0.85 + vec3(0.2, 0.6, 0.7) * rim * (0.15 + lit * 0.5);
		col = mix(col, shade, edge);
	}
	// ring
	vec3 ax2 = normalize(ring_axis);
	float dn = dot(d, ax2);
	if (abs(dn) > 1e-4) {
		float tr = dot(pc, ax2) / dn;
		if (tr > 0.0) {
			vec3 hp = d * tr - pc;
			float rr = length(hp) / R;
			if (rr > 1.3 && rr < 2.45 && tr < tp) {
				float dens = smoothstep(1.3, 1.36, rr) * smoothstep(2.45, 2.36, rr);
				float fine = 0.35 + 0.65 * h21(vec2(floor(rr * 70.0), 3.0));
				float coarse = 0.3 + 0.7 * smoothstep(0.2, 0.6, vnoise(vec2(rr * 9.0, 1.0)));
				float gap = smoothstep(0.02, 0.05, abs(rr - 1.95));
				float bs = dot(hp, sun);
				float sh = (bs < 0.0 && bs * bs - (dot(hp, hp) - R * R) > 0.0) ? 0.12 : 1.0;
				vec3 rc = mix(vec3(0.95, 0.7, 0.5), vec3(0.6, 0.75, 0.9), fine) * sh;
				col = mix(col, pre * 0.5 + rc * 0.75, dens * fine * coarse * gap * 0.85);
			}
		}
	}
	// small moon
	vec3 md = normalize(vec3(-0.65, 0.5, 0.35));
	float mR = 0.022;
	float mb = dot(d, md);
	float mdisc = mb * mb - (1.0 - mR * mR);
	if (mdisc > 0.0 && mb > 0.0) {
		vec3 mn = normalize(d * (mb - sqrt(mdisc)) - md);
		float ml = smoothstep(-0.1, 0.6, dot(mn, sun));
		col = mix(col, pre * 0.6 + vec3(0.75, 0.7, 0.8) * ml * (0.7 + 0.3 * vnoise(mn.xy * 9.0)), smoothstep(0.0, 0.00002, mdisc));
	}

	// cirrus
	if (d.y > 0.0) {
		vec2 uv = d.xz / (d.y + 0.14);
		float t = TIME * 0.008;
		float n = fbm(uv * vec2(0.55, 1.3) + vec2(t, t * 0.3));
		n = smoothstep(0.50, 0.82, n + 0.18 * fbm(uv * 3.7 - t));
		float fade = smoothstep(0.0, 0.2, d.y) * (1.0 - smoothstep(0.55, 0.95, d.y) * 0.6);
		vec3 cc = mix(vec3(0.13, 0.07, 0.22), mix(vec3(1.6, 0.55, 0.28), vec3(1.7, 0.3, 0.2), mood), pow(warm, 1.5) * 0.85 + pow(sd, 6.0) * 0.5);
		col = mix(col, cc, n * fade * 0.72);
	}
	if (!AT_CUBEMAP_PASS) {
		col += vec3(2.4, 1.5, 0.9) * smoothstep(0.99955, 0.9998, dot(d, sun)) * 8.0;
	}
	// below horizon haze
	vec3 hz = mix(mix(hor_cool, hor_warm, warm) * 0.55, vec3(0.03, 0.03, 0.06), smoothstep(0.0, -0.4, d.y));
	col = mix(col, hz, smoothstep(0.0, -0.03, d.y));
	COLOR = col;
}
