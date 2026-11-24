shader_type canvas_item;
// Final screen pass: shock ripples, heat shimmer, chromatic aberration, vignette, grade, letterbox.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float hit = 0.0;
uniform float flash = 0.0;
uniform float fade = 0.0;
uniform float bars = 0.0;
uniform float heat = 0.0;
uniform float aspect = 1.7778;
uniform vec4 shock0 = vec4(0.0);
uniform vec4 shock1 = vec4(0.0);
uniform vec4 shock2 = vec4(0.0);

vec2 ripple(vec2 uv, vec4 s) {
	vec2 d = (uv - s.xy) * vec2(aspect, 1.0);
	float dist = length(d);
	float w = dist - s.z;
	float k = exp(-w * w * 260.0) * s.w;
	return normalize(d + vec2(1e-5)) / vec2(aspect, 1.0) * k * 0.035;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	uv += ripple(uv, shock0) + ripple(uv, shock1) + ripple(uv, shock2);
	uv += vec2(sin(uv.y * 80.0 + TIME * 7.0), cos(uv.x * 60.0 + TIME * 5.0)) * 0.0014 * heat * smoothstep(0.75, 0.2, uv.y);
	vec2 c = SCREEN_UV - 0.5;
	float r2 = dot(c, c);
	vec2 ca = c * (0.0022 + 0.02 * hit) * (0.2 + r2 * 3.0);
	vec3 col = vec3(texture(screen_tex, uv + ca).r, texture(screen_tex, uv).g, texture(screen_tex, uv - ca).b);
	col *= 1.0 - smoothstep(0.15, 0.9, r2 * 1.5) * 0.22;
	float l = dot(col, vec3(0.3, 0.59, 0.11));
	col = mix(col, col * vec3(0.90, 1.0, 1.10), (1.0 - smoothstep(0.0, 0.5, l)) * 0.5);
	col = mix(col, col * vec3(1.06, 1.0, 0.94), smoothstep(0.5, 1.0, l) * 0.5);
	col += vec3(1.0, 0.12, 0.08) * hit * r2 * 1.6;
	col = mix(col, vec3(1.0), flash);
	col *= 1.0 - fade;
	float lim = 0.5 - bars * 0.5 * (1.0 - aspect / 2.2);
	col *= 1.0 - smoothstep(lim - 0.001, lim + 0.001, abs(c.y));
	COLOR = vec4(col, 1.0);
}
