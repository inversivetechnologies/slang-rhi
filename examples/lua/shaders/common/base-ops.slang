#ifndef BASE_OPS_SLANG
#define BASE_OPS_SLANG

const static float PI = 3.14159265359;
const static float PI2 = 6.28318530718;

float2 Project(float2 a, float2 b) {
    return (dot(a, b) / dot(b, b)) * b;
}

float3 Project(float3 a, float3 b) {
    return (dot(a, b) / dot(b, b)) * b;
}

float LineToLocal(float2 a, float2 b, float2 p)
{
    float2 ab = b - a;
    float t = dot(p - a, ab) / dot(ab, ab);
    return saturate(t);
}

float LineToLocal(float3 a, float3 b, float3 p)
{
    float3 ab = b - a;
    float t = dot(p - a, ab) / dot(ab, ab);
    return saturate(t);
}


float Angle(float2 a, float2 b) {
    return acos(dot(a, b) / (length(a) * length(b)));
}

float AngleNormalized(float2 a, float2 b) {
    return acos(dot(a, b));
}

float2 SquareSample(int n, int k)
{
    const float l = .5 / float(n);
    int kx = k % n;
    int ky = k / n;
    float x = float(kx) / float(n) + l;
    float y = float(ky) / float(n) + l;
    return float2(x, y);
}

float Radial(float2 p)
{
    return 1 - fract(atan2(p.x, p.y) / PI2 - .25);
}

float2 ToEuclid(float2 polar)
{
    return float2(cos(polar.x), sin(polar.x)) * polar.y;
}

float2 ToPolar(float2 euclid)
{
    float a = Radial(euclid);
    float r = length(euclid);
    return float2(a, r);
}


#endif // BASE_OPS_SLANG

