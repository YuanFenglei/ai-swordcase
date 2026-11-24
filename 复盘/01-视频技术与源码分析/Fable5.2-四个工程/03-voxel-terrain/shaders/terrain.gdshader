shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// CUSTOM0: rgb = the three material ids of this triangle, a = corner index (2 bits) | occlusion (6 bits)

uniform vec4 heat_pos[24];
uniform float heat_t0[24];
uniform float time_now = 0.0;
uniform vec3 brush_pos = vec3(0.0, -1000.0, 0.0);
uniform float brush_r = 0.0;
uniform vec3 brush_col : source_color = vec3(1.0, 0.8, 0.4);
uniform float water_level = 24.0;
// generated at startup: rg = slope, a = height
uniform sampler2D tex_rock : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_grass : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_soil : repeat_enable, filter_linear_mipmap_anisotropic;

varying flat vec3 v_ids;
varying vec3 v_bary;
varying float v_ao;
varying vec3 v_gn;

float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float hash13(vec3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }

float vnoise2(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
float vnoise3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), f.x), f.y),
		f.z);
}
// triplanar projection of a 2D pattern; side projections are stretched along the bedding
float tri(vec3 p, vec3 w, vec2 s) {
	float r = 0.0;
	float t = 0.0;
	if (w.x > 0.06) { r += w.x * vnoise2(p.zy * s); t += w.x; }
	if (w.y > 0.06) { r += w.y * vnoise2(p.xz * s.x + 19.7); t += w.y; }
	if (w.z > 0.06) { r += w.z * vnoise2(p.xy * s + 43.1); t += w.z; }
	return r / max(t, 0.001);
}

// rock detail on all three planes; side planes are squashed so features run along the bedding.
// xyz = world-space normal offset, a = height
vec4 tri_rock(vec3 p, vec3 w, float s) {
	vec4 tx = texture(tex_rock, p.zy * vec2(s, s * 2.4));
	vec4 ty = texture(tex_rock, p.xz * s + 0.37);
	vec4 tz = texture(tex_rock, p.xy * vec2(s, s * 2.4) + 0.71);
	vec2 ax = tx.xy * 2.0 - 1.0;
	vec2 ay = ty.xy * 2.0 - 1.0;
	vec2 az = tz.xy * 2.0 - 1.0;
	vec3 o = vec3(0.0, ax.y, ax.x) * w.x + vec3(ay.x, 0.0, ay.y) * w.y + vec3(az.x, az.y, 0.0) * w.z;
	return vec4(o, tx.a * w.x + ty.a * w.y + tz.a * w.z);
}
// ground cover is laid from above
vec4 top_tex(sampler2D t, vec2 uv) {
	vec4 s = texture(t, uv);
	vec2 a = s.xy * 2.0 - 1.0;
	return vec4(a.x, 0.0, a.y, s.a);
}

vec3 strata_pal(float i) {
	float h = hash11(i * 1.37 + 5.0);
	if (h < 0.24) return vec3(0.52, 0.22, 0.12);
	if (h < 0.46) return vec3(0.66, 0.40, 0.20);
	if (h < 0.64) return vec3(0.76, 0.62, 0.46);
	if (h < 0.84) return vec3(0.40, 0.14, 0.10);
	return vec3(0.34, 0.24, 0.31);
}

void vertex() {
	int a = int(CUSTOM0.a * 255.0 + 0.5);
	int corner = a & 3;
	v_ao = float(a >> 2) / 63.0;
	v_ids = floor(CUSTOM0.rgb * 255.0 + 0.5);
	v_bary = vec3(float(corner == 0), float(corner == 1), float(corner == 2));
}

void mat_eval(int id, vec3 p, vec3 n, vec3 vw, float det, float fine, float big, float grain, vec3 nz2, vec3 nz3, float lod, float lod2, float lod3, float rim, vec3 gh, vec2 sh, out vec3 alb, out float rough, out vec3 emi, out float spec) {
	emi = vec3(0.0);
	rough = 0.92;
	spec = 0.3;
	float micro = mix(0.5, nz3.x, lod3);
	vec3 soil = mix(vec3(0.15, 0.09, 0.06), vec3(0.30, 0.19, 0.115), det) * (0.75 + 0.5 * fine);
	soil *= (0.50 + 1.0 * sh.x) * (0.72 + 0.56 * sh.y);
	// layered sandstone: bands follow height with a slow warp
	float t = p.y * 0.19 + (big - 0.5) * 4.0 + (det - 0.5) * 0.35;
	float fi = floor(t);
	float fr = t - fi;
	vec3 rock = mix(strata_pal(fi), strata_pal(fi + 1.0), smoothstep(0.82, 1.0, fr));
	float tl = t * 5.0 + grain * 0.8;
	float lam = fract(tl);
	rock = mix(rock, strata_pal(floor(tl) * 3.0 + 40.0), 0.30);
	rock *= 0.66 + 0.34 * smoothstep(0.0, 0.25, lam) * smoothstep(1.0, 0.75, lam);
	float lam2 = fract(t * 23.0 + grain * 2.0 + nz2.y);
	rock *= 1.0 - 0.16 * lod2 * smoothstep(0.35, 0.0, lam2);
	rock *= 0.70 + 0.6 * mix(0.5, grain, lod * 0.8 + 0.2);
	rock *= 0.85 + 0.3 * fine;
	// hairline cracks and pits close up
	float crk = pow(1.0 - abs(2.0 * nz2.x - 1.0), 10.0) * lod2;
	rock *= 1.0 - 0.22 * crk;
	rock *= 0.82 + 0.36 * micro;
	// embedded stones and pits
	rock = mix(rock, rock * 1.35 + 0.02, smoothstep(0.62, 0.72, nz2.y) * 0.5);
	rock *= 1.0 - 0.35 * smoothstep(0.30, 0.18, nz2.y);
	vec3 sand = mix(vec3(0.56, 0.44, 0.28), vec3(0.74, 0.62, 0.43), fine * 0.7 + 0.15) * (0.85 + 0.3 * micro);
	float beach = smoothstep(water_level + 3.2, water_level + 1.5, p.y + (det - 0.5) * 2.2) * smoothstep(0.3, 0.6, n.y);
	if (id == 0) {
		// macro hue drift, straw patches, then tufts and blades close up
		vec3 g = mix(vec3(0.075, 0.185, 0.06), vec3(0.16, 0.25, 0.07), big);
		float dry = smoothstep(0.52, 0.72, vnoise3(p * 0.09 + 5.0) * 0.7 + det * 0.3);
		g = mix(g, vec3(0.33, 0.30, 0.10), dry * 0.75);
		// clumps at three scales: patches, tufts, blades
		g *= 0.55 + 0.9 * gh.x;
		g *= 0.42 + 1.16 * gh.y;
		g *= mix(1.0, 0.55 + 0.9 * gh.z, lod3);
		// sunlit tips
		g = mix(g, g * vec3(1.55, 1.5, 0.9) + 0.012, smoothstep(0.56, 0.8, gh.y * 0.55 + gh.z * 0.45) * 0.55 * lod2);
		// scattered blossoms
		vec3 fc = floor(p * 2.6);
		float fh = hash13(fc);
		float fl = step(0.988, fh) * lod3 * smoothstep(0.42, 0.1, length(fract(p * 2.6) - 0.5));
		g = mix(g, mix(vec3(0.85, 0.78, 0.55), vec3(0.8, 0.35, 0.45), step(0.994, fh)), fl * (1.0 - dry));
		float bare = smoothstep(0.36, 0.24, gh.x * 0.55 + det * 0.45);
		float sl = smoothstep(0.62, 0.78, n.y + (det - 0.5) * 0.2 + (gh.y - 0.5) * 0.28) * (1.0 - bare * 0.9);
		alb = mix(mix(rock, soil, smoothstep(0.25, 0.5, n.y)), g, sl);
		alb = mix(alb, sand, beach);
		rough = 0.95;
	} else if (id == 1) {
		alb = mix(rock, soil, smoothstep(0.25, 0.6, n.y + (det - 0.5) * 0.3) * 0.75 + 0.12);
		alb = mix(alb, alb * 1.5 + 0.03, smoothstep(0.66, 0.74, sh.y) * 0.45 * lod2);
		alb = mix(alb, sand, beach);
	} else if (id == 2) {
		alb = rock;
		rough = 0.84;
	} else if (id == 3) {
		alb = mix(vec3(0.04, 0.047, 0.07), vec3(0.12, 0.125, 0.16), det) * (0.75 + 0.5 * grain) * (0.8 + 0.4 * micro);
		alb *= 1.0 - 0.5 * crk;
		rough = 0.5;
		spec = 0.55;
	} else if (id == 4) {
		float v1 = vnoise3(p * 1.25 + 3.0);
		float v2 = vnoise3(p * 3.1 + 11.0);
		float vein = pow(1.0 - abs(2.0 * v1 - 1.0), 18.0) + 0.5 * pow(1.0 - abs(2.0 * v2 - 1.0), 20.0);
		vein = min(vein, 1.1);
		float pulse = 0.78 + 0.22 * sin(time_now * 1.7 + p.x * 0.21 + p.y * 0.33 + p.z * 0.17);
		alb = mix(rock * 0.36, vec3(0.03, 0.22, 0.2), min(vein, 1.0));
		emi = vec3(0.0, 0.78, 0.58) * (vein * 2.0 + 0.02) * pulse;
		rough = mix(0.7, 0.25, min(vein, 1.0));
		spec = 0.5;
	} else if (id == 5) {
		// crystal: dark glassy shell, light comes from layers that shift with the view
		float in1 = vnoise3((p + vw * 1.6) * 0.75);
		float in2 = vnoise3((p + vw * 4.5) * 0.36 + 9.0);
		float core = pow(in2, 1.6) * (0.4 + 0.9 * in1);
		float vein = pow(1.0 - abs(2.0 * vnoise3((p + vw * 0.7) * vec3(0.9, 0.22, 0.9)) - 1.0), 5.0);
		alb = vec3(0.05, 0.015, 0.11);
		emi = mix(vec3(0.16, 0.02, 0.70), vec3(0.90, 0.12, 0.55), in1) * (0.05 + 1.1 * core);
		emi += vec3(0.9, 0.4, 1.0) * vein * 0.3;
		emi += vec3(0.6, 0.25, 1.0) * rim * 0.9;
		rough = 0.06;
		spec = 1.0;
	} else {
		float rip = sin(p.x * 1.3 + p.z * 0.9 + det * 6.0) * 0.5 + 0.5;
		alb = mix(vec3(0.56, 0.44, 0.28), vec3(0.74, 0.62, 0.43), rip * 0.35 + fine * 0.65) * (0.85 + 0.3 * micro);
		rough = 0.9;
	}
}

void fragment() {
	vec3 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 vn = normalize(NORMAL);
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(vn, 0.0)).xyz);
	float vdist = length(VERTEX);
	vec3 vw = normalize((INV_VIEW_MATRIX * vec4(VERTEX / max(vdist, 0.001), 0.0)).xyz);
	float lod = smoothstep(190.0, 30.0, vdist);
	float lod2 = smoothstep(80.0, 14.0, vdist);
	float lod3 = smoothstep(30.0, 5.0, vdist);
	vec3 tw = pow(abs(n), vec3(4.0));
	tw /= (tw.x + tw.y + tw.z);
	// turf follows the real facet slope, so it never smears down a freshly cut lip
	float ny_geo = abs(normalize(cross(dFdx(p), dFdy(p))).y);
	vec3 nm = vec3(n.x, min(n.y, mix(n.y, ny_geo, 0.85)), n.z);
	float big = vnoise3(p * 0.03);
	// two scales of rock, three of turf, two of earth; scale ratios are irrational-ish so tiling never lines up
	vec4 r1 = tri_rock(p, tw, 0.083);
	vec4 r2 = tri_rock(p, tw, 0.47);
	vec4 g1 = top_tex(tex_grass, p.xz * 0.061);
	vec4 g2 = top_tex(tex_grass, p.xz * 0.37 + 0.31);
	vec4 g3 = top_tex(tex_grass, p.xz * 1.93 + 0.67);
	vec4 s1 = top_tex(tex_soil, p.xz * 0.13 + 0.11);
	vec4 s2 = top_tex(tex_soil, p.xz * 0.71 + 0.53);
	vec3 gh = vec3(g1.a, g2.a, g3.a);
	float flatk = smoothstep(0.35, 0.65, n.y);
	vec2 sh = mix(vec2(r1.a, r2.a), vec2(s1.a, s2.a), flatk);
	vec3 nz = vec3(r1.a, r2.a, r1.a * 0.5 + r2.a * 0.5);
	vec3 nz2 = vec3(r2.a, r1.a, s2.a);
	vec3 nz3 = vec3(r2.a, g3.a, g2.a);
	float fine = mix(0.5, r1.a * 0.4 + r2.a * 0.6, lod);
	float det = tri(p, tw, vec2(0.27, 0.27)) * 0.62 + r1.a * 0.38;
	float grain = tri(p, tw, vec2(0.6, 3.1)) * 0.5 + r1.a * 0.5;

	vec3 w = v_bary;
	// break the per-triangle material borders with surface detail instead of smooth blobs
	w = max(w + (vec3(det, grain, 1.0 - det) - 0.5) * 0.3 + (vec3(g2.a, r2.a, s2.a) - 0.5) * 0.55, vec3(0.0));
	w = w * w;
	w /= (w.x + w.y + w.z + 1e-5);

	float rim = pow(1.0 - clamp(dot(vn, normalize(-VERTEX)), 0.0, 1.0), 3.0);
	vec3 alb; float rough; vec3 emi; float spec;
	ivec3 ids = ivec3(v_ids + 0.5);
	float crystal = 0.0;
	if (ids.x == ids.y && ids.y == ids.z) {
		mat_eval(ids.x, p, nm, vw, det, fine, big, grain, nz2, nz3, lod, lod2, lod3, rim, gh, sh, alb, rough, emi, spec);
		crystal = float(ids.x == 5);
	} else {
		vec3 a0; float r0; vec3 e0; float s0;
		alb = vec3(0.0); rough = 0.0; emi = vec3(0.0); spec = 0.0;
		mat_eval(ids.x, p, nm, vw, det, fine, big, grain, nz2, nz3, lod, lod2, lod3, rim, gh, sh, a0, r0, e0, s0);
		alb += a0 * w.x; rough += r0 * w.x; emi += e0 * w.x; spec += s0 * w.x;
		mat_eval(ids.y, p, nm, vw, det, fine, big, grain, nz2, nz3, lod, lod2, lod3, rim, gh, sh, a0, r0, e0, s0);
		alb += a0 * w.y; rough += r0 * w.y; emi += e0 * w.y; spec += s0 * w.y;
		mat_eval(ids.z, p, nm, vw, det, fine, big, grain, nz2, nz3, lod, lod2, lod3, rim, gh, sh, a0, r0, e0, s0);
		alb += a0 * w.z; rough += r0 * w.z; emi += e0 * w.z; spec += s0 * w.z;
		crystal = float(ids.x == 5) * w.x + float(ids.y == 5) * w.y + float(ids.z == 5) * w.z;
	}

	float ao = smoothstep(0.0, 0.92, v_ao);
	float glow = step(0.001, emi.r + emi.g + emi.b);

	// snow on exposed high ground
	float snow = smoothstep(96.0, 108.0, p.y + (big - 0.5) * 30.0 + (det - 0.5) * 8.0) * smoothstep(0.38, 0.62, n.y + (grain - 0.5) * 0.2) * smoothstep(0.55, 0.85, ao) * (1.0 - glow);
	alb = mix(alb, vec3(0.80, 0.84, 0.92) * (0.88 + 0.12 * fine) * (0.9 + 0.2 * mix(0.5, nz3.x, lod3)), snow);
	rough = mix(rough, 0.5, snow);

	// enclosed rock is damp: darker, cooler, glossy
	float cave = (1.0 - smoothstep(0.3, 0.72, ao)) * (1.0 - crystal) * (1.0 - glow * 0.5);
	float drip = smoothstep(0.35, 0.75, nz.z * 0.6 + grain * 0.4);
	alb = mix(alb, vec3(dot(alb, vec3(0.4, 0.4, 0.2))) * vec3(0.55, 0.6, 0.78), cave * 0.75);
	rough = mix(rough, mix(0.5, 0.3, drip), cave * 0.85);
	spec = mix(spec, 0.75, cave * 0.8);

	// wet / submerged
	float wet = smoothstep(water_level + 1.6, water_level + 0.2, p.y + (det - 0.5) * 1.2);
	alb *= mix(1.0, 0.55, wet);
	rough = mix(rough, 0.3, wet * 0.8);
	alb *= mix(vec3(1.0), vec3(0.40, 0.70, 0.70), smoothstep(water_level, water_level - 7.0, p.y));

	// fresh craters: shock ring, scorch, heat that cools down
	float heat = 0.0;
	float scorch = 0.0;
	float ring = 0.0;
	for (int i = 0; i < 24; i++) {
		float age = time_now - heat_t0[i];
		if (age < 0.0 || age > 90.0) continue;
		vec4 hp = heat_pos[i];
		float dc = length(p - hp.xyz);
		if (age < 0.45) {
			float rr = hp.w * 0.8 + age * 95.0;
			ring += smoothstep(1.0 + age * 5.0, 0.0, abs(dc - rr)) * (1.0 - age / 0.45) * (1.0 - age / 0.45);
		}
		float d = dc - hp.w;
		if (d > 8.0) continue;
		float shell = smoothstep(hp.w * 0.3 + 1.5, -1.5, d);
		heat += shell * exp(-age * 0.55);
		scorch = max(scorch, smoothstep(hp.w * 0.5 + 3.5, -0.5, d) * exp(-age * 0.022));
	}
	alb = mix(alb, vec3(0.022, 0.02, 0.02), scorch * 0.9);
	rough = mix(rough, 0.7, scorch);
	if (heat > 0.002) {
		float crack = pow(1.0 - abs(2.0 * tri(p, tw, vec2(0.5, 0.5)) - 1.0), 4.0);
		heat = clamp(heat, 0.0, 1.5);
		float hk = heat * (0.12 + 1.1 * crack * (0.6 + 0.8 * fine)) + pow(heat, 3.0) * 0.5;
		emi += mix(vec3(1.0, 0.07, 0.0), vec3(1.0, 0.50, 0.14), clamp(hk * 0.8, 0.0, 1.0)) * hk * 3.2;
	}
	emi += vec3(1.0, 0.66, 0.36) * min(ring, 1.0) * 0.7;

	// brush ring
	float bd = abs(length(p - brush_pos) - brush_r);
	emi += brush_col * smoothstep(clamp(vdist * 0.012, 0.05, 0.3), 0.0, bd) * 2.5 * step(0.01, brush_r);

	// surface relief: three octaves of vector noise tilt the normal, bedding planes add ledges
	vec3 idf = vec3(ids);
	float share_g = dot(w, vec3(equal(idf, vec3(0.0))));
	float share_s = dot(w, vec3(equal(idf, vec3(1.0)))) + dot(w, vec3(equal(idf, vec3(6.0))));
	float bare = smoothstep(0.36, 0.24, gh.x * 0.55 + det * 0.45);
	float turf = share_g * smoothstep(0.62, 0.78, nm.y + (det - 0.5) * 0.2 + (gh.y - 0.5) * 0.28) * (1.0 - bare * 0.9);
	float earth = share_g - turf + share_s;
	float stone = clamp(1.0 - turf - earth, 0.0, 1.0);
	vec3 b_rock = r1.xyz * 1.5 + r2.xyz * 1.2 * lod2;
	vec3 b_turf = g1.xyz * 0.5 + g2.xyz * 1.3 * lod2 + g3.xyz * 1.0 * lod3;
	vec3 b_earth = mix(r1.xyz * 1.2 + r2.xyz * 1.0 * lod2, s1.xyz * 1.1 + s2.xyz * 1.1 * lod2, flatk);
	vec3 bump = b_rock * stone * (1.0 - cave * 0.4) + b_turf * turf + b_earth * earth;
	float ledge = (fract((p.y * 0.19 + (big - 0.5) * 4.0) * 5.0 + grain * 0.8) - 0.5) * (1.0 - abs(n.y));
	bump.y += ledge * 1.1;
	vec3 wn2 = normalize(n + bump * lod * (1.0 - snow * 0.6) * (1.0 - crystal));
	vec3 vnn = normalize((VIEW_MATRIX * vec4(wn2, 0.0)).xyz);
	if (crystal > 0.5) {
		// cut-gem facets from the triangle planes
		vec3 nf = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
		if (dot(nf, VERTEX) > 0.0) nf = -nf;
		vnn = normalize(mix(vn, nf, 0.8));
	}
	v_gn = vn;
	NORMAL = vnn;

	ALBEDO = alb * mix(0.7, 1.0, ao);
	ROUGHNESS = rough;
	SPECULAR = spec * mix(ao, 1.0, cave);
	EMISSION = emi;
	AO = mix(0.015, 1.0, ao * ao);
	AO_LIGHT_AFFECT = 0.1;
}

void light() {
	// fade direct light out where the true surface grazes the light: kills shadow acne on
	// walls parallel to the sun (bored tunnels) without touching the bumped shading
	float geo = smoothstep(0.02, 0.24, dot(v_gn, LIGHT));
	float ndl = clamp(dot(NORMAL, LIGHT) * 0.9 + 0.1, 0.0, 1.0);
	vec3 li = LIGHT_COLOR * ATTENUATION * geo;
	DIFFUSE_LIGHT += li * ndl / PI;
	vec3 h = normalize(VIEW + LIGHT);
	float gloss = 1.0 - ROUGHNESS;
	float s = pow(max(dot(NORMAL, h), 0.0), 6.0 + 220.0 * gloss * gloss);
	SPECULAR_LIGHT += li * s * gloss * gloss * (0.5 + 1.0 * gloss * gloss) * ndl;
}
