#include "shader-toy.slang"
#include "common/sdfs.slang"
#include "common/coloring.slang"


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
    float d0 = SDF(Square(), p - posSquare);
    float d1 = SDF(Polygon(k), p - posPolygon);
    float d2 = SDF(Circle(), p - posCircle);
    float d = min(d0,min(d1, d2));

    // Coloring
    float3 innerCol = float3(0.5,0.5,1);
    float3 outerCol = float3(1,0.6,0);          
    float3 c = ColorSDF(innerCol, outerCol , 0.15, d);
    return c;
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
