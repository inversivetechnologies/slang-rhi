// Raymarching an SDF composition two ways, to compare them: evaluating its DAG
// (sdf-dag.slang) at every step, or sampling its baked cache (sdf-cache.slang). One thread
// per pixel; everything else is the same, so the difference in frame time is the
// difference between the two.
//
// The scene: the composition at the origin, on a floor, under a sun with soft shadows and
// a little ambient occlusion -- the shadows and the occlusion march the field too, as a
// real renderer would, so a pixel evaluates it a few dozen to a couple hundred times.
//
// sdfSource:
//   0  the DAG
//   1  the cache
//   2  the cache's error: marched with the DAG; where it hits, how far the cached distance
//      is from zero there: blue 0, green an eighth of a voxel, red a quarter or more

#include "sdf-dag.slang"
#include "sdf-cache.slang"

struct CompareCamera
{
    float3 eye;
    float fovY;
    float3 target;
};

uniform CompareCamera camera;
uniform float2 viewportSize; // provided by the host
uniform uint sdfSource;
uniform float3 sunDirection; // toward the sun
uniform float floorHeight;
RWTexture2D<float4> image;   // linear color, tone mapped

static const int kMaxSteps = 160;
static const float kMaxDistance = 40.0;

// The composition's distance at p, from the source in use. The cache is a cube around the
// composition; the DAG gets the same cube as a bounding volume, so that both start and
// stop marching in the same places.
float field(float3 p, uint source)
{
    if (source == 1)
    {
        return sampleSdfCache(p);
    }
    float3 q = abs(p) - sdfCacheExtent;
    float d = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    // Far from the cube: no need to evaluate what's inside.
    if (d <= 0.05)
    {
        d = evaluateSdf(p).distance;
    }
    return d;
}

float stepScale(uint source)
{
    return source == 1 ? kSdfCacheStep : 1.0;
}

float3 fieldColor(float3 p, uint source)
{
    return source == 1 ? sampleSdfCacheColor(p) : evaluateSdf(p).color;
}

float3 fieldNormal(float3 p, uint source)
{
    // Four samples at the corners of a tetrahedron; the cache's at half a voxel, finer
    // than which it holds nothing.
    float e = source == 1 ? 0.5 * sdfCacheVoxelSize() : 0.0015;
    const float2 k = float2(1, -1);
    return normalize(
        k.xyy * field(p + k.xyy * e, source) + k.yyx * field(p + k.yyx * e, source) +
        k.yxy * field(p + k.yxy * e, source) + k.xxx * field(p + k.xxx * e, source));
}

// The stretch of the ray inside the cache's cube: (enter, exit); misses have enter > exit.
float2 cubeInterval(float3 origin, float3 direction)
{
    float3 inverse = 1.0 / direction;
    float3 a = (-sdfCacheExtent - origin) * inverse;
    float3 b = (sdfCacheExtent - origin) * inverse;
    float3 near = min(a, b), far = max(a, b);
    return float2(max(near.x, max(near.y, near.z)), min(far.x, min(far.y, far.z)));
}

// Sphere tracing within [start, end]; the distance travelled at the hit, or -1.
float march(float3 origin, float3 direction, float start, float end, uint source)
{
    float t = start;
    float scale = stepScale(source);
    [loop]
    for (int i = 0; i < kMaxSteps && t < end; ++i)
    {
        float d = field(origin + direction * t, source);
        if (d < 0.0005 * t + 0.0002)
        {
            return t;
        }
        t += d * scale;
    }
    return -1.0;
}

// Soft shadow toward the sun ("soft shadows" in Inigo Quilez's SDF articles).
float softShadow(float3 origin, uint source)
{
    float2 span = cubeInterval(origin, sunDirection);
    float t = max(span.x, 0.02);
    float end = min(span.y, 6.0);
    float lit = 1.0;
    [loop]
    for (int i = 0; i < 48 && t < end; ++i)
    {
        float d = field(origin + sunDirection * t, source);
        if (d < 0.0005)
        {
            return 0.0;
        }
        lit = min(lit, 10.0 * d / t);
        t += clamp(d * stepScale(source), 0.01, 0.2);
    }
    return smoothstep(0.0, 1.0, lit);
}

// Ambient occlusion: how much of the field crowds in along the normal.
float occlusion(float3 p, float3 n, uint source)
{
    float blocked = 0.0;
    float weight = 1.0;
    [unroll]
    for (int i = 1; i <= 5; ++i)
    {
        float h = 0.03 * float(i);
        blocked += weight * max(h - field(p + n * h, source), 0.0);
        weight *= 0.7;
    }
    return saturate(1.0 - 4.0 * blocked);
}

float3 sky(float3 direction)
{
    return lerp(float3(0.30, 0.33, 0.38), float3(0.08, 0.12, 0.22), saturate(direction.y * 1.5));
}

float3 shade(float3 p, float3 n, float3 albedo, uint source)
{
    float diffuse = saturate(dot(n, sunDirection));
    float shadow = diffuse > 0.0 ? softShadow(p + n * 0.004, source) : 0.0;
    float ambient = occlusion(p, n, source) * (0.5 + 0.5 * n.y);
    return albedo * (float3(1.0, 0.92, 0.8) * 2.2 * diffuse * shadow + float3(0.25, 0.3, 0.4) * ambient);
}

// Blue (0) to green (0.5) to red (1 and more).
float3 errorColor(float x)
{
    x = saturate(x);
    return x < 0.5 ? lerp(float3(0.1, 0.25, 1.0), float3(0.1, 0.9, 0.2), x * 2.0)
                   : lerp(float3(0.1, 0.9, 0.2), float3(1.0, 0.15, 0.1), x * 2.0 - 1.0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void compareMain(uint3 tid: SV_DispatchThreadID)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
    {
        return;
    }
    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float focal = 1.0 / tan(camera.fovY * 0.5);
    float2 ndc = float2((tid.x + 0.5) / viewportSize.x * 2 - 1, 1 - (tid.y + 0.5) / viewportSize.y * 2);
    float3 dir = normalize(forward * focal + right * ndc.x * viewportSize.x / viewportSize.y + up * ndc.y);
    // The error view marches the DAG, and only looks the cache up where it hits.
    uint source = sdfSource == 1 ? 1 : 0;

    // The floor, analytically; the composition, by marching its cube.
    float floorT = dir.y < -1e-4 ? (floorHeight - camera.eye.y) / dir.y : kMaxDistance;
    float2 span = cubeInterval(camera.eye, dir);
    float hitT = -1.0;
    if (span.x < span.y && span.y > 0.0)
    {
        hitT = march(camera.eye, dir, max(span.x, 0.0), min(span.y, floorT), source);
    }

    float3 color;
    if (hitT > 0.0)
    {
        float3 p = camera.eye + dir * hitT;
        if (sdfSource == 2)
        {
            float voxels = abs(sampleSdfCache(p)) / sdfCacheVoxelSize();
            voxels *= 4.0; // red from a quarter voxel off
            float3 n = fieldNormal(p, 0);
            color = errorColor(voxels) * (0.35 + 0.65 * saturate(dot(n, sunDirection) * 0.5 + 0.5));
        }
        else
        {
            float3 n = fieldNormal(p, source);
            color = shade(p, n, fieldColor(p, source), source);
        }
    }
    else if (floorT < kMaxDistance)
    {
        float3 p = camera.eye + dir * floorT;
        float2 cell = floor(p.xz * 2.0);
        float checker = fmod(abs(cell.x + cell.y), 2.0) < 1.0 ? 0.55 : 0.45;
        float fade = exp(-0.06 * floorT);
        color = lerp(sky(dir), shade(p, float3(0, 1, 0), float3(checker, checker, checker), source), fade);
    }
    else
    {
        color = sky(dir);
    }
    // Exposure: the sunlit parts go past 1.
    image[tid.xy] = float4(1.0 - exp(-color * 1.2), 1.0);
}
