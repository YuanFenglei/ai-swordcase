shader_type spatial;
render_mode cull_back, diffuse_burley;
// Shared hard-surface / chitin material. Vertex colour masks: R accent, G emissive, B dark joint.
// Per-instance: hit flash, dissolve, emission boost.

uniform vec3 base_col : source_color = vec3(0.7, 0.68, 0.62);
uniform vec3 accent_col : source_color = vec3(1.0, 0.45, 0.1);
uniform vec3 dark_col : source_color = vec3(0.05, 0.055, 0.07);
uniform vec3 emit_col : source_color = vec3(0.2, 0.9, 1.0);
uniform vec3 rim_col : source_color = vec3(0.3, 0.5, 0.8);
uniform float emit_power = 4.0;
uniform float metal = 0.75;
uniform float rough = 0.42;
uniform float detail = 1.0;
uniform float organic = 0.0;
uniform float rim_power = 0.25;
uniform float sway = 0.0;
instance uniform float flash = 0.0;
instance uniform float dissolve = 0.0;
instance uniform float boost = 1.0;
instance uniform float seed = 0.0;

varying vec3 op;
varying vec3 on;

float h31(vec3 p) {
	ivec3 i = ivec3(floor(p + 0.5));
	uint n = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u ^ uint(i.z) * 2798796415u;
	n = (n ^ (n >> 16u)) * 2246822519u;
	n ^= n >> 13u;
	return float(n & 16777215u) / 16777216.0;
}
float n3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h31(i), h31(i + vec3(1, 0, 0)), f.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), f.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm3(vec3 p) {
	return n3(p) * 0.5 + n3(p * 2.1 + 3.7) * 0.3 + n3(p * 4.3 + 9.1) * 0.2;
}
vec3 bump(vec3 pos, vec3 nrm, float hgt, float k) {
	vec3 dpx = dFdx(pos);
	vec3 dpy = dFdy(pos);
	float dhx = dFdx(hgt);
	float dhy = dFdy(hgt);
	vec3 r1 = cross(dpy, nrm);
	vec3 r2 = cross(nrm, dpx);
	float det = dot(dpx, r1);
	vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
	return normalize(abs(det) * nrm - k * grad);
}

void vertex() {
	if (sway > 0.0) {
		vec3 w = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float k = VERTEX.y * VERTEX.y * sway;
		VERTEX.x += sin(TIME * 1.1 + w.x * 0.7 + VERTEX.y * 0.4) * k;
		VERTEX.z += cos(TIME * 0.8 + w.z * 0.6 + VERTEX.y * 0.3) * k;
	}
	op = VERTEX;
	on = NORMAL;
}

void fragment() {
	float dn = fbm3(op * 2.2 + seed);
	if (dissolve > 0.0 && dn < dissolve * 1.15 - 0.05) {
		discard;
	}
	vec3 an = abs(normalize(on));
	vec3 tw = pow(an, vec3(6.0));
	tw /= (tw.x + tw.y + tw.z);
	// panel lines: triplanar grid in object space with staggered seams
	vec3 q = op * detail * 1.7;
	vec2 pa = vec2(q.z, q.y) * tw.x + vec2(q.x, q.z) * tw.y + vec2(q.x, q.y) * tw.z;
	vec2 cell = floor(pa);
	pa.x += step(0.5, fract(cell.y * 0.5)) * 0.37;
	vec2 pf = abs(fract(pa) - 0.5);
	float line = smoothstep(0.47, 0.495, max(pf.x, pf.y));
	float plate = h31(vec3(floor(pa), 3.0 + floor(pa.x * 0.0)));
	// organic: cellular plates
	float cellv = n3(op * detail * 3.0 + seed);
	float org_line = smoothstep(0.06, 0.0, abs(cellv - 0.5));
	line = mix(line, org_line, organic);
	float wear = smoothstep(0.55, 0.8, fbm3(op * 5.0 + 11.0));
	float grime = fbm3(op * 1.3 + 5.0);

	vec3 base = base_col * (0.78 + 0.3 * plate * (1.0 - organic));
	base = mix(base, accent_col, COLOR.r);
	base = mix(base, dark_col, COLOR.b);
	base *= 0.7 + 0.5 * grime;
	base = mix(base, base * 0.25, line * 0.85);
	base = mix(base, vec3(0.5, 0.48, 0.45), wear * 0.25 * (1.0 - COLOR.b) * (1.0 - organic));

	float fr = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float pulse = 0.8 + 0.2 * sin(TIME * 3.0 + seed * 10.0 + op.z * 2.0);
	vec3 em = emit_col * COLOR.g * emit_power * boost * pulse;
	em += rim_col * fr * rim_power;
	em += emit_col * org_line * organic * 0.09 * boost * (0.5 + 0.5 * sin(TIME * 2.0 + cellv * 20.0));
	// dissolve edge
	float edge = smoothstep(dissolve * 1.15 + 0.07, dissolve * 1.15 - 0.05, dn) * step(0.001, dissolve);
	em += vec3(1.0, 0.5, 0.15) * edge * 12.0;
	em += vec3(1.0, 0.9, 0.85) * flash * 1.6;

	ALBEDO = mix(base, vec3(1.0), flash * 0.5);
	METALLIC = metal * (1.0 - COLOR.g) * (1.0 - COLOR.b * 0.6);
	ROUGHNESS = clamp(rough + wear * 0.2 + line * 0.3 - COLOR.r * 0.1 + COLOR.b * 0.25, 0.05, 1.0);
	EMISSION = em;
	float hgt = -line * 0.02 + grime * 0.004 * (1.0 + organic * 4.0);
	NORMAL = bump(VERTEX, NORMAL, hgt, 1.0);
}
