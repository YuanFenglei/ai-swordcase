#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, r32f) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform PC {
	vec4 a; // dir.xy, filter radius in pixels at depth 1, depth threshold
	vec4 b; // max radius px, stride, 0, 0
} pc;
void main() {
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = textureSize(src, 0);
	if (pix.x >= size.x || pix.y >= size.y) return;
	float zc = texelFetch(src, pix, 0).r;
	if (zc > 9.0e4) {
		imageStore(dst, pix, vec4(zc));
		return;
	}
	float rpx = clamp(pc.a.z / zc, 1.0, pc.b.x);
	int stride = int(pc.b.y);
	int R = int(ceil(rpx / float(stride)));
	float sigma = max(rpx * 0.5, 0.5);
	float inv2s2 = 1.0 / (2.0 * sigma * sigma);
	float delta = pc.a.w;
	ivec2 dir = ivec2(pc.a.xy);
	float sum = 0.0, wsum = 0.0;
	for (int i = -R; i <= R; i++) {
		ivec2 q = clamp(pix + dir * i * stride, ivec2(0), size - 1);
		float zs = texelFetch(src, q, 0).r;
		if (zs > zc + delta) continue;
		zs = max(zs, zc - delta);
		float d = float(i * stride);
		float w = exp(-d * d * inv2s2);
		sum += zs * w;
		wsum += w;
	}
	imageStore(dst, pix, vec4(sum / max(wsum, 1e-5)));
}
