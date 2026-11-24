#[compute]
#version 450

// Density + material field for the whole world, evaluated once on the GPU.
// density byte: 127.5 + signed_distance_in_voxels * 32 (solid >= 128)

#ifdef PASS_HEIGHT
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D height_img;
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(r8ui, set = 0, binding = 0) uniform restrict writeonly uimage3D dens_img;
layout(r8ui, set = 0, binding = 1) uniform restrict writeonly uimage3D mat_img;
layout(set = 0, binding = 2) uniform sampler2D height_tex;
#endif

layout(push_constant, std430) uniform Params {
	ivec4 offset;
} pc;

const float HM_PAD = 24.0;
const float HM_SIZE = 560.0;

const float WL = 24.0;

const int M_GRASS = 0;
const int M_SOIL = 1;
const int M_ROCK = 2;
const int M_BASALT = 3;
const int M_ORE = 4;
const int M_CRYSTAL = 5;
const int M_SAND = 6;

float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float hash13(vec3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }

float vnoise2(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}
float vnoise3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}
float fbm2(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 5; i++) { s += a * vnoise2(p); p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + vec2(17.1, 9.3); a *= 0.5; }
	return s / 0.96875;
}
float fbm3(vec3 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 3; i++) { s += a * vnoise3(p); p = p * 2.03 + vec3(13.7, 7.1, 21.3); a *= 0.5; }
	return s / 0.875;
}
float sd_seg2(vec2 p, vec2 a, vec2 b) { vec2 pa = p - a; vec2 ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h); }
float sd_seg3(vec3 p, vec3 a, vec3 b) { vec3 pa = p - a; vec3 ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h); }

#ifdef PASS_HEIGHT
vec2 terrain_h(vec2 q) {
	float r = length(q - vec2(256.0)) + (fbm2(q * 0.011 + 5.0) - 0.5) * 90.0;
	float mask = smoothstep(238.0, 182.0, r);
	// lowland + terraced highland
	float h = 31.0 + 7.0 * fbm2(q * 0.012 + 3.7);
	float v = smoothstep(0.34, 0.70, fbm2(q * 0.0078 + 13.7));
	float tv = v * 3.0;
	float ti = floor(tv);
	float ter = (ti + smoothstep(0.40, 0.60, tv - ti)) / 3.0;
	h += mix(v, ter, 0.86) * 36.0;
	h += (fbm2(q * 0.045 + 11.0) - 0.5) * 5.0;
	// mountain
	float md = length((q - vec2(165.0, 165.0)) * vec2(1.0, 0.9));
	float rid = 1.0 - abs(2.0 * fbm2(q * 0.021 + 7.0) - 1.0);
	float mh = exp(-md * md / (54.0 * 54.0));
	float peak = pow(mh, 1.25) * (62.0 + 52.0 * rid * rid) + (fbm2(q * 0.07 + 2.0) - 0.5) * 16.0 * mh;
	h = mix(h, 40.0, mh * 0.8) + peak;
	h -= max(h - 138.0, 0.0) * 0.55;
	// roof above the crystal cavern
	float cd = length(q - vec2(232.0, 285.0));
	h = mix(h, max(h, 64.0), smoothstep(70.0, 42.0, cd));
	// mesa
	float dm = length(q - vec2(372.0, 160.0)) + (fbm2(q * 0.03 + 21.0) - 0.5) * 28.0;
	float mm = smoothstep(56.0, 50.0, dm);
	h = mix(h, 66.0 + (fbm2(q * 0.06) - 0.5) * 1.0, mm);
	// plain
	float dp = length(q - vec2(400.0, 335.0));
	float pm = smoothstep(85.0, 52.0, dp) * 0.94;
	h = mix(h, 45.0 + (fbm2(q * 0.03 + 40.0) - 0.5) * 3.0, pm);
	float flatm = max(mm, pm);
	// fjord gorge
	float dg = min(sd_seg2(q, vec2(30.0, 420.0), vec2(105.0, 392.0)), min(sd_seg2(q, vec2(105.0, 392.0), vec2(150.0, 352.0)), sd_seg2(q, vec2(150.0, 352.0), vec2(172.0, 318.0))));
	dg += (fbm2(q * 0.05 + 60.0) - 0.5) * 9.0;
	h = mix(WL - 8.0, h, smoothstep(8.0, 19.0, dg));
	h = mix(WL - 15.0, h, mask);
	return vec2(h, flatm);
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	vec2 th = terrain_h(vec2(id) - HM_PAD);
	imageStore(height_img, id, vec4(th, 0.0, 0.0));
}
#else

float island(vec3 p, vec4 c) {
	vec3 l = p - c.xyz;
	float R = c.w;
	if (dot(l, l) > R * R * 4.0) return -1e3;
	float rr = length(l.xz) / R;
	float top = (fbm2(p.xz * 0.06 + c.x) - 0.5) * 7.0 - l.y;
	float bot = l.y + R * 1.25 * pow(max(1.0 - rr, 0.0), 0.75) + (fbm3(p * 0.09 + c.y) - 0.5) * 12.0 - 2.0;
	float rim = (1.0 - rr) * R * 0.8 + (fbm3(p * 0.11) - 0.5) * 5.0;
	return min(top, min(bot, rim));
}

float arch(vec3 p, vec3 c, vec2 dir, float Rm, float rm) {
	vec2 l = p.xz - c.xz;
	float u = dot(l, dir);
	float w = dot(l, vec2(-dir.y, dir.x));
	float v = p.y - c.y;
	if (abs(u) > Rm + rm + 8.0 || abs(w) > rm + 8.0) return -1e3;
	float n = (fbm3(p * 0.14) - 0.5) * 3.0;
	float dd;
	if (v > 0.0) dd = length(vec2(length(vec2(u, v)) - Rm, w));
	else dd = length(vec2(abs(u) - Rm, w));
	return rm + n - dd;
}

const vec3 CAV = vec3(232.0, 33.0, 285.0);
const vec3 CAVR = vec3(34.0, 14.0, 28.0);

float cave_sd(vec3 p) {
	float c = 1e3;
	if (p.y < 112.0 && p.x > 100.0 && p.x < 345.0 && p.z > 215.0 && p.z < 450.0) {
		vec3 q = p + (vec3(vnoise3(p * 0.11), vnoise3(p * 0.11 + 13.0), vnoise3(p * 0.11 + 29.0)) - 0.5) * 5.0;
		float t = sd_seg3(q, vec3(314, 106, 424), vec3(288, 46, 374));
		t = min(t, sd_seg3(q, vec3(288, 46, 374), vec3(266, 37, 348)));
		t = min(t, sd_seg3(q, vec3(266, 37, 348), vec3(250, 35, 322)));
		t = min(t, sd_seg3(q, vec3(250, 35, 322), vec3(238, 34, 302)));
		t = min(t, sd_seg3(q, vec3(224, 34, 272), vec3(205, 36, 252)));
		t = min(t, sd_seg3(q, vec3(205, 36, 252), vec3(178, 42, 248)));
		t = min(t, sd_seg3(q, vec3(178, 42, 248), vec3(150, 56, 258)));
		t = min(t, sd_seg3(q, vec3(150, 56, 258), vec3(128, 76, 262)));
		c = t - 6.0;
		vec3 l = (q - CAV) / CAVR;
		c = min(c, (length(l) - 1.0) * 14.0);
		float rm = smoothstep(125.0, 85.0, length(p.xz - vec2(250.0, 300.0))) * smoothstep(66.0, 50.0, p.y) * smoothstep(8.0, 14.0, p.y);
		if (rm > 0.0) {
			float n1 = fbm3(p * 0.03 + 3.0);
			float n2 = fbm3(p * vec3(0.03, 0.045, 0.03) + 57.0);
			c = min(c, (max(abs(n1 - 0.5), abs(n2 - 0.5)) - 0.055 * rm) * 45.0);
		}
	}
	return c;
}

float crystal_sd(vec3 p) {
	vec3 lc = p - CAV;
	if (dot(lc, lc) > 50.0 * 50.0) return -1e3;
	float k = -1e3;
	for (int i = 0; i < 26; i++) {
		float fi = float(i / 2);
		bool side = (i % 2) == 1;
		float a = fi * 2.399 + 0.4;
		float rr = 13.0 + 17.0 * hash11(fi * 7.13 + 1.0);
		vec2 dxz = vec2(cos(a), sin(a));
		if (dot(dxz, vec2(0.33, 0.94)) > 0.72 || dot(dxz, vec2(-0.52, -0.85)) > 0.72) continue;
		bool up = (i / 2) % 3 != 2;
		float ex = rr / 34.0;
		float dy = 14.0 * sqrt(max(1.0 - ex * ex, 0.05));
		float tilt = side ? 1.5 : 0.45;
		vec3 dir = normalize(vec3((hash11(fi * 3.7 + 2.0 + float(i)) - 0.5) * tilt + dxz.x * (side ? 0.5 : 0.1), up ? 1.0 : -1.0, (hash11(fi * 5.3 + 4.0 + float(i)) - 0.5) * tilt + dxz.y * (side ? 0.5 : 0.1)));
		vec3 base = vec3(CAV.x + dxz.x * rr, CAV.y + (up ? -dy : dy), CAV.z + dxz.y * rr * 0.82) - dir * 3.0;
		float len = up ? 17.0 + 13.0 * hash11(fi * 9.1) : 9.0 + 6.0 * hash11(fi * 9.1);
		float r0 = 1.9 + 1.5 * hash11(fi * 2.3 + 8.0);
		if (side) { len *= 0.6; r0 *= 0.62; }
		vec3 pa = p - base;
		float h = clamp(dot(pa, dir) / len, 0.0, 1.0);
		vec3 q = pa - dir * len * h;
		vec3 u = normalize(cross(dir, vec3(0.31, 0.1, 0.94)));
		vec3 v = cross(dir, u);
		float ang = fi * 1.3;
		vec2 hx = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang))) * vec2(dot(q, u), dot(q, v));
		hx = abs(hx);
		float hd = max(hx.x * 0.866 + hx.y * 0.5, hx.y) + length(q - u * dot(q, u) - v * dot(q, v));
		float rad = r0 * (1.0 - 0.25 * h) * (1.0 - 0.96 * smoothstep(0.78, 1.0, h));
		k = max(k, rad - hd);
	}
	return k;
}

float spires(vec3 p) {
	const float C = 34.0;
	vec2 cell = floor(p.xz / C);
	float d = -1e3;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = cell + vec2(float(i), float(j));
			float h1 = hash12(c + 3.1);
			// stands of spires with clearings between them
			if (vnoise2(c * 0.37 + 4.0) < 0.42 || h1 > 0.8) continue;
			vec2 ctr = (c + 0.15 + 0.7 * vec2(hash12(c + 17.7), hash12(c + 41.3))) * C;
			float kind = hash12(c + 61.9);
			float R = 2.6 + 6.0 * hash12(c + 7.9) * hash12(c + 9.9);
			float H = 12.0 + 44.0 * hash12(c + 23.5) * (0.4 + 0.6 * kind);
			vec2 lean = (vec2(hash12(c + 71.0), hash12(c + 83.0)) - 0.5) * 0.3;
			vec2 hb = textureLod(height_tex, (ctr + HM_PAD + 0.5) / HM_SIZE, 0.0).xy;
			float y = p.y - hb.x;
			vec2 dl = p.xz - ctr - lean * max(y, 0.0);
			float lim = R * 2.6 + 5.0;
			if (dot(dl, dl) > lim * lim) continue;
			if (hb.x < WL + 5.0 || hb.x > 74.0 || hb.y > 0.03) continue;
			if (length(ctr - vec2(165.0)) < 92.0) continue;
			if (length(ctr - vec2(410.0, 410.0)) < 80.0) continue;
			if (length(ctr - vec2(302.0, 405.0)) < 42.0) continue;
			if (length(ctr - vec2(372.0, 160.0)) < 74.0) continue;
			if (length(ctr - vec2(318.0, 238.0)) < 44.0) continue;
			float dg = min(sd_seg2(ctr, vec2(30.0, 420.0), vec2(105.0, 392.0)), min(sd_seg2(ctr, vec2(105.0, 392.0), vec2(150.0, 352.0)), sd_seg2(ctr, vec2(150.0, 352.0), vec2(172.0, 318.0))));
			if (dg < 34.0) continue;
			float t = y / H;
			if (t > 1.3) continue;
			float prof;
			if (kind > 0.55) {
				// hoodoo: waisted column under a hard cap
				prof = mix(1.0, 0.5, clamp(t, 0.0, 1.0));
				prof += (0.5 + 0.9 * hash12(c + 5.5)) * smoothstep(0.68, 0.84, t) * smoothstep(1.02, 0.9, t);
				prof -= 0.18 * sin(t * 19.0 + h1 * 30.0) * smoothstep(0.1, 0.3, t) * smoothstep(0.7, 0.6, t);
			} else {
				// pinnacle / fin
				prof = pow(max(1.0 - t, 0.0), 0.6) * 1.15 + 0.12 * sin(t * 13.0 + h1 * 20.0);
			}
			prof *= 1.0 + 1.1 * smoothstep(0.22, -0.3, t);
			float n = (fbm3(p * vec3(0.12, 0.32, 0.12) + h1 * 50.0) - 0.5) * 3.4;
			float stretch = kind > 0.55 ? 1.0 : mix(1.0, 2.2, hash12(c + 91.0));
			vec2 de = vec2(dl.x * cos(h1 * 6.0) + dl.y * sin(h1 * 6.0), (-dl.x * sin(h1 * 6.0) + dl.y * cos(h1 * 6.0)) * stretch);
			float dd = R * prof + n - length(de);
			dd = min(dd, (H - y) * 0.9 + 1.0);
			d = max(d, dd);
		}
	}
	return d;
}

// x: density with caves, y: density without caves
vec2 map(vec3 p) {
	vec2 h0 = textureLod(height_tex, (p.xz + HM_PAD + 0.5) / HM_SIZE, 0.0).xy;
	float d;
	if (abs(h0.x - p.y) > 34.0) {
		d = h0.x - p.y;
	} else {
		vec3 wp = p * vec3(0.045, 0.07, 0.045);
		vec2 w = (vec2(fbm3(wp), fbm3(wp + 31.7)) - 0.5) * 24.0 * smoothstep(WL - 4.0, WL + 8.0, p.y);
		vec2 th = textureLod(height_tex, (p.xz + w + HM_PAD + 0.5) / HM_SIZE, 0.0).xy;
		d = th.x - p.y;
		d += (fbm3(p * 0.085 + 7.0) - 0.5) * 3.0 * (1.0 - th.y);
	}
	if (p.y > 84.0) {
		d = max(d, island(p, vec4(120.0, 118.0, 410.0, 26.0)));
		d = max(d, island(p, vec4(88.0, 136.0, 335.0, 18.0)));
		d = max(d, island(p, vec4(278.0, 140.0, 236.0, 22.0)));
		d = max(d, island(p, vec4(432.0, 124.0, 405.0, 24.0)));
		d = max(d, island(p, vec4(300.0, 132.0, 88.0, 20.0)));
		d = max(d, island(p, vec4(455.0, 140.0, 215.0, 15.0)));
	}
	if (p.y > WL && p.y < 128.0 && h0.x - p.y < 12.0) d = max(d, spires(p));
	d = max(d, arch(p, vec3(128.0, 44.0, 372.0), vec2(0.66, 0.75), 22.0, 4.5));
	d = max(d, arch(p, vec3(72.0, 36.0, 405.0), vec2(0.33, 0.94), 19.0, 4.0));
	d = max(d, arch(p, vec3(318.0, 50.0, 238.0), vec2(0.8, 0.6), 27.0, 6.0));
	d = min(d, 156.5 - p.y);
	float dn = d;
	d = min(d, cave_sd(p));
	d = max(d, crystal_sd(p));
	return vec2(d, dn);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID) + pc.offset.xyz;
	vec3 p = vec3(id);
	vec2 m = map(p);
	float d = m.x;
	int mat = M_ROCK;
	bool top = false;
	if (abs(d) < 9.0) {
		vec3 g = vec3(map(p + vec3(1, 0, 0)).x, map(p + vec3(0, 1, 0)).x, map(p + vec3(0, 0, 1)).x) - d;
		float gl = length(g);
		d = d / max(gl, 0.75);
		if (d > -5.0 && d < 7.5) {
			vec3 nrm = -g / max(gl, 0.001);
			if (crystal_sd(p) > -1.6) {
				mat = M_CRYSTAL;
				top = true;
			} else if (map(p + nrm * 2.7).y < 0.0) {
				mat = M_GRASS;
				top = true;
			} else if (map(p + nrm * 6.5).y < 0.0) {
				mat = M_SOIL;
				top = true;
			}
		}
	}
	if (!top) {
		mat = p.y < 19.0 + (vnoise3(p * 0.05) - 0.5) * 10.0 ? M_BASALT : M_ROCK;
		if (m.y > 4.0 && p.y < 84.0) {
			float on = abs(fbm3(p * 0.06 + 91.0) - 0.5);
			float om = vnoise3(p * 0.025 + 44.0);
			if (on < 0.03 && om > 0.57) mat = M_ORE;
		}
	}
	uint dv = uint(clamp(128.0 + d * 32.0, 0.0, 255.0));
	imageStore(dens_img, id, uvec4(dv, 0u, 0u, 0u));
	imageStore(mat_img, id, uvec4(uint(mat), 0u, 0u, 0u));
}
#endif
