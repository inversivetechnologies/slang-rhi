// Puts a view's SSAO and SSGI (post/ssao.slang) on its merged image: the image darkened
// by the ambient visibility, plus the indirect light, into the window or the inset's
// texture. The effects are at half resolution, filtered up.
//
// A single triangle covers the viewport; no vertex buffer needed.

Texture2D<float4> litColor;  // the view's merged image, linear
Texture2D<float4> effects;   // rgb indirect light, a ambient visibility
SamplerState effectsSampler;
uniform float giStrength;
uniform uint outputEncodeGamma; // 1 if the destination doesn't do the sRGB encoding itself
uniform uint showMode;          // as the depth composite's: 0 everything; 5 the AO, 6 the GI
uniform float2 viewportSize;    // provided by the host

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

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float3 lit = litColor.Load(int3(int2(input.position.xy), 0)).rgb;
    float4 e = effects.SampleLevel(effectsSampler, input.position.xy / viewportSize, 0);
    float3 color;
    if (showMode == 0)
        color = lit * e.a + e.rgb * giStrength;
    else if (showMode == 5)
        color = e.aaa;
    else if (showMode == 6)
        color = e.rgb * giStrength;
    else
        color = lit; // the composite's own views of the parts
    if (outputEncodeGamma != 0)
        color = pow(max(color, 0.0), 1.0 / 2.2);
    return float4(color, 1.0);
}
