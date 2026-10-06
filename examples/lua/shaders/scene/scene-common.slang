// Shared by the scene's shadow pass (shadow.slang) and lit pass (lit.slang).
//
// The scene is a render graph the host runs every frame without calling into Lua, so
// everything that moves on its own is computed here from `time`: the light's orbit and
// the objects' spin. Lua only changes these parameters when something else changes them
// (a key press, the camera being dragged).

#include "mesh/mesh-vertex.slang"

// Seconds since start; provided by the host to every draw that declares it.
uniform float time;

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

// Where an object sits: scaled, turned about the vertical axis, then moved.
struct Transform
{
    float3 position;
    float yaw;        // radians
    float3 scale;
    float spin;       // radians per second, added to yaw
    uint followLight; // 1: placed at the light instead of `position` (the light's marker)
};

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
