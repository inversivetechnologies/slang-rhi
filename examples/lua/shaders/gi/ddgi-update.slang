// Updating the world-space probes (ddgi.slang) every frame:
//
//   traceMain       one thread per ray (kRays a probe, a spherical Fibonacci set turned
//                   anew each frame): traced through the global SDF; what it hits shaded by
//                   the key light (shadowed), the point lights, and the probes' own
//                   irradiance there (last frame's: the light's further bounces); a miss
//                   sees the sky. -> ddgiRays: radiance, distance
//   irradianceMain  one thread per texel of a probe's irradiance and radiance maps: the
//                   rays, cosine-weighted (irradiance) or in a narrow lobe (radiance),
//                   blended with what the texel held (ddgiHysteresis of it), unless the
//                   probe's slot just changed hands
//   depthMain       the same for the depth map: the rays' distances and squares, in a
//                   narrow lobe
//   stampMain       each slot: the world cell it now holds
//
// World space, not screen space: a probe's history is its own place's.

#include "scene/shadow-lookup.slang"
#include "global-sdf.slang"
#include "ddgi.slang"

static const uint kRays = 96;
static const float kMaxDistance = 30.0;

uniform float ddgiHysteresis;
uniform float3 ddgiSky;     // the light of a ray that leaves the volume
uniform uint frameCounter;  // provided by the host
RWStructuredBuffer<float4> ddgiRays;    // per probe and ray: radiance, distance
RWStructuredBuffer<uint> ddgiProbeStamps; // per slot: the world cell it holds (hashed)

// Ray r of the frame's set: spherical Fibonacci, turned by a rotation that changes every
// frame (so that, over frames, a probe sees every direction).
float3 rayDirection(uint r)
{
    float golden = 2.39996323;
    float z = 1.0 - (2.0 * float(r) + 1.0) / float(kRays);
    float radius = sqrt(max(0.0, 1.0 - z * z));
    float phi = float(r) * golden;
    float3 d = float3(cos(phi) * radius, sin(phi) * radius, z);
    // The frame's rotation: about a pseudo-random axis, by a pseudo-random angle.
    uint s = frameCounter * 747796405u + 2891336453u;
    float a = float(s & 0xFFFFu) / 65535.0 * 6.2831853;
    float3 axis = normalize(float3(float((s >> 16) & 0xFFu) - 127.5, float((s >> 24) & 0xFFu) - 127.5, 37.0));
    float c = cos(a), sn = sin(a);
    return d * c + cross(axis, d) * sn + axis * dot(axis, d) * (1.0 - c);
}

uint cellStamp(int3 cell)
{
    return (uint(cell.x & 1023) << 20) | (uint(cell.y & 1023) << 10) | uint(cell.z & 1023) | 0x40000000u;
}

// The light leaving a surface point (albedo, normal) toward a probe's ray.
float3 shadeHit(float3 p, float3 n, float3 albedo)
{
    float3 lightPos = lightPosition();
    float3 toLight = lightPos - p;
    float distanceToLight = length(toLight);
    toLight /= max(distanceToLight, 1e-4);
    float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
    float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);
    float diffuse = saturate(dot(n, toLight));
    // The shadow maps' (meshes', splats') only: the SDFs' soft shadow, a march of their
    // whole field, is too much for every probe ray.
    float shadow = 0.0;
    if (diffuse > 0)
    {
        float3 d = p + n * 0.05 - lightPos;
        uint face = cubeFaceOf(d);
        int3 at = int3(int2(shadowFaceOrigin(face, shadowFaceSize)) + int2(shadowFaceTexel(d, face, shadowFaceSize)), 0);
        shadow = shadowTexelLight(at, length(d) - 0.05);
    }
    float3 direct = light.color * attenuation * diffuse * shadow;
    // The point lights (all of them: probes are few), unshadowed as everywhere.
    for (uint i = 0; i < min(pointLightCount, kMaxPointLights); ++i)
    {
        float4 placement = pointLightData[2 * i];
        float4 look = pointLightData[2 * i + 1];
        float3 l = placement.xyz - p;
        float dl = length(l);
        if (dl >= placement.w)
            continue;
        float wl = saturate(1.0 - pow(dl / placement.w, 4.0));
        direct += look.rgb * look.w * wl * wl / (1.0 + dl * dl) * saturate(dot(n, l / max(dl, 1e-4)));
    }
    float3 indirect = ddgiSampleIrradiance(p, n);
    return albedo * (direct + indirect);
}

[shader("compute")]
[numthreads(32, 1, 1)]
void traceMain(uint3 tid: SV_DispatchThreadID)
{
    uint r = tid.x, probe = tid.y;
    uint count = uint(ddgiCounts.x * ddgiCounts.y * ddgiCounts.z);
    if (r >= kRays || probe >= count)
        return;
    float3 origin = ddgiProbePosition(ddgiGridOf(int(probe)));
    float3 dir = rayDirection(r);
    float t;
    float4 result;
    if (gsdfTrace(origin, dir, kMaxDistance, t))
    {
        float3 p = origin + dir * t;
        float3 n = gsdfNormal(p);
        // A ray that started inside something meets its back face: it sees nothing, and
        // its short distance keeps the probe from being trusted that way.
        if (dot(n, dir) > 0.0)
            result = float4(0, 0, 0, t * 0.2);
        else
            result = float4(shadeHit(p, n, gsdfAlbedo(p)), t);
    }
    else
    {
        result = float4(ddgiSky, kMaxDistance);
    }
    ddgiRays[probe * kRays + r] = result;
}

float hysteresisFor(int3 grid, int slot)
{
    return ddgiProbeStamps[slot] == cellStamp(ddgiWorldCell(grid)) ? ddgiHysteresis : 0.0;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void irradianceMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> irradianceOut,
                    uniform RWTexture2D<float4> radianceOut)
{
    uint texel = tid.x, probe = tid.y;
    uint count = uint(ddgiCounts.x * ddgiCounts.y * ddgiCounts.z);
    if (texel >= kIrradianceRes * kIrradianceRes || probe >= count)
        return;
    int3 grid = ddgiGridOf(int(probe));
    int slot = ddgiSlot(grid);
    uint2 t2 = uint2(texel % kIrradianceRes, texel / kIrradianceRes);
    float3 dir = octDecode((float2(t2) + 0.5) / float(kIrradianceRes) * 2.0 - 1.0);
    float3 irradiance = float3(0, 0, 0), radiance = float3(0, 0, 0);
    float irradianceWeights = 0, radianceWeights = 0;
    for (uint r = 0; r < kRays; ++r)
    {
        float4 ray = ddgiRays[probe * kRays + r];
        float c = dot(dir, rayDirection(r));
        float wi = max(0.0, c);
        irradiance += ray.rgb * wi;
        irradianceWeights += wi;
        float wr = pow(max(0.0, c), 24.0);
        radiance += ray.rgb * wr;
        radianceWeights += wr;
    }
    irradiance /= max(irradianceWeights, 1e-4);
    radiance = radianceWeights > 1e-4 ? radiance / radianceWeights : irradiance;
    uint2 at = uint2(uint(slot) % kAtlasTilesAcross, uint(slot) / kAtlasTilesAcross) * kIrradianceRes + t2;
    float keep = hysteresisFor(grid, slot);
    irradianceOut[at] = float4(lerp(irradiance, irradianceOut[at].rgb, keep), 1);
    radianceOut[at] = float4(lerp(radiance, radianceOut[at].rgb, keep), 1);
}

[shader("compute")]
[numthreads(64, 1, 1)]
void depthMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> depthOut)
{
    uint texel = tid.x, probe = tid.y;
    uint count = uint(ddgiCounts.x * ddgiCounts.y * ddgiCounts.z);
    if (texel >= kDepthRes * kDepthRes || probe >= count)
        return;
    int3 grid = ddgiGridOf(int(probe));
    int slot = ddgiSlot(grid);
    uint2 t2 = uint2(texel % kDepthRes, texel / kDepthRes);
    float3 dir = octDecode((float2(t2) + 0.5) / float(kDepthRes) * 2.0 - 1.0);
    float2 moments = float2(0, 0);
    float weights = 0;
    for (uint r = 0; r < kRays; ++r)
    {
        float4 ray = ddgiRays[probe * kRays + r];
        float w = pow(max(0.0, dot(dir, rayDirection(r))), 50.0);
        float d = min(ray.a, ddgiSpacing * 1.5);
        moments += float2(d, d * d) * w;
        weights += w;
    }
    if (weights > 1e-4)
        moments /= weights;
    else
        moments = float2(ddgiSpacing * 1.5, ddgiSpacing * ddgiSpacing * 2.25);
    uint2 at = uint2(uint(slot) % kAtlasTilesAcross, uint(slot) / kAtlasTilesAcross) * kDepthRes + t2;
    float keep = hysteresisFor(grid, slot);
    depthOut[at] = float4(lerp(moments, depthOut[at].xy, keep), 0, 0);
}

[shader("compute")]
[numthreads(64, 1, 1)]
void stampMain(uint3 tid: SV_DispatchThreadID)
{
    uint count = uint(ddgiCounts.x * ddgiCounts.y * ddgiCounts.z);
    if (tid.x >= count)
        return;
    int3 grid = ddgiGridOf(int(tid.x));
    ddgiProbeStamps[ddgiSlot(grid)] = cellStamp(ddgiWorldCell(grid));
}
