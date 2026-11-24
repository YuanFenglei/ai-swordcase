shader_type spatial;

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D stain_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
varying vec3 wp;

void vertex() {
	vec2 uv = (VERTEX.xz + 320.0) / 640.0;
	VERTEX.y = textureLod(height_tex, uv, 0.0).r;
	wp = VERTEX;
}

void fragment() {
	vec2 uv = (wp.xz + 320.0) / 640.0;
	float e = 1.0 / 1024.0;
	float hl = texture(height_tex, uv - vec2(e, 0.0)).r;
	float hr = texture(height_tex, uv + vec2(e, 0.0)).r;
	float hd = texture(height_tex, uv - vec2(0.0, e)).r;
	float hu = texture(height_tex, uv + vec2(0.0, e)).r;
	float n1 = texture(noise_tex, wp.xz * 0.0035).r;
	float n2 = texture(noise_tex, wp.xz * 0.027 + 0.31).r;
	float n3 = texture(noise_tex, wp.xz * 0.19).r;
	float n4 = texture(noise_tex, wp.xz * 0.9).r;
	vec3 n = normalize(vec3(hl - hr, 1.25, hd - hu));
	float slope = 1.0 - n.y;
	vec2 dn = vec2(texture(noise_tex, wp.xz * 0.19 + vec2(0.004, 0.0)).r - n3, texture(noise_tex, wp.xz * 0.19 + vec2(0.0, 0.004)).r - n3);
	n = normalize(n + vec3(-dn.x, 0.0, -dn.y) * 2.2);

	vec3 grass_dry = vec3(0.37, 0.32, 0.13);
	vec3 grass_green = vec3(0.15, 0.23, 0.075);
	vec3 dirt = vec3(0.27, 0.19, 0.11);
	vec3 rock = vec3(0.40, 0.36, 0.31);
	vec3 sand = vec3(0.50, 0.42, 0.28);
	vec3 c = mix(grass_green, grass_dry, smoothstep(0.32, 0.68, n1 + (n2 - 0.5) * 0.5));
	c = mix(c, dirt, smoothstep(0.52, 0.72, n2 * 0.55 + n3 * 0.45) * 0.65);
	c = mix(c, rock, smoothstep(0.10, 0.28, slope));
	float h = wp.y;
	c = mix(c, sand, smoothstep(-0.25, -1.25, h));
	c = mix(c, sand * vec3(0.35, 0.42, 0.40), smoothstep(-1.5, -3.2, h));
	c *= 0.72 + n3 * 0.36 + n4 * 0.2;

	vec4 s = texture(stain_tex, uv);
	float tr = smoothstep(0.02, 0.75, s.g) * (0.6 + n4 * 0.6);
	c = mix(c, vec3(0.19, 0.135, 0.085) * (0.75 + n3 * 0.5), clamp(tr, 0.0, 0.9));
	float bl = smoothstep(0.04, 0.7, s.r * (0.6 + n4 * 0.8));
	c = mix(c, vec3(0.16, 0.022, 0.018), bl * 0.88);
	ALBEDO = c;
	ROUGHNESS = mix(0.96, 0.55, bl);
	SPECULAR = 0.25;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
