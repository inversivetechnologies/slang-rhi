#include "base-ops.slang"

float3 ColorSDF (float3 inner, float3 outer, float thickness, float d)
{
    float h = frac(d / thickness) < 0.5 ? 0.5 : 1.0;
    float3 c = d < 0.0f ? inner/h : outer*h;
    return c;
}

float3 ColorGradient(float2 p0, float2 p1, float3 c0, float3 c1, float2 p)
{
    float t = LineToLocal(p0, p1, p);
    return lerp(c0, c1, t);
}

float3 ColorGradient(float3 p0, float3 p1, float3 c0, float3 c1, float3 p)
{
    float t = LineToLocal(p0, p1, p);
    return lerp(c0, c1, t);
}

float3 Ramp<let N : int>(float3 colors[N], float t)
{
    if (N == 1)
        return colors[0];

    float x = saturate(t) * (N - 1);
    int i = min((int)floor(x), N - 2); // keep i+1 in range when t == 1
    return lerp(colors[i], colors[i + 1], x - i);
}

float3 ColorGradient<let N : int >(float2 p0, float2 p1, float3 c[N], float2 p)
{
    float t = LineToLocal(p0, p1, p);
    return Ramp<N>(c,t);
}

float3 ColorGradient<let N : int >(float3 p0, float3 p1, float3 c[N], float3 p)
{
    float t = LineToLocal(p0, p1, p);
    return Ramp<N>(c,t);
}

float3 ColorGradientSpherical(float2 p0, float r, float3 c0, float3 c1, float2 p){
    float t = distance(p0,p) / r;
    return lerp (t, c0, c1);
}

float3 ColorGradientSpherical(float3 p0, float r, float3 c0, float3 c1, float3 p){
    float t = distance(p0,p) / r;
    return lerp (t, c0, c1);
}

float3 ColorGradientSpherical<let N : int>(float2 p0, float r, float3 c[N], float2 p){
    float t = distance(p0,p) / r;
    return Ramp<N>(c,t);
}

float3 ColorGradientSpherical<let N : int>(float3 p0, float r, float3 c[N], float3 p){
    float t = distance(p0,p) / r;
    return Ramp<N>(c,t);
}
