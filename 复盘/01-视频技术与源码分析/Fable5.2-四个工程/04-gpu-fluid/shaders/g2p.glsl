#version 450
layout(local_size_x = 256) in;
#include "common.inc"
layout(set = 0, binding = 1, std430) restrict buffer Particles { Particle p[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Grid { int g[]; };
void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= uint(P.grid.w)) return;
	vec3 pos = p[id].pos.xyz;
	float dt = P.grav_dt.w;
	vec3 lo = vec3(2.0), hi = vec3(P.grid.xyz) - 2.0;
	ivec3 cell = ivec3(floor(pos));
	if (any(lessThan(cell, ivec3(1))) || any(greaterThanEqual(cell, P.grid.xyz - 1)) || any(isnan(pos))) {
		p[id].pos.xyz = clamp(pos, lo + 0.5, hi - 0.5);
		if (any(isnan(pos))) p[id].pos.xyz = vec3(P.grid.xyz) * 0.5;
		p[id].vel.xyz = vec3(0.0);
		return;
	}
	vec3 f = pos - (vec3(cell) + 0.5);
	vec3 w[3];
	w[0] = 0.5 * (0.5 - f) * (0.5 - f);
	w[1] = 0.75 - f * f;
	w[2] = 0.5 * (0.5 + f) * (0.5 + f);
	mat3 B = mat3(0.0);
	vec3 v = vec3(0.0);
	float minM = 1e9, dens = 0.0;
	for (int gx = 0; gx < 3; gx++) for (int gy = 0; gy < 3; gy++) for (int gz = 0; gz < 3; gz++) {
		float wt = w[gx].x * w[gy].y * w[gz].z;
		ivec3 c = cell + ivec3(gx, gy, gz) - 1;
		int ci = cellIndex(c);
		vec3 cd = vec3(c) + 0.5 - pos;
		vec3 wv = vec3(dec(g[ci * 4]), dec(g[ci * 4 + 1]), dec(g[ci * 4 + 2])) * wt;
		float m = dec(g[ci * 4 + 3]);
		minM = min(minM, m);
		dens += m * wt;
		B += mat3(wv * cd.x, wv * cd.y, wv * cd.z);
		v += wv;
	}
	mat3 C = B * 4.0;
	pos += v * dt;
	// soft walls
	vec3 xn = pos + v * dt * 3.0;
	vec3 wlo = lo + 1.0, whi = hi - 1.0;
	v += 3.0 * max(wlo - xn, 0.0) * dt;
	v -= 3.0 * max(xn - whi, 0.0) * dt;
	for (int i = 0; i < P.counts.x; i++) {
		vec3 n;
		float sd = colSDF(i, pos, n);
		if (sd < 0.0) {
			pos -= n * sd;
			vec3 vc = colVel(i, pos);
			vec3 vr = v - vc;
			float vn = dot(vr, n);
			if (vn < 0.0) vr -= n * vn;
			v = vc + vr;
		}
	}
	pos = clamp(pos, lo + 0.01, hi - 0.01);
	float foam = min(fract(p[id].vel.w * 0.5) * 2.0, 1.0);
	bool interior = minM > P.fluid.y * 0.55;
	float speed = length(v);
	float turb = sqrt(dot(C[0], C[0]) + dot(C[1], C[1]) + dot(C[2], C[2]));
	float gen = smoothstep(P.misc.x, P.misc.x * 2.0, turb) * (interior ? 0.2 : 1.0);
	foam = clamp(foam + (gen * P.misc.y - P.misc.z) * dt, 0.0, 0.999);
	p[id].pos.xyz = pos;
	p[id].vel = vec4(v, foam + (interior ? 2.0 : 0.0));
	// density predicted to the advected position, so next step's pressure is not explicit-Euler lagged
	float rpred = (dens / P.fluid.y) / clamp(1.0 + dt * (C[0][0] + C[1][1] + C[2][2]), 0.6, 1.6);
	p[id].c0 = vec4(C[0], rpred);
	p[id].c1.xyz = C[1];
	p[id].c2.xyz = C[2];
}
