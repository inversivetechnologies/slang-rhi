#ifndef BASE_OPS_SLANG
#define BASE_OPS_SLANG

const static float PI = 3.14159265359;
const static float PI2 = 6.28318530718;

float2 Project(float2 a, float2 b) {
    return (dot(a, b) / dot(b, b)) * b;
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

#endif // BASE_OPS_SLANG

