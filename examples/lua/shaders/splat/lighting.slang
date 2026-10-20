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
//
// `showVisibility` 1 shows only how much light reaches each splat instead, white to black.
//
// Shadows and the levels of detail: a splat may be one of the file's or a merged one,
// standing in for a whole cluster. So the shadow lookup is sized by the splat: it counts
// as nearer to the light by part of its own extent (so that it isn't shadowed by itself,
// or by its own cluster's splats in the light's cut), plus a texel or so (the shadow map's
// own error); and it averages the maps over as many texels as it covers, rather than
// sampling one spot of the area it stands for.

#include "ply.slang"
#include "splat-common.slang"
#include "scene/shadow-lookup.slang"

RWStructuredBuffer<ProjectedSplat> projected; // per drawn splat
StructuredBuffer<uint2> drawnSplats;          // per drawn splat: which splat and instance
StructuredBuffer<uint> drawCount;             // [0]: how many (maybe more than fit: see sortCount)
uniform uint sortCount;                       // how many fit
uniform SplatCamera camera;
uniform float relight;
uniform float shadowStrength;     // relight 0: how dark a fully shadowed splat gets
uniform float shadowBias;         // how far any splat counts as nearer the light than its center
uniform float shadowBiasExtent;   // plus this much of its own extent (3 sigma, largest axis)
uniform float shadowBiasTexels;   // plus this many shadow map texels
uniform uint showVisibility;      // 1: show the light reaching each splat, not its color

// Each splat's shadow visibility, kept from frame to frame (per splat and instance), and
// blended with the new one: the splats' shadow maps are drawn anew every frame, and the
// light reaching a splat changes in small steps as the light, the levels of detail or the
// splats' footprints in the maps move. Smoothed per splat, it doesn't trail the camera at
// all (nothing is reprojected), only the light, by a few frames. A packed uint each: the
// frame it was written (16 bits), the visibility (16 bits).
RWStructuredBuffer<uint> shadowHistory;
uniform uint shadowHistoryCapacity; // entries it holds (0: no history)
uniform uint lightingEntries;       // splats an instance has (the file's and merged ones)
uniform float shadowHistoryBlend;   // the new frame's share (1: no smoothing)
uniform uint frameCounter;          // provided by the host

// The screen-space indirect light (post/ssao.slang), for the splats cached per splat as the
// shadows are: each splat takes the last frame's GI where its center is, blends it into its
// own history (giHistory: rgb, 10 bits each, the square root of a quarter of the light,
// so that faint light keeps its precision), and adds it to its color, as the effects add it
// to the meshes'; the effects' apply pass then leaves the splats out. A screen-space estimate on
// splats is noisy (their depth buffer holds one depth a splat, so the normals rebuilt from
// it are rough), and a moving light changes it every frame; smoothed per splat, it neither
// flickers nor trails the camera.
Texture2D<float4> splatGi;      // the view's GI history (rgb), last frame's
SamplerState splatGiSampler;
uniform float splatGiStrength;  // 0: no GI on the splats here
uniform float splatGiBlend;     // the new frame's share
// 1: splatGi is the radiance cascades' (lib/scene/gi.lua): rgb irradiance -- times the
// splat's albedo -- and a the ambient visibility, cached as well (the effects' apply pass
// then leaves both out where a splat is nearest). 0: SSGI's light, added as it is.
uniform uint splatGiIrradiance;
RWStructuredBuffer<uint> giHistory;
uniform float2 viewportSize;    // the view's: the host's (the window's) or the view block's (an inset's)

// rgb: the square root of a quarter of the light, 8 bits each (faint light keeps its
// precision); a: the ambient visibility, 8 bits.
uint packGi(float4 c)
{
    uint3 q = uint3(sqrt(saturate(c.rgb * 0.25)) * 255.0 + 0.5);
    uint a = uint(saturate(c.a) * 255.0 + 0.5);
    return q.x | (q.y << 8) | (q.z << 16) | (a << 24);
}

float4 unpackGi(uint v)
{
    float3 r = float3(v & 255u, (v >> 8) & 255u, (v >> 16) & 255u) / 255.0;
    return float4(r * r * 4.0, float(v >> 24) / 255.0);
}

// 256 a group: one thread per slot, up to 2^23 of them, in at most 32768 groups (the
// limit is 65535).
[shader("compute")]
[numthreads(256, 1, 1)]
void lightSplatsMain(uint3 tid: SV_DispatchThreadID)
{
    uint slot = tid.x;
    if (slot >= min(drawCount[0], sortCount))
    {
        return; // fewer drawn this frame
    }
    uint2 drawn = drawnSplats[slot];
    uint i = drawn.x;
    beginInstance(drawn.y);
    uint base = splatBase(i);
    float3 world = splatWorldPosition(base);
    float3 lightPos = lightPosition();
    float3 fromLight = world - lightPos;
    float3 scale = splatWorldScale(base);
    float extent = 3.0 * max(scale.x, max(scale.y, scale.z));
    float texel = shadowTexelSize(length(fromLight));
    float bias = shadowBias + shadowBiasExtent * extent + shadowBiasTexels * texel;
    // The filter: the splat's footprint in the map, half of it either way, at least the
    // texel's neighbors.
    float spacing = clamp(0.5 * extent / texel, 1.0, 8.0);
    float visibility = shadowVisibilitySpread(fromLight, bias, spacing);

    // Its visibility of the frame before, if it was drawn then (else it starts over: new in
    // the levels of detail's cut, or back in view). A second view in the same frame finds
    // this frame's already, and takes it as it is.
    ProjectedSplat splat = projected[slot];
    float4 indirect = float4(0, 0, 0, 1); // rgb light, a ambient visibility
    if (splatGiStrength > 0)
    {
        float4 g = splatGi.SampleLevel(splatGiSampler, splat.centerAxis1.xy / viewportSize, 0);
        indirect = float4(g.rgb * splatGiStrength, splatGiIrradiance != 0 ? g.a : 1.0);
    }

    uint historyIndex = drawn.y * lightingEntries + i;
    [branch]
    if (historyIndex < shadowHistoryCapacity)
    {
        uint old = shadowHistory[historyIndex];
        uint stamp = old >> 16;
        float before = float(old & 0xFFFFu) / 65535.0;
        uint now = frameCounter & 0xFFFFu;
        bool fresh = stamp == now;
        bool continuing = stamp == ((now - 1u) & 0xFFFFu);
        float4 indirectBefore = splatGiStrength > 0 ? unpackGi(giHistory[historyIndex]) : float4(0, 0, 0, 1);
        if (fresh)
        {
            visibility = before;
            indirect = indirectBefore;
        }
        else if (continuing)
        {
            visibility = lerp(before, visibility, shadowHistoryBlend);
            indirect = lerp(indirectBefore, indirect, splatGiBlend);
        }
        [branch]
        if (!fresh)
        {
            shadowHistory[historyIndex] = (now << 16) | uint(saturate(visibility) * 65535.0 + 0.5);
            if (splatGiStrength > 0)
                giHistory[historyIndex] = packGi(indirect);
        }
    }

    float3 captured = splat.color.rgb;
    float3 shadowed = captured * lerp(1.0 - shadowStrength, 1.0, visibility);

    // Lit like the meshes in scene/lit.slang, in linear color.
    // A splat's normal (its shortest axis) has no side of its own: the one facing the eye is
    // taken. Not by a hard flip, which as the camera turned past a splat edge on switched
    // its light from one side to the other in a frame -- a pop for every splat the view
    // swept past -- but by blending the two sides' light over a narrow band about edge on.
    float flatness;
    float3 normal = splatWorldNormal(base, flatness);
    float3 toEye = normalize(camera.eye - world);
    float front = smoothstep(-0.25, 0.25, dot(normal, toEye)); // 1: `normal` faces the eye
    float3 toLight = lightPos - world;
    float distanceToLight = length(toLight);
    toLight /= distanceToLight;
    float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
    float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);
    float facing = lerp(saturate(-dot(normal, toLight)), saturate(dot(normal, toLight)), front);
    float diffuse = lerp(0.5, facing, saturate(flatness));
    float3 albedo = pow(max(captured, 0.0), 2.2);
    // The unshadowed point lights: a diffuse term only, trusted as far as the normal is;
    // both sides' near edge on, as above.
    float3 extra;
    [branch]
    if (front <= 0.0 || front >= 1.0)
    {
        extra = pointLightsRadiance(splat.centerAxis1.xy, world, front >= 1.0 ? normal : -normal, toEye, albedo, 0.0, saturate(flatness));
    }
    else
    {
        extra = lerp(pointLightsRadiance(splat.centerAxis1.xy, world, -normal, toEye, albedo, 0.0, saturate(flatness)),
                     pointLightsRadiance(splat.centerAxis1.xy, world, normal, toEye, albedo, 0.0, saturate(flatness)), front);
    }
    float3 lit = albedo * float3(0.05, 0.06, 0.08) + albedo * diffuse * light.color * attenuation * visibility + extra;
    lit = lit / (1.0 + lit);
    // The indirect light, after the tone map, as the effects add it: the cascades' times
    // the ambient visibility and the albedo; SSGI's as it is.
    float3 bounce = splatGiIrradiance != 0 ? albedo * indirect.rgb : indirect.rgb;
    lit = lit * indirect.a + bounce;
    float3 relit = pow(max(lit, 0.0), 1.0 / 2.2); // max: fxc can't tell lit >= 0
    // As captured, the point lights still add on (in linear light, then back).
    shadowed = pow(max(pow(max(shadowed, 0.0), 2.2) * indirect.a + extra + bounce, 0.0), 1.0 / 2.2);

    splat.color.rgb = lerp(shadowed, relit, relight);
    if (showVisibility != 0)
    {
        splat.color.rgb = visibility;
    }
    projected[slot] = splat;
}
