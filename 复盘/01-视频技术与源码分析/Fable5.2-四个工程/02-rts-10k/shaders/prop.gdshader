shader_type spatial;
render_mode cull_back;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 base : source_color = vec3(0.42, 0.38, 0.33);
uniform float use_vcol = 0.0;
varying vec3 wp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (n.z < 0.0) n = -n;
	NORMAL = n;
	vec3 wn = (INV_VIEW_MATRIX * vec4(n, 0.0)).xyz;
	float nz = texture(noise_tex, wp.xz * 0.06 + wp.y * 0.09).r;
	float nf = texture(noise_tex, wp.xz * 0.5 + wp.y * 0.4).r;
	vec3 c = mix(base, COLOR.rgb, use_vcol) * (0.68 + nz * 0.45 + nf * 0.2);
	c = mix(c, c * vec3(1.18, 1.1, 0.88), smoothstep(0.45, 0.9, wn.y) * (1.0 - use_vcol * 0.6));
	ALBEDO = c;
	EMISSION = c * (0.10 + 0.14 * (1.0 - wn.y));
	ROUGHNESS = 0.92;
	SPECULAR = 0.25;
}
