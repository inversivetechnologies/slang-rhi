// Splat shadows, levels of detail: every frame, picks the splats the shadow passes draw
// (shadow.slang), as preprocess.slang picks the ones the camera sees -- a cut through the
// tree of merged splats (splat-lod.h), but measured from the light, against the shadow
// map's resolution. The picked splats' indices are packed into `shadowList`.
//
// Run as resetShadowMain (one thread), then selectShadowMain (one thread per splat,
// merged ones included).

#include "ply.slang"
#include "scene/scene-common.slang"

StructuredBuffer<float4> lodBounds; // per splat: its bounds, then its parent's
uniform uint lodEnabled;            // 0: no merged splats; every one of the file's casts
uniform float lodShadowTexels;      // small enough: a bounds radius of this many shadow map texels
uniform float shadowFaceSize;       // texels across a cube face of the shadow map

RWStructuredBuffer<uint> shadowList;  // the picked splats, packed
RWStructuredBuffer<uint> shadowCount; // [0]: how many

[shader("compute")]
[numthreads(1, 1, 1)]
void resetShadowMain()
{
    shadowCount[0] = 0;
}

[shader("compute")]
[numthreads(256, 1, 1)]
void selectShadowMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x;
    if (i >= splatCount)
    {
        return;
    }
    bool picked = true;
    if (lodEnabled != 0)
    {
        // A cube face spans 90 degrees: its focal length is half its size, in texels.
        float focal = shadowFaceSize * 0.5;
        float3 lightPos = lightPosition();
        picked = lodSmallEnough(lodBounds[2 * i], lightPos, focal, lodShadowTexels) &&
                 !lodSmallEnough(lodBounds[2 * i + 1], lightPos, focal, lodShadowTexels);
    }
    // [branch]: D3D11's fxc otherwise flattens the writes, and fails ("flattened side
    // effect").
    [branch]
    if (picked)
    {
        uint slot;
        InterlockedAdd(shadowCount[0], 1, slot);
        shadowList[slot] = i;
    }
}
