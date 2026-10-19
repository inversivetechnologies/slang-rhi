// The GI's view of the frame (lib/scene/gi.lua): a G-buffer and a Hi-Z pyramid, from the
// merged depth of the meshes, the SDFs and the splats (post/ssao-common.slang).
//
//   gbufferMain  per pixel: its view-space normal (rebuilt from depth: on each axis, the
//                neighbor nearer in depth, so that edges don't bend it) and its view depth
//                -> gbuffer: xyz normal (facing the camera), w view depth (far: background)
//                and the albedo of what is nearest there, as the depth composite picks it
//                -> albedoOut (the meshes' from the albedo pass, the SDFs' from the
//                raymarcher; the splats': their albedo's luminance, from their blended
//                depth, in the hue of their image)
//   hizFirstMain the pyramid's first level: the view depth, at half resolution, the
//                nearest of each 2 x 2
//   hizDownMain  each next level: the nearest of the 2 x 2 below
//
// The pyramid's levels are separate textures (hiz0 at half resolution, hiz1 at a quarter,
// ...), each holding the nearest view depth over its texel's footprint: a ray that is
// nearer than that over a stretch can't hit anything there.

#include "post/ssao-common.slang"

uniform float2 viewportSize; // provided by the host: the dispatch's texture's size

Texture2D<float4> meshAlbedo;
Texture2D<float4> sdfAlbedo;
Texture2D<float4> sdfColor;        // a: 1 where an SDF is hit
Texture2D<float4> splatColor;      // display-space, premultiplied
Texture2D<float4> splatDepthBlend; // view depth x a, albedo luminance x a, 0, a

float3 albedoAt(int2 p)
{
    int3 t = int3(p, 0);
    float meshZ = viewDistance(meshDepth.Load(t));
    float sdfZ = viewDistance(sdfDepth.Load(t));
    float splatZ = viewDistance(splatDepth.Load(t));
    bool sdfInFront = sdfColor.Load(t).a > 0 && sdfZ < meshZ;
    float3 albedo = sdfInFront ? sdfAlbedo.Load(t).rgb : meshAlbedo.Load(t).rgb;
    float opaqueZ = sdfInFront ? sdfZ : meshZ;
    if (splatZ <= opaqueZ)
    {
        float4 b = splatDepthBlend.Load(t);
        float4 c = splatColor.Load(t);
        float luminance = b.a > 1e-3 ? b.g / b.a : 0.0;
        float3 hue = c.a > 1e-3 ? pow(max(c.rgb / c.a, 0.0), 2.2) : float3(1, 1, 1);
        float hueLuminance = max(dot(hue, float3(0.2126, 0.7152, 0.0722)), 1e-3);
        albedo = saturate(hue * (luminance / hueLuminance));
    }
    return albedo;
}

float3 viewNormalAt(int2 p, float z, uint2 size, float aspect)
{
    float2 texel = 1.0 / float2(size);
    float2 uv = (float2(p) + 0.5) * texel;
    float3 position = viewPosition(camera, uv, z, aspect);
    float zl = sceneZ(p - int2(1, 0), size), zr = sceneZ(p + int2(1, 0), size);
    float zu = sceneZ(p - int2(0, 1), size), zd = sceneZ(p + int2(0, 1), size);
    float3 dx = abs(zr - z) < abs(zl - z)
        ? viewPosition(camera, uv + float2(texel.x, 0), zr, aspect) - position
        : position - viewPosition(camera, uv - float2(texel.x, 0), zl, aspect);
    float3 dy = abs(zd - z) < abs(zu - z)
        ? viewPosition(camera, uv + float2(0, texel.y), zd, aspect) - position
        : position - viewPosition(camera, uv - float2(0, texel.y), zu, aspect);
    float3 n = normalize(cross(dx, dy));
    return dot(n, position) > 0 ? -n : n;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void gbufferMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> gbuffer, uniform RWTexture2D<float4> albedoOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    float z = sceneZ(int2(tid.xy), size);
    bool background = isBackground(z);
    float3 n = background ? float3(0, 0, -1) : viewNormalAt(int2(tid.xy), z, size, aspect);
    gbuffer[tid.xy] = float4(n, z);
    albedoOut[tid.xy] = float4(background ? float3(0, 0, 0) : albedoAt(int2(tid.xy)), 1);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void hizFirstMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float4> gbufferIn, uniform RWTexture2D<float> hizOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint w, h;
    gbufferIn.GetDimensions(w, h);
    int2 base = int2(tid.xy) * 2;
    float z = 1e9;
    for (int k = 0; k < 4; ++k)
    {
        int2 p = min(base + int2(k & 1, k >> 1), int2(w, h) - 1);
        z = min(z, gbufferIn.Load(int3(p, 0)).w);
    }
    hizOut[tid.xy] = z;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void hizDownMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float> hizIn, uniform RWTexture2D<float> hizOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint w, h;
    hizIn.GetDimensions(w, h);
    int2 base = int2(tid.xy) * 2;
    float z = 1e9;
    for (int k = 0; k < 4; ++k)
    {
        int2 p = min(base + int2(k & 1, k >> 1), int2(w, h) - 1);
        z = min(z, hizIn.Load(int3(p, 0)));
    }
    hizOut[tid.xy] = z;
}
