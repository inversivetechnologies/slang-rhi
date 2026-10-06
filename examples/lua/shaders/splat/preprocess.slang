// Gaussian splatting, step 1: one thread per splat turns the trained 3D Gaussian into what
// the rasterizer needs -- the ellipse it covers on screen, its color as seen from the
// camera, and a depth to sort by.
//
// The splats come straight from the PLY file (rhi.load_ply), as records of floats whose
// layout the script passes in `ply`. Following "3D Gaussian Splatting for Real-Time
// Radiance Field Rendering" (Kerbl et al. 2023):
//
//   - the 3D covariance is built from the splat's rotation and scale: R S S^T R^T
//   - it is projected to 2D with the Jacobian of the perspective projection (EWA splatting)
//   - the color is evaluated from spherical harmonics (up to degree 3) in the direction
//     from the camera

#include "splat-common.slang"

// Where each property sits in a splat's record (offsets in floats).
struct PlyLayout
{
    uint stride;    // floats per splat
    uint position;  // x, y, z
    uint rotation;  // rot_0..3: quaternion w, x, y, z (not normalized)
    uint scale;     // scale_0..2: log of the scale along each axis
    uint opacity;   // logit of the opacity
    uint dc;        // f_dc_0..2: spherical harmonics band 0, per channel
    uint rest;      // f_rest_*: the higher bands, all of red's, then green's, then blue's
    uint restCount; // number of f_rest floats: 0, 9, 24 or 45 (degree 0 to 3)
};

struct SplatCamera
{
    float3 eye;
    float fovY; // vertical field of view, radians
    float3 target;
};

// Places the splats in the world: scaled, turned about the vertical axis, then moved
// (after the optional y/z flip). The identity is { position = 0, yaw = 0, scale = 1 }.
struct SplatModel
{
    float3 position;
    float yaw;
    float scale;
};

StructuredBuffer<float> plyData;
uniform PlyLayout ply;
uniform uint splatCount;
uniform uint sortCount;      // splatCount padded to the sort's power of two
uniform SplatCamera camera;
uniform uint flipYZ;         // 1: the scene is y-down (as COLMAP captures are); turn it upright
uniform SplatModel model;
uniform float splatScale;    // multiplies every splat's size; 1 is as trained
uniform float2 viewportSize; // provided by the host

RWStructuredBuffer<ProjectedSplat> projected;
RWStructuredBuffer<float> sortKeys;
RWStructuredBuffer<uint> sortValues;

float3 loadFloat3(uint index)
{
    return float3(plyData[index], plyData[index + 1], plyData[index + 2]);
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

// The rotation matrix of a unit quaternion (w, x, y, z).
float3x3 quaternionToMatrix(float4 q)
{
    float w = q.x, x = q.y, y = q.z, z = q.w;
    return float3x3(
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)
    );
}

[shader("compute")]
[numthreads(256, 1, 1)]
void preprocessMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x;
    if (i >= sortCount)
    {
        return;
    }
    // Not drawn unless it survives everything below.
    sortKeys[i] = kCulledKey;
    sortValues[i] = i;
    if (i >= splatCount)
    {
        return;
    }
    uint base = i * ply.stride;

    float opacity = 1.0 / (1.0 + exp(-plyData[base + ply.opacity]));
    if (opacity < 1.0 / 255.0)
    {
        return;
    }

    // The splat's frame to the world: optionally turned upright, then placed by `model`.
    float3 flip = flipYZ != 0 ? float3(1, -1, -1) : float3(1, 1, 1);
    float yawCos = cos(model.yaw), yawSin = sin(model.yaw);
    float3x3 yaw = float3x3(yawCos, 0, yawSin, 0, 1, 0, -yawSin, 0, yawCos);
    float3 world = mul(yaw, loadFloat3(base + ply.position) * flip * model.scale) + model.position;

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

    // 3D covariance: R S S^T R^T, flipped and placed into the world, then into the view.
    float4 q = float4(plyData[base + ply.rotation], plyData[base + ply.rotation + 1],
                      plyData[base + ply.rotation + 2], plyData[base + ply.rotation + 3]);
    float3x3 rotation = quaternionToMatrix(normalize(q));
    float3 scale = exp(loadFloat3(base + ply.scale)) * splatScale * model.scale;
    float3x3 m = float3x3(rotation[0] * scale, rotation[1] * scale, rotation[2] * scale);
    float3x3 covariance = mul(m, transpose(m));
    float3x3 flipOuter = float3x3(flip * flip.x, flip * flip.y, flip * flip.z);
    float3x3 toView = mul(view, yaw);
    covariance = mul(toView, mul(covariance * flipOuter, transpose(toView)));

    // Project to pixels (y down) and take the Jacobian there. Clamping the point to a bit
    // beyond the frustum keeps splats at the edges from blowing up.
    float focal = viewportSize.y * 0.5 / tan(camera.fovY * 0.5);
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

    ProjectedSplat splat;
    splat.centerAxis1 = float4(center, axis * radius1);
    splat.axis2 = float4(float2(-axis.y, axis.x) * radius2, t.z, 0);
    splat.color = float4(color, opacity);
    projected[i] = splat;
    // Sorted ascending, so far splats (large z) come first: drawn back to front.
    sortKeys[i] = -t.z;
}
