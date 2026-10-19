// The splats' depth, from their blended depth (render.slang's depthBlendFragmentMain:
// view depth x alpha, and alpha, composited back to front): where they cover a pixel at
// least kDepthCoverage together, the depth of what it shows (red over alpha), as z/w; else
// the far plane. Written into the depth texture the composite, the screen-space effects
// and TAA read, as the depth pass would.

#include "splat-common.slang"

static const float kDepthCoverage = 0.2;

Texture2D<float4> depthBlend;
uniform float2 viewportSize; // provided by the host: the target's size

[shader("compute")]
[numthreads(8, 8, 1)]
void resolveMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float> depthResolved)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    float4 b = depthBlend.Load(int3(tid.xy, 0));
    depthResolved[tid.xy] = b.a >= kDepthCoverage ? depthFromViewZ(b.r / b.a) : 1.0;
}
