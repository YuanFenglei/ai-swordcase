shader_type spatial;
render_mode cull_back;
uniform vec3 col_a : source_color = vec3(1.0, 0.16, 0.5);
uniform vec3 col_b : source_color = vec3(0.5, 0.3, 1.0);
uniform float glow = 2.0;
instance uniform float boost = 1.0;
varying vec3 op;
varying vec3 wo;

void vertex() {
	op = VERTEX;
	wo = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

void fragment() {
	float fr = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	float ph = wo.x * 0.37 + wo.z * 0.23;
	float bands = 0.5 + 0.5 * sin(op.y * 4.0 - TIME * 1.4 + ph + sin(op.x * 5.0 + op.z * 4.0));
	float core = pow(bands, 3.0);
	ALBEDO = col_a * 0.08;
	METALLIC = 0.3;
	ROUGHNESS = 0.07;
	SPECULAR = 0.9;
	EMISSION = (mix(col_a, col_b, fr) * (0.25 + fr * 1.3) + col_a * core * 0.9) * glow * boost;
}
