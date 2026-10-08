// Splat shadows, step 1: one thread per splat (merged ones included: splat-lod.h) writes
// what shadow.slang needs to draw it into the light's view -- its center, opacity, and 3D
// covariance, in the file's frame (only flipped, if it is). shadow.slang places them per
// instance. The splats don't change, so this runs once, not every frame; which of them
// are drawn, for which instances, is picked every frame (shadow-select.slang).
//
// See shadow.slang for how the shadows are made.

#include "ply.slang"

// Three float4s per splat:
//   [3i]     xyz: center in the file's frame, w: opacity (0: casts nothing)
//   [3i + 1] the covariance's xx, xy, xz, yy
//   [3i + 2] the covariance's yz, zz, and two unused
RWStructuredBuffer<float4> shadowCastersOut;

// Splats fainter than this don't noticeably dim the light; skipping them saves drawing.
static const float kMinOpacity = 1.0 / 255.0;

[shader("compute")]
[numthreads(256, 1, 1)]
void shadowCastersMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x;
    if (i >= splatCount)
    {
        return;
    }
    beginFileFrame();
    uint base = splatBase(i);
    float opacity = splatOpacity(base);
    float3x3 c = splatWorldCovariance(base);
    shadowCastersOut[3 * i] = float4(splatWorldPosition(base), opacity >= kMinOpacity ? opacity : 0.0);
    shadowCastersOut[3 * i + 1] = float4(c[0][0], c[0][1], c[0][2], c[1][1]);
    shadowCastersOut[3 * i + 2] = float4(c[1][2], c[2][2], 0, 0);
}
