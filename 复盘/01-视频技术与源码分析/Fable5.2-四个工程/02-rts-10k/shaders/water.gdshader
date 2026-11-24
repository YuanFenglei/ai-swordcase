shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
varying vec3 wp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (wp.xz + 320.0) / 640.0;
	float depth = wp.y - texture(height_tex, uv).r;
	if (depth < 0.0) discard;
	vec2 fl = vec2(0.0, TIME * 0.03);
	vec2 q1 = wp.xz * 0.045 + fl;
	vec2 q2 = wp.xz * 0.11 - fl * 1.9 + 0.37;
	float a = texture(noise_tex, q1).r;
	float b = texture(noise_tex, q2).r;
	vec2 g = vec2(texture(noise_tex, q1 + vec2(0.01, 0.0)).r - a, texture(noise_tex, q1 + vec2(0.0, 0.01)).r - a) * 1.4
		+ vec2(texture(noise_tex, q2 + vec2(0.01, 0.0)).r - b, texture(noise_tex, q2 + vec2(0.0, 0.01)).r - b);
	vec3 n = normalize(vec3(-g.x * 2.5, 1.0, -g.y * 2.5));
	vec3 deep = vec3(0.025, 0.14, 0.17);
	vec3 shallow = vec3(0.16, 0.40, 0.37);
	vec3 c = mix(shallow, deep, smoothstep(0.0, 2.4, depth));
	float foam = smoothstep(0.32, 0.0, depth) * smoothstep(0.35, 0.6, a * 0.6 + b * 0.6);
	foam += smoothstep(0.9, 0.2, depth) * smoothstep(0.62, 0.75, b) * 0.6;
	c = mix(c, vec3(0.86, 0.9, 0.88), clamp(foam, 0.0, 1.0));
	ALBEDO = c;
	ALPHA = clamp(smoothstep(0.0, 0.5, depth) * 0.86 + foam * 0.3, 0.0, 0.95);
	ROUGHNESS = 0.06;
	SPECULAR = 0.7;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
