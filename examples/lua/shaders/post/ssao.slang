// Screen-space ambient occlusion (SSAO) and screen-space indirect light (SSGI), for a view
// whose surfaces were merged by depth (post/depth-composite.slang): the meshes', the SDFs'
// and the splats' depth buffers give the nearest surface in each pixel, and the composite's
// image (linear, before encoding) the light leaving it. Run at half or full resolution
// (whatever size the effects textures are: lib/scene/renderer.lua), in a chain:
//
//   effectsMain   per pixel, its position and normal (rebuilt from depth), and kSamples
//                 directions over the normal's hemisphere, cosine-weighted (a golden-
//                 angle spiral, turned per pixel by a 4 x 4 pattern, and per frame).
//                 AO, by one of two methods (aoMethod):
//                   SSAO: a point a short way along each direction, occluded where the
//                   depth buffer has something in front of it (counted less, the
//                   farther that is from the pixel's depth: no halos round foreground
//                   objects).
//                   GTAO (ground-truth AO, Jimenez et al. 2016): kSlices planes through
//                   the view direction, turned per pixel and frame; along each, both
//                   ways, the highest horizon the depth buffer has within aoRadius, and
//                   the visible arc between the two horizons integrated against the
//                   normal projected into the plane -- the cosine-weighted visibility,
//                   in closed form. Smoother than SSAO for its samples, and unbiased.
//                 GI: a point a longer way along it; where the depth buffer has a
//                 surface in front of that point (the direction is blocked) and that
//                 surface faces the pixel, its light, by the cosine at the pixel and a
//                 falloff with distance, is bounced onto the pixel.
//                 -> rgb the indirect light, a the ambient visibility (1: open)
//   blurMain      a 5 x 5 blur that keeps to similar depths: the pattern averaged out
//   temporalMain  blended with the frames before: each pixel's surface is found where it
//                 was the frame before (moved back by its own motion: the bodies' motion
//                 vectors, scene/motion.slang, or the SDF composition's spin; the splats
//                 stand still) and where the last frame's camera saw it there, and that
//                 frame's result there (if its depth agrees: nothing disoccluded or moved
//                 in front) taken 90 to 10
//                 (bounded by a fast history: see historyClip, fastHistoryWeight)
//   historyMain   the results and their depths kept for the next frame
//
// post/ssao-apply.slang puts them on the image: color x visibility + indirect light.

#include "ssao-common.slang"

static const int kSamples = 12;
static const int kSlices = 3;     // GTAO's planes a pixel
static const int kSliceSteps = 6; // and its samples each way along each
static const float kPi = 3.14159265;
static const float kHistoryWeight = 0.9; // of the frames before, where they agree

Texture2D<float4> litColor; // the view's merged image, linear

uniform uint aoEnabled;
uniform uint aoMethod;    // 0: SSAO, 1: GTAO
uniform float gtaoPower;  // GTAO's visibility, raised to this: how dark it gets
uniform uint giEnabled;
uniform float aoRadius;   // world units
uniform float aoStrength; // 1: fully occluded where every sample is
uniform float giRadius;   // world units
uniform uint frameIndex;  // turns the samples a little each frame

// The temporal pass's (the view's temporal block).
uniform EffectsCamera prevCamera; // the last frame's camera
uniform uint historyValid;        // 0: no frames before (just built, or resized)
// History clipping (Salvi 2016): the history is clamped to this many standard deviations
// about the mean of the current frame's 3 x 3 neighborhood, per channel; 0 turns it off.
// What stays where it was but changed -- the floor a box slid off, a wall a light moved
// away from -- passes reprojection and depth, and without it fades out over ~10 frames.
uniform float historyClip;
// The fast history's share of the frames before (0.5: about the last two or three); the
// history is clamped about it rather than about the neighborhood's mean. 0: no fast history.
uniform float fastHistoryWeight;

// What moved: the bodies, per pixel (the motion pass: the previous world position minus the
// current, where a body is the nearest mesh), and the SDF composition, turning about its
// origin by sdfSpin radians a second (its block; sdf/sdf-world.slang).
Texture2D<float4> meshMotion;
uniform float3 sdfOrigin;
uniform float sdfSpin;
uniform float timeDelta; // provided by the host: 0 while paused

uniform float2 viewportSize; // provided by the host: the effects textures' size

// Each entry point's own textures are its parameters (bound by name, as the globals are),
// so that none has another's to bind.

// The normal, from the neighbors' positions: on each axis the side whose depth is nearer
// the pixel's, so that edges don't bend it.
float3 viewNormal(int2 p, float3 position, uint2 size, float aspect)
{
    float2 texel = 1.0 / float2(size);
    float2 uv = (float2(p) + 0.5) * texel;
    float zl = sceneZ(p - int2(1, 0), size), zr = sceneZ(p + int2(1, 0), size);
    float zu = sceneZ(p - int2(0, 1), size), zd = sceneZ(p + int2(0, 1), size);
    float3 dx = abs(zr - position.z) < abs(zl - position.z)
        ? viewPosition(camera, uv + float2(texel.x, 0), zr, aspect) - position
        : position - viewPosition(camera, uv - float2(texel.x, 0), zl, aspect);
    float3 dy = abs(zd - position.z) < abs(zu - position.z)
        ? viewPosition(camera, uv + float2(0, texel.y), zd, aspect) - position
        : position - viewPosition(camera, uv - float2(0, texel.y), zu, aspect);
    float3 n = normalize(cross(dx, dy));
    return dot(n, position) > 0 ? -n : n; // facing the camera
}

// GTAO's visibility (1: open) at a pixel, from its view-space position and normal. `turn`
// and `jitter` in [0, 1) place its slices and their samples.
float gtaoVisibility(int2 p, float3 position, float3 normal, uint2 size, float aspect, float turn, float jitter)
{
    float3 toEye = normalize(-position);
    // aoRadius in pixels at this depth (not past a third of the view: near the camera, a
    // radius of world units covers the screen).
    float focal = 1.0 / tan(camera.fovY * 0.5);
    float radiusPixels = min(aoRadius * focal * 0.5 * float(size.y) / position.z, float(size.y) / 3.0);
    if (radiusPixels < 1.0)
        return 1.0;

    float visibility = 0;
    for (int slice = 0; slice < kSlices; ++slice)
    {
        float phi = (float(slice) + turn) * kPi / float(kSlices);
        float2 screenDirection = float2(cos(phi), sin(phi)); // pixels: x right, y down
        float3 direction = float3(screenDirection.x, -screenDirection.y, 0); // view: y up

        // The slice: the plane through the view direction and `direction`. The normal,
        // projected into it, and its angle from the view direction (n).
        float3 axis = normalize(cross(direction, toEye));
        float3 projected = normal - axis * dot(normal, axis);
        float projectedLength = length(projected);
        if (projectedLength < 1e-4)
        {
            visibility += 1.0;
            continue;
        }
        float3 ortho = direction - dot(direction, toEye) * toEye;
        float cosN = saturate(dot(projected, toEye) / projectedLength);
        float n = (dot(ortho, projected) < 0 ? -1.0 : 1.0) * acos(cosN);

        // The highest horizon each way, as a cosine from the view direction; the tangent
        // plane's at the least.
        float horizonCos[2];
        for (int side = 0; side < 2; ++side)
        {
            float way = side == 0 ? -1.0 : 1.0;
            float lowest = cos(n + way * kPi * 0.5);
            float best = lowest;
            for (int k = 0; k < kSliceSteps; ++k)
            {
                float t = (float(k) + jitter) / float(kSliceSteps);
                t = t * t; // more samples near the pixel
                int2 q = p + int2(round(screenDirection * way * max(t * radiusPixels, 1.0 + float(k))));
                if (any(q < 0) || q.x >= int(size.x) || q.y >= int(size.y))
                    break;
                float qz = sceneZ(q, size);
                float3 d = viewPosition(camera, (float2(q) + 0.5) / float2(size), qz, aspect) - position;
                float distanceSquared = dot(d, d);
                float c = dot(d, toEye) * rsqrt(max(distanceSquared, 1e-8));
                // Nearer than aoRadius counts fully, fading out to it.
                float falloff = saturate(1.0 - distanceSquared / (aoRadius * aoRadius));
                best = max(best, lerp(lowest, c, falloff));
            }
            horizonCos[side] = best;
        }

        // The horizons as angles from the view direction, no farther than the normal's
        // hemisphere allows; then the visible arc between them, cosine-weighted.
        float h0 = n + max(-acos(horizonCos[0]) - n, -kPi * 0.5);
        float h1 = n + min(acos(horizonCos[1]) - n, kPi * 0.5);
        float sinN = sin(n);
        float arc0 = 0.25 * (-cos(2.0 * h0 - n) + cosN + 2.0 * h0 * sinN);
        float arc1 = 0.25 * (-cos(2.0 * h1 - n) + cosN + 2.0 * h1 * sinN);
        visibility += projectedLength * (arc0 + arc1);
    }
    return saturate(visibility / float(kSlices));
}

// A different turn per pixel, in [0, 1): a 4 x 4 Bayer pattern, which the 5 x 5 blur
// covers whole, so its structure averages out.
float noise(uint2 p)
{
    static const float kBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    return (kBayer[(p.y & 3) * 4 + (p.x & 3)] + 0.5) / 16.0;
}

// (The entry points write their output once, at the end: fxc, for D3D11, fails on writes
// in branches it flattens.)
float4 computeEffects(uint2 tid)
{
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    int2 p = toFull(tid, viewportSize, size);
    float z = sceneZ(p, size);
    if (isBackground(z))
        return float4(0, 0, 0, 1);
    float3 position = viewPosition(camera, (float2(p) + 0.5) / float2(size), z, aspect);
    float3 normal = viewNormal(p, position, size, aspect);
    float3 tangent = normalize(abs(normal.y) < 0.99 ? cross(normal, float3(0, 1, 0)) : cross(normal, float3(1, 0, 0)));
    float3 bitangent = cross(normal, tangent);

    // Per frame, the golden ratio on: each frame's samples between the last ones'.
    float frameTurn = frac(float(frameIndex % 64u) * 0.618034);
    float turn = frac(noise(tid) + frameTurn) * 2 * kPi;
    float jitter = frac(noise(tid.yx + uint2(1, 2)) + frameTurn * 0.5);
    float occlusion = 0;
    float3 indirect = float3(0, 0, 0);
    for (int i = 0; i < kSamples; ++i)
    {
        // Cosine-weighted: radius sqrt(u) on the disc, lifted onto the hemisphere.
        float u = (float(i) + 0.5) / float(kSamples);
        float r = sqrt(u);
        float phi = float(i) * 2.39996323 + turn;
        float3 h = float3(r * cos(phi), r * sin(phi), sqrt(1 - u));
        float3 direction = tangent * h.x + bitangent * h.y + normal * h.z;
        // More samples near the pixel than far from it.
        float reach = frac(float(i) * 0.618034 + jitter);
        reach = lerp(0.1, 1.0, reach * reach);

        if (aoEnabled != 0 && aoMethod == 0)
        {
            float3 s = position + direction * aoRadius * reach;
            float2 suv = projectToUv(camera, s, aspect);
            if (all(suv > 0) && all(suv < 1) && s.z > depthNear)
            {
                float found = sceneZ(int2(suv * float2(size)), size);
                float range = smoothstep(0.0, 1.0, aoRadius / max(abs(z - found), 1e-4));
                occlusion += found < s.z - 0.01 * s.z ? range : 0.0;
            }
        }
        if (giEnabled != 0)
        {
            float3 s = position + direction * giRadius * reach;
            float2 suv = projectToUv(camera, s, aspect);
            if (all(suv > 0) && all(suv < 1) && s.z > depthNear)
            {
                int2 q = int2(suv * float2(size));
                float qz = sceneZ(q, size);
                // Blocked: something in front of the point, not far in front of it.
                if (qz < s.z - 0.01 * s.z && s.z - qz < 2.0 * giRadius)
                {
                    float3 emitter = viewPosition(camera, (float2(q) + 0.5) / float2(size), qz, aspect);
                    float3 d = emitter - position;
                    float distance = length(d);
                    float3 toEmitter = d / max(distance, 1e-4);
                    float cosine = dot(normal, toEmitter);
                    float facing = dot(viewNormal(q, emitter, size, aspect), -toEmitter);
                    if (distance > 1e-3 && cosine > 0 && facing > 0)
                    {
                        float falloff = 1.0 / (1.0 + 4.0 * (distance * distance) / (giRadius * giRadius));
                        indirect += litColor.Load(int3(q, 0)).rgb * cosine * saturate(facing * 2.0) * falloff;
                    }
                }
            }
        }
    }
    float visibility = 1.0;
    if (aoEnabled != 0 && aoMethod == 1)
        visibility = pow(gtaoVisibility(p, position, normal, size, aspect, turn / (2 * kPi), jitter), gtaoPower);
    else if (aoEnabled != 0)
        visibility = saturate(1.0 - aoStrength * occlusion / float(kSamples));
    return float4(indirect * (2.0 / float(kSamples)), visibility);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void effectsMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> effects)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    effects[tid.xy] = computeEffects(tid.xy);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void blurMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float4> effectsIn, uniform RWTexture2D<float4> effectsOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint2 size = fullSize();
    float center = sceneZ(toFull(tid.xy, viewportSize, size), size);
    float4 sum = float4(0, 0, 0, 0);
    float weights = 0;
    for (int y = -2; y <= 2; ++y)
    {
        for (int x = -2; x <= 2; ++x)
        {
            int2 t = clamp(int2(tid.xy) + int2(x, y), int2(0, 0), int2(viewportSize) - 1);
            float z = sceneZ(toFull(uint2(t), viewportSize, size), size);
            float w = exp(-abs(z - center) / (0.03 * center + 1e-3)) * (3.0 - 0.4 * float(abs(x) + abs(y)));
            sum += effectsIn.Load(int3(t, 0)) * w;
            weights += w;
        }
    }
    effectsOut[tid.xy] = sum / max(weights, 1e-6);
}

// The temporal pass's two results: the history (`slow`, the frames before taken 90 to 10)
// and the fast history (`fast`, fastHistoryWeight of the frames before: about the last two
// or three), which bounds it.
struct Temporal
{
    float4 slow;
    float4 fast;
};

Temporal computeTemporal(uint2 tid, Texture2D<float4> current, Texture2D<float4> history, Texture2D<float4> fastHistory,
                         Texture2D<float> historyDepth)
{
    Temporal result;
    float4 now = current.Load(int3(tid, 0));
    result.slow = now;
    result.fast = now;
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    int2 p = toFull(tid, viewportSize, size);
    float z = sceneZ(p, size);
    if (historyValid == 0 || isBackground(z))
        return result;

    // Where this pixel's surface was the frame before: by the motion of whichever surface
    // is nearest here.
    float3 world = viewToWorld(camera, viewPosition(camera, (float2(p) + 0.5) / float2(size), z, aspect));
    int3 t = int3(p, 0);
    float meshZ = viewDistance(meshDepth.Load(t));
    float sdfZ = viewDistance(sdfDepth.Load(t));
    float3 previous = world;
    if (meshZ <= z * 1.0001)
    {
        previous += meshMotion.Load(t).xyz;
    }
    else if (sdfZ <= z * 1.0001)
    {
        float a = -sdfSpin * timeDelta, c = cos(a), s = sin(a);
        float3 d = world - sdfOrigin;
        previous = sdfOrigin + float3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z);
    }

    // Where the last frame's camera saw it there.
    float3 before = worldToView(prevCamera, previous);
    float2 uv = projectToUv(prevCamera, before, aspect);
    if (before.z <= depthNear || any(uv < 0) || any(uv > 1))
        return result;

    // Both histories, filtered over the 4 nearest texels that saw the same surface.
    float2 f = uv * viewportSize - 0.5;
    int2 base = int2(floor(f));
    float2 w = f - float2(base);
    float4 sum = float4(0, 0, 0, 0);
    float4 fastSum = float4(0, 0, 0, 0);
    float weights = 0;
    for (int k = 0; k < 4; ++k)
    {
        int2 o = int2(k & 1, k >> 1);
        int2 t = clamp(base + o, int2(0, 0), int2(viewportSize) - 1);
        float bilinear = (o.x == 1 ? w.x : 1 - w.x) * (o.y == 1 ? w.y : 1 - w.y);
        float seen = historyDepth.Load(int3(t, 0));
        if (abs(seen - before.z) < 0.04 * before.z)
        {
            sum += history.Load(int3(t, 0)) * bilinear;
            fastSum += fastHistory.Load(int3(t, 0)) * bilinear;
            weights += bilinear;
        }
    }
    if (weights < 0.25)
        return result; // newly seen: nothing to go on
    // Where only some of the texels agree, the histories count for less.
    float trust = saturate(weights);
    float4 kept = sum / weights;
    result.fast = lerp(now, fastSum / weights, fastHistoryWeight * trust);
    if (historyClip > 0)
    {
        // The current frame's spread here (it is blurred already, so tight where flat).
        float4 mean = float4(0, 0, 0, 0), meanSquares = float4(0, 0, 0, 0);
        for (int y = -1; y <= 1; ++y)
        {
            for (int x = -1; x <= 1; ++x)
            {
                int2 n = clamp(int2(tid) + int2(x, y), int2(0, 0), int2(viewportSize) - 1);
                float4 c = current.Load(int3(n, 0));
                mean += c;
                meanSquares += c * c;
            }
        }
        mean /= 9.0;
        float4 sigma = sqrt(max(meanSquares / 9.0 - mean * mean, 0.0));
        float4 extent = historyClip * sigma + float4(0.002, 0.002, 0.002, 0.01);
        // About the fast history (anti-lag, as NVIDIA's ReLAX): it has seen a change within
        // a frame or two, without the single frame's noise; without one, about the mean.
        float4 center = fastHistoryWeight > 0 ? result.fast : mean;
        kept = clamp(kept, center - extent, center + extent);
    }
    result.slow = lerp(now, kept, kHistoryWeight * trust);
    return result;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void temporalMain(
    uint3 tid: SV_DispatchThreadID,
    uniform Texture2D<float4> current,
    uniform Texture2D<float4> history,
    uniform Texture2D<float4> fastHistory,
    uniform Texture2D<float> historyDepth,
    uniform RWTexture2D<float4> resolved,
    uniform RWTexture2D<float4> resolvedFast)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    Temporal t = computeTemporal(tid.xy, current, history, fastHistory, historyDepth);
    resolved[tid.xy] = t.slow;
    resolvedFast[tid.xy] = t.fast;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void historyMain(
    uint3 tid: SV_DispatchThreadID,
    uniform Texture2D<float4> resolvedIn,
    uniform Texture2D<float4> resolvedFastIn,
    uniform RWTexture2D<float4> history,
    uniform RWTexture2D<float4> fastHistory,
    uniform RWTexture2D<float> historyDepth)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint2 size = fullSize();
    history[tid.xy] = resolvedIn.Load(int3(tid.xy, 0));
    fastHistory[tid.xy] = resolvedFastIn.Load(int3(tid.xy, 0));
    historyDepth[tid.xy] = sceneZ(toFull(tid.xy, viewportSize, size), size);
}
