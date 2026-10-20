// Spatial anti-aliasing of a view's final image (FXAA, after Lottes' FXAA 3.11, its
// quality preset): no history, so nothing lags or ghosts -- what it doesn't do is
// stabilize what shimmers from frame to frame (the splats' detail finer than a pixel: the
// TAA's, post/taa.slang).
//
// Per pixel: where the local contrast of luma (perceptual: the square root of the linear
// luminance) is high enough, the edge through the pixel is found (horizontal or vertical,
// from the 3 x 3 neighborhood), walked along both ways until its luma pair stops matching,
// and the pixel is sampled across the edge by how far it is from the edge's nearer end --
// so that a staircase becomes a slope. A subpixel term softens what is a pixel wide.
//
// The image is linear (before the window's encoding); it is blended in linear light.

Texture2D<float4> fxaaInput;
SamplerState fxaaSampler; // linear, clamped
uniform float2 viewportSize; // provided by the host: the dispatch's texture

static const float kEdgeThreshold = 0.125;    // the least contrast that is an edge, of the local maximum
static const float kEdgeThresholdMin = 0.0312; // ...and at least this (dark areas)
static const float kSubpix = 0.75;            // how much the subpixel term softens
static const int kSteps = 10;
static const float kStepSizes[kSteps] = { 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0, 12.0 };

float lumaOf(float3 c)
{
    return sqrt(max(dot(c, float3(0.299, 0.587, 0.114)), 0.0));
}

float lumaAt(float2 uv)
{
    return lumaOf(fxaaInput.SampleLevel(fxaaSampler, uv, 0).rgb);
}

float lumaLoad(int2 p)
{
    p = clamp(p, int2(0, 0), int2(viewportSize) - 1);
    return lumaOf(fxaaInput.Load(int3(p, 0)).rgb);
}

float3 fxaa(int2 p)
{
    float2 texel = 1.0 / viewportSize;
    float2 uv = (float2(p) + 0.5) * texel;
    float3 center = fxaaInput.Load(int3(p, 0)).rgb;
    float lumaM = lumaOf(center);
    float lumaN = lumaLoad(p + int2(0, -1));
    float lumaS = lumaLoad(p + int2(0, 1));
    float lumaW = lumaLoad(p + int2(-1, 0));
    float lumaE = lumaLoad(p + int2(1, 0));
    float maxLuma = max(lumaM, max(max(lumaN, lumaS), max(lumaW, lumaE)));
    float minLuma = min(lumaM, min(min(lumaN, lumaS), min(lumaW, lumaE)));
    float range = maxLuma - minLuma;
    if (range < max(kEdgeThresholdMin, maxLuma * kEdgeThreshold))
        return center;

    float lumaNW = lumaLoad(p + int2(-1, -1));
    float lumaNE = lumaLoad(p + int2(1, -1));
    float lumaSW = lumaLoad(p + int2(-1, 1));
    float lumaSE = lumaLoad(p + int2(1, 1));

    // Which way the edge runs: horizontal if the luma changes more vertically.
    float edgeHorizontal = abs(lumaNW - 2.0 * lumaN + lumaNE) + 2.0 * abs(lumaW - 2.0 * lumaM + lumaE) +
                           abs(lumaSW - 2.0 * lumaS + lumaSE);
    float edgeVertical = abs(lumaNW - 2.0 * lumaW + lumaSW) + 2.0 * abs(lumaN - 2.0 * lumaM + lumaS) +
                         abs(lumaNE - 2.0 * lumaE + lumaSE);
    bool horizontal = edgeHorizontal >= edgeVertical;

    // Which side of the pixel the edge is on: the neighbor across it with the larger step.
    float luma1 = horizontal ? lumaN : lumaW;
    float luma2 = horizontal ? lumaS : lumaE;
    float gradient1 = luma1 - lumaM;
    float gradient2 = luma2 - lumaM;
    bool side1 = abs(gradient1) >= abs(gradient2);
    float gradientScaled = 0.25 * max(abs(gradient1), abs(gradient2));
    float stepLength = horizontal ? texel.y : texel.x;
    float lumaLocalAverage;
    if (side1)
    {
        stepLength = -stepLength;
        lumaLocalAverage = 0.5 * (luma1 + lumaM);
    }
    else
    {
        lumaLocalAverage = 0.5 * (luma2 + lumaM);
    }

    // Along the edge, half a pixel toward it, both ways until the luma pair changes.
    float2 edgeUv = uv;
    if (horizontal)
        edgeUv.y += stepLength * 0.5;
    else
        edgeUv.x += stepLength * 0.5;
    float2 along = horizontal ? float2(texel.x, 0) : float2(0, texel.y);
    float2 uv1 = edgeUv - along;
    float2 uv2 = edgeUv + along;
    float lumaEnd1 = lumaAt(uv1) - lumaLocalAverage;
    float lumaEnd2 = lumaAt(uv2) - lumaLocalAverage;
    bool reached1 = abs(lumaEnd1) >= gradientScaled;
    bool reached2 = abs(lumaEnd2) >= gradientScaled;
    [loop]
    for (int i = 1; i < kSteps && !(reached1 && reached2); ++i)
    {
        if (!reached1)
        {
            uv1 -= along * kStepSizes[i];
            lumaEnd1 = lumaAt(uv1) - lumaLocalAverage;
            reached1 = abs(lumaEnd1) >= gradientScaled;
        }
        if (!reached2)
        {
            uv2 += along * kStepSizes[i];
            lumaEnd2 = lumaAt(uv2) - lumaLocalAverage;
            reached2 = abs(lumaEnd2) >= gradientScaled;
        }
    }

    // How far the pixel is from the nearer end, as an offset across the edge -- if that end
    // turns the way the pixel's own step does (else it is the edge's other side).
    float distance1 = horizontal ? uv.x - uv1.x : uv.y - uv1.y;
    float distance2 = horizontal ? uv2.x - uv.x : uv2.y - uv.y;
    bool nearer1 = distance1 < distance2;
    float nearest = min(distance1, distance2);
    float edgeLength = distance1 + distance2;
    bool centerSmaller = lumaM - lumaLocalAverage < 0.0;
    bool goodSpan = ((nearer1 ? lumaEnd1 : lumaEnd2) < 0.0) != centerSmaller;
    float pixelOffset = goodSpan ? 0.5 - nearest / edgeLength : 0.0;

    // The subpixel term: how far the pixel stands out of its 3 x 3 average.
    float average = (2.0 * (lumaN + lumaS + lumaW + lumaE) + lumaNW + lumaNE + lumaSW + lumaSE) / 12.0;
    float subpix1 = saturate(abs(average - lumaM) / range);
    float subpix2 = (-2.0 * subpix1 + 3.0) * subpix1 * subpix1;
    float subpixOffset = subpix2 * subpix2 * kSubpix;
    float offset = max(pixelOffset, subpixOffset);

    float2 sampleUv = uv;
    if (horizontal)
        sampleUv.y += offset * stepLength;
    else
        sampleUv.x += offset * stepLength;
    return fxaaInput.SampleLevel(fxaaSampler, sampleUv, 0).rgb;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void fxaaMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> fxaaOutput)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    fxaaOutput[tid.xy] = float4(fxaa(int2(tid.xy)), 1.0);
}
