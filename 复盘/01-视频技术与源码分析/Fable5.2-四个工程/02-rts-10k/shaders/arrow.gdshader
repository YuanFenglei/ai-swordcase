shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, shadows_disabled;

// row0 = start.xz, end.xz   row1 = fire time, flight time, arc height, seed
// The whole ballistic arc is evaluated here; the sim only tracks the impact tick.
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform float sim_time = 0.0;
varying float v_t;
varying float v_k;

void vertex() {
	vec4 r0 = vec4(MODEL_MATRIX[0][0], MODEL_MATRIX[1][0], MODEL_MATRIX[2][0], MODEL_MATRIX[3][0]);
	vec4 r1 = vec4(MODEL_MATRIX[0][1], MODEL_MATRIX[1][1], MODEL_MATRIX[2][1], MODEL_MATRIX[3][1]);
	float age = sim_time - r1.x;
	float t = age / max(r1.y, 0.001);
	float tc = clamp(t, 0.0, 1.0);
	vec2 p = mix(r0.xy, r0.zw, tc);
	float ys = textureLod(height_tex, (r0.xy + 320.0) / 640.0, 0.0).g + 1.5;
	float ye = textureLod(height_tex, (r0.zw + 320.0) / 640.0, 0.0).g + 0.15;
	float y = mix(ys, ye, tc) + r1.z * 4.0 * tc * (1.0 - tc);
	vec2 hd = r0.zw - r0.xy;
	float vy = (ye - ys) + r1.z * 4.0 * (1.0 - 2.0 * tc);
	vec3 dir = normalize(vec3(hd.x, vy, hd.y));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), dir) + vec3(1e-4, 0.0, 0.0));
	vec3 up = cross(dir, right);
	float stuck = max(age - r1.y, 0.0);
	y -= max(stuck - 4.0, 0.0) * 0.5;
	vec3 w = vec3(p.x, y, p.y) + right * VERTEX.x + up * VERTEX.y + dir * VERTEX.z;
	if (r1.y < 0.01 || t < 0.0 || stuck > 6.5) w = vec3(0.0, -500.0, 0.0);
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	NORMAL = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	v_t = step(1.0, t);
	v_k = UV.x;
}

void fragment() {
	vec3 c = mix(vec3(0.45, 0.33, 0.20), vec3(0.85, 0.82, 0.74), v_k);
	ALBEDO = c;
	ROUGHNESS = 0.9;
	EMISSION = c * mix(0.4, 0.03, v_t);
}
