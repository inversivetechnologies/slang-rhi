// Puts a view's SSAO and SSGI (post/ssao.slang) on its merged image: the image darkened
// by the ambient visibility, plus the indirect light, into the window or the inset's
// texture.
//
// The ambient visibility comes from `aoEffects`' alpha, the indirect light from
// `giEffects`' color: the same texture, or two of different sizes (the "Mixed" quality:
// AO at full resolution, GI at half). A texture smaller than the image is filtered up by
// depth (a joint bilateral upsample): of its 4 nearest texels, those whose surface is at
// this pixel's depth count, so the effects don't bleed across silhouettes.
//
// A single triangle covers the viewport; no vertex buffer needed.

#include "ssao-common.slang"

Texture2D<float4> litColor; // the view's merged image, linear
Texture2D<float4> aoEffects;
Texture2D<float4> giEffects;
uniform float giStrength;
uniform uint outputEncodeGamma; // 1 if the destination doesn't do the sRGB encoding itself
uniform uint showMode;          // as the depth composite's: 0 everything; 5 the AO, 6 the GI,
                                // 7 the meshes' motion vectors
Texture2D<float4> meshMotion;   // scene/motion.slang: the previous world position minus the current

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

float4 upsample(Texture2D<float4> effects, int2 pixel, float z, uint2 size)
{
    uint w, h;
    effects.GetDimensions(w, h);
    float2 lowSize = float2(w, h);
    if (w == size.x && h == size.y)
        return effects.Load(int3(pixel, 0));

    float2 f = (float2(pixel) + 0.5) * lowSize / float2(size) - 0.5;
    int2 base = int2(floor(f));
    float2 frac2 = f - float2(base);
    float4 sum = float4(0, 0, 0, 0);
    float weights = 0;
    float4 nearest = float4(0, 0, 0, 1);
    float nearestGap = 1e30;
    for (int k = 0; k < 4; ++k)
    {
        int2 o = int2(k & 1, k >> 1);
        int2 t = clamp(base + o, int2(0, 0), int2(lowSize) - 1);
        float bilinear = (o.x == 1 ? frac2.x : 1 - frac2.x) * (o.y == 1 ? frac2.y : 1 - frac2.y);
        float tz = sceneZ(toFull(uint2(t), lowSize, size), size);
        float gap = abs(tz - z) / z;
        float4 value = effects.Load(int3(t, 0));
        float weight = (bilinear + 1e-3) / (1e-3 + gap * 50.0);
        sum += value * weight;
        weights += weight;
        if (gap < nearestGap)
        {
            nearestGap = gap;
            nearest = value;
        }
    }
    // None at this depth (a thin edge): the nearest in depth, rather than a blend.
    return nearestGap > 0.1 ? nearest : sum / weights;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    int2 pixel = int2(input.position.xy);
    float3 lit = litColor.Load(int3(pixel, 0)).rgb;
    uint2 size = fullSize();
    float z = sceneZ(pixel, size);
    float visibility = 1.0;
    float3 indirect = float3(0, 0, 0);
    if (!isBackground(z))
    {
        visibility = upsample(aoEffects, pixel, z, size).a;
        indirect = upsample(giEffects, pixel, z, size).rgb * giStrength;
    }

    float3 color;
    if (showMode == 0)
        color = lit * visibility + indirect;
    else if (showMode == 5)
        color = visibility.xxx;
    else if (showMode == 6)
        color = indirect;
    else if (showMode == 7)
        color = abs(meshMotion.Load(int3(pixel, 0)).xyz) * 30.0; // a body moving 1 cm a frame: 0.3
    else
        color = lit; // the composite's own views of the parts
    if (outputEncodeGamma != 0)
        color = pow(max(color, 0.0), 1.0 / 2.2);
    return float4(color, 1.0);
}
