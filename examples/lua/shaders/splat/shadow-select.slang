// Splat shadows, levels of detail: every frame, picks the splats the shadow passes draw
// (shadow.slang), as lod.slang and preprocess.slang pick the ones the camera sees -- the
// cut through the tree of merged splats (splat-lod.h) that fits a budget, but measured
// from the light, in shadow map texels, and over every direction (a cube map culls
// nothing). The picked splats and their instances are packed into `shadowList`.
//
// Run, every frame: lodClearMain, lodHistogramLightMain, lodPickMain (with the shadows'
// budget), resetShadowMain, then selectShadowMain -- one thread per splat and instance for
// the histogram and the selection.

#include "lod.slang"
#include "scene/scene-common.slang"

uniform float shadowFaceSize; // texels across a cube face of the shadow map
uniform uint shadowCapacity;  // what shadowList holds

RWStructuredBuffer<uint2> shadowList; // the picked splats and their instances, packed
RWStructuredBuffer<uint> shadowCount; // [0]: how many (no more than shadowCapacity are kept)

LodView lightLodView()
{
    LodView v;
    v.eye = lightPosition();
    // A cube face spans 90 degrees: its focal length is half its size, in texels.
    v.focal = shadowFaceSize * 0.5;
    v.right = float3(1, 0, 0);
    v.up = float3(0, 1, 0);
    v.forward = float3(0, 0, 1);
    v.tanX = 1;
    v.tanY = 1;
    v.cull = 0;
    return v;
}

[shader("compute")]
[numthreads(256, 1, 1)]
void lodHistogramLightMain(uint3 tid: SV_DispatchThreadID, uint groupIndex: SV_GroupIndex)
{
    lodHistogramBody(lightLodView(), tid, groupIndex);
}

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
    uint instance = tid.y;
    if (i >= splatCount || instance >= instanceCount)
    {
        return;
    }
    beginInstance(instance);
    bool picked = lodInCut(lightLodView(), i);
    // [branch]: D3D11's fxc otherwise flattens the writes, and fails ("flattened side
    // effect").
    [branch]
    if (picked)
    {
        uint slot;
        InterlockedAdd(shadowCount[0], 1, slot);
        if (slot < shadowCapacity)
        {
            shadowList[slot] = uint2(i, instance);
        }
    }
}
