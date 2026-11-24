shader_type spatial;
render_mode skip_vertex_transform, cull_back;

// Per-instance data is packed raw into the 3x4 instance transform + instance colour:
// row0 = prev.xz, curr.xz   row1 = prev facing, curr facing   row2 = state, state start time, last hit time, speed
// colour = team, selected, seed, unused
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform float alpha = 1.0;
uniform float sim_time = 0.0;
uniform float kind = 0.0;
uniform float usize = 1.0;
uniform vec3 team_a : source_color = vec3(0.16, 0.39, 0.85);
uniform vec3 team_b : source_color = vec3(0.80, 0.18, 0.11);
uniform vec3 trim_a : source_color = vec3(0.93, 0.74, 0.25);
uniform vec3 trim_b : source_color = vec3(0.10, 0.09, 0.09);

varying flat float v_cid;
varying flat vec4 v_inst;
varying float v_h;

vec2 rotx(vec2 yz, vec2 piv, float a) {
	float c = cos(a), s = sin(a);
	vec2 d = yz - piv;
	return piv + vec2(d.x * c - d.y * s, d.x * s + d.y * c);
}

void vertex() {
	vec4 r0 = vec4(MODEL_MATRIX[0][0], MODEL_MATRIX[1][0], MODEL_MATRIX[2][0], MODEL_MATRIX[3][0]);
	vec4 r1 = vec4(MODEL_MATRIX[0][1], MODEL_MATRIX[1][1], MODEL_MATRIX[2][1], MODEL_MATRIX[3][1]);
	vec4 r2 = vec4(MODEL_MATRIX[0][2], MODEL_MATRIX[1][2], MODEL_MATRIX[2][2], MODEL_MATRIX[3][2]);
	float st = r2.x;
	float dead = step(3.5, st);
	float tst = sim_time - r2.y;
	float a = mix(alpha, 1.0, dead);
	vec2 p = mix(r0.xy, r0.zw, a);
	vec2 f = normalize(mix(r1.xy, r1.zw, a) + vec2(1e-4, 0.0));
	float seed = COLOR.b;
	float speed = r2.w;
	int part = int(UV.x + 0.5);
	vec2 piv = vec2(UV.y, UV2.x);
	vec3 v = VERTEX;
	float walk = clamp(speed * 0.45, 0.0, 1.0) * (1.0 - dead);
	float atk = (st > 2.5 && st < 3.5) ? 1.0 : 0.0;
	float bob = 0.0;
	float lunge = 0.0;
	if (kind < 1.5) {
		float ph = sim_time * (6.5 + speed * 0.9) + seed * 6.283;
		float sw = sin(ph) * walk;
		float ang = 0.0;
		float s1 = smoothstep(0.0, 0.16, tst), s2 = smoothstep(0.16, 0.28, tst), s3 = smoothstep(0.3, 0.62, tst);
		if (part == 2) ang = sw * 0.75;
		else if (part == 3) ang = -sw * 0.75;
		else if (part == 4) {
			ang = -sw * 0.4 - 0.25;
			if (kind > 0.5) ang = mix(-0.35 - sw * 0.3, -1.45, atk * (s1 - s3 * 0.9));
		} else if (part == 5) {
			ang = sw * 0.4 - 0.55;
			if (kind < 0.5) ang += atk * (-2.1 * s1 + 3.1 * s2 - 1.0 * s3);
			else ang = mix(ang + 0.3, -1.2, atk * (s1 - s3 * 0.9));
		}
		v.yz = rotx(v.yz, piv, ang);
		bob = abs(cos(ph)) * 0.05 * walk;
		if (kind < 0.5) lunge = atk * (s2 - s3) * 0.28;
	} else {
		float ph = sim_time * (5.0 + speed * 0.75) + seed * 6.283;
		float ang = 0.0;
		float s1 = smoothstep(0.0, 0.2, tst), s2 = smoothstep(0.2, 0.32, tst), s3 = smoothstep(0.35, 0.7, tst);
		if (part == 8) ang = sin(ph) * 0.8 * walk;
		else if (part == 9) ang = sin(ph + 0.9) * 0.8 * walk;
		else if (part == 10) ang = sin(ph + 3.1) * 0.75 * walk;
		else if (part == 11) ang = sin(ph + 4.0) * 0.75 * walk;
		else if (part == 5) ang = -0.15 + atk * (-0.9 * s1 + 1.5 * s2 - 0.6 * s3);
		v.yz = rotx(v.yz, piv, ang);
		bob = (sin(ph * 2.0) * 0.5 + 0.5) * 0.12 * walk;
		if (part < 7) v.y += sin(ph * 2.0 + 0.8) * 0.04 * walk;
		v.yz = rotx(v.yz, vec2(1.0, 0.0), sin(ph) * 0.06 * walk);
		lunge = atk * (s2 - s3) * 0.35;
	}
	if (part == 12) {
		v.x += sin(sim_time * 5.0 + seed * 40.0 + v.z * 2.5) * 0.3 * max(-(v.z + 0.3), 0.0);
	}
	v_h = (part == 6) ? 2.0 : v.y;
	v.y += bob;
	v.z += lunge;
	v *= usize * (0.93 + seed * 0.14);
	float fall = dead * min(tst / 0.5, 1.0);
	fall = fall * fall;
	float dir = (fract(seed * 7.13) > 0.5) ? 1.0 : -1.0;
	v.yz = rotx(v.yz, vec2(0.0, 0.0), fall * 1.5 * dir);
	v.x += fall * (fract(seed * 3.7) - 0.5) * 0.3;
	v.y += fall * 0.16 - dead * max(tst - 20.0, 0.0) * 0.3;
	if (part == 6) {
		if (COLOR.g < 0.5 || dead > 0.5) v = vec3(0.0);
	}
	vec3 right = vec3(f.y, 0.0, -f.x);
	vec3 fwd = vec3(f.x, 0.0, f.y);
	float gy = textureLod(height_tex, (p + 320.0) / 640.0, 0.0).g;
	vec3 w = vec3(p.x, gy, p.y) + right * v.x + vec3(0.0, v.y, 0.0) + fwd * v.z;
	if (st < 0.5) w = vec3(0.0, -500.0, 0.0);
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_cid = UV2.y;
	v_inst = vec4(COLOR.r, dead, exp(-max(sim_time - r2.z, 0.0) * 12.0), seed);
}

void fragment() {
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (n.z < 0.0) n = -n;
	NORMAL = n;
	int cid = int(v_cid + 0.5);
	float seed = v_inst.w;
	vec3 team = mix(team_a, team_b, step(0.5, v_inst.x));
	vec3 trim = mix(trim_a, trim_b, step(0.5, v_inst.x));
	vec3 c = team * (0.9 + fract(seed * 5.1) * 0.25);
	float metal = 0.0;
	float rough = 0.85;
	float emit = 0.0;
	if (cid == 1) c = vec3(0.78, 0.55, 0.40);
	else if (cid == 2) { c = vec3(0.42, 0.44, 0.48); metal = 0.55; rough = 0.5; }
	else if (cid == 3) c = vec3(0.13, 0.10, 0.08);
	else if (cid == 4) c = trim;
	else if (cid == 5) {
		float hsel = fract(seed * 11.3);
		c = hsel < 0.45 ? vec3(0.23, 0.13, 0.07) : (hsel < 0.75 ? vec3(0.09, 0.07, 0.06) : (hsel < 0.9 ? vec3(0.42, 0.28, 0.15) : vec3(0.62, 0.58, 0.52)));
	}
	else if (cid == 6) c = vec3(0.36, 0.23, 0.12);
	else if (cid == 7) { c = mix(team, vec3(1.0), 0.45); emit = 2.2; }
	else if (cid == 8) c = team * 0.55;
	if (v_inst.y > 0.5) {
		float g = dot(c, vec3(0.3, 0.5, 0.2));
		c = mix(vec3(g), c, 0.55) * 0.5;
	}
	c *= mix(0.6, 1.0, smoothstep(0.0, 1.0, v_h));
	ALBEDO = c;
	METALLIC = metal;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
	EMISSION = c * (0.10 + emit) + vec3(1.0, 0.85, 0.7) * v_inst.z * 0.3 * (1.0 - v_inst.y);
}
