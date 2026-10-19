// 2D user interface: rounded rectangles and text, drawn over the window in one pass
// (lib/ui.lua builds the lists). A single triangle covers the viewport; every pixel
// composites the rectangles, then the text, in order, and the pass blends the result over
// what is there (the pipeline's blend is "alpha").
//
// Text is monospaced, from the bitmap font in font.slang (16 x 32 cells), smoothed by
// filtering its bits bilinearly; `scale` is screen pixels per font pixel.

#include "font.slang"

static const uint kMaxRects = 32;
static const uint kMaxTexts = 32;

struct UiRect
{
    float4 rect;  // x, y (top left), width, height: pixels
    float4 color; // display-space rgb, alpha
    float4 style; // x: corner radius (pixels), y: border width (0: filled), zw: unused
};

struct UiText
{
    float4 place; // x, y (the top left of the first cell), scale, unused
    float4 color;
    uint start;   // its characters: chars[start .. start + length)
    uint length;
};

uniform UiRect rects[kMaxRects];
uniform uint rectCount;
uniform UiText texts[kMaxTexts];
uniform uint textCount;
uniform uint4 chars[64]; // 1024 characters, 4 bytes to a uint, 16 to a uint4
uniform uint decodeGamma; // 1: the window encodes sRGB itself, so linearize the colors

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

uint character(uint i)
{
    uint4 group = chars[i / 16];
    uint word = group[(i / 4) % 4];
    return (word >> (8 * (i % 4))) & 0xFF;
}

// One bit of glyph `c` at texel `t` (0 outside its cell).
float fontBit(uint c, int2 t)
{
    if (c < kFontFirst || c > kFontLast || any(t < 0) || t.x >= int(kFontCell.x) || t.y >= int(kFontCell.y))
        return 0.0;
    uint word = kFontRows[(c - kFontFirst) * (kFontCell.y / 2) + uint(t.y) / 2];
    return float((word >> ((uint(t.y) & 1) * 16 + uint(t.x))) & 1);
}

// Coverage of glyph `c` at `p` (font pixels from its cell's top left), filtered.
float glyph(uint c, float2 p)
{
    float2 q = p - 0.5;
    int2 t = int2(floor(q));
    float2 f = q - float2(t);
    float a = lerp(fontBit(c, t), fontBit(c, t + int2(1, 0)), f.x);
    float b = lerp(fontBit(c, t + int2(0, 1)), fontBit(c, t + int2(1, 1)), f.x);
    return smoothstep(0.25, 0.75, lerp(a, b, f.y));
}

// Signed distance to a rounded rectangle (negative inside).
float roundedBox(float2 p, float4 rect, float radius)
{
    float2 halfSize = rect.zw * 0.5;
    float2 d = abs(p - (rect.xy + halfSize)) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// `over` compositing, premultiplied.
void blendOver(inout float4 dst, float3 color, float alpha)
{
    dst.rgb = color * alpha + dst.rgb * (1.0 - alpha);
    dst.a = alpha + dst.a * (1.0 - alpha);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float2 p = input.position.xy;
    float4 result = float4(0, 0, 0, 0);

    for (uint i = 0; i < min(rectCount, kMaxRects); ++i)
    {
        UiRect r = rects[i];
        float d = roundedBox(p, r.rect, min(r.style.x, 0.5 * min(r.rect.z, r.rect.w)));
        if (r.style.y > 0.0)
            d = abs(d + 0.5 * r.style.y) - 0.5 * r.style.y; // just the border
        float coverage = saturate(0.5 - d);
        if (coverage > 0.0)
            blendOver(result, r.color.rgb, r.color.a * coverage);
    }

    for (uint i = 0; i < min(textCount, kMaxTexts); ++i)
    {
        UiText t = texts[i];
        float scale = t.place.z;
        float2 local = (p - t.place.xy) / scale;
        if (local.y < -1.0 || local.y > float(kFontCell.y) + 1.0 || local.x < -1.0)
            continue;
        int index = int(floor(local.x / float(kFontCell.x)));
        float coverage = 0.0;
        // This cell's glyph, and its neighbors' (filtering reaches a pixel across).
        for (int k = index - 1; k <= index + 1; ++k)
        {
            if (k < 0 || k >= int(t.length))
                continue;
            float2 g = local - float2(float(k) * float(kFontCell.x), 0.0);
            coverage = max(coverage, glyph(character(t.start + uint(k)), g));
        }
        if (coverage > 0.0)
            blendOver(result, t.color.rgb, t.color.a * coverage);
    }

    if (result.a <= 0.0)
        discard;
    float3 color = result.rgb / result.a;
    if (decodeGamma != 0)
        color = pow(max(color, 0.0), 2.2);
    return float4(color, result.a);
}
