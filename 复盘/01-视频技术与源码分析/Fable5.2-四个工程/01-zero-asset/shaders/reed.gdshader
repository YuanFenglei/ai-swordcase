shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_burley;
// Bioluminescent reeds: wind sway + parted by the walker and the boss.
uniform vec3 base_col : source_color = vec3(0.03, 0.05, 0.07);
uniform vec3 tip_col : source_color = vec3(0.1, 0.95, 0.8);
global uniform vec3 push_a;
global uniform vec3 push_b;
varying float ph;

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float hgt = UV.y;
	ph = fract(root.x * 0.137 + root.z * 0.291);
	float t = TIME;
	vec2 wind = vec2(sin(t * 1.3 + root.x * 0.21 + root.z * 0.1), cos(t * 0.9 + root.z * 0.17)) * 0.22;
	wind += vec2(1.0, 0.4) * (0.25 + 0.25 * sin(t * 0.5 + root.x * 0.04 + root.z * 0.03));
	vec2 da = root.xz - push_a.xz;
	vec2 db = root.xz - push_b.xz;
	float pa = smoothstep(5.5, 1.0, length(da));
	float pb = smoothstep(14.0, 3.0, length(db));
	vec2 off = wind + normalize(da + vec2(1e-4)) * pa * 1.3 + normalize(db + vec2(1e-4)) * pb * 1.6;
	// blades right in front of the lens shrink away instead of slicing the frame
	float nearcam = smoothstep(1.2, 4.5, distance(root, CAMERA_POSITION_WORLD));
	VERTEX.y = mix(root.y, VERTEX.y, nearcam);
	float k = hgt * hgt * nearcam;
	VERTEX.xz += off * k;
	VERTEX.y -= dot(off, off) * 0.22 * k;
	NORMAL = normalize(vec3(off.x * 0.3, 1.0, off.y * 0.3));
}

void fragment() {
	float g = pow(UV.y, 2.5);
	float pulse = 0.65 + 0.35 * sin(TIME * 2.0 + ph * 40.0);
	ALBEDO = mix(base_col, tip_col * 0.4, UV.y);
	ROUGHNESS = 0.6;
	EMISSION = tip_col * g * pulse * 2.6;
}
