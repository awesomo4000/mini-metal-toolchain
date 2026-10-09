#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut testVertex(uint vid [[vertex_id]], const device float2 *positions [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 testFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return tex.sample(s, in.uv) * float4(in.uv, 1, 1);
}

kernel void testKernel(device float *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    data[id] = sqrt(data[id]);
}
