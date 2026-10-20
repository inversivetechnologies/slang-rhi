// Morphological anti-aliasing of a view's final image, as SMAA 1x does it (Jimenez et al.
// 2012, "SMAA: Enhanced Subpixel Morphological Antialiasing"), in its three passes:
//
//   edgesMain    luma edges, on each pixel's left and top side, where the step is over
//                kThreshold and not much smaller than its neighbors' steps (SMAA's local
//                contrast adaptation: the lesser edge of a double edge is dropped)
//                -> smaaEdges: r left edge, g top edge
//   weightsMain  for each edge: how far it runs either way (up to kMaxSearch pixels), and
//                at each end, which side the crossing edge turns to -- the pattern (none,
//                L, Z, U). The silhouette it stands for is a line through the ends' crossing
//                edges' midpoints (half a pixel off the edge) and the edge's middle (or, for
//                a Z, straight from end to end); the area between that line and the edge,
//                over this pixel, is how much of the pixel on either side is the other's
//                color. -> smaaWeights: xy the top edge's (this pixel takes from the one
//                above, the one above from this), zw the left edge's (likewise, left)
//   blendMain    each pixel mixed with its four neighbors by those areas
//
// Unlike the reference, the areas are worked out here rather than read from its
// precomputed area texture, the search reads the edges one by one (no search texture),
// and there are no diagonal patterns. No history: nothing lags; nothing is stabilized.
// The image is linear (before the window's encoding); luma is perceptual (its square
// root), the blending linear.

Texture2D<float4> smaaInput;
uniform float2 viewportSize; // provided by the host: the dispatch's texture

static const float kThreshold = 0.1;  // the least luma step that is an edge
static const float kAdaptation = 2.0; // an edge this many times smaller than a neighbor's isn't one
static const int kMaxSearch = 16;     // pixels either way along an edge

float lumaOf(float3 c)
{
    return sqrt(max(dot(c, float3(0.2126, 0.7152, 0.0722)), 0.0));
}

int2 clampPixel(int2 p)
{
    return clamp(p, int2(0, 0), int2(viewportSize) - 1);
}

float lumaAt(int2 p)
{
    return lumaOf(smaaInput.Load(int3(clampPixel(p), 0)).rgb);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void edgesMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> smaaEdges)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    int2 p = int2(tid.xy);
    float l = lumaAt(p);
    float lLeft = lumaAt(p + int2(-1, 0));
    float lTop = lumaAt(p + int2(0, -1));
    float2 delta = abs(l - float2(lLeft, lTop));
    float2 edges = step(kThreshold, delta);
    if (dot(edges, 1) > 0)
    {
        // The neighbors' steps: an edge much smaller than one of them is dropped.
        float lRight = lumaAt(p + int2(1, 0));
        float lBottom = lumaAt(p + int2(0, 1));
        float lLeftLeft = lumaAt(p + int2(-2, 0));
        float lTopTop = lumaAt(p + int2(0, -2));
        float2 around = max(abs(l - float2(lRight, lBottom)), abs(float2(lLeft, lTop) - float2(lLeftLeft, lTopTop)));
        float largest = max(max(around.x, around.y), max(delta.x, delta.y));
        edges *= step(largest, kAdaptation * delta);
    }
    smaaEdges[tid.xy] = float4(edges, 0, 0);
}

Texture2D<float4> smaaEdgesIn;

float2 edgeAt(int2 p)
{
    if (any(p < 0) || any(p >= int2(viewportSize)))
        return float2(0, 0);
    return smaaEdgesIn.Load(int3(p, 0)).rg;
}

// The integral of the line from (x0, h0) to (x1, h1) -- over x0..x1 -- above zero and
// below it (both positive).
float2 splitArea(float x0, float h0, float x1, float h1)
{
    float width = x1 - x0;
    if (width <= 0)
        return float2(0, 0);
    if (h0 >= 0 && h1 >= 0)
        return float2(0.5 * (h0 + h1) * width, 0);
    if (h0 <= 0 && h1 <= 0)
        return float2(0, -0.5 * (h0 + h1) * width);
    float t = h0 / (h0 - h1) * width; // where it crosses zero
    float2 first = float2(0.5 * h0 * t, 0);
    float2 second = float2(0.5 * h1 * (width - t), 0);
    return h0 > 0 ? float2(first.x, -second.x) : float2(second.x, -first.x);
}

// The silhouette's height over the edge at x (0 at the run's start, d at its end), for a
// run of d pixels whose ends turn by hStart and hEnd (+-0.5, or 0 for no turn).
float silhouette(float x, float d, float hStart, float hEnd)
{
    // A Z (the ends turn opposite ways): one line from end to end.
    if (hStart * hEnd < 0)
        return lerp(hStart, hEnd, x / d);
    // Else (an L, a U): from each end to the middle.
    float half = 0.5 * d;
    return x < half ? hStart * (1.0 - x / half) : hEnd * ((x - half) / half);
}

// The areas over pixel `i` (i .. i + 1) of a run of d: x above the edge, y below.
float2 runArea(float i, float d, float hStart, float hEnd)
{
    float half = 0.5 * d;
    float2 area = float2(0, 0);
    if (hStart * hEnd < 0 || i + 1 <= half || i >= half)
    {
        area = splitArea(i, silhouette(i, d, hStart, hEnd), i + 1, silhouette(i + 1, d, hStart, hEnd));
    }
    else
    {
        // The middle is inside this pixel: two pieces.
        area = splitArea(i, silhouette(i, d, hStart, hEnd), half, 0) + splitArea(half, 0, i + 1, silhouette(i + 1, d, hStart, hEnd));
    }
    return area;
}

// How a run's end turns: +0.5 toward the first side (above / left), -0.5 toward the second,
// 0 if neither (or both).
float turn(float first, float second)
{
    return first > 0.5 && second < 0.5 ? 0.5 : (second > 0.5 && first < 0.5 ? -0.5 : 0.0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void weightsMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> smaaWeights)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    int2 p = int2(tid.xy);
    float2 e = edgeAt(p);
    float4 weights = float4(0, 0, 0, 0);

    // The top edge: a horizontal run, between the row above (y - 1) and this one.
    [branch]
    if (e.g > 0.5)
    {
        int left = 0, right = 0;
        [loop]
        for (; left < kMaxSearch && edgeAt(p + int2(-left - 1, 0)).g > 0.5; ++left) {}
        [loop]
        for (; right < kMaxSearch && edgeAt(p + int2(right + 1, 0)).g > 0.5; ++right) {}
        // The ends' crossing edges: vertical edges at the run's start (the left side of its
        // first pixel) and end (the left side of the pixel after its last), above or below.
        int xStart = p.x - left, xEnd = p.x + right + 1;
        float hStart = turn(edgeAt(int2(xStart, p.y - 1)).r, edgeAt(int2(xStart, p.y)).r);
        float hEnd = turn(edgeAt(int2(xEnd, p.y - 1)).r, edgeAt(int2(xEnd, p.y)).r);
        // Above the edge (h > 0): the row above has some of this row's color; below, this
        // row some of the one above's.
        float2 area = runArea(float(left), float(left + right + 1), hStart, hEnd);
        weights.xy = float2(area.y, area.x);
    }
    // The left edge: a vertical run, between the column left (x - 1) and this one.
    [branch]
    if (e.r > 0.5)
    {
        int up = 0, down = 0;
        [loop]
        for (; up < kMaxSearch && edgeAt(p + int2(0, -up - 1)).r > 0.5; ++up) {}
        [loop]
        for (; down < kMaxSearch && edgeAt(p + int2(0, down + 1)).r > 0.5; ++down) {}
        int yStart = p.y - up, yEnd = p.y + down + 1;
        float hStart = turn(edgeAt(int2(p.x - 1, yStart)).g, edgeAt(int2(p.x, yStart)).g);
        float hEnd = turn(edgeAt(int2(p.x - 1, yEnd)).g, edgeAt(int2(p.x, yEnd)).g);
        float2 area = runArea(float(up), float(up + down + 1), hStart, hEnd);
        weights.zw = float2(area.y, area.x);
    }
    smaaWeights[tid.xy] = weights;
}

Texture2D<float4> smaaWeightsIn;

float4 weightsAt(int2 p)
{
    if (any(p < 0) || any(p >= int2(viewportSize)))
        return float4(0, 0, 0, 0);
    return smaaWeightsIn.Load(int3(p, 0));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void blendMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> smaaOutput)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    int2 p = int2(tid.xy);
    float4 own = weightsAt(p);
    // What this pixel takes from each neighbor: its own top and left edges' first areas,
    // and the bottom and right neighbors' edges' second ones.
    float up = own.x, left = own.z;
    float down = weightsAt(p + int2(0, 1)).y;
    float right = weightsAt(p + int2(1, 0)).w;
    float total = up + down + left + right;
    float3 color = smaaInput.Load(int3(p, 0)).rgb;
    [branch]
    if (total > 0)
    {
        float scale = total > 1 ? 1.0 / total : 1.0;
        color = color * (1.0 - total * scale) +
                (smaaInput.Load(int3(clampPixel(p + int2(0, -1)), 0)).rgb * up +
                 smaaInput.Load(int3(clampPixel(p + int2(0, 1)), 0)).rgb * down +
                 smaaInput.Load(int3(clampPixel(p + int2(-1, 0)), 0)).rgb * left +
                 smaaInput.Load(int3(clampPixel(p + int2(1, 0)), 0)).rgb * right) * scale;
    }
    smaaOutput[tid.xy] = float4(color, 1.0);
}
