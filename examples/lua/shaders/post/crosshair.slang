// Crosshair: a ring with four ticks and a dot, alpha-blended over the window's center. The
// player draws it in aim mode (scripts/lib/player.lua).
//
// A single triangle covers the viewport; no vertex buffer needed.

uniform float2 viewportSize; // provided by the host
uniform float4 crosshairColor;
uniform float4 crosshairHotColor; // when the aim ray hits something that can move
uniform float crosshairHot;       // 0 or 1
uniform float crosshairSpread;    // pixels added to the ring's radius (after firing)

struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv : UV;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    VertexOutput output;
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    output.uv = uv;
    return output;
}

// Coverage of a band of half-width `halfWidth` around distance 0, antialiased over a pixel.
float band(float distance, float halfWidth)
{
    return saturate(halfWidth + 0.5 - abs(distance));
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float2 p = input.uv * viewportSize - viewportSize * 0.5;
    float scale = max(viewportSize.y / 720.0, 0.75);
    p /= scale;
    float r = length(p);
    float radius = 11.0 + crosshairSpread;

    float alpha = 0.0;
    // The ring.
    alpha = max(alpha, band(r - radius, 0.9) * 0.85);
    // The center dot.
    alpha = max(alpha, saturate(2.2 - r));
    // Four ticks outside the ring, along the axes.
    float2 a = abs(p);
    float along = max(a.x, a.y);
    float across = min(a.x, a.y);
    if (along > radius + 4.0 && along < radius + 11.0)
    {
        alpha = max(alpha, band(across, 0.9));
    }
    if (alpha <= 0.0)
    {
        discard;
    }
    float4 color = lerp(crosshairColor, crosshairHotColor, crosshairHot);
    return float4(color.rgb, color.a * alpha);
}
