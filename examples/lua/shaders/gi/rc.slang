// Screen-space radiance cascades (Sannikov's radiance cascades, on the G-buffer's
// surfaces), the GI's near field; the world-space probes (ddgi.slang) are its far field.
//
// Cascade i has a probe every rcSpacing0 x 2^i pixels, on the surface at its cell's middle
// pixel (pushed off along the normal), and rcDirections0 x 2^i directions a side over its
// hemisphere (hemispherical octahedral, in the normal's frame): an atlas of probes x
// directions^2 texels, the same size for every cascade. A texel's ray covers the
// cascade's interval of distances, [rcInterval(i), rcInterval(i + 1)): 4 x longer each
// cascade.
//
//   cascadeMain   one thread per texel of cascade rcCascade, coarsest first. Its interval
//                 is marched on the screen (the Hi-Z pyramid skipping what the ray is in
//                 front of; a hit is a depth within the thickness: its radiance the lit
//                 image's there); where the screen can't say -- off it, or behind a surface
//                 by more than the thickness -- the global SDF takes over (global-sdf.slang;
//                 a hit shaded by the key light and the probes' irradiance).
//                 Merged (rcMerge) with the cascade above, coarse to fine: for each of the
//                 4 probes above around this one (bilinear), the ray is traced from this
//                 probe's interval start to *that* probe's (the bilinear fix: no gaps or
//                 overlaps between the intervals of different probes), and continued with
//                 that probe's radiance (its 2 x 2 finer directions about this one); the 4
//                 weighted bilinearly, by depth (plane distance) and normal, and by whether
//                 the direction is in that probe's hemisphere. The last cascade continues
//                 with the probes' radiance (the far field).
//                 -> rgb radiance, a transmittance: its own interval's (cascade 0: times
//                 cascade 1's, merged as the radiance is -- the near field's, for the AO)
//   integrateMain one thread per probe of cascade 0: its directions cosine-weighted ->
//                 rgb irradiance, a the ambient visibility (the near cascades' transmittance)
//
// No history: every frame's cascades are their own.

#include "scene/shadow-lookup.slang"
#include "post/ssao-common.slang"
#include "global-sdf.slang"
#include "ddgi.slang"

static const float kThickness = 0.35;  // a depth this far behind the screen's still counts as a hit

uniform uint rcCascade;
uniform uint rcCascadeCount;
uniform uint rcSpacing0;       // cascade 0's probe spacing, pixels
uniform uint rcDirections0;    // cascade 0's directions a side
uniform float rcInterval0;     // cascade 0's interval length, world units
uniform uint rcMerge;          // 0: each cascade its own interval alone (debug)
uniform float2 viewportSize;   // provided by the host: the dispatch's texture's (the atlas's)

Texture2D<float4> gbuffer;     // view normal, view depth
Texture2D<float> hiz0;
Texture2D<float> hiz1;
Texture2D<float> hiz2;
Texture2D<float> hiz3;
Texture2D<float> hiz4;
Texture2D<float4> litImage;    // the view's lit image (linear)
Texture2D<float4> cascadeAbove; // cascade rcCascade + 1, merged

// ---------------------------------------------------------------------------------------
// Directions

// Hemispherical octahedral: the upper half of the octahedron onto the square [-1, 1]^2.
float2 hemiOctEncode(float3 v)
{
    float2 p = v.xy / (abs(v.x) + abs(v.y) + max(v.z, 0.0));
    return float2(p.x + p.y, p.x - p.y);
}

float3 hemiOctDecode(float2 e)
{
    float2 p = float2(e.x + e.y, e.x - e.y) * 0.5;
    return normalize(float3(p, 1.0 - abs(p.x) - abs(p.y)));
}

// An orthonormal frame about n (Duff et al. 2017): continuous, and the same for the same n.
float3x3 frameOf(float3 n)
{
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float b = n.x * n.y * a;
    float3 t = float3(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
    float3 bt = float3(b, s + n.y * n.y * a, -n.y);
    return float3x3(t, bt, n);
}

float3 toWorldDir(float3x3 f, float3 local)
{
    return f[0] * local.x + f[1] * local.y + f[2] * local.z;
}

float3 toLocalDir(float3x3 f, float3 world)
{
    return float3(dot(world, f[0]), dot(world, f[1]), dot(world, f[2]));
}

// A view-space direction into the world.
float3 toWorldDirection(float3 v)
{
    float3x3 b = cameraBasis(camera);
    return b[0] * v.x + b[1] * v.y + b[2] * v.z;
}

uint cascadeSpacing(uint i) { return rcSpacing0 << i; }
uint cascadeDirections(uint i) { return rcDirections0 << i; }
float rcInterval(uint i) { return i == 0 ? 0.0 : rcInterval0 * (pow(4.0, float(i)) - 1.0) / 3.0; }

// ---------------------------------------------------------------------------------------
// Probes

struct Probe
{
    bool valid;
    float3 position; // view space, off the surface
    float3 normal;   // view space
    float depth;
};

// Probe `cell` of cascade i (cells of cascadeSpacing(i) pixels).
// The probes of each cascade (probesMain): per cell, the view depth and normal (octahedral)
// about its middle pixel, averaged over the cell, and whether there is a surface. The mean, not the middle
// pixel's: a pixel's normal (rebuilt from depth) is rough -- on the splats above all -- and
// as the camera moves a probe lands on another pixel; the cell's mean moves smoothly.
Texture2D<float4> probes0;
Texture2D<float4> probes1;
Texture2D<float4> probes2;
Texture2D<float4> probes3;

float2 octEncodeNormal(float3 v)
{
    float3 a = abs(v);
    float2 p = v.xy / (a.x + a.y + a.z);
    if (v.z < 0)
        p = (1.0 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
    return p;
}

float3 octDecodeNormal(float2 p)
{
    float3 v = float3(p, 1.0 - abs(p.x) - abs(p.y));
    if (v.z < 0)
        v.xy = (1.0 - abs(v.yx)) * float2(v.x >= 0 ? 1 : -1, v.y >= 0 ? 1 : -1);
    return normalize(v);
}

float4 probeData(uint i, int2 cell)
{
    float4 d;
    uint w, h;
    switch (i)
    {
    case 0: probes0.GetDimensions(w, h); d = probes0.Load(int3(clamp(cell, int2(0, 0), int2(w, h) - 1), 0)); break;
    case 1: probes1.GetDimensions(w, h); d = probes1.Load(int3(clamp(cell, int2(0, 0), int2(w, h) - 1), 0)); break;
    case 2: probes2.GetDimensions(w, h); d = probes2.Load(int3(clamp(cell, int2(0, 0), int2(w, h) - 1), 0)); break;
    default: probes3.GetDimensions(w, h); d = probes3.Load(int3(clamp(cell, int2(0, 0), int2(w, h) - 1), 0)); break;
    }
    return d;
}

int2 probePixel(uint i, int2 cell)
{
    uint2 size = fullSize();
    return clamp(cell * int(cascadeSpacing(i)) + int(cascadeSpacing(i) / 2), int2(0, 0), int2(size) - 1);
}

Probe probeAt(uint i, int2 cell)
{
    Probe probe;
    float4 d = probeData(i, cell);
    probe.valid = d.w > 0.5;
    probe.depth = d.x;
    probe.normal = octDecodeNormal(d.yz);
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    float3 surface = viewPosition(camera, (float2(probePixel(i, cell)) + 0.5) / float2(size), d.x, aspect);
    probe.position = surface + probe.normal * (0.02 + 0.004 * d.x);
    return probe;
}

// Cascade rcCascade's probes: per cell, the middle pixel's depth and the cell's mean
// normal, weighted to the pixels at about that depth (not what is behind or in front of
// it); 8 x 8 samples over the cell at most.
[shader("compute")]
[numthreads(8, 8, 1)]
void probesMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> probesOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint i = rcCascade;
    int2 cell = int2(tid.xy);
    uint2 size = fullSize();
    int2 center = probePixel(i, cell);
    float4 g = gbuffer.Load(int3(center, 0));
    float4 result = float4(g.w, 0, 0, 0);
    if (!isBackground(g.w))
    {
        int spacing = int(cascadeSpacing(i));
        int samples = min(spacing, 8);
        float stride = float(spacing) / float(samples);
        int2 corner = cell * spacing;
        float3 sum = float3(0, 0, 0);
        float depthSum = 0, weights = 0;
        [loop]
        for (int y = 0; y < samples; ++y)
        {
            [loop]
            for (int x = 0; x < samples; ++x)
            {
                int2 p = clamp(corner + int2((float2(x, y) + 0.5) * stride), int2(0, 0), int2(size) - 1);
                float4 s = gbuffer.Load(int3(p, 0));
                float w = isBackground(s.w) ? 0.0 : exp(-abs(s.w - g.w) / (0.03 * g.w + 0.01));
                sum += s.xyz * w;
                depthSum += s.w * w;
                weights += w;
            }
        }
        float3 n = dot(sum, sum) > 1e-8 ? normalize(sum) : g.xyz;
        // The depth too: the mean about the middle pixel's.
        float depth = weights > 1e-6 ? depthSum / weights : g.w;
        result = float4(depth, octEncodeNormal(n), 1.0);
    }
    probesOut[tid.xy] = result;
}

// ---------------------------------------------------------------------------------------
// Tracing a segment

float hizAt(uint level, float2 uv)
{
    uint w, h;
    float z;
    switch (level)
    {
    case 0: hiz0.GetDimensions(w, h); z = hiz0.Load(int3(int2(uv * float2(w, h)), 0)); break;
    case 1: hiz1.GetDimensions(w, h); z = hiz1.Load(int3(int2(uv * float2(w, h)), 0)); break;
    case 2: hiz2.GetDimensions(w, h); z = hiz2.Load(int3(int2(uv * float2(w, h)), 0)); break;
    case 3: hiz3.GetDimensions(w, h); z = hiz3.Load(int3(int2(uv * float2(w, h)), 0)); break;
    default: hiz4.GetDimensions(w, h); z = hiz4.Load(int3(int2(uv * float2(w, h)), 0)); break;
    }
    return z;
}

// The light leaving what the global SDF has at p (normal n), toward the ray: the key light
// (shadowed) and the probes' irradiance. (The point lights' direct light isn't here: the
// probes carry their bounce.)
float3 shadeSdfHit(float3 p, float3 n)
{
    float3 lightPos = lightPosition();
    float3 toLight = lightPos - p;
    float distanceToLight = length(toLight);
    toLight /= max(distanceToLight, 1e-4);
    float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
    float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);
    float diffuse = saturate(dot(n, toLight));
    // The shadow maps' (meshes', splats') only: the SDFs' soft shadow, a march of their
    // whole field, is too much for light bounced once.
    float shadow = 0.0;
    if (diffuse > 0)
    {
        float3 d = p + n * 0.05 - lightPos;
        uint face = cubeFaceOf(d);
        int3 at = int3(int2(shadowFaceOrigin(face, shadowFaceSize)) + int2(shadowFaceTexel(d, face, shadowFaceSize)), 0);
        shadow = shadowTexelLight(at, length(d) - 0.05);
    }
    float3 direct = light.color * attenuation * diffuse * shadow;
    return gsdfAlbedo(p) * (direct + ddgiSampleIrradiance(p, n));
}

// The rest of a segment (world space, from `from` for `length` along `dir`) in the global
// SDF: radiance and transmittance.
float4 traceSdf(float3 from, float3 dir, float remaining)
{
    float t = 0.0;
    float4 result = float4(0, 0, 0, 1);
    bool hit = remaining > 0.0 && gsdfTrace(from, dir, remaining, t);
    if (hit)
    {
        float3 p = from + dir * t;
        float3 n = gsdfNormal(p);
        // Inside something (its back face): dark.
        result = dot(n, dir) > 0.0 ? float4(0, 0, 0, 0) : float4(shadeSdfHit(p, n), 0.0);
    }
    return result;
}

// A segment from `a` to `b` (view space): marched on the screen; where the screen can't
// say, continued in the global SDF. -> radiance, transmittance.
float4 traceSegment(float3 a, float3 b)
{
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    float3 delta = b - a;
    float segmentLength = max(sqrt(dot(delta, delta)), 1e-5);
    float3 dir = delta / segmentLength;

    // Steps: about one per 4 pixels the segment covers on screen, 4 to 24.
    float2 uvA = projectToUv(camera, float3(a.xy, max(a.z, depthNear)), aspect);
    float2 uvB = projectToUv(camera, float3(b.xy, max(b.z, depthNear)), aspect);
    float2 span = (uvB - uvA) * float2(size);
    float pixels = sqrt(dot(span, span));
    int steps = clamp(int(pixels / 4.0), 4, 24);
    float stepLength = segmentLength / float(steps);
    // The Hi-Z level whose texels are about a step across.
    uint level = uint(clamp(log2(max(pixels / float(steps), 1.0)), 0.0, 4.0));

    float t = 0.0;
    [loop]
    for (int s = 0; s < steps; ++s)
    {
        t += stepLength;
        float3 p = a + dir * min(t, segmentLength);
        float2 uv = projectToUv(camera, p, aspect);
        if (p.z <= depthNear || any(uv < 0.0) || any(uv > 1.0))
        {
            // Off the screen: the global SDF from the last point the screen vouched for.
            float back = t - stepLength;
            return traceSdf(viewToWorld(camera, a + dir * back), toWorldDirection(dir), segmentLength - back);
        }
        // In front of everything over this step's footprint: nothing to hit here.
        if (p.z < hizAt(level, uv))
            continue;
        float sceneDepth = gbuffer.Load(int3(int2(uv * float2(size)), 0)).w;
        float behind = p.z - sceneDepth;
        // A hit is behind the surface by more than its roughness (a depth-relative margin:
        // the splats' blended depth has bumps a pixel wide, which rays from just above it
        // would otherwise hit, and hit differently as the probes slide with the camera).
        if (behind > 0.004 + 0.004 * p.z)
        {
            if (behind < kThickness)
            {
                float3 radiance = litImage.Load(int3(int2(uv * float2(size)), 0)).rgb;
                return float4(radiance, 0.0);
            }
            // Behind a surface by more than the thickness: the screen can't say what is
            // there. The global SDF, from the last point in front.
            float back = t - stepLength;
            return traceSdf(viewToWorld(camera, a + dir * back), toWorldDirection(dir), segmentLength - back);
        }
    }
    return float4(0, 0, 0, 1);
}

// ---------------------------------------------------------------------------------------
// The cascades

// Cascade-above's radiance for probe `cell`, direction `dir` (view space): the 2 x 2 finer
// texels about dir in that probe's map, averaged. w: 0 if dir is below its hemisphere.
// `transmittance`: their alpha, averaged (their own intervals').
float4 aboveRadiance(int2 cell, Probe probe, float3 dir, out float transmittance)
{
    transmittance = 1.0;
    uint i = rcCascade + 1;
    uint res = cascadeDirections(i);
    float3x3 f = frameOf(probe.normal);
    float3 local = toLocalDir(f, dir);
    if (local.z <= 0.02)
        return float4(0, 0, 0, 0);
    float2 e = (hemiOctEncode(local) * 0.5 + 0.5) * float(res) - 0.5;
    int2 t = clamp(int2(floor(e)), int2(0, 0), int2(res) - 2);
    uint w, h;
    cascadeAbove.GetDimensions(w, h);
    int2 origin = cell * int(res);
    float4 sum = float4(0, 0, 0, 0);
    for (int k = 0; k < 4; ++k)
    {
        int2 at = clamp(origin + t + int2(k & 1, k >> 1), int2(0, 0), int2(w, h) - 1);
        sum += cascadeAbove.Load(int3(at, 0));
    }
    transmittance = sum.a * 0.25;
    return float4(sum.rgb * 0.25, 1.0);
}

// The far field beyond the last cascade: the probes' radiance from `dir` (world).
float3 farRadiance(float3 viewPoint, float3 dirWorld)
{
    float3 p = viewToWorld(camera, viewPoint);
    return ddgiSampleRadiance(p, dirWorld, dirWorld);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cascadeMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> cascadeOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint i = rcCascade;
    uint res = cascadeDirections(i);
    int2 cell = int2(tid.xy / res);
    int2 texel = int2(tid.xy % res);
    Probe probe = probeAt(i, cell);
    float4 result = float4(0, 0, 0, 1);
    if (probe.valid)
    {
        float3x3 f = frameOf(probe.normal);
        float3 dir = toWorldDir(f, hemiOctDecode((float2(texel) + 0.5) / float(res) * 2.0 - 1.0));
        float a = rcInterval(i), b = rcInterval(i + 1);
        bool last = i + 1 >= rcCascadeCount;

        // The segments to trace: one per probe above (the bilinear fix: from this probe's
        // interval start to that one's), each with its weight and that probe's radiance to
        // continue with -- or, without probes above to merge with, this probe's own
        // interval, continued by the far field. (Gathered first and traced in one loop:
        // one call site keeps the shader small enough for fxc, D3D11's compiler.)
        float3 ends[4] = { float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0) };
        float weightsOf[4] = { 0, 0, 0, 0 };
        float3 continueWith[4] = { float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0) };
        float continueT[4] = { 0, 0, 0, 0 };
        int count = 0;
        if (rcMerge != 0 && !last)
        {
            // The 4 probes above, bilinearly about this one's pixel.
            uint upper = cascadeSpacing(i + 1);
            uint2 size = fullSize();
            int2 pixel = cell * int(cascadeSpacing(i)) + int(cascadeSpacing(i) / 2);
            float2 q = (float2(pixel) + 0.5) / float(upper) - 0.5;
            int2 baseCell = int2(floor(q));
            float2 fq = q - float2(baseCell);
            int2 upperCells = int2((size + upper - 1) / upper);
            [loop]
            for (int k = 0; k < 4; ++k)
            {
                int2 o = int2(k & 1, k >> 1);
                int2 c = clamp(baseCell + o, int2(0, 0), upperCells - 1);
                Probe up = probeAt(i + 1, c);
                if (!up.valid)
                    continue;
                float w = (o.x == 1 ? fq.x : 1 - fq.x) * (o.y == 1 ? fq.y : 1 - fq.y);
                // Depth- and normal-aware: the upper probe on this probe's plane, facing
                // its way.
                float plane = abs(dot(up.position - probe.position, probe.normal));
                w *= exp(-plane / (0.02 * probe.depth + 0.02));
                w *= saturate(dot(up.normal, probe.normal) * 2.0 - 0.6);
                float aboveT;
                float4 above = aboveRadiance(c, up, dir, aboveT);
                w *= above.a;
                if (w <= 1e-5)
                    continue;
                ends[count] = up.position + dir * b;
                weightsOf[count] = w;
                continueWith[count] = above.rgb;
                // Cascade 0 keeps its own transmittance times cascade 1's (the near field's,
                // for the AO); the others, their own.
                continueT[count] = i == 0 ? aboveT : 1.0;
                ++count;
            }
        }
        bool own = count == 0;
        if (own)
        {
            ends[0] = probe.position + dir * b;
            weightsOf[0] = 1.0;
            continueWith[0] = rcMerge != 0 ? farRadiance(probe.position + dir * b, toWorldDirection(dir)) : float3(0, 0, 0);
            continueT[0] = 1.0;
            count = 1;
        }

        // Cascade 0 starts a little off its surface (no hits on the surface's own roughness).
        float3 start = probe.position + dir * max(a, 0.01 + 0.004 * probe.depth);
        float3 sum = float3(0, 0, 0);
        float transmittance = 0, weights = 0;
        [loop]
        for (int k = 0; k < count; ++k)
        {
            float4 segment = traceSegment(start, ends[k]);
            sum += weightsOf[k] * (segment.rgb + segment.a * continueWith[k]);
            transmittance += weightsOf[k] * segment.a * continueT[k];
            weights += weightsOf[k];
        }
        result = float4(sum / weights, transmittance / weights);
    }
    cascadeOut[tid.xy] = result;
}

// Cascade 0's probes, integrated: irradiance (cosine-weighted radiance, as the probes'
// irradiance is) and the ambient visibility -- cascade 0's alpha: its transmittance times
// cascade 1's (the near field's, not the sky's).
Texture2D<float4> cascade0;

[shader("compute")]
[numthreads(8, 8, 1)]
void integrateMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> irradianceOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint res = cascadeDirections(0);
    int2 cell = int2(tid.xy);
    Probe probe = probeAt(0, cell);
    if (!probe.valid)
    {
        irradianceOut[tid.xy] = float4(0, 0, 0, 1);
        return;
    }
    float3x3 f = frameOf(probe.normal);
    float3 irradiance = float3(0, 0, 0);
    float visibility = 0, weights = 0;
    [loop]
    for (uint v = 0; v < res; ++v)
    {
        [loop]
        for (uint u = 0; u < res; ++u)
        {
            float3 local = hemiOctDecode((float2(u, v) + 0.5) / float(res) * 2.0 - 1.0);
            float c = local.z; // cos(theta); hemi-oct texels are near equal-area
            float4 r = cascade0.Load(int3(cell * int(res) + int2(u, v), 0));
            irradiance += r.rgb * c;
            visibility += r.a * c;
            weights += c;
        }
    }
    irradianceOut[tid.xy] = float4(irradiance / weights, visibility / weights);
}
