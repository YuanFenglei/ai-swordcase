#version 450
layout(local_size_x = 8, local_size_y = 8) in;
#include "common.inc"
layout(set = 0, binding = 2, std430) restrict readonly buffer Grid { int g[]; };
layout(set = 0, binding = 7, r32f) uniform restrict writeonly image2D column;
void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (c.x >= P.grid.x || c.y >= P.grid.z) return;
	float s = 0.0;
	for (int y = 0; y < P.grid.y; y++) s += dec(g[cellIndex(ivec3(c.x, y, c.y)) * 4 + 3]);
	imageStore(column, c, vec4(s / P.fluid.y, 0.0, 0.0, 1.0));
}
