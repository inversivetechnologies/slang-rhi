// The splat effects: a field that moves and colors splats -- in view (preprocess.slang,
// before it culls and projects them; the lighting takes the offsets it wrote), in the
// levels of detail (lod.slang: what the effects may move into view isn't counted as off
// screen), in the shadows they cast (shadow.slang) and in the global SDF
// (gi/global-sdf-splats.slang), and in the TAA's motion (preprocess.slang: where the
// field moved a splat since the frame before). Spheres in the world, each moving to and fro along an axis
// and round a circle, by `time` (the host provides no per-frame data for them):
//
//   color     the splats inside take the effect's color, by its strength, fading out over
//             the sphere's outer fifth
//   displace  the splats inside are pushed away from its center, by up to its strength
//             (at the center; smoothly less out to the radius)
//
// Only the dynamic instances' splats are affected (ply.slang: placementDynamic); the
// static ones keep their place and color, and can be cached as they are.

#pragma once

#include "common/time.slang"

// Four float4s per effect:
//   [0] xyz: center (in the world), w: 0 color, 1 displace
//   [1] xyz: the color (display space, as the splats'), w: radius
//   [2] xyz: how far it moves to either side of the center, w: how fast (radians per second)
//   [3] x: the radius of a circle it goes round (about y), y: how fast (radians per
//       second), z: strength (color: how much of it; displace: how far, world units)
StructuredBuffer<float4> effectShapes;
uniform uint effectCount;
uniform float timeDelta; // provided by the host: the time since the frame before (0 while paused)

// Effect k's center at time `t`.
float3 effectCenterAt(uint k, float t)
{
    float4 a = effectShapes[4 * k];
    float4 c = effectShapes[4 * k + 2];
    float4 d = effectShapes[4 * k + 3];
    float angle = t * d.y;
    return a.xyz + c.xyz * sin(t * c.w) + d.x * float3(cos(angle), 0, sin(angle));
}

float3 effectCenter(uint k)
{
    return effectCenterAt(k, time);
}

// How far the effects move a splat centered at `world` (its own place), at time `t`.
float3 effectDisplacementAt(float3 world, float t)
{
    float3 offset = float3(0, 0, 0);
    for (uint k = 0; k < effectCount; ++k)
    {
        if (effectShapes[4 * k].w < 0.5)
            continue;
        float3 q = world - effectCenterAt(k, t);
        float distance = length(q);
        float f = saturate(1.0 - distance / effectShapes[4 * k + 1].w);
        offset += (distance > 1e-5 ? q / distance : float3(0, 1, 0)) * effectShapes[4 * k + 3].z * f * f * (3.0 - 2.0 * f);
    }
    return offset;
}

// ... now.
float3 effectDisplacement(float3 world)
{
    return effectDisplacementAt(world, time);
}

// How far the effects may move a splat within `radius` of `center`: the strengths of the
// displacements whose spheres reach that far (each moves a splat by at most its strength).
float effectReach(float3 center, float radius)
{
    float reach = 0;
    for (uint k = 0; k < effectCount; ++k)
    {
        if (effectShapes[4 * k].w >= 0.5 && length(center - effectCenter(k)) < radius + effectShapes[4 * k + 1].w)
            reach += effectShapes[4 * k + 3].z;
    }
    return reach;
}

// A splat's color (display space) at `world`, as the effects color it.
float3 effectColor(float3 world, float3 color)
{
    for (uint k = 0; k < effectCount; ++k)
    {
        float4 b = effectShapes[4 * k + 1];
        if (effectShapes[4 * k].w >= 0.5)
            continue;
        float inside = 1.0 - smoothstep(0.8 * b.w, b.w, length(world - effectCenter(k)));
        color = lerp(color, b.rgb, inside * effectShapes[4 * k + 3].z);
    }
    return color;
}
