#include "base-ops.slang"

float3 ColorSDF (float3 inner, float3 outer, float thickness, float d)
{
    float h = frac(d / thickness) < 0.5 ? 0.5 : 1.0;
    float3 c = d < 0.0f ? inner/h : outer*h;
    return c;
}

float3 ColorGradient(float2 p0, float2 p1, float3 c0, float3 c1, float2 p)
{
    float t = LineSegmentInv(p0, p1, p);
    return lerp(c0, c1, t);
}

float3 ColorGradient(float3 p0, float3 p1, float3 c0, float3 c1, float3 p)
{
    float t = LineSegmentInv(p0, p1, p);
    return lerp(c0, c1, t);
}
