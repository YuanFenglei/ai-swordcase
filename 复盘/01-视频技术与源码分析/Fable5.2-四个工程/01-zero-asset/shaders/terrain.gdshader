shader_type spatial;
render_mode cull_back, diffuse_burley;
// Triplanar procedural ground: slope/height layer blending, strata, dune ripples,
// glowing vein network. No textures: every detail is evaluated here.

uniform vec3 dust_a : source_color = vec3(0.47, 0.25, 0.15);
uniform vec3 dust_b : source_color = vec3(0.23, 0.18, 0.27);
uniform vec3 rock_a : source_color = vec3(0.11, 0.095, 0.125);
uniform vec3 rock_b : source_color = vec3(0.40, 0.24, 0.20);
uniform vec3 peak_col : source_color = vec3(0.52, 0.38, 0.46);
uniform vec3 vein_col : source_color = vec3(0.08, 0.95, 0.8);
uniform vec3 salt_col : source_color = vec3(0.66, 0.54, 0.46);
uniform float rock_mode = 0.0;
uniform float vein_gain = 1.0;
uniform float bump_gain = 1.0;

varying vec3 wp;
varying vec3 wn;

float h21(vec2 p) {
	ivec2 i = ivec2(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u;
	n = (n ^ (n >> 16u)) * 2246822519u;
	n ^= n >> 13u;
	return float(n & 16777215u) / 16777216.0;
}
vec2 h22(vec2 p) {
	return vec2(0.15 + 0.7 * h21(p), 0.15 + 0.7 * h21(p + vec2(91.0, 37.0)));
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
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 3.3);
		a *= 0.5;
	}
	return s;
}
float ridged(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 3; i++) {
		s += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.1 + vec2(5.1, 9.3);
		a *= 0.5;
	}
	return s;
}
vec2 voro(vec2 p) {
	vec2 g = floor(p);
	vec2 f = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 r = o + h22(g + o) - f;
			float d = dot(r, r);
			if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
		}
	}
	return vec2(sqrt(f1), sqrt(f2) - sqrt(f1));
}
float tri_fbm(vec3 p, vec3 w, float s) {
	return fbm(p.zy * s) * w.x + fbm(p.xz * s) * w.y + fbm(p.xy * s) * w.z;
}
float tri_ridged(vec3 p, vec3 w, float s) {
	return ridged(p.zy * s) * w.x + ridged(p.xz * s) * w.y + ridged(p.xy * s) * w.z;
}
vec3 bump(vec3 pos, vec3 nrm, float hgt, float k) {
	vec3 dpx = dFdx(pos);
	vec3 dpy = dFdy(pos);
	float dhx = dFdx(hgt);
	float dhy = dFdy(hgt);
	vec3 r1 = cross(dpy, nrm);
	vec3 r2 = cross(nrm, dpx);
	float det = dot(dpx, r1);
	vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
	return normalize(abs(det) * nrm - k * grad);
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 n = normalize(wn);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	float dist = length(wp - CAMERA_POSITION_WORLD);
	float lod = 1.0 - smoothstep(50.0, 260.0, dist);
	float near = 1.0 - smoothstep(12.0, 60.0, dist);

	float big = fbm(wp.xz * 0.011);
	float mid = tri_fbm(wp, w, 0.13);
	float rdg = tri_ridged(wp, w, 0.22);
	float fine = tri_fbm(wp, w, 1.3);

	float slope = 1.0 - n.y;
	float rockm = smoothstep(0.10, 0.28, slope + (mid - 0.5) * 0.3);
	rockm = max(rockm, rock_mode);

	float strata = 0.5 + 0.5 * sin(wp.y * 2.6 + mid * 7.0 + big * 12.0);
	strata = smoothstep(0.25, 0.75, strata);
	// thin bands turn to moire once they shrink below a pixel
	strata = mix(0.5, strata, 1.0 - smoothstep(70.0, 200.0, dist));
	vec3 rock = mix(rock_a, rock_b, strata * 0.55 + rdg * 0.35);
	rock *= 0.65 + 0.7 * fine;
	float hi = smoothstep(16.0, 90.0, wp.y);
	rock = mix(rock, peak_col * (0.6 + 0.6 * rdg), hi * 0.75);

	float dmix = smoothstep(0.38, 0.62, big + (mid - 0.5) * 0.35);
	vec3 dust = mix(dust_a, dust_b, dmix);
	// pale salt pans pooled in the hollows, darker wind streaks across the dunes
	float pan = smoothstep(0.52, 0.70, fbm(wp.xz * 0.023 + 31.0) + (0.5 - mid) * 0.25) * smoothstep(4.0, -3.0, wp.y);
	dust = mix(dust, salt_col * (0.85 + 0.3 * fine), pan * 0.8);
	float streak = fbm(vec2(wp.x * 0.83 + wp.z * 0.55, wp.x * -0.55 + wp.z * 0.83) * vec2(0.012, 0.11));
	dust *= 0.82 + 0.36 * streak;
	float ripple = sin((wp.x * 0.83 + wp.z * 0.55) * 2.2 + mid * 11.0) * 0.5 + 0.5;
	ripple = ripple * ripple;
	dust *= 0.72 + 0.3 * ripple * lod + 0.5 * (fine - 0.5) * near + 0.2 * (mid - 0.5);
	// scattered dark pebbles close to the camera
	float peb = smoothstep(0.84, 0.92, vnoise(wp.xz * 9.0) * 0.75 + vnoise(wp.xz * 23.0) * 0.25) * near * (1.0 - rockm);
	dust = mix(dust, rock_a * 1.2, peb * 0.8);

	vec3 alb = mix(dust, rock, rockm);

	vec2 vv = voro(wp.xz * 0.085 + vec2(mid, rdg) * 0.5);
	float vmask = smoothstep(0.50, 0.66, fbm(wp.xz * 0.017 + 7.3)) * (1.0 - rockm) * (1.0 - rock_mode);
	float vein = smoothstep(0.036, 0.0, vv.y) * vmask;
	float halo = smoothstep(0.45, 0.0, vv.y) * vmask;
	float pulse = 0.55 + 0.45 * sin(TIME * 1.6 - vv.x * 9.0 + big * 30.0);
	alb = mix(alb, alb * 0.45, halo * 0.4);

	ALBEDO = alb;
	EMISSION = vein_col * (vein * pulse * 1.7 + halo * halo * 0.08) * vein_gain;
	ROUGHNESS = mix(0.96, 0.62, rockm * (0.4 + 0.6 * strata)) - vein * 0.4;
	SPECULAR = 0.35;
	float hgt = (mid * 1.5 + rdg * 0.9) * rockm + fine * 0.11 * near + ripple * 0.07 * (1.0 - rockm) * lod - halo * 0.25 + peb * 0.06;
	NORMAL = bump(VERTEX, NORMAL, hgt, mix(0.5, 1.3, rockm) * lod * bump_gain);
}
