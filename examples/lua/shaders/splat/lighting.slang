// Lighting the splats: one thread per splat, run after preprocess.slang and before the
// sort, lights each visible splat by the scene's point light -- the way scene/lit.slang
// lights the meshes, and shadowed through the same lookup (scene/shadow-lookup.slang):
// by the meshes, and by the splats in front of it.
//
// A splat has no normal, but the Gaussians of a surface lie flat along it, so the
// direction of its shortest axis stands in for one (ply.slang), turned to face the camera.
// A round splat's shortest axis means nothing; its diffuse term fades toward a neutral 0.5
// the rounder it is.
//
// The captured colors have the capture's lighting baked in; they stand in for the albedo
// here. `relight` blends between the two:
//
//   0  the colors as captured, only darkened where something shadows them
//   1  the colors as albedo, lit by the point light like the meshes (ambient, falloff,
//      diffuse, shadows), tone mapped the same way

#include "ply.slang"
#include "splat-common.slang"
#include "scene/shadow-lookup.slang"

RWStructuredBuffer<ProjectedSplat> projected;
StructuredBuffer<float> sortKeys; // still in splat order: preprocess wrote them, the sort hasn't run
uniform SplatCamera camera;
uniform float relight;
uniform float shadowStrength;     // relight 0: how dark a fully shadowed splat gets
uniform float shadowBias;         // how far a splat counts as nearer the light than its center

[shader("compute")]
[numthreads(256, 1, 1)]
void lightSplatsMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = tid.x;
    if (i >= splatCount || sortKeys[i] >= kCulledKey * 0.5)
    {
        return; // not drawn this frame
    }
    uint base = splatBase(i);
    float3 world = splatWorldPosition(base);
    float3 lightPos = lightPosition();
    float visibility = shadowVisibility(world - lightPos, shadowBias);

    ProjectedSplat splat = projected[i];
    float3 captured = splat.color.rgb;
    float3 shadowed = captured * lerp(1.0 - shadowStrength, 1.0, visibility);

    // Lit like the meshes in scene/lit.slang, in linear color.
    float flatness;
    float3 normal = splatWorldNormal(base, flatness);
    if (dot(normal, camera.eye - world) < 0)
    {
        normal = -normal;
    }
    float3 toLight = lightPos - world;
    float distanceToLight = length(toLight);
    toLight /= distanceToLight;
    float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
    float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);
    float diffuse = lerp(0.5, saturate(dot(normal, toLight)), saturate(flatness));
    float3 albedo = pow(max(captured, 0.0), 2.2);
    float3 lit = albedo * float3(0.05, 0.06, 0.08) + albedo * diffuse * light.color * attenuation * visibility;
    lit = lit / (1.0 + lit);
    float3 relit = pow(max(lit, 0.0), 1.0 / 2.2); // max: fxc can't tell lit >= 0

    splat.color.rgb = lerp(shadowed, relit, relight);
    projected[i] = splat;
}
