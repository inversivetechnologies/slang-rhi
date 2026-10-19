// Gaussian splatting, step 3: draws the sorted splats back to front, each as a quad
// covering its ellipse, blended with premultiplied alpha.
//
// Six vertices per splat, fetched by SV_VertexID: vertex v belongs to the splat in sorted
// position v / 6. Slots past the drawn splats become degenerate quads.
//
// depthFragmentMain draws the same quads into a depth buffer instead, for compositing
// with other passes by depth: where a splat is at least fairly opaque, it writes the
// splat's depth (its center's, for the whole splat), and depth testing keeps the nearest.
//
// depthBlendFragmentMain draws them, blended as the colors are (premultiplied, back to
// front), into an rgba16f target as (view depth x alpha, 0, 0, alpha): the result's red over
// its alpha is the depth of what the pixel shows, weighted as the colors are -- smooth, and
// wherever the splats cover it together, however faint each (splat/depth-resolve.slang turns
// it into a depth). What the composite, the screen-space effects and TAA rely on.
//
// Clipping (clip.slang): a splat across the clip field's surface is clipped per pixel --
// its vertices hand the fragments which splat it is, and each fragment finds where the
// splat is densest along its own ray, and clips there.

#include "splat-common.slang"
#include "ply.slang"
#include "clip.slang"

StructuredBuffer<ProjectedSplat> projected;
StructuredBuffer<float> sortKeys;
StructuredBuffer<uint> sortValues;
StructuredBuffer<uint2> drawnSplats; // per drawn splat: which splat and instance it is
StructuredBuffer<uint> drawCount; // [0]: how many splats are drawn; the rest of the slots aren't
uniform float2 viewportSize; // provided by the host
uniform SplatCamera camera;

struct VertexOutput
{
    float4 position : SV_Position;
    float2 offset : OFFSET; // position on the ellipse, in units of its half axes (3 sigma)
    nointerpolation float4 color : COLOR;
    // For clipping per pixel: the splat's slot + 1, or 0 not to clip.
    nointerpolation uint clipSlot : CLIP;
};

// The ray from the camera through a pixel (SV_Position.xy), as preprocess.slang projects.
float3 pixelRay(float2 pixel)
{
    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float tanY = tan(camera.fovY * 0.5);
    float tanX = tanY * viewportSize.x / viewportSize.y;
    float2 ndc = float2(pixel.x / viewportSize.x * 2 - 1, 1 - pixel.y / viewportSize.y * 2);
    return normalize(forward + right * ndc.x * tanX + up * ndc.y * tanY);
}

// Whether the fragment is clipped away.
bool clippedAway(VertexOutput input)
{
    if (input.clipSlot == 0)
    {
        return false;
    }
    uint2 drawn = drawnSplats[input.clipSlot - 1];
    beginInstance(drawn.y);
    uint base = splatBase(drawn.x);
    float3 ray = pixelRay(input.position.xy);
    return clipAtRay(camera.eye, ray, splatWorldPosition(base), splatWorldCovariance(base)) < 0;
}

static const float2 kCorners[6] = {
    float2(-1, -1), float2(1, -1), float2(1, 1),
    float2(-1, -1), float2(1, 1), float2(-1, 1),
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    VertexOutput output;
    uint slot = vertexId / 6;
    if (slot >= drawCount[0] || sortKeys[slot] >= kCulledKey * 0.5)
    {
        // All six vertices at one point: nothing is rasterized.
        output.position = float4(0, 0, 0, 1);
        output.offset = float2(0, 0);
        output.color = float4(0, 0, 0, 0);
        output.clipSlot = 0;
        return output;
    }

    ProjectedSplat splat = projected[sortValues[slot]];
    float2 corner = kCorners[vertexId % 6];
    float2 pixel = splat.centerAxis1.xy + corner.x * splat.centerAxis1.zw + corner.y * splat.axis2.xy;
    output.position = float4(pixel.x / viewportSize.x * 2 - 1, 1 - pixel.y / viewportSize.y * 2, depthFromViewZ(splat.axis2.z), 1);
    output.offset = corner;
    output.color = splat.color;
    output.clipSlot = splat.axis2.w > 0.5 ? sortValues[slot] + 1 : 0;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The Gaussian falls off over the half axes, which are 3 sigma long: exp(-(3r)^2 / 2).
    float alpha = min(0.99, input.color.a * exp(-4.5 * dot(input.offset, input.offset)));
    if (alpha < 1.0 / 255.0 || clippedAway(input))
    {
        discard;
    }
    return float4(input.color.rgb * alpha, alpha);
}

[shader("fragment")]
float4 depthBlendFragmentMain(VertexOutput input) : SV_Target
{
    float alpha = min(0.99, input.color.a * exp(-4.5 * dot(input.offset, input.offset)));
    if (alpha < 1.0 / 255.0 || clippedAway(input))
    {
        discard;
    }
    // The splat's center's view depth: the quad's z/w (the same at every vertex), undone.
    float viewZ = kDepthNear * kDepthFar / (kDepthFar - input.position.z * (kDepthFar - kDepthNear));
    return float4(viewZ * alpha, 0, 0, alpha);
}

// How opaque a splat has to be at a pixel to count as a surface in the depth buffer.
static const float kDepthOpacity = 0.3;

[shader("fragment")]
void depthFragmentMain(VertexOutput input)
{
    if (input.color.a * exp(-4.5 * dot(input.offset, input.offset)) < kDepthOpacity || clippedAway(input))
    {
        discard;
    }
}
