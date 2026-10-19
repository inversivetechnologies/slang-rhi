// Looking up how much of the point light reaches a point, from the shadow maps -- shared by
// everything that receives shadows: the meshes (lit.slang) and the Gaussian splats
// (splat/lighting.slang), so both are shadowed by exactly the same rules.
//
// Three maps, all in the atlas layout of scene-common.slang (six cube faces, 3 x 2 cells):
//
//   shadowMap          the meshes: the distance from the light to the nearest one
//   splatShadowMap     the splats, as a translucent medium (splat/shadow.slang):
//                        r  optical depth of all splats in that direction
//                        a  distance to the nearest of them
//   splatShadowLayers  the splats' deep opacity map: the optical depth gathered from the
//                      nearest splat up to kSplatLayerBounds[k] past it, in channel k
//
// The layers say how much of the splats lies in front of a point, not only how much there
// is in that direction -- what a splat needs to be shadowed by the splats in front of it
// (self-shadowing), and what a mesh between splats needs, too.
//
// The SDF composition (sdf/sdf-dag.slang) isn't in a map: its shadows are soft, so each
// point marches toward the light through the distance field itself (sdfSoftShadow).

#pragma once

#include "scene-common.slang"
#include "sdf/sdf-dag.slang"
#include "sdf/sdf-world.slang"

Texture2D<float> shadowMap;
uniform uint shadowFaceSize;
Texture2D<float4> splatShadowMap;
Texture2D<float4> splatShadowLayers;
uniform uint splatShadows; // 1: read the splat maps (the fusion example draws them)
uniform uint sdfShadows;   // 1: march the SDF composition for its soft shadows
// How sharp the SDF shadows' edges are: penumbrae are about distance / sharpness wide, so
// larger is harder (it stands for a smaller light).
uniform float sdfShadowSharpness;

// The distances past the nearest splat where the layers end. Close together near it, where
// a surface's own splats are, and farther apart behind.
static const float4 kSplatLayerBounds = float4(0.05, 0.15, 0.4, 1.2);

// The optical depth of the splats between the light and a point `distance` from it.
// Piecewise linear through the layers; past the last one, all the splats in that direction.
// (Written out rather than as a loop: D3D11's fxc can't unroll a loop with returns in it
// inside the 3x3 lookup below.)
float splatOpticalDepth(float4 nearest, float4 layers, float distance)
{
    float behind = distance - nearest.a;
    if (behind <= 0)
    {
        return 0;
    }
    if (behind >= kSplatLayerBounds.w)
    {
        return max(nearest.r, layers.w);
    }
    // The layer segment `behind` falls in: from (bound0, depth0) to (bound1, depth1).
    float bound0 = 0, depth0 = 0, bound1 = kSplatLayerBounds.x, depth1 = layers.x;
    if (behind >= kSplatLayerBounds.x)
    {
        bound0 = kSplatLayerBounds.x; depth0 = layers.x; bound1 = kSplatLayerBounds.y; depth1 = layers.y;
    }
    if (behind >= kSplatLayerBounds.y)
    {
        bound0 = kSplatLayerBounds.y; depth0 = layers.y; bound1 = kSplatLayerBounds.z; depth1 = layers.z;
    }
    if (behind >= kSplatLayerBounds.z)
    {
        bound0 = kSplatLayerBounds.z; depth0 = layers.z; bound1 = kSplatLayerBounds.w; depth1 = layers.w;
    }
    return lerp(depth0, depth1, (behind - bound0) / (bound1 - bound0));
}

// Soft shadow of the SDF composition: how much of the light reaches `origin` past it, from
// a march toward the light ("soft shadows" in Inigo Quilez's SDF articles). At each step,
// d / t is how near the ray passes the surface -- d the distance to it, t the distance
// travelled -- as an angle, seen from the point. A ray that just grazes the shape leaves
// the point in partial shadow, and the penumbra widens with distance from the caster, as
// a real light's does. Rays that miss the composition's bounding sphere don't march.
float sdfSoftShadow(float3 origin, float3 toLight, float distanceToLight)
{
    float2 bounds = sdfBoundsInterval(origin, toLight);
    float t = max(bounds.x, 0.02);
    float end = min(bounds.y, distanceToLight);
    if (t >= end)
    {
        return 1.0;
    }
    float lit = 1.0;
    [loop]
    for (int i = 0; i < 64 && t < end; ++i)
    {
        float d = sdfFieldDistance(toSdfSpace(origin + toLight * t));
        if (d < 0.0005)
        {
            return 0.0;
        }
        lit = min(lit, sdfShadowSharpness * d / t);
        t += clamp(d, 0.005, 0.25);
    }
    lit = saturate(lit);
    return lit * lit * (3.0 - 2.0 * lit); // smooth the penumbra's falloff
}

// The size of a shadow map texel at `distance` from the light: a cube face spans 90
// degrees, 2 x distance across, over shadowFaceSize texels.
float shadowTexelSize(float distance)
{
    return 2.0 * distance / float(shadowFaceSize);
}

// The light one shadow map texel lets through to a point at `current` from the light:
// none behind a mesh, else what the splats in front of it leave (their optical depth).
float shadowTexelLight(int3 p, float current)
{
    if (current > shadowMap.Load(p))
        return 0.0; // behind a mesh
    if (splatShadows == 0)
        return 1.0;
    return exp(-splatOpticalDepth(splatShadowMap.Load(p), splatShadowLayers.Load(p), current));
}

// Fraction of the light reaching a point (0: in shadow, 1: lit), filtered for soft edges:
// blocked by the meshes, dimmed by the splats in front of it, and shaded softly by the SDF
// composition. `d` is the point minus the light's position; `bias` how far the point
// counts as nearer to the light than it is, so that a surface doesn't shadow itself. A
// receiver that covers many texels (a merged splat of the levels of detail) samples them
// `spacing` texels apart, so it gets the average over its extent rather than over one spot.
//
// Four taps, half `spacing` either way of the point, each filtered bilinearly over the 4
// texels around it (each texel's comparison made first, then weighted): the footprint is a
// tent about 2 x spacing texels wide, and the weights follow the point continuously. So a
// light, a camera or a splat moving a fraction of a texel changes the result by a fraction,
// rather than flipping taps from one texel to the next -- what made shadows shimmer as the
// light moved.
float shadowVisibilitySpread(float3 d, float bias, float spacing)
{
    float current = length(d) - bias;
    uint face = cubeFaceOf(d);
    float2 texel = shadowFaceTexel(d, face, shadowFaceSize) - 0.5; // texel centers at whole numbers
    int2 origin = int2(shadowFaceOrigin(face, shadowFaceSize));
    int last = int(shadowFaceSize) - 1;

    float lit = 0;
    for (int tap = 0; tap < 4; ++tap)
    {
        float2 q = texel + (float2(tap & 1, tap >> 1) - 0.5) * spacing;
        float2 cell = floor(q);
        float2 f = q - cell;
        // Stay inside this face's cell: the next cell over is a different view.
        int2 i0 = clamp(int2(cell), int2(0, 0), int2(last, last));
        int2 i1 = clamp(int2(cell) + 1, int2(0, 0), int2(last, last));
        float a = shadowTexelLight(int3(origin + int2(i0.x, i0.y), 0), current);
        float b = shadowTexelLight(int3(origin + int2(i1.x, i0.y), 0), current);
        float c = shadowTexelLight(int3(origin + int2(i0.x, i1.y), 0), current);
        float e = shadowTexelLight(int3(origin + int2(i1.x, i1.y), 0), current);
        lit += lerp(lerp(a, b, f.x), lerp(c, e, f.x), f.y);
    }
    float visibility = lit / 4.0;
    if (sdfShadows != 0 && visibility > 0)
    {
        float distanceToLight = length(d);
        visibility *= sdfSoftShadow(lightPosition() + d, -d / distanceToLight, distanceToLight - bias);
    }
    return visibility;
}

float shadowVisibility(float3 d, float bias)
{
    return shadowVisibilitySpread(d, bias, 1.0);
}
