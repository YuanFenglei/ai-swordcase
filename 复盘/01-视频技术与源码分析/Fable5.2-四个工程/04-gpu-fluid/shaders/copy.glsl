#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2D dst;
void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst);
	if (pix.x >= size.x || pix.y >= size.y) return;
	imageStore(dst, pix, texelFetch(src, pix, 0));
}
