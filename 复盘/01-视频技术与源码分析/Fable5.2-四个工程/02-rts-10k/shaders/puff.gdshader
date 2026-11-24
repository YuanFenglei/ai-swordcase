shader_type spatial;
render_mode skip_vertex_transform, unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// row0 = xyz, spawn time   row1 = size, kind (0 dust, 1 blood, 2 spark), seed, life
uniform float sim_time = 0.0;
uniform vec3 light_tint : source_color = vec3(1.0, 0.85, 0.7);
varying vec4 v_col;
varying vec2 v_uv;
varying float v_seed;

void vertex() {
	vec4 r0 = vec4(MODEL_MATRIX[0][0], MODEL_MATRIX[1][0], MODEL_MATRIX[2][0], MODEL_MATRIX[3][0]);
	vec4 r1 = vec4(MODEL_MATRIX[0][1], MODEL_MATRIX[1][1], MODEL_MATRIX[2][1], MODEL_MATRIX[3][1]);
	float age = sim_time - r0.w;
	float life = r1.w;
	float k = age / max(life, 0.001);
	float kind = r1.y;
	float seed = r1.z;
	vec3 c = r0.xyz;
	float sz = r1.x;
	vec4 col;
	if (kind < 0.5) {
		c.y += 0.4 + age * 0.7;
		c.x += age * 0.5 * (seed - 0.3);
		sz *= 0.5 + k * 1.6;
		col = vec4(0.62, 0.52, 0.38, 0.30 * sin(min(k * 5.0, 1.0) * 1.57) * (1.0 - k));
	} else if (kind < 1.5) {
		c.y += 0.9 + age * 1.2 - age * age * 2.5;
		sz *= 0.5 + k * 1.3;
		col = vec4(0.42, 0.02, 0.02, 0.75 * (1.0 - k));
	} else {
		c.y += 1.2 + age * 0.8;
		sz *= 1.0 - k * 0.6;
		col = vec4(3.0, 2.2, 1.2, (1.0 - k));
	}
	vec4 vc = VIEW_MATRIX * vec4(c, 1.0);
	vc.xy += VERTEX.xy * sz;
	if (life < 0.01 || k < 0.0 || k > 1.0) vc = vec4(0.0, 0.0, 10.0, 1.0);
	VERTEX = vc.xyz;
	v_col = col;
	v_uv = UV * 2.0 - 1.0;
	v_seed = seed;
}

void fragment() {
	float d = dot(v_uv, v_uv);
	float a = smoothstep(1.0, 0.1, d);
	float lump = 0.75 + 0.25 * sin(v_uv.x * 5.0 + v_seed * 20.0) * sin(v_uv.y * 4.0 + v_seed * 11.0);
	ALBEDO = v_col.rgb * (v_col.r > 1.5 ? vec3(1.0) : light_tint);
	ALPHA = a * v_col.a * lump;
}
