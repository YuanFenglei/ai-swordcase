shader_type canvas_item;

uniform sampler2D base_tex : filter_linear;
uniform sampler2D unit_tex : filter_nearest;
uniform vec3 team_a : source_color = vec3(0.25, 0.55, 1.0);
uniform vec3 team_b : source_color = vec3(1.0, 0.25, 0.15);

void fragment() {
	vec3 c = texture(base_tex, UV).rgb;
	float u = texture(unit_tex, UV).r * 255.0;
	if (u > 1.5) c = team_b;
	else if (u > 0.5) c = team_a;
	COLOR = vec4(c, 1.0);
}
