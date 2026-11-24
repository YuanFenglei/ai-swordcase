shader_type spatial;
render_mode cull_disabled, depth_draw_never, specular_schlick_ggx, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec3 shallow : source_color = vec3(0.07, 0.42, 0.40);
uniform vec3 deep : source_color = vec3(0.010, 0.085, 0.13);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float sky_vis = 1.0;
uniform vec3 zenith : source_color = vec3(0.07, 0.17, 0.36);
uniform vec3 horizon_sun : source_color = vec3(1.0, 0.56, 0.27);
uniform vec3 horizon_far : source_color = vec3(0.52, 0.47, 0.60);

varying vec3 v_wp;

// sum of directional waves, returns height and analytic gradient
vec3 waves(vec2 p, float t) {
	float h = 0.0;
	vec2 g = vec2(0.0);
	float a = 0.5;
	float f = 0.16;
	vec2 d = vec2(0.8, 0.6);
	for (int i = 0; i < 7; i++) {
		float ph = dot(p, d) * f + t * (0.9 + 0.25 * float(i)) + float(i) * 1.7;
		h += a * sin(ph);
		g += a * f * cos(ph) * d;
		// domain warp keeps crests from lining up
		p += d * cos(ph) * a * 0.6;
		d = mat2(vec2(0.31, 0.95), vec2(-0.95, 0.31)) * d;
		a *= 0.62;
		f *= 1.55;
	}
	return vec3(h, g);
}

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 wv = waves(v_wp.xz, TIME);
	float vd = length(VERTEX);
	float fade = 1.0 / (1.0 + vd * 0.02);
	vec3 wn = normalize(vec3(-wv.y * 1.3 * fade, 1.0, -wv.z * 1.3 * fade));
	vec3 view_w = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	float facing = FRONT_FACING ? 1.0 : -1.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz) * facing;

	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 up = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -up.z / up.w;
	float diff = max(scene_z + VERTEX.z, 0.0);

	vec2 ruv = SCREEN_UV + wn.xz * 0.03 * clamp(diff * 0.25, 0.0, 1.0) / (1.0 + vd * 0.03);
	float rdepth = texture(depth_tex, ruv).r;
	vec4 rup = INV_PROJECTION_MATRIX * vec4(ruv * 2.0 - 1.0, rdepth, 1.0);
	if (-rup.z / rup.w + VERTEX.z < 0.0) ruv = SCREEN_UV;
	vec3 behind = texture(screen_tex, ruv).rgb;

	float k = 1.0 - exp(-diff * 0.15);
	vec3 body = mix(behind * mix(vec3(1.0), shallow * 2.0, clamp(diff * 0.35, 0.0, 1.0)), mix(shallow, deep, k) * 0.55 * mix(0.06, 1.0, sky_vis), clamp(k * 1.2 + 0.1, 0.0, 1.0) * mix(0.6, 1.0, sky_vis));

	// sky reflection, same gradient as the sky shader
	vec3 rd = reflect(view_w, wn);
	rd.y = abs(rd.y);
	float az = clamp(dot(normalize(rd.xz + vec2(1e-5)), normalize(sun_dir.xz)) * 0.5 + 0.5, 0.0, 1.0);
	vec3 hz = mix(horizon_far, horizon_sun, pow(az, 1.6));
	vec3 sky = mix(hz, zenith, pow(clamp(rd.y, 0.0, 1.0), 0.42));
	float sd = clamp(dot(rd, sun_dir), 0.0, 1.0);
	sky += vec3(1.0, 0.55, 0.22) * pow(sd, 6.0) * 0.5 + vec3(1.0, 0.8, 0.55) * pow(sd, 260.0) * 5.0;
	float fres = 0.03 + 0.97 * pow(1.0 - clamp(dot(-view_w, wn), 0.0, 1.0), 5.0);
	fres = FRONT_FACING ? fres : 0.0;

	float foam = smoothstep(0.8, 0.0, diff + wv.x * 0.5) * 0.7;
	vec3 col = mix(body, sky * sky_vis, fres);
	col = mix(col, vec3(0.86, 0.82, 0.76) * mix(0.1, 1.0, sky_vis), foam);
	// melt into the horizon
	float far = smoothstep(260.0, 2200.0, vd);
	col = mix(col, mix(horizon_far, horizon_sun, pow(clamp(dot(normalize(view_w.xz + vec2(1e-5)), normalize(sun_dir.xz)) * 0.5 + 0.5, 0.0, 1.0), 1.6)), far);
	col += (vec3(0.02, 0.13, 0.12) * fres + vec3(0.004, 0.02, 0.022)) * (1.0 - sky_vis) * (0.7 + 0.6 * wv.x);

	ALBEDO = vec3(0.0);
	EMISSION = col;
	ROUGHNESS = 0.2;
	SPECULAR = 0.5;
	AO = 0.0;
}

void light() {
	// only local lights reflect; the sun glint is handled above
	if (!LIGHT_IS_DIRECTIONAL) {
		vec3 h = normalize(VIEW + LIGHT);
		float s = pow(max(dot(NORMAL, h), 0.0), 70.0);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * s * 0.6;
	}
}
