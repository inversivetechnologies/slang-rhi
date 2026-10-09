// Where the SDF composition is in the world, for the passes that trace rays through it:
// the camera's raymarching (raymarch.slang) and the light's (shadow.slang).
//
// The composition sits at sdfOrigin and turns about its vertical axis by sdfSpin radians
// per second. It lies within sdfBoundsRadius of its origin -- whatever it spins to -- so a
// ray that misses that sphere misses the composition, and needs no marching at all.
//
// The field itself comes from the DAG (sdf-dag.slang), or, with sdfUseCache = 1, from its
// cache baked into 3D textures (sdf-cache.slang), in the composition's own space either
// way: sdfFieldDistance and sdfFieldColor say which, for everything that samples it.

#pragma once

#include "scene/scene-common.slang"
#include "sdf-dag.slang"
#include "sdf-cache.slang"

uniform float3 sdfOrigin;
uniform float sdfSpin;
uniform float sdfBoundsRadius;
uniform uint sdfUseCache; // 1: sample the baked cache instead of evaluating the DAG

// The composition's distance at q (in its own space). (An if, not ?:, which would evaluate
// both.)
float sdfFieldDistance(float3 q)
{
    float d;
    if (sdfUseCache != 0)
    {
        d = sampleSdfCache(q) * kSdfCacheStep; // filtering can overestimate a little
    }
    else
    {
        d = evaluateSdf(q).distance;
    }
    return d;
}

float3 sdfFieldColor(float3 q)
{
    float3 color;
    if (sdfUseCache != 0)
    {
        color = sampleSdfCacheColor(q);
    }
    else
    {
        color = evaluateSdf(q).color;
    }
    return color;
}

// The spacing for taking the field's gradient: finer than the cache holds is noise.
float sdfGradientStep()
{
    return sdfUseCache != 0 ? 0.5 * sdfCacheVoxelSize() : 0.0015;
}

// The world into the composition's own space.
float3 toSdfSpace(float3 world)
{
    return rotateYaw(world - sdfOrigin, -sdfSpin * time);
}

// A direction from the composition's space back into the world's.
float3 fromSdfSpaceDirection(float3 v)
{
    return rotateYaw(v, sdfSpin * time);
}

// The stretch of the ray origin + t * direction (unit length) inside the bounding sphere:
// (enter, exit). Misses have enter > exit.
float2 sdfBoundsInterval(float3 origin, float3 direction)
{
    float3 oc = origin - sdfOrigin;
    float b = dot(oc, direction);
    float c = dot(oc, oc) - sdfBoundsRadius * sdfBoundsRadius;
    float h = b * b - c;
    if (h < 0)
    {
        return float2(1, -1);
    }
    h = sqrt(h);
    return float2(-b - h, -b + h);
}
