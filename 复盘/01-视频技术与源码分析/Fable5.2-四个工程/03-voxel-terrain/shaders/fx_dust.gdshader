shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap, specular_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
varying float v_seed;

float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vnoise2(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	v_seed = float(INSTANCE_ID) * 7.31;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 c = UV - 0.5;
	float d = length(c) * 2.0;
	float n = vnoise2(UV * 3.5 + v_seed) * 0.6 + vnoise2(UV * 8.0 + v_seed * 1.7) * 0.4;
	float a = smoothstep(1.0, 0.25, d + (n - 0.5) * 0.7);
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 up = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((-up.z / up.w + VERTEX.z) * 0.6, 0.0, 1.0);
	ALBEDO = COLOR.rgb * (0.75 + 0.5 * n);
	ALPHA = a * COLOR.a * soft;
	BACKLIGHT = vec3(0.55, 0.42, 0.32);
	ROUGHNESS = 1.0;
}
