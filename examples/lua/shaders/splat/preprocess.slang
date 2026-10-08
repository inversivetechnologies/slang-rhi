// Gaussian splatting, step 1: one thread per splat turns the trained 3D Gaussian into what
// the rasterizer needs -- the ellipse it covers on screen, its color as seen from the
// camera, and a depth to sort by.
//
// Levels of detail: the splats include merged ones (built by the host when the file was
// loaded: splat-lod.h), one per node of a tree over the file's splats. A splat is drawn
// when it is small enough on screen and its parent isn't -- each decides on its own, and
// the tree's bounds make sure exactly one splat on every path from the root to a file's
// splat is drawn. The drawn ones are packed at the front of the sort's buffers (an atomic
// counter, `drawCount`), so the sort, the lighting and the draw skip the rest.
//
// The splats are read and placed by ply.slang. Following "3D Gaussian Splatting for
// Real-Time Radiance Field Rendering" (Kerbl et al. 2023):
//
//   - the 3D covariance is built from the splat's rotation and scale: R S S^T R^T
//   - it is projected to 2D with the Jacobian of the perspective projection (EWA splatting)
//   - the color is evaluated from spherical harmonics (up to degree 3) in the direction
//     from the camera

#include "splat-common.slang"
#include "ply.slang"

uniform uint sortCount;      // splatCount padded to the sort's power of two
uniform SplatCamera camera;
uniform float2 viewportSize; // provided by the host

RWStructuredBuffer<ProjectedSplat> projected;
RWStructuredBuffer<float> sortKeys;
RWStructuredBuffer<uint> sortValues;
RWStructuredBuffer<uint> drawCount; // [0]: splats drawn this frame (packed at the front)

// Levels of detail.
StructuredBuffer<float4> lodBounds; // per splat: its bounds, then its parent's (splat-lod.h)
StructuredBuffer<uint> lodLevel;    // per splat: 0 for the file's, the height above them for merged ones
uniform uint lodEnabled;            // 0: no merged splats; draw every one of the file's
uniform float lodPixels;            // a merged splat stands in for its children once its bounds' radius is this small, in pixels
uniform uint lodShowLevels;         // 1: tint the splats by level

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
// with keys that sort last.
[shader("compute")]
[numthreads(256, 1, 1)]
void padMain(uint3 tid: SV_DispatchThreadID)
{
    uint count = drawCount[0];
    uint i = tid.x;
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
    if (i >= splatCount)
    {
        return;
    }
    float focal = viewportSize.y * 0.5 / tan(camera.fovY * 0.5);
    if (lodEnabled != 0)
    {
        // Drawn if small enough, and its parent isn't (so its parent isn't drawn).
        if (!lodSmallEnough(lodBounds[2 * i], camera.eye, focal, lodPixels) ||
            lodSmallEnough(lodBounds[2 * i + 1], camera.eye, focal, lodPixels))
        {
            return;
        }
    }
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
    if (lodShowLevels != 0)
    {
        color = lerp(color, levelColor(lodEnabled != 0 ? lodLevel[i] : 0), 0.7);
    }

    ProjectedSplat splat;
    splat.centerAxis1 = float4(center, axis * radius1);
    splat.axis2 = float4(float2(-axis.y, axis.x) * radius2, t.z, 0);
    splat.color = float4(color, opacity);
    projected[i] = splat;
    // Packed at the front; sorted ascending, so far splats (large z) come first: drawn
    // back to front.
    uint slot;
    InterlockedAdd(drawCount[0], 1, slot);
    sortKeys[slot] = -t.z;
    sortValues[slot] = i;
}
