struct Particle {
	vec4 pos;   // xyz grid-space position, w dye (0..1)
	vec4 vel;   // xyz velocity, w foam (0..1) + 2 if interior
	vec4 c0;    // affine matrix columns
	vec4 c1;
	vec4 c2;
};
struct Collider {
	mat4 inv;        // grid space -> collider local
	vec4 size_type;  // xyz half extents (box) or x radius (sphere), w type 1 box 2 sphere
	vec4 linvel;
	vec4 angvel;
	vec4 center;
};
layout(set = 0, binding = 0, std140) uniform Params {
	ivec4 grid;      // gx gy gz particleCount
	vec4 grav_dt;    // gravity xyz, dt
	vec4 fluid;      // stiffness, rest density, viscosity, time
	vec4 mouse_o;    // ray origin, radius
	vec4 mouse_d;    // ray dir, active
	vec4 mouse_f;    // impulse
	ivec4 counts;    // colliders, probes, frame, flags
	vec4 misc;       // foam speed threshold, foam gain, foam decay, damping
	Collider col[16];
} P;

const float FP = 1.0e7;
int enc(float f) { return int(clamp(f, -210.0, 210.0) * FP); }
float dec(int i) { return float(i) / FP; }
int cellIndex(ivec3 c) { return (c.z * P.grid.y + c.y) * P.grid.x + c.x; }

float colSDF(int i, vec3 x, out vec3 n) {
	vec3 l = (P.col[i].inv * vec4(x, 1.0)).xyz;
	vec4 st = P.col[i].size_type;
	float sd;
	vec3 nl;
	if (st.w > 1.5) {
		float len = length(l);
		sd = len - st.x;
		nl = l / max(len, 1e-4);
	} else {
		vec3 q = abs(l) - st.xyz;
		float outside = length(max(q, 0.0));
		sd = outside + min(max(q.x, max(q.y, q.z)), 0.0);
		if (outside > 1e-5) nl = sign(l) * max(q, 0.0) / outside;
		else if (q.x > q.y && q.x > q.z) nl = vec3(sign(l.x), 0.0, 0.0);
		else if (q.y > q.z) nl = vec3(0.0, sign(l.y), 0.0);
		else nl = vec3(0.0, 0.0, sign(l.z));
	}
	n = transpose(mat3(P.col[i].inv)) * nl;
	return sd;
}
vec3 colVel(int i, vec3 x) {
	return P.col[i].linvel.xyz + cross(P.col[i].angvel.xyz, x - P.col[i].center.xyz);
}
