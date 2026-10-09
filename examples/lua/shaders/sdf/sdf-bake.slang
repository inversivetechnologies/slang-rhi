// Baking an SDF composition (sdf-dag.slang) into the cache that sdf-cache.slang reads: one
// thread per voxel evaluates the DAG at the voxel's center, and stores the distance and
// the color. Run once, and again whenever the composition changes.

#include "sdf-dag.slang"

RWTexture3D<float> sdfCacheDistanceOut; // r16f
RWTexture3D<float4> sdfCacheColorOut;   // rgba8
uniform float sdfCacheExtent;
uniform uint sdfCacheResolution;

[shader("compute")]
[numthreads(4, 4, 4)]
void bakeMain(uint3 tid: SV_DispatchThreadID)
{
    if (any(tid >= sdfCacheResolution))
    {
        return;
    }
    float3 p = ((float3(tid) + 0.5) / float(sdfCacheResolution) * 2.0 - 1.0) * sdfCacheExtent;
    SdfSample s = evaluateSdf(p);
    sdfCacheDistanceOut[tid] = s.distance;
    sdfCacheColorOut[tid] = float4(saturate(s.color), 1.0);
}
