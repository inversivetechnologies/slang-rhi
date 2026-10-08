// Shared by the Gaussian splatting passes: preprocess.slang writes these, render.slang
// draws them.

// A splat after preprocessing: the ellipse it covers on screen, and its color.
struct ProjectedSplat
{
    float4 centerAxis1; // xy: center in pixels, zw: the ellipse's first half axis (3 sigma), pixels
    float4 axis2;       // xy: the second half axis (3 sigma), pixels; z: view depth; w: unused
    float4 color;       // rgb: color as trained (display space), a: opacity
};

struct SplatCamera
{
    float3 eye;
    float fovY; // vertical field of view, radians
    float3 target;
};

// Sort key of splats that aren't drawn (culled, or padding): sorts after every real one.
static const float kCulledKey = 1e30;

// How many elements the sort works on for `count` drawn splats: a power of two, at least
// one block of 1024 (shaders/sort/bitonic.slang).
uint sortSizeFor(uint count)
{
    return count <= 1024 ? 1024 : 1u << (firstbithigh(count - 1) + 1);
}

// The depth range splats are written to a depth buffer with -- the same as the scene's
// (scene/lit.slang), so depth buffers of both can be compared.
static const float kDepthNear = 0.1;
static const float kDepthFar = 100.0;

float depthFromViewZ(float z)
{
    return (z - kDepthNear) * kDepthFar / ((kDepthFar - kDepthNear) * z);
}
