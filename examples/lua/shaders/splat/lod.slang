// Levels of detail for Gaussian splats, held to a budget: every frame, picks the cut
// through the tree of merged splats (splat-lod.h) that draws as many splats as the budget
// allows, and no more -- however many instances there are, however near or far.
//
// Each splat (file's or merged, of every instance) has a size as seen from a viewer: its
// bounding sphere's radius over the distance to the sphere, in pixels (the camera's) or
// texels (the light's shadow map), and a fraction of that off screen. Sizes are binned on
// a log scale, kLodBinsPerOctave bins per doubling. A splat is in the cut for bin B when
// its own bin is at most B and its parent's is above B: small enough, under a parent that
// isn't. A child's sphere lies in its parent's, so bins never grow from parent to child,
// and every cut is consistent -- one splat on every path from the root to a file's splat.
//
// The cut is picked on the GPU, without the CPU hearing of it, in three dispatches:
//
//   lodClearMain        zeroes the histogram
//   lodHistogram...     one thread per splat and instance: +1 at its own bin, -1 at its
//                       parent's, so that the running sum up to bin B counts the cut for
//                       B (lodHistogramCameraMain here; shadow-select.slang has the light's)
//   lodPickMain         one thread: the first B whose cut fits lodBudget -> lodChoice
//
// Then preprocess.slang (and shadow-select.slang) draw what is in the cut for that B.

#pragma once

#include "splat-common.slang"
#include "ply.slang"
#include "clip.slang"
#include "effect-field.slang"

// Bins 1 .. kLodBins - 1 hold sizes from 2^kLodMinLog2 up, kLodBinsPerOctave per doubling.
// Bin 0: the file's splats (always small enough). kLodBins: the root's parent (never).
static const uint kLodBins = 160;
static const float kLodBinsPerOctave = 8.0;
static const float kLodMinLog2 = -8.0;
// Off screen, sizes count this much less: what isn't seen gets the coarsest splats, and
// leaves the budget to what is. The same for what the clip field cuts away wholly.
static const float kLodOffscreen = 1.0 / 64.0;
// Across the clip field's surface, sizes count this much more: the cut goes finer there,
// so that the clipped edge is cut through small splats.
static const float kLodClipEdge = 4.0;

StructuredBuffer<float4> lodBounds; // per merged splat: its bounding sphere, in the file's frame
StructuredBuffer<uint> lodParents;  // per splat: its parent's index; 0xFFFFFFFF at the root
uniform uint lodLeafCount;          // the file's splats: indices below are leaves
uniform uint lodEnabled;            // 0: no tree; every file's splat is drawn
uniform uint lodBudget;             // the most splats a cut may have
uniform float lodFinest;            // and no finer than this: bounds of this radius (pixels or texels) are small enough
RWStructuredBuffer<int> lodHistogram; // kLodBins + 1 counts
RWStructuredBuffer<uint> lodChoice;   // [0]: the bin picked

uniform SplatCamera camera;
uniform float2 viewportSize; // provided by the host

// Where sizes are measured from.
struct LodView
{
    float3 eye;
    float focal;   // pixels per unit at distance 1
    float3 right;  // the view's axes, for culling (when `cull`)
    float tanX;    // tan of half the field of view, across
    float3 up;
    float tanY;    // and up
    float3 forward;
    uint cull;     // 1: count what is off screen less
};

LodView cameraLodView()
{
    LodView v;
    v.eye = camera.eye;
    v.forward = normalize(camera.target - camera.eye);
    v.right = normalize(cross(float3(0, 1, 0), v.forward));
    v.up = cross(v.forward, v.right);
    v.tanY = tan(camera.fovY * 0.5);
    v.tanX = v.tanY * viewportSize.x / viewportSize.y;
    v.focal = viewportSize.y * 0.5 / v.tanY;
    v.cull = 1;
    return v;
}

// Whether a sphere is wholly outside the view's frustum. Conservative the right way: a
// sphere inside one that is outside is outside too.
bool lodOutside(LodView v, float3 center, float radius)
{
    float3 d = center - v.eye;
    float3 t = float3(dot(d, v.right), dot(d, v.up), dot(d, v.forward));
    if (t.z + radius < 0.1)
    {
        return true;
    }
    float nx = rsqrt(1.0 + v.tanX * v.tanX);
    float ny = rsqrt(1.0 + v.tanY * v.tanY);
    return (abs(t.x) - v.tanX * t.z) * nx > radius || (abs(t.y) - v.tanY * t.z) * ny > radius;
}

// The size bin of a merged splat's bounds, placed by the current placement.
uint lodBin(LodView v, float4 bounds)
{
    float3 center = splatPlace(bounds.xyz * splatFlip());
    float radius = bounds.w * placement.scale;
    float distance = length(center - v.eye) - radius;
    if (distance <= 0.1)
    {
        return kLodBins - 1; // around the viewer: as large as can be
    }
    float size = radius * v.focal / distance;
    // Off screen only if the effects can't move any of it into view (dynamic instances).
    float reach = placementDynamic ? effectReach(center, radius) : 0.0;
    if (v.cull != 0 && lodOutside(v, center, radius + reach))
    {
        size *= kLodOffscreen;
    }
    // Both of these keep sizes from growing parent to child: a sphere inside one wholly
    // cut away is cut away too, and one across the surface lies in a parent across it.
    // Widened as above, by how far the effects may move its splats.
    uint clipClass = clipClassify(center, radius + reach);
    if (clipClass == 2)
    {
        size *= kLodOffscreen;
    }
    else if (clipClass == 1)
    {
        size *= kLodClipEdge;
    }
    return lodSizeBin(size);
}

// A splat's own bin and its parent's.
void lodEntryBins(LodView v, uint i, out uint own, out uint parentBin)
{
    own = 0;
    parentBin = kLodBins;
    if (lodEnabled == 0)
    {
        return;
    }
    if (i >= lodLeafCount)
    {
        own = lodBin(v, lodBounds[i - lodLeafCount]);
    }
    uint parent = lodParents[i];
    if (parent != 0xFFFFFFFF)
    {
        parentBin = lodBin(v, lodBounds[parent - lodLeafCount]);
    }
}

// Whether splat i is in the cut lodPickMain picked.
bool lodInCut(LodView v, uint i)
{
    uint own, parentBin;
    lodEntryBins(v, i, own, parentBin);
    uint chosen = lodChoice[0];
    return own <= chosen && parentBin > chosen;
}

[shader("compute")]
[numthreads(256, 1, 1)]
void lodClearMain(uint3 tid: SV_DispatchThreadID)
{
    if (tid.x <= kLodBins)
    {
        lodHistogram[tid.x] = 0;
    }
}

groupshared int lodLocal[kLodBins + 1];

// Thread (splat, instance) of the histogram: counted in group shared memory first, then
// added to the histogram once per group and bin.
void lodHistogramBody(LodView v, uint3 tid, uint groupIndex)
{
    // A group has more threads than there are bins: one bin each.
    [branch]
    if (groupIndex <= kLodBins)
    {
        lodLocal[groupIndex] = 0;
    }
    GroupMemoryBarrierWithGroupSync();
    // Every thread computes bins (threads past the splats or instances, for the last
    // one) and adds 1 and -1 if it is a real one, 0 if not -- no branch around the
    // atomics, which D3D11's fxc can't compile here ("flattened side effect").
    int active = int(tid.x < splatCount && tid.y < instanceCount);
    beginInstance(min(tid.y, max(instanceCount, 1u) - 1));
    uint own, parentBin;
    lodEntryBins(v, min(tid.x, max(splatCount, 1u) - 1), own, parentBin);
    InterlockedAdd(lodLocal[own], active);
    InterlockedAdd(lodLocal[parentBin], -active); // kLodBins: past every bin summed
    GroupMemoryBarrierWithGroupSync();
    int count = groupIndex <= kLodBins ? lodLocal[min(groupIndex, kLodBins)] : 0;
    [branch]
    if (count != 0)
    {
        InterlockedAdd(lodHistogram[groupIndex], count);
    }
}

[shader("compute")]
[numthreads(256, 1, 1)]
void lodHistogramCameraMain(uint3 tid: SV_DispatchThreadID, uint groupIndex: SV_GroupIndex)
{
    lodHistogramBody(cameraLodView(), tid, groupIndex);
}

// The bin of a size (in pixels or texels).
uint lodSizeBin(float size)
{
    float bin = floor((log2(max(size, 1e-30)) - kLodMinLog2) * kLodBinsPerOctave) + 1.0;
    return uint(clamp(bin, 1.0, float(kLodBins - 1)));
}

// The finest cut within the budget: the first bin whose running sum fits. The cut only
// gets coarser, and smaller, bin by bin. But no finer than lodFinest: detail below what
// the view resolves costs splats and shows nothing -- and with the floor, a view that
// needs fewer splats than the budget gets a cut that doesn't follow the budget at all.
[shader("compute")]
[numthreads(1, 1, 1)]
void lodPickMain()
{
    uint finest = lodFinest > 0.0 ? lodSizeBin(lodFinest) : 0;
    int running = 0;
    uint chosen = kLodBins - 1;
    for (uint b = 0; b < kLodBins; ++b)
    {
        running += lodHistogram[b];
        if (b >= finest && running <= int(lodBudget))
        {
            chosen = b;
            break;
        }
    }
    lodChoice[0] = chosen;
}
