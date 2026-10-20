// Gaussian splatting, step 1: one thread per splat turns the trained 3D Gaussian into what
// the rasterizer needs -- the ellipse it covers on screen, its color as seen from the
// camera, and a depth to sort by.
//
// One thread per splat and instance (threads x: splats, y: instances). Levels of detail:
// the splats include merged ones (built by the host when the file was loaded:
// splat-lod.h), one per node of a tree over the file's splats, and lod.slang has picked
// the cut through it that fits the splat budget. Only the splats in that cut go on. The
// drawn ones are packed at the front of the buffers (an atomic counter, `drawCount`), so
// the sort, the lighting and the draw skip the rest; the buffers hold at most `sortCount`.
//
// The splats are read and placed by ply.slang. Following "3D Gaussian Splatting for
// Real-Time Radiance Field Rendering" (Kerbl et al. 2023):
//
//   - the 3D covariance is built from the splat's rotation and scale: R S S^T R^T
//   - it is projected to 2D with the Jacobian of the perspective projection (EWA splatting)
//   - the color is evaluated from spherical harmonics (up to degree 3) in the direction
//     from the camera

#include "lod.slang"

uniform uint sortCount;      // what the buffers below hold: the most splats drawn, a power of two

// Per drawn splat, in the order they were packed (`slot`):
RWStructuredBuffer<ProjectedSplat> projected;
RWStructuredBuffer<uint2> drawnSplats; // which splat and instance it is
RWStructuredBuffer<float> sortKeys;    // sorted, with sortValues: the slots
RWStructuredBuffer<uint> sortValues;
RWStructuredBuffer<uint> drawCount; // [0]: splats drawn this frame (packed at the front)
// Two float4s per drawn splat: [2 slot] xyz how far the effects moved it (effect-field.slang),
// for the lighting and the clipping; [2 slot + 1] xyz where it was the frame before, from
// where it is (the effects moved it since), for the TAA's motion (render.slang's blended
// depth pass). One buffer: D3D11 has 8 UAVs.
RWStructuredBuffer<float4> splatOffsets;
uniform uint splatEffectsOn; // 0: no effects (splatOffsets isn't written)

StructuredBuffer<uint> lodLevel; // per splat: 0 for the file's, the height above them for merged ones
uniform uint lodShowLevels;      // 1: tint the splats by level
// The 2D Mip filter (Mip-Splatting, Yu et al. 2024): the low-pass filter below widens a
// splat; its opacity is lowered by as much, so that a splat smaller than a pixel keeps the
// weight it has rather than growing to a pixel's. Without it, splats shimmer as they
// shrink and grow on screen (a dolly, a zoom). 0: off (as 3DGS was trained), 1: in full.
uniform float splatMipFilter;

// A color per level, for lodShowLevels.
float3 levelColor(uint level)
{
    static const float3 kColors[8] = {
        float3(0.9, 0.9, 0.9), float3(0.2, 0.6, 1.0), float3(0.2, 0.9, 0.4), float3(1.0, 0.85, 0.2),
        float3(1.0, 0.5, 0.15), float3(1.0, 0.2, 0.3), float3(0.8, 0.3, 1.0), float3(0.4, 1.0, 1.0),
    };
    return kColors[min(level, 7u)];
}

// Resets the count of drawn splats, before preprocessMain.
[shader("compute")]
[numthreads(1, 1, 1)]
void resetCountMain()
{
    drawCount[0] = 0;
}

// After preprocessMain (and the lighting): fills the rest of what the sort will work on
// with keys that sort last. Also holds the count to what the buffers hold, for the sort
// and the draw (more never fit: preprocessMain drops them).
[shader("compute")]
[numthreads(256, 1, 1)]
void padMain(uint3 tid: SV_DispatchThreadID)
{
    uint count = min(drawCount[0], sortCount);
    uint i = tid.x;
    if (i == 0)
    {
        drawCount[0] = count;
    }
    bool padding = i >= count && i < sortSizeFor(count) && i < sortCount;
    // [branch]: D3D11's fxc otherwise flattens the writes, and fails ("flattened side
    // effect").
    [branch]
    if (padding)
    {
        sortKeys[i] = kCulledKey;
        sortValues[i] = 0;
    }
}

// Spherical harmonics coefficient `k` (0 = band 0) of all three channels.
float3 shCoefficient(uint base, uint k)
{
    if (k == 0)
    {
        return loadFloat3(base + ply.dc);
    }
    uint perChannel = ply.restCount / 3;
    uint index = base + ply.rest + (k - 1);
    return float3(plyData[index], plyData[index + perChannel], plyData[index + 2 * perChannel]);
}

// The splat's color seen along `dir` (unit length, from the camera, in the splat's frame).
float3 evaluateColor(uint base, float3 dir)
{
    float3 color = 0.28209479177387814 * shCoefficient(base, 0);
    uint perChannel = ply.restCount / 3;
    float x = dir.x, y = dir.y, z = dir.z;
    if (perChannel >= 3)
    {
        const float c1 = 0.4886025119029199;
        color += -c1 * y * shCoefficient(base, 1) + c1 * z * shCoefficient(base, 2) - c1 * x * shCoefficient(base, 3);
    }
    if (perChannel >= 8)
    {
        float xx = x * x, yy = y * y, zz = z * z;
        color += 1.0925484305920792 * x * y * shCoefficient(base, 4);
        color += -1.0925484305920792 * y * z * shCoefficient(base, 5);
        color += 0.31539156525252005 * (2 * zz - xx - yy) * shCoefficient(base, 6);
        color += -1.0925484305920792 * x * z * shCoefficient(base, 7);
        color += 0.5462742152960396 * (xx - yy) * shCoefficient(base, 8);
        if (perChannel >= 15)
        {
            color += -0.5900435899266435 * y * (3 * xx - yy) * shCoefficient(base, 9);
            color += 2.890611442640554 * x * y * z * shCoefficient(base, 10);
            color += -0.4570457994644658 * y * (4 * zz - xx - yy) * shCoefficient(base, 11);
            color += 0.3731763325901154 * z * (2 * zz - 3 * xx - 3 * yy) * shCoefficient(base, 12);
            color += -0.4570457994644658 * x * (4 * zz - xx - yy) * shCoefficient(base, 13);
            color += 1.445305721320277 * z * (xx - yy) * shCoefficient(base, 14);
            color += -0.5900435899266435 * x * (xx - 3 * yy) * shCoefficient(base, 15);
        }
    }
    return max(color + 0.5, 0.0);
}

[shader("compute")]
[numthreads(256, 1, 1)]
void preprocessMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x;
    uint instance = tid.y;
    if (i >= splatCount || instance >= instanceCount)
    {
        return;
    }
    beginInstance(instance);
    LodView lodView = cameraLodView();
    if (!lodInCut(lodView, i))
    {
        return;
    }
    float focal = lodView.focal;
    uint base = splatBase(i);

    float opacity = splatOpacity(base);
    if (opacity < 1.0 / 255.0)
    {
        return;
    }

    // The splat's frame to the world: optionally turned upright, then placed by `model`.
    float3 flip = splatFlip();
    float3x3 yaw = splatYaw();
    float3 world = splatWorldPosition(base);
    // A dynamic instance's splat where the effects move it (effect-field.slang), before
    // anything is culled or projected: what they push into view is drawn.
    float3 offset = float3(0, 0, 0), motion = float3(0, 0, 0);
    if (placementDynamic)
    {
        offset = effectDisplacement(world);
        motion = effectDisplacementAt(world, time - timeDelta) - offset;
    }
    world += offset;

    // Clipping (clip.slang): cut away wholly, or flagged for render.slang to clip per pixel.
    float3 worldScale = splatWorldScale(base);
    uint clipClass = clipClassify(world, 3.0 * max(worldScale.x, max(worldScale.y, worldScale.z)));
    if (clipClass == 2)
    {
        return;
    }

    // Into the camera's view: x right, y up, z forward.
    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float3x3 view = float3x3(right, up, forward);
    float3 t = mul(view, world - camera.eye);
    if (t.z < 0.1)
    {
        return;
    }

    // 3D covariance (R S S^T R^T, in the world), into the view.
    float3x3 covariance = mul(view, mul(splatWorldCovariance(base), transpose(view)));

    // Project to pixels (y down) and take the Jacobian there. Clamping the point to a bit
    // beyond the frustum keeps splats at the edges from blowing up.
    float2 limit = 1.3 * viewportSize * 0.5 / focal;
    float2 clamped = clamp(t.xy / t.z, -limit, limit) * t.z;
    float invZ = 1.0 / t.z;
    float3x3 jacobian = float3x3(
        focal * invZ, 0, -focal * clamped.x * invZ * invZ,
        0, -focal * invZ, focal * clamped.y * invZ * invZ,
        0, 0, 0
    );
    float3x3 covariance2D = mul(jacobian, mul(covariance, transpose(jacobian)));
    // Low-pass filter: every splat covers at least about a pixel.
    float a = covariance2D[0][0] + 0.3;
    float b = covariance2D[0][1];
    float c = covariance2D[1][1] + 0.3;
    float detUnfiltered = max(covariance2D[0][0] * covariance2D[1][1] - b * b, 0.0);
    float compensation = sqrt(detUnfiltered / max(a * c - b * b, 1e-12));
    opacity *= lerp(1.0, compensation, splatMipFilter);

    // The ellipse's axes are the eigenvectors of the 2D covariance.
    float mid = 0.5 * (a + c);
    float spread = sqrt(max(mid * mid - (a * c - b * b), 0.0));
    float lambda1 = mid + spread;
    float lambda2 = max(mid - spread, 0.1);
    float2 axis = abs(b) > 1e-6 ? normalize(float2(b, lambda1 - a)) : (a >= c ? float2(1, 0) : float2(0, 1));
    float radius1 = min(3.0 * sqrt(lambda1), 2048.0);
    float radius2 = min(3.0 * sqrt(lambda2), 2048.0);

    float2 center = float2(viewportSize.x * 0.5 + focal * t.x * invZ, viewportSize.y * 0.5 - focal * t.y * invZ);
    if (center.x + radius1 < 0 || center.x - radius1 > viewportSize.x || center.y + radius1 < 0 ||
        center.y - radius1 > viewportSize.y)
    {
        return;
    }

    // The color as seen from the camera; the harmonics are in the splat's own frame.
    float3 dir = mul(transpose(yaw), normalize(world - camera.eye)) * flip;
    float3 color = evaluateColor(base, dir);
    if (placementDynamic)
    {
        color = effectColor(world - offset, color);
    }
    if (lodShowLevels != 0)
    {
        color = lerp(color, levelColor(lodEnabled != 0 ? lodLevel[i] : 0), 0.7);
    }

    ProjectedSplat splat;
    splat.centerAxis1 = float4(center, axis * radius1);
    // w: 1 to clip per pixel, plus 0.49 x the albedo's luminance (the captured color's,
    // linear): what the GI's G-buffer takes for the splats' albedo (render.slang).
    float3 albedoLinear = pow(saturate(color), 2.2);
    float albedoLuminance = dot(albedoLinear, float3(0.2126, 0.7152, 0.0722));
    splat.axis2 = float4(float2(-axis.y, axis.x) * radius2, t.z, (clipClass == 1 ? 1.0 : 0.0) + 0.49 * saturate(albedoLuminance));
    splat.color = float4(color, opacity);
    // Packed at the front; sorted ascending, so far splats (large z) come first: drawn
    // back to front.
    uint slot;
    InterlockedAdd(drawCount[0], 1, slot);
    [branch]
    if (slot < sortCount)
    {
        projected[slot] = splat;
        drawnSplats[slot] = uint2(i, instance);
        // By the distance to the eye, not the view depth: an order that turning the camera
        // doesn't change (only moving it does), so overlapping splats don't swap -- and pop --
        // as the view turns (as StopThePop, Radl et al. 2024, notes of view-depth sorting).
        sortKeys[slot] = -length(t);
        sortValues[slot] = slot;
        [branch]
        if (splatEffectsOn != 0)
        {
            splatOffsets[2 * slot] = float4(offset, 0);
            splatOffsets[2 * slot + 1] = float4(motion, 0);
        }
    }
}
