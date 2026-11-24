shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 col : source_color = vec3(0.2, 0.9, 1.0);
uniform float tile = 5.0;
instance uniform float power = 0.0;
instance uniform vec3 hit_pos = vec3(0.0, 1.0, 0.0);
varying vec3 op;

float hexd(vec2 p) {
	p = abs(p);
	return max(dot(p, vec2(0.5, 0.8660254)), p.x);
}
vec2 hexc(vec2 uv) {
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(uv, r) - h;
	vec2 b = mod(uv - h, r) - h;
	return dot(a, a) < dot(b, b) ? a : b;
}

void vertex() {
	op = normalize(VERTEX);
}

void fragment() {
	vec3 n = normalize(op);
	float fr = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.2);
	vec3 w = pow(abs(n), vec3(8.0));
	w /= (w.x + w.y + w.z);
	float e = smoothstep(0.40, 0.5, hexd(hexc(n.zy * tile))) * w.x + smoothstep(0.40, 0.5, hexd(hexc(n.xz * tile))) * w.y + smoothstep(0.40, 0.5, hexd(hexc(n.xy * tile))) * w.z;
	float dh = distance(n, normalize(hit_pos));
	float near = smoothstep(1.5, 0.0, dh);
	float ripple = 0.5 + 0.5 * sin(dh * 16.0 - TIME * 22.0);
	float scan = 0.5 + 0.5 * sin(n.y * 30.0 - TIME * 6.0);
	float a = (fr * 0.55 + e * (0.22 + near * 0.9) + near * ripple * 0.5 + scan * 0.04) * power;
	ALBEDO = col * (1.5 + near * 3.0);
	ALPHA = clamp(a, 0.0, 1.0);
}
