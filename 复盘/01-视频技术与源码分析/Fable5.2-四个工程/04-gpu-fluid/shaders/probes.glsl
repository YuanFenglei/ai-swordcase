#version 450
layout(local_size_x = 64) in;
#include "common.inc"
layout(set = 0, binding = 2, std430) restrict readonly buffer Grid { int g[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ProbeIn { vec4 pin[]; };
layout(set = 0, binding = 6, std430) restrict writeonly buffer ProbeOut { vec4 pout[]; };
void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= uint(P.counts.y)) return;
	vec3 pos = pin[id].xyz;
	ivec3 base = ivec3(floor(pos));
	vec3 vel = vec3(0.0);
	float msum = 0.0, fill = 0.0, freeN = 0.0;
	for (int x = -2; x <= 2; x++) for (int y = -2; y <= 2; y++) for (int z = -2; z <= 2; z++) {
		ivec3 c = base + ivec3(x, y, z);
		if (any(lessThan(c, ivec3(2))) || any(greaterThanEqual(c, P.grid.xyz - 2))) continue;
		vec3 cx = vec3(c) + 0.5;
		bool blocked = false;
		for (int i = 0; i < P.counts.x; i++) {
			vec3 n;
			if (colSDF(i, cx, n) < 0.0) { blocked = true; break; }
		}
		if (blocked) continue;
		int ci = cellIndex(c);
		float m = dec(g[ci * 4 + 3]);
		freeN += 1.0;
		fill += min(m / P.fluid.y, 1.0);
		vel += vec3(dec(g[ci * 4]), dec(g[ci * 4 + 1]), dec(g[ci * 4 + 2])) * m;
		msum += m;
	}
	float frac = freeN > 2.5 ? fill / freeN : 0.0;
	pout[id] = vec4(msum > 1e-4 ? vel / msum : vec3(0.0), frac);
}
