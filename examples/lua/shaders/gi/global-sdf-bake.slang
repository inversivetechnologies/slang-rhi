// Builds the global SDF (global-sdf.slang) every frame, in a buffer first (so that every
// source can min into it with an atomic), then into the texture that is sampled:
//
//   clearMain       every voxel: the static part's (the splats, baked when the volume last
//                   moved), or the band's edge and no albedo
//   compositionMain the SDF composition (sdf-world.slang), over the voxels of its bounds,
//                   first: the nearer of it and the static part
//   bodiesMain      one thread per body and z slice of the volume (a group's bodies: boxes
//                   or spheres, from its bodies buffer, scene-common.slang's layout): the
//                   voxels of that slice near the body take the body's distance and color,
//                   if nearer
//   (the splats: global-sdf-splats.slang, into the static part, when the volume moves)
//   resolveMain     into gsdfVolumeOut: rgb albedo, a distance
//
// A voxel is one uint: its distance quantized to 16 bits (over [-band, band]) above its
// albedo (RGB 5:6:5) -- so an atomic min keeps the nearest distance and its owner's color
// together, in one write. (fxc, for D3D11, can't compile a conditional albedo write after
// the distances: this needs none.)

#include "sdf/sdf-world.slang"
#include "global-sdf-voxels.slang"

uniform uint bodyCount;
uniform uint bodyIsSphere; // the group's shape: 0 boxes, 1 spheres

// The static part (the splats: global-sdf-splats.slang), baked into gsdfStatic only when
// the volume moves; the clear starts every frame from it.
StructuredBuffer<uint> gsdfStatic;
uniform uint gsdfHasStatic;

[shader("compute")]
[numthreads(64, 1, 1)]
void clearMain(uint3 tid: SV_DispatchThreadID)
{
    uint n = gsdfResolution * gsdfResolution * gsdfResolution;
    if (tid.x >= n)
        return;
    // What doesn't move (the splats), baked when the volume last moved; else nothing.
    gsdfVoxels[tid.x] = gsdfHasStatic != 0 ? gsdfStatic[tid.x] : encodeVoxel(gsdfBand, float3(0, 0, 0));
}

// A body's distance at `p` (bodies[]: position, rotation, scale -- half extents, or the
// radius -- and color).
float bodyDistance(uint body, float3 p)
{
    uint base = body * kBodyStride;
    float3 local = p - bodies[base].xyz;
    float4 q = bodies[base + 1];
    // Into the body's frame: the inverse rotation.
    local = rotateByQuaternion(float4(-q.xyz, q.w), local);
    float3 s = bodies[base + 2].xyz;
    if (bodyIsSphere != 0)
        return length(local) - s.x;
    float3 a = abs(local) - s;
    return length(max(a, 0.0)) + min(max(a.x, max(a.y, a.z)), 0.0);
}

// The voxels of z slice `z` within the body's reach (its bounding sphere plus the band),
// or none (hi below lo) for a thread past the bodies or a slice the body doesn't reach.
void bodyRange(uint body, uint z, out int2 lo, out int2 hi)
{
    lo = int2(0, 0);
    hi = int2(-1, -1);
    if (body >= bodyCount || z >= gsdfResolution)
        return;
    uint base = body * kBodyStride;
    float3 center = bodies[base].xyz;
    float3 s = bodies[base + 2].xyz;
    float reach = (bodyIsSphere != 0 ? s.x : length(s)) + gsdfBand;
    float3 l = (center - reach - gsdfOrigin) / gsdfVoxel;
    float3 h = (center + reach - gsdfOrigin) / gsdfVoxel;
    if (float(z) + 1.0 < l.z || float(z) > h.z)
        return;
    lo = max(int2(floor(l.xy)), int2(0, 0));
    hi = min(int2(ceil(h.xy)), int2(gsdfResolution - 1, gsdfResolution - 1));
}

[shader("compute")]
[numthreads(64, 1, 1)]
void bodiesMain(uint3 tid: SV_DispatchThreadID)
{
    uint body = tid.x, z = tid.y;
    int2 lo, hi;
    bodyRange(body, z, lo, hi);
    float3 color = bodies[min(body, max(bodyCount, 1u) - 1) * kBodyStride + 3].rgb;
    [loop]
    for (int y = lo.y; y <= hi.y; ++y)
    {
        [loop]
        for (int x = lo.x; x <= hi.x; ++x)
        {
            uint3 v = uint3(x, y, z);
            // Clamped to the band, so a far body leaves the voxel as it was.
            InterlockedMin(gsdfVoxels[voxelIndex(v)], encodeVoxel(bodyDistance(body, voxelCenter(v)), color));
        }
    }
}

// The composition's voxels: those of the box about its bounds (sdfOrigin, sdfBoundsRadius
// plus the band); threads over that box, whose corner voxel is compositionCorner.
uniform uint3 compositionCorner;
uniform uint3 compositionSize;

[shader("compute")]
[numthreads(4, 4, 4)]
void compositionMain(uint3 tid: SV_DispatchThreadID)
{
    uint3 v = compositionCorner + tid;
    bool inside = all(tid < compositionSize) && all(v < gsdfResolution);
    float3 q = toSdfSpace(voxelCenter(min(v, gsdfResolution - 1)));
    float d = sdfFieldDistance(q);
    float3 color = sdfFieldColor(q);
    // The nearer of it and what is there (the static part): one thread a voxel, no atomic.
    // (The encoding's order is the distance's.)
    if (inside)
    {
        uint i = voxelIndex(v);
        gsdfVoxels[i] = min(gsdfVoxels[i], encodeVoxel(d, color));
    }
}

[shader("compute")]
[numthreads(4, 4, 4)]
void resolveMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture3D<float4> gsdfVolumeOut)
{
    if (any(tid >= gsdfResolution))
        return;
    uint v = gsdfVoxels[voxelIndex(tid)];
    gsdfVolumeOut[tid] = float4(decodeAlbedo(v), decodeDistance(v));
}
