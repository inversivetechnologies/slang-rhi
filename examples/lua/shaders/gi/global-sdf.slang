// The GI's global SDF (lib/scene/gi.lua): a distance field of the whole scene near the
// camera, with each voxel's albedo -- what rays leave the screen into (the cascades'
// fallback) and what the world-space probes trace.
//
// A 3D texture (gsdfVolume, rgba16f: rgb albedo, a distance) of gsdfResolution^3 voxels,
// gsdfVoxel apart, its first voxel's corner at gsdfOrigin; it follows the camera (snapped
// to 4 voxels, so it doesn't swim). Narrow-band: distances are exact within gsdfBand of a
// surface and clamped there, which still steps a sphere tracer gsdfBand at a time through
// empty space. Rebuilt every frame (global-sdf-bake.slang), as bodies move.

#pragma once

Texture3D<float4> gsdfVolume;
SamplerState gsdfSampler; // trilinear, clamped
uniform float3 gsdfOrigin;
uniform float gsdfVoxel;
uniform uint gsdfResolution;
uniform float gsdfBand;

float3 gsdfUvw(float3 world)
{
    return (world - gsdfOrigin) / (gsdfVoxel * float(gsdfResolution));
}

bool gsdfInside(float3 world)
{
    float3 uvw = gsdfUvw(world);
    return all(uvw > 0.0) && all(uvw < 1.0);
}

float gsdfDistance(float3 world)
{
    return gsdfVolume.SampleLevel(gsdfSampler, gsdfUvw(world), 0).a;
}

float3 gsdfAlbedo(float3 world)
{
    return gsdfVolume.SampleLevel(gsdfSampler, gsdfUvw(world), 0).rgb;
}

float3 gsdfNormal(float3 world)
{
    float e = 0.5 * gsdfVoxel;
    float3 n = float3(
        gsdfDistance(world + float3(e, 0, 0)) - gsdfDistance(world - float3(e, 0, 0)),
        gsdfDistance(world + float3(0, e, 0)) - gsdfDistance(world - float3(0, e, 0)),
        gsdfDistance(world + float3(0, 0, e)) - gsdfDistance(world - float3(0, 0, e)));
    float l = length(n);
    return l > 1e-6 ? n / l : float3(0, 1, 0);
}

// Sphere-traces from `origin` along `dir` (unit) for up to `maxT`: true and the distance
// `t` where it hits; false if it leaves the volume or reaches maxT first.
bool gsdfTrace(float3 origin, float3 dir, float maxT, out float t)
{
    t = 0.0;
    float hitAt = 0.25 * gsdfVoxel;
    [loop]
    for (int i = 0; i < 64; ++i)
    {
        float3 p = origin + dir * t;
        if (!gsdfInside(p))
            return false;
        float d = gsdfDistance(p);
        if (d < hitAt)
        {
            // Onto the surface: the field is near linear this close (no contour steps).
            t += d;
            t += gsdfDistance(origin + dir * t);
            return true;
        }
        t += max(d, 0.5 * gsdfVoxel);
        if (t > maxT)
            return false;
    }
    return false;
}
