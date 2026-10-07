// Raymarching pass: one thread per pixel sphere-traces the SDF composition (sdf-dag.slang)
// from the camera, and writes what it hits -- lit like the meshes -- with its depth, so the
// depth composite (post/depth-composite.slang) can merge it with the other passes.
//
//   - Rays stop at the meshes: the mesh pass's depth buffer says how far each pixel can
//     go before a mesh is in front anyway.
//   - The surface normal comes from the distance field's gradient (four extra samples).
//   - Lighting is scene/lit.slang's: ambient, falloff, diffuse, specular, and shadows from
//     the meshes and the splats through scene/shadow-lookup.slang.
//   - Depth is written as the meshes write it (z/w over the same near and far planes), so
//     the composite compares all three kinds of surface the same way.

#include "sdf-dag.slang"
#include "sdf-world.slang"
#include "scene/shadow-lookup.slang"

struct RaymarchCamera
{
    float3 eye;
    float fovY;
    float3 target;
};

uniform RaymarchCamera camera;
uniform float2 viewportSize; // provided by the host: the window's size
Texture2D<float> meshDepth;
RWTexture2D<float4> sdfColor; // linear, tone mapped like the meshes; 0 where nothing is hit
RWTexture2D<float> sdfDepth;  // z/w depth; 1 (the far plane) where nothing is hit

static const float kNear = 0.1;
static const float kFar = 100.0;
static const int kMaxSteps = 128;

float3 sdfNormal(float3 world)
{
    // The gradient by four samples at the corners of a tetrahedron.
    const float e = 0.0015;
    const float2 k = float2(1, -1);
    return normalize(
        k.xyy * evaluateSdf(toSdfSpace(world + k.xyy * e)).distance +
        k.yyx * evaluateSdf(toSdfSpace(world + k.yyx * e)).distance +
        k.yxy * evaluateSdf(toSdfSpace(world + k.yxy * e)).distance +
        k.xxx * evaluateSdf(toSdfSpace(world + k.xxx * e)).distance);
}

float depthFromViewZ(float z)
{
    return (z - kNear) * kFar / ((kFar - kNear) * z);
}

float viewZFromDepth(float depth)
{
    return kNear * kFar / (kFar - depth * (kFar - kNear));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void raymarchMain(uint3 tid: SV_DispatchThreadID)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
    {
        return;
    }

    // The pixel's ray, with the meshes' camera.
    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float focal = 1.0 / tan(camera.fovY * 0.5);
    float2 ndc = float2((tid.x + 0.5) / viewportSize.x * 2 - 1, 1 - (tid.y + 0.5) / viewportSize.y * 2);
    float3 dir = normalize(forward * focal + right * ndc.x * viewportSize.x / viewportSize.y + up * ndc.y);
    float forwardness = dot(dir, forward);

    // No farther than the meshes in this pixel.
    float maxT = min(viewZFromDepth(meshDepth.Load(int3(tid.xy, 0))), 30.0) / forwardness;

    // Only inside the composition's bounding sphere; most pixels miss it and stop here.
    float2 bounds = sdfBoundsInterval(camera.eye, dir);
    maxT = min(maxT, bounds.y);
    float t = max(kNear / forwardness, bounds.x);
    bool hit = false;
    [loop]
    for (int i = 0; i < kMaxSteps && t < maxT; ++i)
    {
        float d = evaluateSdf(toSdfSpace(camera.eye + dir * t)).distance;
        if (d < 0.0005 * t)
        {
            hit = true;
            break;
        }
        t += d;
    }

    if (!hit)
    {
        sdfColor[tid.xy] = float4(0, 0, 0, 0);
        sdfDepth[tid.xy] = 1.0;
        return;
    }

    float3 world = camera.eye + dir * t;
    float3 albedo = evaluateSdf(toSdfSpace(world)).color;
    float3 normal = sdfNormal(world);
    // The normal is in the composition's space; turn it back into the world's.
    normal = fromSdfSpaceDirection(normal);

    float3 lightPos = lightPosition();
    float3 toLight = lightPos - world;
    float distanceToLight = length(toLight);
    toLight /= distanceToLight;
    float3 toEye = -dir;
    float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
    float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);
    float diffuse = saturate(dot(normal, toLight));
    float specular = pow(saturate(dot(normal, normalize(toLight + toEye))), 48.0) * 0.5 * (diffuse > 0 ? 1 : 0);
    float grazing = 1.0 - diffuse;
    float shadow = shadowVisibility(world + normal * (0.02 + 0.04 * grazing) - lightPos, 0.02);

    float3 color = albedo * float3(0.05, 0.06, 0.08) + (albedo * diffuse + specular) * light.color * attenuation * shadow;
    color = color / (1.0 + color);
    sdfColor[tid.xy] = float4(color, 1);
    sdfDepth[tid.xy] = depthFromViewZ(t * forwardness);
}
