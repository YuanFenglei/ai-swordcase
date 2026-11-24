#version 450
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
#include "common.inc"
layout(set = 0, binding = 2, std430) restrict buffer Grid { int g[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Dye { int dye[]; };
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image3D density;
void main() {
	ivec3 c = ivec3(gl_GlobalInvocationID.xyz);
	if (any(greaterThanEqual(c, P.grid.xyz))) return;
	int ci = cellIndex(c);
	int mi = g[ci * 4 + 3];
	if (mi <= 0) {
		imageStore(density, c, vec4(0.0));
		return;
	}
	float m = dec(mi);
	vec3 v = vec3(dec(g[ci * 4]), dec(g[ci * 4 + 1]), dec(g[ci * 4 + 2])) / m;
	v += P.grav_dt.xyz * P.grav_dt.w;
	v *= P.misc.w;
	vec3 x = vec3(c) + 0.5;
	if (P.mouse_d.w > 0.5) {
		vec3 rel = x - P.mouse_o.xyz;
		float dist = length(cross(rel, P.mouse_d.xyz));
		float k = clamp(1.0 - dist / P.mouse_o.w, 0.0, 1.0);
		v += P.mouse_f.xyz * k * k;
	}
	for (int i = 0; i < P.counts.x; i++) {
		vec3 n;
		float sd = colSDF(i, x, n);
		if (sd < 0.6) {
			vec3 vc = colVel(i, x);
			vec3 vr = v - vc;
			float vn = dot(vr, n);
			if (vn < 0.0) vr -= n * vn;
			if (sd < -1.0) vr *= 0.0;
			v = vc + vr;
		}
	}
	if (c.x < 2 || c.x >= P.grid.x - 2) v.x = 0.0;
	if (c.y < 2 || c.y >= P.grid.y - 2) v.y = 0.0;
	if (c.z < 2 || c.z >= P.grid.z - 2) v.z = 0.0;
	float sp = length(v);
	if (sp > 4.0) v *= 4.0 / sp;
	g[ci * 4 + 0] = enc(v.x);
	g[ci * 4 + 1] = enc(v.y);
	g[ci * 4 + 2] = enc(v.z);
	imageStore(density, c, vec4(m, float(dye[ci]) / 65536.0 / m, sp, 0.0));
}
