// Temporal stabilization of a view's final image (TAA without jitter): each pixel is
// blended with what it showed before, so that detail finer than a pixel -- above all the
// splats' -- doesn't shimmer from frame to frame as the camera, the light or the splats'
// footprints move.
//
//   taaMain      the pixel's surface is found where it was the frame before (moved back by
//                its own motion: the bodies' motion vectors, scene/motion.slang, the SDF
//                composition's spin, or the splats' -- what the effects move, blended as
//                their depth is, splat/render.slang; the rest stand still) and where the
//                last frame's camera saw it there; that frame's image there, filtered (Catmull-Rom, so
//                the history doesn't blur), is taken -- if its depth agrees -- clipped to
//                the current 3 x 3 neighborhood's color box (in YCoCg; a history outside it
//                is out of date) and blended with the new frame, kTaaCurrent of it.
//                -> resolved: rgb the image, a its view depth (for the next frame's check)
//   taaKeepMain  the resolved image kept as the next frame's history
//
// The image is linear (before the window's encoding).

#include "reprojection.slang"

static const float kTaaCurrent = 0.1;

Texture2D<float4> taaCurrent; // the view's final image, linear
uniform uint historyValid;
uniform float2 viewportSize; // provided by the host: the view's size (the dispatch's texture)

float3 toYCoCg(float3 c)
{
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

float3 fromYCoCg(float3 c)
{
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// The history at `uv`, filtered with Catmull-Rom weights over the 4 x 4 texels around it,
// and its depth (nearest texel's).
float4 sampleHistory(Texture2D<float4> history, float2 uv, out float depth)
{
    float2 p = uv * viewportSize - 0.5;
    int2 base = int2(floor(p));
    float2 f = p - float2(base);
    // Catmull-Rom weights for offsets -1, 0, 1, 2.
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float wx[4] = { w0.x, w1.x, w2.x, w3.x };
    float wy[4] = { w0.y, w1.y, w2.y, w3.y };
    int2 last = int2(viewportSize) - 1;
    float3 sum = float3(0, 0, 0);
    float weights = 0;
    for (int y = 0; y < 4; ++y)
    {
        for (int x = 0; x < 4; ++x)
        {
            int2 t = clamp(base + int2(x - 1, y - 1), int2(0, 0), last);
            float w = wx[x] * wy[y];
            sum += history.Load(int3(t, 0)).rgb * w;
            weights += w;
        }
    }
    depth = history.Load(int3(clamp(int2(round(p)), int2(0, 0), last), 0)).a;
    return float4(max(sum / weights, 0.0), 1.0);
}

float4 resolve(uint2 tid, Texture2D<float4> history)
{
    float3 now = taaCurrent.Load(int3(tid, 0)).rgb;
    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    float z = sceneZ(int2(tid), size);
    float4 result = float4(now, z);
    if (historyValid == 0)
        return result;

    // The current neighborhood's color box, in YCoCg.
    float3 lo = float3(1e9, 1e9, 1e9), hi = float3(-1e9, -1e9, -1e9);
    float3 mean = float3(0, 0, 0), meanSquares = float3(0, 0, 0);
    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            int2 n = clamp(int2(tid) + int2(x, y), int2(0, 0), int2(viewportSize) - 1);
            float3 c = toYCoCg(taaCurrent.Load(int3(n, 0)).rgb);
            mean += c;
            meanSquares += c * c;
        }
    }
    mean /= 9.0;
    float3 sigma = sqrt(max(meanSquares / 9.0 - mean * mean, 0.0));
    lo = mean - 1.25 * sigma;
    hi = mean + 1.25 * sigma;

    // Where this pixel's surface was the frame before.
    float3 world = viewToWorld(camera, viewPosition(camera, (float2(tid) + 0.5) / float2(size), z, aspect));
    float3 previous = previousWorld(int2(tid), z, world);
    float3 before = worldToView(prevCamera, previous);
    float2 uv = projectToUv(prevCamera, before, aspect);
    if (before.z <= depthNear || any(uv < 0) || any(uv > 1))
        return result;

    float seenDepth;
    float3 kept = sampleHistory(history, uv, seenDepth).rgb;
    // The background (far) agrees with the background; a surface with a surface at its depth.
    bool agrees = isBackground(z) ? isBackground(seenDepth) : abs(seenDepth - before.z) < 0.05 * before.z;
    if (!agrees)
        return result; // newly seen: this frame alone
    kept = fromYCoCg(clamp(toYCoCg(kept), lo, hi));
    result.rgb = lerp(kept, now, kTaaCurrent);
    return result;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void taaMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float4> history, uniform RWTexture2D<float4> resolved)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    resolved[tid.xy] = resolve(tid.xy, history);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void taaKeepMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float4> resolvedIn, uniform RWTexture2D<float4> history)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    history[tid.xy] = resolvedIn.Load(int3(tid.xy, 0));
}
