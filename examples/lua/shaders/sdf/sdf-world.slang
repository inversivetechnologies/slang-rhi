// Where the SDF composition is in the world, for the passes that trace rays through it:
// the camera's raymarching (raymarch.slang) and the light's (shadow.slang).
//
// The composition sits at sdfOrigin and turns about its vertical axis by sdfSpin radians
// per second. It lies within sdfBoundsRadius of its origin -- whatever it spins to -- so a
// ray that misses that sphere misses the composition, and needs no marching at all.

#pragma once

#include "scene/scene-common.slang"

uniform float3 sdfOrigin;
uniform float sdfSpin;
uniform float sdfBoundsRadius;

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
