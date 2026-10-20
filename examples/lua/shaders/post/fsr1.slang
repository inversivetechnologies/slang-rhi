// Spatial upscaling of the main view's final image (AMD FidelityFX Super Resolution 1.0,
// after its reference, ffx_fsr1.h -- MIT licensed -- in plain float): the view is drawn at a
// fraction of the window's size, then
//
//   easuMain   Edge Adaptive Spatial Upsampling: each output pixel from the 12 input
//              pixels around it (a 4 x 4 square less its corners), weighted by a Lanczos-2
//              like kernel stretched along the local edge (found from the luma of the four
//              nearest), its result clamped to the four nearest (no ringing)
//              -> fsrUpscaled, the window's size
//   rcasMain   Robust Contrast Adaptive Sharpening: each pixel sharpened by as much as its
//              cross neighborhood allows without clipping (`fsrSharpness` in stops: 0 the
//              most)
//              -> fsrOutput
//
// Both work in a perceptual space (the square root of the linear image, as FSR wants its
// input gamma encoded); rcasMain writes linear again. The input should be anti-aliased (FSR
// 1 adds no detail and smooths no stairs: the AA runs first, at the drawn size).

Texture2D<float4> fsrInput;       // easuMain: the view's image (linear), drawn smaller
uniform float2 fsrInputSize;      // its size, pixels
uniform float fsrSharpness;       // rcasMain: stops from the most (0) -- 0.2 is FSR's default
uniform float2 viewportSize;      // provided by the host: the output's size

float3 perceptual(float3 c)
{
    return sqrt(max(c, 0.0));
}

float3 loadInput(int2 p)
{
    p = clamp(p, int2(0, 0), int2(fsrInputSize) - 1);
    return perceptual(fsrInput.Load(int3(p, 0)).rgb);
}

// FSR's luma (twice the usual weights, enough for comparisons): 0.5 r + g + 0.5 b.
float luma(float3 c)
{
    return c.b * 0.5 + (c.r * 0.5 + c.g);
}

// A low precision reciprocal, as FSR's approximations: plain here.
float rcpSafe(float x)
{
    return 1.0 / max(x, 1e-8);
}

// The edge's direction and length, from one bilinear quarter around the pixel (a above, b
// left, c center, d right, e below), weighted by that quarter's bilinear weight.
void easuSet(inout float2 dir, inout float len, float w, float lA, float lB, float lC, float lD, float lE)
{
    float dc = lD - lC;
    float cb = lC - lB;
    float lenX = max(abs(dc), abs(cb));
    lenX = rcpSafe(lenX);
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX);
    lenX *= lenX;
    len += lenX * w;

    float ec = lE - lC;
    float ca = lC - lA;
    float lenY = max(abs(ec), abs(ca));
    lenY = rcpSafe(lenY);
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY);
    lenY *= lenY;
    len += lenY * w;
}

// One tap: its weight from the kernel, rotated along `dir` and stretched by `len2`.
void easuTap(inout float3 color, inout float weight, float2 offset, float2 dir, float2 len2, float lob, float clp, float3 c)
{
    float2 v;
    v.x = offset.x * dir.x + offset.y * dir.y;
    v.y = offset.x * -dir.y + offset.y * dir.x;
    v *= len2;
    float d2 = min(v.x * v.x + v.y * v.y, clp);
    // A polynomial approximation of Lanczos 2: (25/16 (2/5 x^2 - 1)^2 - (25/16 - 1)) (lob x^2 - 1)^2.
    float wB = 2.0 / 5.0 * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
    float w = wB * wA;
    color += c * w;
    weight += w;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void easuMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> fsrUpscaled)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    // Where the output pixel's center falls on the input, texel centers on integers.
    float2 pp = (float2(tid.xy) + 0.5) * fsrInputSize / viewportSize - 0.5;
    float2 fp = floor(pp);
    pp -= fp;
    int2 f0 = int2(fp);

    //    b c
    //  e f g h
    //  i j k l
    //    n o
    float3 bC = loadInput(f0 + int2(0, -1)), cC = loadInput(f0 + int2(1, -1));
    float3 eC = loadInput(f0 + int2(-1, 0)), fC = loadInput(f0), gC = loadInput(f0 + int2(1, 0)), hC = loadInput(f0 + int2(2, 0));
    float3 iC = loadInput(f0 + int2(-1, 1)), jC = loadInput(f0 + int2(0, 1)), kC = loadInput(f0 + int2(1, 1)), lC = loadInput(f0 + int2(2, 1));
    float3 nC = loadInput(f0 + int2(0, 2)), oC = loadInput(f0 + int2(1, 2));
    float bL = luma(bC), cL = luma(cC), eL = luma(eC), fL = luma(fC), gL = luma(gC), hL = luma(hC);
    float iL = luma(iC), jL = luma(jC), kL = luma(kC), lL = luma(lC), nL = luma(nC), oL = luma(oC);

    // The edge, from the four nearest, each by its bilinear weight.
    float2 dir = float2(0, 0);
    float len = 0.0;
    easuSet(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);
    easuSet(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);
    easuSet(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);
    easuSet(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);

    // Normalized; no direction: along x.
    float2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    bool zero = dirR < 1.0 / 32768.0;
    dirR = zero ? 1.0 : rsqrt(dirR);
    dir.x = zero ? 1.0 : dir.x;
    dir *= dirR;
    // The kernel: stretched along the edge as far as it is one, its negative lobe less.
    len = len * 0.5;
    len *= len;
    float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpSafe(max(abs(dir.x), abs(dir.y)));
    float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    float clp = rcpSafe(lob);

    float3 color = float3(0, 0, 0);
    float weight = 0.0;
    easuTap(color, weight, float2(0, -1) - pp, dir, len2, lob, clp, bC);
    easuTap(color, weight, float2(1, -1) - pp, dir, len2, lob, clp, cC);
    easuTap(color, weight, float2(-1, 1) - pp, dir, len2, lob, clp, iC);
    easuTap(color, weight, float2(0, 1) - pp, dir, len2, lob, clp, jC);
    easuTap(color, weight, float2(0, 0) - pp, dir, len2, lob, clp, fC);
    easuTap(color, weight, float2(-1, 0) - pp, dir, len2, lob, clp, eC);
    easuTap(color, weight, float2(1, 1) - pp, dir, len2, lob, clp, kC);
    easuTap(color, weight, float2(2, 1) - pp, dir, len2, lob, clp, lC);
    easuTap(color, weight, float2(2, 0) - pp, dir, len2, lob, clp, hC);
    easuTap(color, weight, float2(1, 0) - pp, dir, len2, lob, clp, gC);
    easuTap(color, weight, float2(1, 2) - pp, dir, len2, lob, clp, oC);
    easuTap(color, weight, float2(0, 2) - pp, dir, len2, lob, clp, nC);

    // No ringing: within the four nearest.
    float3 lo = min(min(fC, gC), min(jC, kC));
    float3 hi = max(max(fC, gC), max(jC, kC));
    fsrUpscaled[tid.xy] = float4(clamp(color / weight, lo, hi), 1.0);
}

Texture2D<float4> fsrUpscaledIn; // rcasMain: easuMain's (perceptual)

float3 loadUpscaled(int2 p)
{
    p = clamp(p, int2(0, 0), int2(viewportSize) - 1);
    return fsrUpscaledIn.Load(int3(p, 0)).rgb;
}

// RCAS's limit on the lobe (no more sharpening than this, whatever the sharpness).
static const float kRcasLimit = 0.25 - 1.0 / 16.0;

[shader("compute")]
[numthreads(8, 8, 1)]
void rcasMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> fsrOutput)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    int2 p = int2(tid.xy);
    //   b
    // d e f
    //   h
    float3 b = loadUpscaled(p + int2(0, -1));
    float3 d = loadUpscaled(p + int2(-1, 0));
    float3 e = loadUpscaled(p);
    float3 f = loadUpscaled(p + int2(1, 0));
    float3 h = loadUpscaled(p + int2(0, 1));

    // The most the cross allows, per channel, before the result would clip (0..1).
    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));
    float2 peak = float2(1.0, -4.0);
    float3 hitMin = mn4 / (4.0 * mx4 + 1e-8);
    float3 hitMax = (peak.x - mx4) / (4.0 * mn4 + peak.y);
    float3 lobeRGB = max(-hitMin, hitMax);
    float lobe = max(-kRcasLimit, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * exp2(-fsrSharpness);

    float3 color = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);
    fsrOutput[tid.xy] = float4(color * color, 1.0); // linear again
}
