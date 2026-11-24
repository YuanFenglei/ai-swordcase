#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0, std140) uniform FX {
	mat4 view;
	mat4 inv_view;
	vec4 proj;      // P00, P11, P22, P32
	vec4 screen;    // w, h, time, wipe
	vec4 grid_org;  // origin xyz, dx
	vec4 grid_dim;  // dims xyz, rest density
	vec4 sun;       // dir xyz (towards sun), intensity
	vec4 absorb_a;  // rgb absorption / metre, w scatter density
	vec4 absorb_b;
	vec4 scat_a;    // rgb scatter colour, w unused
	vec4 scat_b;
	vec4 misc;      // foam strength, refraction strength, radius, debug
} fx;
layout(set = 0, binding = 1) uniform sampler2D depth_smooth;
layout(set = 0, binding = 2) uniform sampler2D depth_raw;
layout(set = 0, binding = 3) uniform sampler2D aux;
layout(set = 0, binding = 4) uniform sampler2D scene_copy;
layout(set = 0, binding = 5) uniform sampler2D scene_depth;
layout(set = 0, binding = 6) uniform sampler3D density;
layout(set = 0, binding = 7, rgba16f) uniform restrict writeonly image2D out_color;

#include "env.inc"

vec3 vpos(vec2 uv, float z) {
	vec2 ndc = uv * 2.0 - 1.0;
	return vec3(ndc.x * z / fx.proj.x, ndc.y * z / fx.proj.y, -z);
}
float sceneZ(vec2 uv) {
	float d = textureLod(scene_depth, uv, 0.0).r;
	return fx.proj.w / max(d + fx.proj.z, 1e-7);
}
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}
vec3 speedRamp(float s) {
	vec3 a = vec3(0.02, 0.10, 0.55), b = vec3(0.0, 0.62, 0.95), c = vec3(0.75, 1.0, 0.95), d = vec3(1.0);
	if (s < 0.33) return mix(a, b, s / 0.33);
	if (s < 0.66) return mix(b, c, (s - 0.33) / 0.33);
	return mix(c, d, (s - 0.66) / 0.34);
}
vec3 speedRampB(float s) {
	vec3 a = vec3(0.50, 0.02, 0.30), b = vec3(1.0, 0.25, 0.45), c = vec3(1.0, 0.8, 0.6);
	if (s < 0.5) return mix(a, b, s / 0.5);
	return mix(b, c, (s - 0.5) / 0.5);
}

void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(fx.screen.xy);
	if (pix.x >= size.x || pix.y >= size.y) return;
	vec2 uv = (vec2(pix) + 0.5) / vec2(size);
	vec2 px = 1.0 / vec2(size);
	float wipe = fx.screen.w;
	float edge = uv.x + (uv.y - 0.5) * 0.18 - wipe;
	bool liquid = edge < 0.0;
	float zscene = sceneZ(uv);
	vec3 L = normalize(fx.sun.xyz);
	vec3 cam = fx.inv_view[3].xyz;
	vec3 line = vec3(0.6, 0.95, 1.0) * 6.0 * smoothstep(0.004, 0.0, abs(edge)) * step(-0.19, wipe) * step(wipe, 1.19);

	if (!liquid) {
		float z = texelFetch(depth_raw, pix, 0).r;
		if (z > 9.0e4 || z > zscene) {
			if (dot(line, line) > 0.0) imageStore(out_color, pix, vec4(texelFetch(scene_copy, pix, 0).rgb + line, 1.0));
			return;
		}
		vec4 a = texelFetch(aux, pix, 0);
		vec3 n = vec3(a.xy, sqrt(max(1.0 - dot(a.xy, a.xy), 0.0)));
		vec3 N = normalize(mat3(fx.inv_view) * n);
		float sp = fract(a.z);
		vec3 base = a.z >= 1.0 ? speedRampB(sp * 1.02) : speedRamp(sp * 1.02);
		base = mix(base, vec3(1.0), a.w * 0.6);
		float ndl = max(dot(N, L), 0.0);
		vec3 V = normalize(cam - (fx.inv_view * vec4(vpos(uv, z), 1.0)).xyz);
		vec3 H = normalize(L + V);
		vec3 col = base * (0.28 + 0.9 * ndl) + vec3(1.0) * pow(max(dot(N, H), 0.0), 60.0) * 0.6;
		col += base * pow(1.0 - n.z, 3.0) * 0.5;
		imageStore(out_color, pix, vec4(col + line, 1.0));
		return;
	}

	float z = texelFetch(depth_smooth, pix, 0).r;
	if (z > 9.0e4 || z > zscene) {
		if (dot(line, line) > 0.0) imageStore(out_color, pix, vec4(texelFetch(scene_copy, pix, 0).rgb + line, 1.0));
		return;
	}
	vec3 Pv = vpos(uv, z);
	float zl = texelFetch(depth_smooth, pix - ivec2(1, 0), 0).r;
	float zr = texelFetch(depth_smooth, pix + ivec2(1, 0), 0).r;
	float zu = texelFetch(depth_smooth, pix - ivec2(0, 1), 0).r;
	float zd = texelFetch(depth_smooth, pix + ivec2(0, 1), 0).r;
	vec3 ddx = abs(zr - z) < abs(z - zl) ? vpos(uv + vec2(px.x, 0.0), zr) - Pv : Pv - vpos(uv - vec2(px.x, 0.0), zl);
	vec3 ddy = abs(zd - z) < abs(z - zu) ? vpos(uv + vec2(0.0, px.y), zd) - Pv : Pv - vpos(uv - vec2(0.0, px.y), zu);
	vec3 n = normalize(cross(ddy, ddx));
	if (n.z < 0.0) n = -n;
	vec3 N = normalize(mat3(fx.inv_view) * n);
	vec3 W = (fx.inv_view * vec4(Pv, 1.0)).xyz;
	vec3 V = normalize(cam - W);
	float ndv = max(dot(N, V), 0.0);

	// thickness + dye by marching the density volume
	float dx = fx.grid_org.w;
	vec3 rd = refract(-V, N, 1.0 / 1.33);
	if (dot(rd, rd) < 0.5) rd = -V;
	rd = normalize(mix(-V, rd, 0.5));
	float maxDist = (zscene - z) / max(dot(-V, -normalize(fx.inv_view[2].xyz)), 0.05);
	float stepW = dx * 1.8;
	float t = stepW * (0.3 + ign(vec2(pix)));
	float thick = 0.0, dyeAcc = 0.0;
	vec3 invDim = 1.0 / fx.grid_dim.xyz;
	for (int i = 0; i < 30; i++) {
		if (t > maxDist) break;
		vec3 g = (W + rd * t - fx.grid_org.xyz) / dx * invDim;
		if (any(lessThan(g, vec3(0.0))) || any(greaterThan(g, vec3(1.0)))) break;
		vec4 s = textureLod(density, g, 0.0);
		float occ = clamp(s.r / fx.grid_dim.w * 1.3, 0.0, 1.0);
		thick += occ * stepW;
		dyeAcc += occ * stepW * s.g;
		t += stepW;
	}
	thick = max(thick, max(fx.misc.z * 0.6, fx.misc.w));
	float dyeAvg = clamp(dyeAcc / max(thick, 1e-4), 0.0, 1.0);
	dyeAvg = smoothstep(0.02, 0.98, dyeAvg);
	vec3 absorb = mix(fx.absorb_a.rgb, fx.absorb_b.rgb, dyeAvg);
	vec3 scat = mix(fx.scat_a.rgb, fx.scat_b.rgb, dyeAvg);
	float scatK = mix(fx.absorb_a.w, fx.absorb_b.w, dyeAvg);

	// refraction
	vec2 off = -n.xy * vec2(1.0, -1.0) * fx.misc.y * clamp(thick, 0.0, 1.6) / max(z * 0.12, 0.25) * px.y * 1080.0 * 0.02;
	vec2 ruv = clamp(uv + off, vec2(0.001), vec2(0.999));
	if (sceneZ(ruv) < z) ruv = uv;
	vec3 bg = textureLod(scene_copy, ruv, 0.0).rgb;
	vec3 trans = exp(-absorb * thick);
	float ndl = max(dot(N, L), 0.0);
	vec3 inscat = scat * (1.0 - exp(-thick * scatK)) * (0.35 + 0.65 * ndl) * fx.sun.w;
	vec3 col = bg * trans + inscat;

	// reflection
	vec3 R = reflect(-V, N);
	float F = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
	vec3 refl = envColor(R, L);
	col = mix(col, refl, F);
	vec3 H = normalize(L + V);
	float ndh = max(dot(N, H), 0.0);
	col += vec3(1.0, 0.96, 0.88) * (pow(ndh, 1600.0) * 5.0 + pow(ndh, 140.0) * 0.05) * fx.sun.w;

	// foam
	float foam = 0.0, fw = 0.0;
	for (int i = 0; i < 9; i++) {
		ivec2 o = ivec2(i % 3 - 1, i / 3 - 1) * 2;
		ivec2 q = clamp(pix + o, ivec2(0), size - 1);
		if (texelFetch(depth_raw, q, 0).r < 9.0e4) {
			foam += texelFetch(aux, q, 0).a;
			fw += 1.0;
		}
	}
	foam = fw > 0.0 ? foam / fw : 0.0;
	float lace = envFbm(W.xz * 2.6 + W.y * 1.7 + fx.screen.z * 0.05) * 0.6 + envFbm(W.xz * 9.0 - W.y * 5.0) * 0.4;
	float fm = smoothstep(0.30, 0.62, foam * (0.35 + 1.3 * lace)) * fx.misc.x;
	vec3 foamCol = mix(vec3(0.92, 0.97, 1.02), vec3(1.3, 1.27, 1.22), ndl) * fx.sun.w;
	col = mix(col, foamCol, fm * 0.8);

	imageStore(out_color, pix, vec4(col + line, 1.0));
}
