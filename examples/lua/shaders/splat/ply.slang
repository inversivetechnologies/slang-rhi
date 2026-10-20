// Reading splats from the PLY data and placing them in the world. Shared by everything
// that starts from the file: preprocess.slang (drawing the splats) and
// shadow-casters.slang (their shadows), so both put every splat in the same place.
//
// The splats come straight from the PLY file (rhi.load_ply), as records of floats whose
// layout the script passes in `ply`.

// Where each property sits in a splat's record (offsets in floats).
#pragma once

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
uniform uint flipYZ;      // 1: the scene is y-down (as COLMAP captures are); turn it upright
uniform SplatModel model; // where all the instances go
uniform float splatScale; // multiplies every splat's size; 1 is as trained

// Instances: copies of all the splats, each placed by its own SplatModel and then by
// `model`. Two float4s per instance: position and yaw, then scale, dynamic (1: the
// effects move and color it, effect-field.slang; 0: static, as captured) and two unused.
StructuredBuffer<float4> instances;
uniform uint instanceCount;

// The placement the functions below use: set per thread, by beginInstance (or
// beginFileFrame), before any of them.
static SplatModel placement;
static bool placementDynamic; // and whether the effects apply to it

// Places the splats as instance `instance`, then `model`: the two placements composed.
void beginInstance(uint instance)
{
    float4 positionYaw = instances[2 * instance];
    float2 scaleDynamic = instances[2 * instance + 1].xy;
    float scale = scaleDynamic.x;
    placementDynamic = scaleDynamic.y != 0;
    float yawCos = cos(model.yaw), yawSin = sin(model.yaw);
    float3x3 modelYaw = float3x3(yawCos, 0, yawSin, 0, 1, 0, -yawSin, 0, yawCos);
    placement.position = mul(modelYaw, positionYaw.xyz * model.scale) + model.position;
    placement.yaw = model.yaw + positionYaw.w;
    placement.scale = model.scale * scale;
}

// Leaves the splats in the file's frame: only the flip.
void beginFileFrame()
{
    placement.position = float3(0, 0, 0);
    placement.yaw = 0;
    placement.scale = 1;
    placementDynamic = false;
}

float3 loadFloat3(uint index)
{
    return float3(plyData[index], plyData[index + 1], plyData[index + 2]);
}

// The first float of splat i's record.
uint splatBase(uint i)
{
    return i * ply.stride;
}

float splatOpacity(uint base)
{
    return 1.0 / (1.0 + exp(-plyData[base + ply.opacity]));
}

// The file's frame to the world's axes: the flip, as a per-axis sign.
float3 splatFlip()
{
    return flipYZ != 0 ? float3(1, -1, -1) : float3(1, 1, 1);
}

// The placement's turn about the vertical axis.
float3x3 splatYaw()
{
    float yawCos = cos(placement.yaw), yawSin = sin(placement.yaw);
    return float3x3(yawCos, 0, yawSin, 0, 1, 0, -yawSin, 0, yawCos);
}

// A point already flipped (in the file's frame, upright) to the world, by the placement.
float3 splatPlace(float3 flipped)
{
    return mul(splatYaw(), flipped * placement.scale) + placement.position;
}

float3 splatWorldPosition(uint base)
{
    return splatPlace(loadFloat3(base + ply.position) * splatFlip());
}

// The splat's scale along its three axes, in world units.
float3 splatWorldScale(uint base)
{
    return exp(loadFloat3(base + ply.scale)) * splatScale * placement.scale;
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

// The splat's surface normal in the world, as Gaussians on a surface lie flat along it: the
// direction of its shortest axis. Its sign is arbitrary. `flatness` says how much to trust
// it -- 0 for a round splat, whose shortest axis means nothing, toward 1 for a flat one.
float3 splatWorldNormal(uint base, out float flatness)
{
    float3 s = exp(loadFloat3(base + ply.scale));
    float4 q = float4(plyData[base + ply.rotation], plyData[base + ply.rotation + 1],
                      plyData[base + ply.rotation + 2], plyData[base + ply.rotation + 3]);
    float3x3 rotation = quaternionToMatrix(normalize(q));
    // The axes are the rotation's columns.
    uint shortest = s.x <= s.y && s.x <= s.z ? 0 : (s.y <= s.z ? 1 : 2);
    float middle = max(min(s.x, s.y), min(max(s.x, s.y), s.z));
    flatness = 1.0 - s[shortest] / max(middle, 1e-12);
    float3 axis = float3(rotation[0][shortest], rotation[1][shortest], rotation[2][shortest]);
    return normalize(mul(splatYaw(), axis * splatFlip()));
}

// The splat's 3D covariance in the world: R S S^T R^T from its rotation and scale, then
// flipped and turned like its position.
float3x3 splatWorldCovariance(uint base)
{
    float4 q = float4(plyData[base + ply.rotation], plyData[base + ply.rotation + 1],
                      plyData[base + ply.rotation + 2], plyData[base + ply.rotation + 3]);
    float3x3 rotation = quaternionToMatrix(normalize(q));
    float3 scale = splatWorldScale(base);
    float3x3 m = float3x3(rotation[0] * scale, rotation[1] * scale, rotation[2] * scale);
    float3x3 covariance = mul(m, transpose(m));
    float3 flip = splatFlip();
    float3x3 flipOuter = float3x3(flip * flip.x, flip * flip.y, flip * flip.z);
    float3x3 yaw = splatYaw();
    return mul(yaw, mul(covariance * flipOuter, transpose(yaw)));
}
