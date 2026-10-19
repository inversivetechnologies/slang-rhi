// Depth compositing: merges separately rendered images -- each with its own color and depth
// buffer -- into one, per pixel, by which is nearer the camera.
//
// The fusion example renders three kinds of surface in passes of their own:
//
//   the mesh scene          opaque, rasterized (scene/lit.slang)
//   the SDF composition     opaque, raymarched (sdf/raymarch.slang)
//   the Gaussian splats     blended, with premultiplied alpha (splat/render.slang)
//
// The two opaque ones first become one: whichever is nearer. Then the splats go over it
// where they are nearer, by their alpha, and are hidden behind it where it is.
//
// All depth buffers hold perspective depth (z/w) over the same near and far planes, so
// they are turned back into view distances to compare them.

Texture2D<float4> meshColor;  // linear color
Texture2D<float> meshDepth;
Texture2D<float4> splatColor; // display-space color, premultiplied alpha; 0 where no splat
Texture2D<float> splatDepth;
Texture2D<float4> sdfColor;   // linear color; alpha 0 where nothing was hit
Texture2D<float> sdfDepth;
uniform float depthNear;
uniform float depthFar;
uniform uint encodeGamma; // 1 if the window doesn't do the sRGB encoding itself
uniform uint showMode;    // 0: combined, 1: mesh only, 2: splats only, 3: SDFs only,
                          // 4: the depth buffers, 8: combined, tinted by the light tiles

// The view's light tiles (scene/light-culling.slang), for showMode 8.
#include "scene/light-tiles-layout.slang"
StructuredBuffer<uint> lightTiles;

// How many lights reach this pixel's tile: blue (none) to green, yellow, red (32 and more).
float3 lightTileTint(float2 pixel)
{
    uint tilesX = lightTiles[0], tilesY = lightTiles[1], tileSize = max(lightTiles[2], 1u);
    uint2 tile = uint2(pixel) / tileSize;
    if (tile.x >= tilesX || tile.y >= tilesY)
        return float3(0, 0, 0);
    float count = float(lightTiles[kTileHeader + (tile.y * tilesX + tile.x) * kTileStride]);
    float x = saturate(count / 32.0);
    float3 heat = x < 0.33 ? lerp(float3(0, 0, 1), float3(0, 1, 0), x / 0.33)
                : x < 0.66 ? lerp(float3(0, 1, 0), float3(1, 1, 0), (x - 0.33) / 0.33)
                           : lerp(float3(1, 1, 0), float3(1, 0, 0), (x - 0.66) / 0.34);
    // The tile's edges, so the grid shows.
    float2 inTile = fmod(pixel, float(tileSize));
    float edge = any(inTile < 1.0) ? 0.5 : 1.0;
    return (count > 0 ? heat : float3(0.05, 0.05, 0.1)) * edge;
}

struct VertexOutput
{
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    VertexOutput output;
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}

// A depth buffer value back to the distance along the view direction.
float viewDistance(float depth)
{
    return depthNear * depthFar / (depthFar - depth * (depthFar - depthNear));
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    int3 texel = int3(int2(input.position.xy), 0);
    float3 mesh = meshColor.Load(texel).rgb;
    float meshDistance = viewDistance(meshDepth.Load(texel));
    float splatDistance = viewDistance(splatDepth.Load(texel));
    float4 sdf = sdfColor.Load(texel);
    float sdfDistance = viewDistance(sdfDepth.Load(texel));

    // The opaque surfaces: the mesh, or the SDFs where they are nearer.
    bool sdfInFront = sdf.a > 0 && sdfDistance < meshDistance;
    float3 opaque = sdfInFront ? sdf.rgb : mesh;
    float opaqueDistance = sdfInFront ? sdfDistance : meshDistance;

    // The splats' color in linear space: undo the premultiplication to decode it.
    float4 splat = splatColor.Load(texel);
    float3 splatLinear = splat.a > 0 ? pow(max(splat.rgb / splat.a, 0.0), 2.2) * splat.a : float3(0, 0, 0);

    float3 color;
    if (showMode == 1)
    {
        color = mesh;
    }
    else if (showMode == 2)
    {
        color = splatLinear;
    }
    else if (showMode == 3)
    {
        color = sdf.rgb;
    }
    else if (showMode == 4)
    {
        // Nearer is brighter: the mesh's depth in blue, the SDFs' in green, the splats' in
        // orange -- whichever is nearest.
        color = float3(0.25, 0.55, 1.0) * saturate(1.0 - meshDistance / 12.0);
        if (sdfInFront)
        {
            color = float3(0.3, 1.0, 0.4) * saturate(1.0 - sdfDistance / 12.0);
        }
        if (splatDistance < opaqueDistance)
        {
            color = float3(1.0, 0.55, 0.15) * saturate(1.0 - splatDistance / 12.0);
        }
    }
    else
    {
        // Where no splat is opaque enough to be in the splats' depth buffer, its depth is
        // the far plane; faint fringes there still go over whatever is behind.
        color = splatDistance <= opaqueDistance ? splatLinear + (1.0 - splat.a) * opaque : opaque;
        if (showMode == 8)
            color = color * 0.35 + lightTileTint(input.position.xy) * 0.4;
    }

    if (encodeGamma != 0)
    {
        color = pow(max(color, 0.0), 1.0 / 2.2);
    }
    return float4(color, 1.0);
}
