// Gaussian splatting, step 3: draws the sorted splats back to front, each as a quad
// covering its ellipse, blended with premultiplied alpha.
//
// Six vertices per splat, fetched by SV_VertexID: vertex v belongs to the splat in sorted
// position v / 6. Splats that were culled sort to the end and become degenerate quads.
//
// depthFragmentMain draws the same quads into a depth buffer instead, for compositing
// with other passes by depth: where a splat is at least fairly opaque, it writes the
// splat's depth (its center's, for the whole splat), and depth testing keeps the nearest.

#include "splat-common.slang"

StructuredBuffer<ProjectedSplat> projected;
StructuredBuffer<float> sortKeys;
StructuredBuffer<uint> sortValues;
uniform float2 viewportSize; // provided by the host

struct VertexOutput
{
    float4 position : SV_Position;
    float2 offset : OFFSET; // position on the ellipse, in units of its half axes (3 sigma)
    nointerpolation float4 color : COLOR;
};

static const float2 kCorners[6] = {
    float2(-1, -1), float2(1, -1), float2(1, 1),
    float2(-1, -1), float2(1, 1), float2(-1, 1),
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    VertexOutput output;
    uint slot = vertexId / 6;
    if (sortKeys[slot] >= kCulledKey * 0.5)
    {
        // All six vertices at one point: nothing is rasterized.
        output.position = float4(0, 0, 0, 1);
        output.offset = float2(0, 0);
        output.color = float4(0, 0, 0, 0);
        return output;
    }

    ProjectedSplat splat = projected[sortValues[slot]];
    float2 corner = kCorners[vertexId % 6];
    float2 pixel = splat.centerAxis1.xy + corner.x * splat.centerAxis1.zw + corner.y * splat.axis2.xy;
    output.position = float4(pixel.x / viewportSize.x * 2 - 1, 1 - pixel.y / viewportSize.y * 2, depthFromViewZ(splat.axis2.z), 1);
    output.offset = corner;
    output.color = splat.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The Gaussian falls off over the half axes, which are 3 sigma long: exp(-(3r)^2 / 2).
    float alpha = min(0.99, input.color.a * exp(-4.5 * dot(input.offset, input.offset)));
    if (alpha < 1.0 / 255.0)
    {
        discard;
    }
    return float4(input.color.rgb * alpha, alpha);
}

// How opaque a splat has to be at a pixel to count as a surface in the depth buffer.
static const float kDepthOpacity = 0.3;

[shader("fragment")]
void depthFragmentMain(VertexOutput input)
{
    if (input.color.a * exp(-4.5 * dot(input.offset, input.offset)) < kDepthOpacity)
    {
        discard;
    }
}
