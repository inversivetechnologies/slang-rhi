// Shared by the scene's shadow pass (shadow.slang) and lit pass (lit.slang).
//
// The scene is a render graph the host runs every frame without calling into Lua, so
// everything that moves on its own is computed here from `time`: the light's orbit and
// the objects' spin. Lua only changes these parameters when something else changes them
// (a key press, the camera being dragged).

#pragma once

#include "mesh/mesh-vertex.slang"
#include "common/time.slang"

struct PointLight
{
    float3 center;     // the orbit's center
    float orbitRadius;
    float3 color;
    float intensity;
    float range;       // the light reaches no further than this; also the shadow far plane
    float speed;       // radians per second; 0 holds it still
    float phase;       // the orbit angle at time 0
    float bob;         // how far it bounces up and down
};
uniform PointLight light;

float3 lightPosition()
{
    float angle = light.phase + light.speed * time;
    return light.center + float3(cos(angle) * light.orbitRadius, light.bob * sin(angle * 1.7), sin(angle) * light.orbitRadius);
}

// ---------------------------------------------------------------------------------------
// More point lights, beside the one above: unshadowed, placed by Lua each frame (the light
// system: lib/scene/systems/light.lua), and added by every kind of surface -- the meshes
// (lit.slang), the SDFs (sdf/raymarch.slang), the splats (splat/lighting.slang) -- with the
// same falloff as the shadowed light. Culled per screen tile (scene/light-culling.slang):
// a point adds only the lights whose spheres reach its tile, so hundreds of short-range
// lights cost what the few near each point do.
// ---------------------------------------------------------------------------------------

#include "light-tiles-layout.slang"

StructuredBuffer<float4> pointLightData; // the light block's
uniform uint pointLightCount;
StructuredBuffer<uint> lightTiles;       // the view block's: its tiles' lights

// The light they add at `world` (seen at `pixel` of the view), with its normal, toward the
// eye, and albedo, as lit.slang shades. `specularScale` 0 leaves out the highlight;
// `normalTrust` below 1 fades the diffuse term toward 0.5 (a splat whose normal means
// little).
float3 pointLightsRadiance(float2 pixel, float3 world, float3 normal, float3 toEye, float3 albedo, float specularScale, float normalTrust)
{
    float3 sum = float3(0, 0, 0);
    if (pointLightCount == 0)
        return sum;
    uint tilesX = lightTiles[0], tilesY = lightTiles[1], tileSize = max(lightTiles[2], 1u);
    int2 tile = int2(floor(pixel / float(tileSize)));
    if (any(tile < 0) || uint(tile.x) >= tilesX || uint(tile.y) >= tilesY)
        return sum;
    uint base = kTileHeader + (uint(tile.y) * tilesX + uint(tile.x)) * kTileStride;
    uint count = min(lightTiles[base], kMaxLightsPerTile);
    for (uint k = 0; k < count; ++k)
    {
        uint i = lightTiles[base + 1 + k];
        float4 placement = pointLightData[2 * i]; // position, range
        float4 look = pointLightData[2 * i + 1];  // color, intensity
        float3 toLight = placement.xyz - world;
        float distanceToLight = length(toLight);
        if (distanceToLight >= placement.w)
            continue;
        toLight /= max(distanceToLight, 1e-4);
        float window = saturate(1.0 - pow(distanceToLight / placement.w, 4.0));
        float attenuation = look.w * window * window / (1.0 + distanceToLight * distanceToLight);
        float facing = saturate(dot(normal, toLight));
        float diffuse = lerp(0.5, facing, normalTrust);
        float specular = specularScale * pow(saturate(dot(normal, normalize(toLight + toEye))), 48.0) * 0.5 * (facing > 0 ? 1 : 0);
        sum += (albedo * diffuse + specular) * look.rgb * attenuation;
    }
    return sum;
}

// Where an object sits: scaled, turned about the vertical axis, then moved.
struct Transform
{
    float3 position;
    float yaw;        // radians
    float3 scale;
    float spin;       // radians per second, added to yaw
    uint followLight; // 1: placed at the light instead of `position` (the light's marker)
};

// ---------------------------------------------------------------------------------------
// Physics bodies (examples/lua/physics.cpp): drawn instanced, one instance per body, from
// a buffer the host fills every frame with kBodyStride float4s per body:
//
//   [0] position.xyz    [1] rotation quaternion xyzw    [2] scale.xyz (of the unit mesh)
//   [3] color.rgb, w: material pattern (as Material.pattern in lit.slang)
//   [4] the frame before's position.xyz    [5] its rotation (for motion vectors)
// ---------------------------------------------------------------------------------------

static const uint kBodyStride = 6;
StructuredBuffer<float4> bodies;

float3 rotateByQuaternion(float4 q, float3 v)
{
    float3 t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

float3 bodyPoint(uint body, float3 p)
{
    uint base = body * kBodyStride;
    return rotateByQuaternion(bodies[base + 1], p * bodies[base + 2].xyz) + bodies[base].xyz;
}

// Where `p` (of the unit mesh) was the frame before.
float3 bodyPreviousPoint(uint body, float3 p)
{
    uint base = body * kBodyStride;
    return rotateByQuaternion(bodies[base + 5], p * bodies[base + 2].xyz) + bodies[base + 4].xyz;
}

float3 bodyNormal(uint body, float3 n)
{
    uint base = body * kBodyStride;
    return normalize(rotateByQuaternion(bodies[base + 1], n / bodies[base + 2].xyz));
}

float3 rotateYaw(float3 p, float yaw)
{
    float c = cos(yaw), s = sin(yaw);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

float currentYaw(Transform transform)
{
    return transform.yaw + transform.spin * time;
}

float3 transformPoint(Transform transform, float3 p)
{
    float3 origin = transform.followLight != 0 ? lightPosition() : transform.position;
    return rotateYaw(p * transform.scale, currentYaw(transform)) + origin;
}

float3 transformNormal(Transform transform, float3 n)
{
    return normalize(rotateYaw(n / transform.scale, currentYaw(transform)));
}

// ---------------------------------------------------------------------------------------
// Point light shadows
//
// A point light sees in every direction, so its shadow map is a cube: six 90-degree views,
// one along each axis. They are stored side by side in one r32f texture, 3 faces wide
// and 2 high, each `faceSize` texels square. A texel holds the distance from the light to
// the nearest surface in its direction.
//
// The shadow pass renders each face with cubeFaceClip(), and the lit pass looks a
// direction up with shadowAtlasTexel(). Both project through the same face basis, so the
// two always agree.
// ---------------------------------------------------------------------------------------

static const float kShadowNear = 0.05;

struct CubeFace
{
    float3 right;
    float3 up;
    float3 forward;
};

CubeFace cubeFace(uint face)
{
    CubeFace f;
    switch (face)
    {
    case 0: f.forward = float3(1, 0, 0);  f.up = float3(0, 1, 0);  f.right = float3(0, 0, -1); break;
    case 1: f.forward = float3(-1, 0, 0); f.up = float3(0, 1, 0);  f.right = float3(0, 0, 1);  break;
    case 2: f.forward = float3(0, 1, 0);  f.up = float3(0, 0, -1); f.right = float3(1, 0, 0);  break;
    case 3: f.forward = float3(0, -1, 0); f.up = float3(0, 0, 1);  f.right = float3(1, 0, 0);  break;
    case 4: f.forward = float3(0, 0, 1);  f.up = float3(0, 1, 0);  f.right = float3(1, 0, 0);  break;
    default: f.forward = float3(0, 0, -1); f.up = float3(0, 1, 0); f.right = float3(-1, 0, 0); break;
    }
    return f;
}

// The face that sees direction `d`: the one along its largest component.
uint cubeFaceOf(float3 d)
{
    float3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z)
        return d.x >= 0 ? 0 : 1;
    if (a.y >= a.z)
        return d.y >= 0 ? 2 : 3;
    return d.z >= 0 ? 4 : 5;
}

// Clip position of `d` (a direction from the light) in a face's 90-degree view.
float4 cubeFaceClip(uint face, float3 d, float farPlane)
{
    CubeFace f = cubeFace(face);
    float z = dot(d, f.forward);
    return float4(dot(d, f.right), dot(d, f.up), (z - kShadowNear) * farPlane / (farPlane - kShadowNear), z);
}

// Where a face sits in the atlas, in texels.
uint2 shadowFaceOrigin(uint face, uint faceSize)
{
    return uint2(face % 3, face / 3) * faceSize;
}

// The atlas texel (as a float position within the face, and the face) that direction `d`
// projects to.
float2 shadowFaceTexel(float3 d, uint face, uint faceSize)
{
    CubeFace f = cubeFace(face);
    float z = dot(d, f.forward);
    float2 ndc = float2(dot(d, f.right), dot(d, f.up)) / z;
    // Clip space y points up, texel rows go down.
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5) * faceSize;
}
