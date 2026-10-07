// Looking up how much of the point light reaches a point, from the shadow maps -- shared by
// everything that receives shadows: the meshes (lit.slang) and the Gaussian splats
// (splat/receive-shadows.slang), so both are shadowed by exactly the same rules.
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

#include "scene-common.slang"

Texture2D<float> shadowMap;
uniform uint shadowFaceSize;
Texture2D<float4> splatShadowMap;
Texture2D<float4> splatShadowLayers;
uniform uint splatShadows; // 1: read the splat maps (the fusion example draws them)

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

// Fraction of the light reaching a point (0: in shadow, 1: lit), averaged over a 3x3 texel
// neighborhood for soft edges: blocked by the meshes, and dimmed by the splats in front of
// it. `d` is the point minus the light's position; `bias` how far the point counts as
// nearer to the light than it is, so that a surface doesn't shadow itself.
float shadowVisibility(float3 d, float bias)
{
    float current = length(d) - bias;
    uint face = cubeFaceOf(d);
    float2 texel = shadowFaceTexel(d, face, shadowFaceSize);
    int2 origin = int2(shadowFaceOrigin(face, shadowFaceSize));
    int last = int(shadowFaceSize) - 1;

    float lit = 0;
    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            // Stay inside this face's cell: the next cell over is a different view.
            int3 p = int3(origin + clamp(int2(texel) + int2(x, y), int2(0, 0), int2(last, last)), 0);
            if (current <= shadowMap.Load(p)) // not behind a mesh
            {
                float transmittance = 1.0;
                if (splatShadows != 0)
                {
                    transmittance = exp(-splatOpticalDepth(splatShadowMap.Load(p), splatShadowLayers.Load(p), current));
                }
                lit += transmittance;
            }
        }
    }
    return lit / 9.0;
}
