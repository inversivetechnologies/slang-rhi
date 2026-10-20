// The splats in the global SDF (global-sdf-bake.slang builds the rest): not the file's
// splats -- millions, most far smaller than a voxel -- but a cut through their levels of
// detail (splat-lod.h) at about a voxel: the merged splats (each a Gaussian standing for a
// cluster) whose bounds are at most gsdfSplatSize across while their parent's are larger,
// and the file's splats under a parent that is. That covers each splat set once, with
// some thousands of Gaussians.
//
// Each, if opaque enough, is an ellipsoid of kSigmas standard deviations along its axes,
// its distance (Quilez's ellipsoid bound) min'ed into the voxels it reaches (its extent plus
// the band) with its albedo -- its color as captured (spherical harmonics band 0), linear.
//
// Static and dynamic instances (ply.slang: placementDynamic):
//
//   staticMain    the static instances' splats, into the static part (baked again only
//                 when the volume moves): one thread per splat and instance; those not in
//                 the cut return at once
//   cutListMain   the dynamic instances' splats in the cut, listed once (the cut depends
//                 only on the instances' scale): one thread per splat and instance, after
//                 cutResetMain
//   dynamicMain   every frame, the listed splats moved and colored by the effects
//                 (effect-field.slang): one thread per listed splat

#include "splat/ply.slang"
#include "splat/effect-field.slang"
#include "global-sdf-voxels.slang"

static const float kSigmas = 2.0;
static const float kMinOpacity = 0.2;

StructuredBuffer<float4> lodBounds; // per merged splat: its bounding sphere, in the file's frame
StructuredBuffer<uint> lodParents;  // per splat: its parent's index; 0xFFFFFFFF at the root
uniform uint lodLeafCount;          // the file's splats: indices below are leaves
uniform uint lodEnabled;            // 0: no tree (every file's splat, too many: none here)
uniform float gsdfSplatSize;        // the cut: bounds about this radius (world units)

RWStructuredBuffer<uint2> gsdfCutList; // the dynamic instances' splats in the cut: splat, instance
RWStructuredBuffer<uint> gsdfCutCount; // [0]: how many (no more than gsdfCutCapacity are kept)
uniform uint gsdfCutCapacity;

// A splat's size for the cut: a merged one's bounds' radius in the world; a file's, none.
float cutSize(uint i)
{
    return i < lodLeafCount ? 0.0 : lodBounds[i - lodLeafCount].w * placement.scale;
}

// Whether splat `i` of the instance begun is in the cut, and opaque enough.
bool inCut(uint i)
{
    if (i >= splatCount || lodEnabled == 0)
        return false;
    uint parent = lodParents[i];
    float parentSize = parent == 0xFFFFFFFFu ? 1e9 : lodBounds[parent - lodLeafCount].w * placement.scale;
    return cutSize(i) <= gsdfSplatSize && parentSize > gsdfSplatSize && splatOpacity(splatBase(i)) >= kMinOpacity;
}

// The ellipsoid's distance, in its own frame (semi-axes r): Quilez's bound, exact enough
// near the surface.
float ellipsoidDistance(float3 p, float3 r)
{
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

// Splat `i` of the instance begun into the voxels it reaches, if `stamp` (else none: the
// atomics stay unconditional, for fxc); a dynamic instance's moved and colored by the
// effects.
void stampSplat(uint i, bool stamp)
{
    int3 lo = int3(0, 0, 0), hi = int3(-1, -1, -1);
    float3 center = float3(0, 0, 0), color = float3(0, 0, 0);
    float3 axes[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };
    float3 radii = float3(1, 1, 1);
    if (stamp)
    {
        uint base = splatBase(i);
        center = splatWorldPosition(base);
        float3 captured = 0.5 + 0.28209479 * float3(plyData[base + ply.dc], plyData[base + ply.dc + 1], plyData[base + ply.dc + 2]);
        if (placementDynamic)
        {
            captured = effectColor(center, captured);
            center += effectDisplacement(center);
        }
        color = pow(saturate(captured), 2.2);
        radii = max(splatWorldScale(base) * kSigmas, 0.25 * gsdfVoxel);
        // Its axes in the world: the rotation's columns, flipped and turned as its position.
        float4 q = float4(plyData[base + ply.rotation], plyData[base + ply.rotation + 1],
                          plyData[base + ply.rotation + 2], plyData[base + ply.rotation + 3]);
        float3x3 rotation = quaternionToMatrix(normalize(q));
        float3x3 yaw = splatYaw();
        float3 flip = splatFlip();
        for (int k = 0; k < 3; ++k)
            axes[k] = normalize(mul(yaw, float3(rotation[0][k], rotation[1][k], rotation[2][k]) * flip));
        float reach = max(radii.x, max(radii.y, radii.z)) + gsdfBand;
        float3 l = (center - reach - gsdfOrigin) / gsdfVoxel;
        float3 h = (center + reach - gsdfOrigin) / gsdfVoxel;
        lo = max(int3(floor(l)), int3(0, 0, 0));
        hi = min(int3(ceil(h)), int3(gsdfResolution - 1, gsdfResolution - 1, gsdfResolution - 1));
    }
    [loop]
    for (int z = lo.z; z <= hi.z; ++z)
    {
        [loop]
        for (int y = lo.y; y <= hi.y; ++y)
        {
            [loop]
            for (int x = lo.x; x <= hi.x; ++x)
            {
                uint3 v = uint3(x, y, z);
                float3 d = voxelCenter(v) - center;
                float3 local = float3(dot(d, axes[0]), dot(d, axes[1]), dot(d, axes[2]));
                // Clamped to the band, so a far splat leaves the voxel as it was.
                InterlockedMin(gsdfVoxels[voxelIndex(v)], encodeVoxel(ellipsoidDistance(local, radii), color));
            }
        }
    }
}

[shader("compute")]
[numthreads(64, 1, 1)]
void staticMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x, instance = tid.y;
    bool stamp = false;
    if (instance < instanceCount)
    {
        beginInstance(instance);
        stamp = !placementDynamic && inCut(i);
    }
    stampSplat(i, stamp);
}

[shader("compute")]
[numthreads(1, 1, 1)]
void cutResetMain()
{
    gsdfCutCount[0] = 0;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void cutListMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x, instance = tid.y;
    if (instance >= instanceCount)
        return;
    beginInstance(instance);
    bool listed = placementDynamic && inCut(i);
    [branch]
    if (listed)
    {
        uint slot;
        InterlockedAdd(gsdfCutCount[0], 1, slot);
        if (slot < gsdfCutCapacity)
            gsdfCutList[slot] = uint2(i, instance);
    }
}

[shader("compute")]
[numthreads(64, 1, 1)]
void dynamicMain(uint3 tid: SV_DispatchThreadID)
{
    uint slot = tid.x;
    bool stamp = slot < min(gsdfCutCount[0], gsdfCutCapacity);
    uint2 listed = stamp ? gsdfCutList[slot] : uint2(0, 0);
    beginInstance(listed.y);
    stampSplat(listed.x, stamp);
}
