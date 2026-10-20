// Where a pixel's surface was the frame before (post/taa.slang, post/dlss-inputs.slang):
// moved back by its own motion -- the bodies' motion vectors (scene/motion.slang), the SDF
// composition's spin, or the splats' (what the effects move, blended as their depth is:
// splat/render.slang); everything else stands still -- for the last frame's camera to see.

#pragma once

#include "ssao-common.slang"

Texture2D<float4> meshMotion;  // previous world position minus current, where a body is nearest
Texture2D<float4> splatMotion; // the splats': the same times their alpha, and their alpha (blended)
uniform EffectsCamera prevCamera;
uniform float3 sdfOrigin;
uniform float sdfSpin;
uniform float timeDelta; // provided by the host: 0 while paused

// The world position the surface at pixel `p` (view depth `z`, at `world` now) had the
// frame before.
float3 previousWorld(int2 p, float z, float3 world)
{
    float3 previous = world;
    if (isBackground(z))
        return previous;
    int3 t = int3(p, 0);
    float meshZ = viewDistance(meshDepth.Load(t));
    float sdfZ = viewDistance(sdfDepth.Load(t));
    if (meshZ <= z * 1.0001)
    {
        previous += meshMotion.Load(t).xyz;
    }
    else if (sdfZ <= z * 1.0001)
    {
        float a = -sdfSpin * timeDelta, c = cos(a), s = sin(a);
        float3 d = world - sdfOrigin;
        previous = sdfOrigin + float3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z);
    }
    else
    {
        // The splats (nearest, as neither is): the motion of what the pixel shows, their
        // blended motion over their blended alpha.
        float4 m = splatMotion.Load(t);
        previous += m.a > 1e-3 ? m.xyz / m.a : float3(0, 0, 0);
    }
    return previous;
}
