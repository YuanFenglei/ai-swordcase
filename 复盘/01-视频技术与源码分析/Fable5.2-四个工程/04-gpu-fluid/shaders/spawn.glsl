#version 450
layout(local_size_x = 256) in;
struct Particle { vec4 pos; vec4 vel; vec4 c0; vec4 c1; vec4 c2; };
layout(set = 0, binding = 1, std430) restrict buffer Particles { Particle p[]; };
layout(push_constant, std430) uniform PC {
	vec4 origin_spacing; // box: min corner + spacing ; disc: centre + radius
	vec4 vel_dye;        // velocity xyz, dye
	vec4 axis_thick;     // disc: normal xyz, slab thickness ; box: jitter in w
	ivec4 idx;           // start, count, nx, ny
	ivec4 idx2;          // mode (0 box, 1 disc), seed, initial foam (permille), 0
	vec4 lo;             // clamp min
	vec4 hi;             // clamp max
} pc;
float hash(uint n) {
	n = (n << 13U) ^ n;
	n = n * (n * n * 15731U + 789221U) + 1376312589U;
	return float(n & 0x7fffffffU) / float(0x7fffffff);
}
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(pc.idx.y)) return;
	uint s = i * 3U + uint(pc.idx2.y) * 7919U;
	vec3 r = vec3(hash(s), hash(s + 1U), hash(s + 2U));
	vec3 pos;
	if (pc.idx2.x == 0) {
		uint nx = uint(pc.idx.z), ny = uint(pc.idx.w);
		uint ix = i % nx, iy = (i / nx) % ny, iz = i / (nx * ny);
		pos = pc.origin_spacing.xyz + (vec3(ix, iy, iz) + 0.5 + (r - 0.5) * pc.axis_thick.w) * pc.origin_spacing.w;
	} else {
		vec3 n = normalize(pc.axis_thick.xyz);
		vec3 t = normalize(abs(n.y) < 0.9 ? cross(n, vec3(0, 1, 0)) : cross(n, vec3(1, 0, 0)));
		vec3 b = cross(n, t);
		float rad = sqrt(r.x) * pc.origin_spacing.w;
		float a = r.y * 6.2831853;
		pos = pc.origin_spacing.xyz + (t * cos(a) + b * sin(a)) * rad + n * r.z * pc.axis_thick.w;
	}
	pos = clamp(pos, pc.lo.xyz, pc.hi.xyz);
	Particle q;
	q.pos = vec4(pos, pc.vel_dye.w);
	q.vel = vec4(pc.vel_dye.xyz, float(pc.idx2.z) * 0.001);
	q.c0 = vec4(0.0, 0.0, 0.0, 1.0); q.c1 = vec4(0.0); q.c2 = vec4(0.0);
	p[uint(pc.idx.x) + i] = q;
}
