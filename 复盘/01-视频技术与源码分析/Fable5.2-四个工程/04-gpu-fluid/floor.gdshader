shader_type spatial;
// Pool floor: tiles + lane lines, lit by fake caustics driven by the fluid column-height texture (Texture2DRD).

uniform sampler2D column_tex : filter_linear, repeat_disable;
uniform vec3 grid_origin;
uniform vec2 grid_size_m;   // grid extent in metres (x, z)
uniform float cell = 0.1667;
uniform float tile = 0.5;
uniform float caustic_strength = 1.0;
uniform vec3 tile_color : source_color = vec3(0.86, 0.90, 0.92);
uniform vec3 grout_color : source_color = vec3(0.42, 0.50, 0.56);
uniform vec3 lane_color : source_color = vec3(0.04, 0.16, 0.42);

varying vec3 wpos;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}
// cheap animated caustic pattern
float caustic(vec2 p, float t) {
	float c = 0.0;
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	vec2 q = p;
	float a = 1.0;
	for (int i = 0; i < 3; i++) {
		q += vec2(sin(q.y * 1.3 + t * 0.9 + float(i)), cos(q.x * 1.1 - t * 0.7 + float(i) * 1.7)) * 0.55;
		float v = abs(sin(q.x * 1.9) * sin(q.y * 1.9));
		c += pow(1.0 - v, 5.0) * a;
		q = m * q;
		a *= 0.65;
	}
	return c;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	vec2 tuv = p / tile;
	vec2 id = floor(tuv);
	vec2 f = fract(tuv);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float w = fwidth(tuv.x) + fwidth(tuv.y);
	float grout = 1.0 - smoothstep(0.02, 0.02 + max(w, 0.01), edge);
	vec3 col = tile_color * (0.93 + 0.07 * hash21(id));
	// lane lines along x
	float lz = abs(fract(p.y / 2.0 + 0.5) - 0.5) * 2.0;
	float lane = 1.0 - smoothstep(0.11, 0.13, lz);
	col = mix(col, lane_color, lane);
	col = mix(col, grout_color, grout * 0.8);

	vec2 uv = (p - grid_origin.xz) / grid_size_m;
	vec2 texel = 1.0 / vec2(textureSize(column_tex, 0));
	float h = texture(column_tex, uv).r * cell;
	float hx = (texture(column_tex, uv + vec2(texel.x * 1.5, 0.0)).r - texture(column_tex, uv - vec2(texel.x * 1.5, 0.0)).r) * cell;
	float hz = (texture(column_tex, uv + vec2(0.0, texel.y * 1.5)).r - texture(column_tex, uv - vec2(0.0, texel.y * 1.5)).r) * cell;
	float wet = smoothstep(0.02, 0.25, h);
	float cs = caustic(p * 1.7 + vec2(hx, hz) * 5.0, TIME * 1.6);
	float focus = clamp(1.0 - (hx * hx + hz * hz) * 3.0, 0.0, 1.0);
	float light = mix(1.0, (mix(0.9, 0.62, caustic_strength) + cs * 0.55 * focus * caustic_strength) * exp(-h * 0.06), wet);
	// soft contact darkening under thick water / at the wet edge
	light *= mix(1.0, 0.86, smoothstep(0.0, 0.08, h) * (1.0 - wet));
	ALBEDO = col * light;
	EMISSION = col * max(cs - 0.75, 0.0) * 0.5 * wet * focus * caustic_strength;
	ROUGHNESS = mix(0.32, 0.6, grout);
	SPECULAR = 0.5;
}
