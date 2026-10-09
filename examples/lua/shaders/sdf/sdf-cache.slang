// A cached SDF composition: the DAG (sdf-dag.slang) baked into 3D textures once
// (sdf-bake.slang), then read by trilinear filtering instead of evaluated, node by node,
// at every step of every ray.
//
// The cache covers a cube, sdfCacheExtent to either side of the composition's origin, in
// the composition's own space, sdfCacheResolution voxels to a side. The composition must
// fit inside it.
//
//   sdfCacheDistance   r16f: the signed distance at each voxel's center
//   sdfCacheColor      rgba8: the color there
//
// What filtering gives back is not exactly a distance: between voxels it is a blend of
// distances, which smooths edges and corners finer than a voxel, and can come out a
// little larger than the true distance near them -- so marching steps a little short
// (kSdfCacheStep). Outside the cube there is nothing cached; there, the distance to the
// cube is a safe step (the composition lies inside it).

#pragma once

Texture3D<float> sdfCacheDistance;
Texture3D<float4> sdfCacheColor;
SamplerState sdfCacheSampler; // trilinear, clamped
uniform float sdfCacheExtent;
uniform uint sdfCacheResolution;

static const float kSdfCacheStep = 0.9;

// Where p is in the textures (0..1 across the cube).
float3 sdfCacheUvw(float3 p)
{
    return p / (2.0 * sdfCacheExtent) + 0.5;
}

float sdfCacheVoxelSize()
{
    return 2.0 * sdfCacheExtent / float(sdfCacheResolution);
}

// The cached distance at p (in the composition's space). Outside the cube: no closer than
// the cube, and no closer than the cached distance at the cube's nearest point less the
// way there -- both are lower bounds, so a march can step by the larger.
float sampleSdfCache(float3 p)
{
    float half = 0.5 * sdfCacheVoxelSize();
    float3 inside = clamp(p, -sdfCacheExtent + half, sdfCacheExtent - half);
    float d = sdfCacheDistance.SampleLevel(sdfCacheSampler, sdfCacheUvw(inside), 0);
    float away = length(p - inside);
    return away > 0.0 ? max(away, d - away) : d;
}

float3 sampleSdfCacheColor(float3 p)
{
    return sdfCacheColor.SampleLevel(sdfCacheSampler, sdfCacheUvw(p), 0).rgb;
}
