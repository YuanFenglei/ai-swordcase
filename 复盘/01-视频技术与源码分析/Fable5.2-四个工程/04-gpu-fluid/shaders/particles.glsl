//@vertex
#version 450
struct Particle { vec4 pos; vec4 vel; vec4 c0; vec4 c1; vec4 c2; };
layout(set = 0, binding = 0, std430) restrict readonly buffer Particles { Particle p[]; };
layout(set = 0, binding = 1, std140) uniform Cam {
	mat4 view;
	mat4 proj;
	vec4 origin_dx;   // grid origin (world), dx
	vec4 params;      // radius (world), cull interior, speed scale, 0
} cam;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_view;   // view-space centre xyz, radius
layout(location = 2) out vec2 v_data;   // speed, foam
const vec2 CORNERS[6] = vec2[6](vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, -1), vec2(1, 1), vec2(-1, 1));
void main() {
	Particle q = p[gl_InstanceIndex];
	bool interior = q.vel.w >= 2.0;
	float foam = min(fract(q.vel.w * 0.5) * 2.0, 1.0);
	if (cam.params.y > 0.5 && (interior || q.c0.w < 0.1)) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		v_uv = vec2(0.0); v_view = vec4(0.0); v_data = vec2(0.0);
		return;
	}
	vec2 c = CORNERS[gl_VertexIndex];
	float r = cam.params.x * mix(0.5, 1.0, smoothstep(0.15, 0.6, q.c0.w));
	vec3 world = cam.origin_dx.xyz + q.pos.xyz * cam.origin_dx.w;
	vec4 vp = cam.view * vec4(world, 1.0);
	v_view = vec4(vp.xyz, r);
	v_uv = c;
	v_data = vec2(min(length(q.vel.xyz) * cam.params.z, 0.98) + (q.pos.w > 0.5 ? 1.0 : 0.0), foam);
	vp.xy += c * r;
	vec4 clip = cam.proj * vp;
	// rasterise at the sphere's nearest depth so conservative depth (depth_less, reverse-Z) keeps early-Z
	vec4 front = cam.proj * vec4(vp.xy, vp.z + r, 1.0);
	clip.z = front.z / front.w * clip.w;
	gl_Position = clip;
}

//@fragment
#version 450
layout(set = 0, binding = 1, std140) uniform Cam {
	mat4 view;
	mat4 proj;
	vec4 origin_dx;
	vec4 params;
} cam;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_view;
layout(location = 2) in vec2 v_data;
layout(depth_less) out float gl_FragDepth;
layout(location = 0) out float o_depth;
layout(location = 1) out vec4 o_aux;
void main() {
	float r2 = dot(v_uv, v_uv);
	if (r2 > 1.0) discard;
	float nz = sqrt(1.0 - r2);
	vec3 vp = v_view.xyz + vec3(v_uv, nz) * v_view.w;
	vec4 clip = cam.proj * vec4(vp, 1.0);
	gl_FragDepth = clip.z / clip.w;
	o_depth = -vp.z;
	o_aux = vec4(v_uv, v_data);
}
