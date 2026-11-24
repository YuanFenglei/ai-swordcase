shader_type spatial;
// One shader for the simple props. kind: 0 concrete, 1 wooden crate, 2 hazard gate, 3 ground
uniform int kind = 0;
uniform vec3 tint : source_color = vec3(0.6, 0.6, 0.6);
varying vec3 wpos;
varying vec3 lpos;
varying vec3 lnrm;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p *= 2.1;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	lpos = VERTEX;
	lnrm = NORMAL;
}

void fragment() {
	vec3 an = abs(lnrm);
	vec2 fuv = an.x > 0.5 ? lpos.zy : (an.y > 0.5 ? lpos.xz : lpos.xy);
	if (kind == 0) {
		float n = fbm(fuv * 3.0) * 0.5 + fbm(fuv * 17.0) * 0.25;
		float seams = smoothstep(0.03, 0.0, abs(fract(fuv.y / 1.2) - 0.5) - 0.48);
		ALBEDO = tint * (0.78 + n * 0.4) * (1.0 - seams * 0.25);
		ROUGHNESS = 0.85;
	} else if (kind == 1) {
		vec2 u = UV * vec2(3.0, 2.0);
		vec2 f = fract(u);
		float border = step(f.x, 0.14) + step(0.86, f.x) + step(f.y, 0.14) + step(0.86, f.y);
		border = clamp(border, 0.0, 1.0);
		float plank = floor(f.x * 5.0);
		float grain = fbm(vec2(f.x * 40.0, f.y * 3.0 + plank * 7.0));
		vec3 wood = tint * (0.75 + 0.35 * grain) * (0.9 + 0.1 * hash21(vec2(plank, floor(u.x) + floor(u.y) * 3.0)));
		float gap = smoothstep(0.06, 0.0, abs(fract(f.x * 5.0) - 0.5) - 0.46);
		wood *= 1.0 - gap * 0.45;
		float diag = smoothstep(0.09, 0.07, abs(f.x - f.y)) * (1.0 - border);
		vec3 trim = tint * vec3(0.62, 0.55, 0.5) * (0.8 + 0.3 * grain);
		ALBEDO = mix(wood, trim, max(border, diag));
		ROUGHNESS = 0.75;
	} else if (kind == 2) {
		float s = fract((fuv.x + fuv.y) * 1.1);
		float band = step(0.5, s);
		float top = step(lpos.y, -0.2);
		vec3 steel = vec3(0.16, 0.18, 0.2);
		vec3 hz = mix(vec3(0.95, 0.72, 0.05), vec3(0.06, 0.06, 0.07), band);
		ALBEDO = mix(tint * (0.85 + 0.2 * fbm(fuv * 6.0)), hz, top * step(0.5, an.x));
		ALBEDO = mix(ALBEDO, steel, step(0.5, an.z) * 0.0);
		METALLIC = 0.6;
		ROUGHNESS = 0.42;
	} else {
		vec2 p = wpos.xz;
		float n = fbm(p * 0.35) * 0.6 + fbm(p * 2.5) * 0.3 + fbm(p * 14.0) * 0.1;
		vec2 q = abs(p) - vec2(13.0, 7.0);
		float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
		float w = fwidth(d);
		float line = 1.0 - smoothstep(0.09, 0.09 + w, abs(d));
		float hatch = step(0.5, fract((p.x + p.y) * 0.9)) * step(abs(d + 0.45), 0.0);
		vec3 base = tint * (0.8 + n * 0.4);
		ALBEDO = mix(base, vec3(0.93, 0.70, 0.08) * (0.75 + n * 0.3), line * 0.9 + hatch);
		ROUGHNESS = 0.82 - n * 0.25;
	}
}
