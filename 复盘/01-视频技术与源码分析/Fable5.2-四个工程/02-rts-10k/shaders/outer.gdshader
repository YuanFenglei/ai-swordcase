shader_type spatial;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
varying vec3 wp;

void vertex() {
	vec2 p = VERTEX.xz;
	float e = max(abs(p.x), abs(p.y));
	float ramp = smoothstep(330.0, 1100.0, e);
	float a = textureLod(noise_tex, p * 0.00055, 0.0).r;
	float b = textureLod(noise_tex, p * 0.0023 + 0.3, 0.0).r;
	VERTEX.y = 9.0 + ramp * (a * 230.0 + b * 60.0 - 40.0) + smoothstep(325.0, 480.0, e) * (b - 0.45) * 22.0;
	if (e < 319.0) VERTEX.y = -40.0;
	wp = VERTEX;
}

void fragment() {
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (n.z < 0.0) n = -n;
	NORMAL = n;
	vec3 wn = (INV_VIEW_MATRIX * vec4(n, 0.0)).xyz;
	float n1 = texture(noise_tex, wp.xz * 0.0035).r;
	float n3 = texture(noise_tex, wp.xz * 0.05).r;
	vec3 c = mix(vec3(0.15, 0.23, 0.075), vec3(0.37, 0.32, 0.13), smoothstep(0.32, 0.68, n1));
	c = mix(c, vec3(0.40, 0.36, 0.31), smoothstep(0.75, 0.55, wn.y));
	c = mix(c, vec3(0.62, 0.60, 0.58), smoothstep(120.0, 190.0, wp.y + n3 * 30.0));
	ALBEDO = c * (0.75 + n3 * 0.4);
	ROUGHNESS = 0.95;
}
