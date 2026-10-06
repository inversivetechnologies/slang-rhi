// Composite pass: copies a texture into the viewport it is drawn with, framed by a border.
// The scene uses it to put the second camera's image in a corner of the window.
//
// A single triangle covers the viewport; no vertex buffer needed.

Texture2D<float4> source;
uniform float4 borderColor;
uniform float borderWidth;   // pixels
uniform float2 viewportSize; // provided by the host
uniform uint encodeGamma;    // 1 if the window doesn't do the sRGB encoding itself

struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv : UV; // 0..1 across the viewport, top left at 0
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    // (0,0), (2,0), (0,2): one triangle whose inner half covers the viewport.
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    VertexOutput output;
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    output.uv = uv;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float2 pixel = input.uv * viewportSize;
    if (pixel.x < borderWidth || pixel.y < borderWidth || pixel.x > viewportSize.x - borderWidth ||
        pixel.y > viewportSize.y - borderWidth)
    {
        return borderColor;
    }

    uint width, height;
    source.GetDimensions(width, height);
    int2 texel = clamp(int2(input.uv * float2(width, height)), int2(0, 0), int2(width - 1, height - 1));
    float3 color = source.Load(int3(texel, 0)).rgb;
    if (encodeGamma != 0)
    {
        color = pow(max(color, 0.0), 1.0 / 2.2);
    }
    return float4(color, 1.0);
}
