// The GI's world-space probes (DDGI: Majercik et al. 2019), the radiance cascades' final
// cascade: a grid of probes about the camera, each with an octahedral map of the light
// reaching it (radiance, kRadianceRes^2: the cascades' far field, per direction), of that
// light cosine-convolved (irradiance, kIrradianceRes^2: what a surface facing a direction
// receives), and of the distance to what its rays hit (visibility, kDepthRes^2: the mean
// and mean square, for a Chebyshev test of whether a point can see the probe).
//
// The grid is ddgiCounts probes, ddgiSpacing apart, its first at ddgiOrigin; it follows
// the camera a probe at a time. A probe's storage is chosen by its world cell modulo the
// counts, so its data stays with its place as the grid moves (ddgiProbeStamps says which
// cell a slot last held: one that changes starts over). Maps are tiles in atlases,
// kAtlasTilesAcross tiles a row, by storage index.

#pragma once

static const uint kIrradianceRes = 8;
static const uint kRadianceRes = 8;
static const uint kDepthRes = 16;
static const uint kAtlasTilesAcross = 64;

uniform float3 ddgiOrigin;
uniform float ddgiSpacing;
uniform int3 ddgiCounts;
uniform int3 ddgiBaseCell; // the world cell of the grid's first probe
Texture2D<float4> ddgiIrradiance; // rgb irradiance (a: unused)
Texture2D<float4> ddgiRadiance;   // rgb radiance
Texture2D<float4> ddgiDepth;      // xy: mean distance, mean square distance
SamplerState ddgiSampler;         // bilinear, clamped

// Octahedral encoding: a unit vector to [-1, 1]^2 and back.
float2 octEncode(float3 v)
{
    float3 a = abs(v);
    float2 p = v.xy / (a.x + a.y + a.z);
    if (v.z < 0)
        p = (1.0 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
    return p;
}

float3 octDecode(float2 p)
{
    float3 v = float3(p, 1.0 - abs(p.x) - abs(p.y));
    if (v.z < 0)
        v.xy = (1.0 - abs(v.yx)) * float2(v.x >= 0 ? 1 : -1, v.y >= 0 ? 1 : -1);
    return normalize(v);
}

int3 ddgiGridOf(int index)
{
    uint3 counts = uint3(ddgiCounts);
    uint i = uint(index);
    return int3(i % counts.x, (i / counts.x) % counts.y, i / (counts.x * counts.y));
}

int3 ddgiWorldCell(int3 grid)
{
    return ddgiBaseCell + grid;
}

float3 ddgiProbePosition(int3 grid)
{
    return ddgiOrigin + float3(grid) * ddgiSpacing;
}

// The storage slot of the probe at `grid`: its world cell modulo the counts.
int ddgiSlot(int3 grid)
{
    // Unsigned (fxc's integer division is slow), offset to be positive: cells within about
    // a thousand grids of the origin.
    uint3 counts = uint3(ddgiCounts);
    uint3 c = uint3(ddgiWorldCell(grid) + ddgiCounts * 1024) % counts;
    return int((c.z * counts.y + c.y) * counts.x + c.x);
}

// The texel of `dir` in slot's tile of an atlas with `res` texels a side (continuous).
float2 ddgiAtlasUv(int slot, float3 dir, uint res, float2 atlasSize)
{
    float2 tile = float2(uint(slot) % kAtlasTilesAcross, uint(slot) / kAtlasTilesAcross) * float(res);
    // Half a texel in from the tile's edges: no bleeding into the next tile.
    float2 inTile = clamp((octEncode(dir) * 0.5 + 0.5) * float(res), 0.5, float(res) - 0.5);
    return (tile + inTile) / atlasSize;
}

// The 8 probes around `p`, for a surface with normal `n`, weighted as DDGI weighs them
// (trilinear, a smooth backface term, and the Chebyshev visibility from the probe's depth
// map): their irradiance along n, or (`radiance`) their radiance from `dir`.
float3 ddgiGather(float3 p, float3 n, float3 dir, bool radiance)
{
    float3 local = (p - ddgiOrigin) / ddgiSpacing;
    int3 base = clamp(int3(floor(local)), int3(0, 0, 0), ddgiCounts - 2);
    float3 f = saturate(local - float3(base));
    uint w, h;
    ddgiIrradiance.GetDimensions(w, h);
    float2 irradianceSize = float2(w, h);
    ddgiDepth.GetDimensions(w, h);
    float2 depthSize = float2(w, h);
    float3 sum = float3(0, 0, 0);
    float weights = 0;
    [loop]
    for (int k = 0; k < 8; ++k)
    {
        int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
        int3 grid = base + o;
        float3 probe = ddgiProbePosition(grid);
        int slot = ddgiSlot(grid);
        float3 trilinear = lerp(1.0 - f, f, float3(o));
        float weight = trilinear.x * trilinear.y * trilinear.z;
        // A probe behind the surface counts less (but never not at all).
        float3 toProbe = probe - p;
        float distance = length(toProbe);
        float3 toProbeDir = toProbe / max(distance, 1e-4);
        float facing = (dot(toProbeDir, n) + 1.0) * 0.5;
        weight *= facing * facing + 0.2;
        // Chebyshev: can the probe see the point (pushed off the surface a little)?
        float3 fromProbe = (p + n * 0.1 * ddgiSpacing) - probe;
        float r = length(fromProbe);
        float2 moments = ddgiDepth.SampleLevel(ddgiSampler, ddgiAtlasUv(slot, fromProbe / max(r, 1e-4), kDepthRes, depthSize), 0).xy;
        float variance = abs(moments.y - moments.x * moments.x);
        float chebyshev = 1.0;
        if (r > moments.x)
        {
            float d = r - moments.x;
            chebyshev = variance / (variance + d * d);
            chebyshev = max(chebyshev * chebyshev * chebyshev, 0.0);
        }
        weight *= max(0.05, chebyshev);
        weight = max(weight, 1e-6);
        float3 value = radiance
            ? ddgiRadiance.SampleLevel(ddgiSampler, ddgiAtlasUv(slot, dir, kRadianceRes, irradianceSize), 0).rgb
            : ddgiIrradiance.SampleLevel(ddgiSampler, ddgiAtlasUv(slot, n, kIrradianceRes, irradianceSize), 0).rgb;
        sum += value * weight;
        weights += weight;
    }
    return sum / weights;
}

// The irradiance a surface at p, normal n, receives from the far field.
float3 ddgiSampleIrradiance(float3 p, float3 n)
{
    return ddgiGather(p, n, n, false);
}

// The radiance arriving at p (on a surface with normal n) from direction dir.
float3 ddgiSampleRadiance(float3 p, float3 n, float3 dir)
{
    return ddgiGather(p, n, dir, true);
}
