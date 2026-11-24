#version 450
layout(local_size_x = 256) in;
#include "common.inc"
layout(set = 0, binding = 1, std430) restrict readonly buffer Particles { Particle p[]; };
layout(set = 0, binding = 2, std430) buffer Grid { int g[]; };
layout(set = 0, binding = 3, std430) buffer Dye { int dye[]; };
void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= uint(P.grid.w)) return;
	vec3 pos = p[id].pos.xyz;
	vec3 v = p[id].vel.xyz;
	float d = p[id].pos.w;
	mat3 C = mat3(p[id].c0.xyz, p[id].c1.xyz, p[id].c2.xyz);
	// pressure + viscosity from the density gathered in the previous g2p, folded into the affine term
	float r = max(p[id].c0.w, 0.02);
	float r2 = r * r;
	float pressure = max(0.0, P.fluid.x * (r2 * r2 * r - 1.0));
	mat3 stress = mat3(-pressure) + P.fluid.z * (C + transpose(C));
	mat3 A = C + (-4.0 * P.grav_dt.w / (r * P.fluid.y)) * stress;
	bool useDye = (P.counts.w & 1) != 0;
	ivec3 cell = ivec3(floor(pos));
	if (any(lessThan(cell, ivec3(1))) || any(greaterThanEqual(cell, P.grid.xyz - 1))) return;
	vec3 f = pos - (vec3(cell) + 0.5);
	vec3 w[3];
	w[0] = 0.5 * (0.5 - f) * (0.5 - f);
	w[1] = 0.75 - f * f;
	w[2] = 0.5 * (0.5 + f) * (0.5 + f);
	for (int gx = 0; gx < 3; gx++) for (int gy = 0; gy < 3; gy++) for (int gz = 0; gz < 3; gz++) {
		float wt = w[gx].x * w[gy].y * w[gz].z;
		ivec3 c = cell + ivec3(gx, gy, gz) - 1;
		vec3 cd = vec3(c) + 0.5 - pos;
		vec3 mv = wt * (v + A * cd);
		int ci = cellIndex(c);
		atomicAdd(g[ci * 4 + 0], enc(mv.x));
		atomicAdd(g[ci * 4 + 1], enc(mv.y));
		atomicAdd(g[ci * 4 + 2], enc(mv.z));
		atomicAdd(g[ci * 4 + 3], enc(wt));
		if (useDye) atomicAdd(dye[ci], int(wt * d * 65536.0));
	}
}
