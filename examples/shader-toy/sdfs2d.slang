#include "shader-toy.slang"

const static float PI = 3.14159265359;
const static float PI2 = 6.28318530718;

void mainImage(out float4 fragColor, in int2 fragCoord)
{
    float2 screenSize = iResolution.xy;
    int AA = 4;
    int m = AA * AA;
    float3 img = float3(0);
    for (int k = 0; k < m; k++)
    {
        float2 p0 = SquareSample(AA, k);
        float2 p = ((float2(fragCoord.xy) + p0) * 2.0f - float2(screenSize.xy)) / (float)screenSize.y;
        float3 c = Render(p);
        img += c;
    }
    img /= m;
    float4 image = float4(img, 1);
    fragColor = image;
}

float3 Render (float2 p)
{
    // Camera
    float zoom = 3;
    p *= zoom;

    // Polygon Parameters
    int minPoly = 3;
    int maxPoly = 12;
    float speed = 6;
    float t = float(iFrame)/(60.0 * speed);
    float t0 = cos(t*PI2)*.5+.5; 
    int k = int(minPoly * (1.0-t0) + (maxPoly+1 - 0.1)*t0);

    // SDFs & Transform
    float2 posSquare = float2(-3.5, 0);
    float2 posPolygon = float2(0, 0);
    float2 posCircle = float2(3.5, 0);
    float d0 = SDFSquare(p - posSquare);
    float d1 = SDFPolygon(k,p - posPolygon);
    float d2 = SDFCircle(p - posCircle);
    float d = min(d0,min(d1, d2));

    // Coloring
    float3 innerCol = float3(0.5,0.5,1);
    float3 outerCol = float3(1,0.6,0);          
    float3 c = ColorSDF(innerCol, outerCol , 0.15, d);
    return c;
}

float2 SquareSample (int n, int k)
{
    const float l = .5 / float(n);
    int kx = k % n;
    int ky = k / n;
    float x = float(kx) / float(n) + l;
    float y = float(ky) / float(n) + l;
    return float2(x,y);
}

float RenderSquarePoints (int n, float2 p)
{
    int m = n*n;
    float h = 0;
    float r = 0.05;
    for (int k = 0; k < m; k++)
    {
        float2 p0 = SquareSample (n,k);
        h = max(h, float(distance(p0,p) < r));
    }
    return h;
}


float Radial (float2 p)
{
    return 1-fract(atan2(p.x,p.y)/PI2-.25);
}

float3 ColorSDF (float3 inner, float3 outer, float thickness, float d)
{
    float h = clamp(round(frac(d/ thickness)), 0, 1);
    h = clamp(0, 1, h + .5);
    float3 c = d < 0.0f ? inner/h : outer*h;
    return c;
}

float2x2 Rotate(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return float2x2(c, -s, s, c);
}

float2 Project(float2 a, float2 b) {
    return (dot(a, b) / dot(b, b)) * b;
}

float Angle(float2 a, float2 b) {
    return acos(dot(a, b) / (length(a) * length(b)));
}

float AngleNormalized(float2 a, float2 b) {
    return acos(dot(a, b));
}

float StencilSquare (float2 p)
{
    float w = float(p.x > 0 && p.x < 1);
    float h = float(p.y > 0 && p.y < 1);
    return min(w,h);
}

float SDFCircle (float2 p)
{
    return length(p) - 1.0f;
}

float SDFSquare (float2 p)
{
    float dx = abs(p.x) - 1;
    float dy = abs(p.y) - 1;
    return max(dx, dy);
}

float SDFCube (float3 p)
{
    float dx = abs(p.x) - 1;
    float dy = abs(p.y) - 1;
    float dz = abs(p.z) - 1;
    return max(dx, max(dy, dz));
}

float SDFLine(float2 center, float2 normal, float2 p) 
{
    return dot(p - center, normal);
}

float SDFPlane(float3 center, float3 normal, float3 p) 
{
    return dot(p - center, normal);
}

float SDFCapsule(float2 p0, float2 p1, float2 p) {
    float2 pa = p - p0;
    float2 ba = p1 - p0;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

float SDFPolygon (int n, float2 p)
{
    n = max(3,n);
    float t = Radial(p);
    int k = int(t*float(n));
    float t0 = float(k) / float(n);
    float t1 = float((k+1)%n) / float(n);
    float2 p0 = float2(cos(t0*PI2),sin(t0*PI2));
    float2 p1 = float2(cos(t1*PI2),sin(t1*PI2));
    float2 v = p1-p0;
    float2 x = p0 + 0.5 * v;
    float2 n = normalize(mul(v,Rotate(PI*.5)));
    float d = SDFLine(x,n,p);
    return d;
}
