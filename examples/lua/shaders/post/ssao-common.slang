// What the screen-space effects (post/ssao.slang, post/ssao-apply.slang) share: the view's
// nearest surface from its three depth buffers (as the depth composite merges them), and
// positions in view space rebuilt from it.
//
// View space: x right, y up, z forward (the view depth), as every pass's camera builds it
// from eye, target and the world's up (scene/lit.slang, sdf/raymarch.slang, splat/...).

Texture2D<float> meshDepth; // z/w, over depthNear .. depthFar
Texture2D<float> splatDepth;
Texture2D<float> sdfDepth;
uniform float depthNear;
uniform float depthFar;

struct EffectsCamera
{
    float3 eye;
    float fovY;
    float3 target;
};

// The view's camera (its view block).
uniform EffectsCamera camera;

float viewDistance(float depth)
{
    return depthNear * depthFar / (depthFar - depth * (depthFar - depthNear));
}

uint2 fullSize()
{
    uint w, h;
    meshDepth.GetDimensions(w, h);
    return uint2(w, h);
}

// The nearest surface's view depth at a full-resolution pixel.
float sceneZ(int2 p, uint2 size)
{
    p = clamp(p, int2(0, 0), int2(size) - 1);
    int3 t = int3(p, 0);
    return viewDistance(min(meshDepth.Load(t), min(splatDepth.Load(t), sdfDepth.Load(t))));
}

bool isBackground(float z)
{
    return z > depthFar * 0.9;
}

// The full-resolution pixel a pixel of a `lowSize` texture stands for.
int2 toFull(uint2 low, float2 lowSize, uint2 size)
{
    return int2((float2(low) + 0.5) * float2(size) / lowSize);
}

float3 viewPosition(EffectsCamera c, float2 uv, float z, float aspect)
{
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float t = tan(c.fovY * 0.5);
    return float3(ndc.x * t * aspect * z, ndc.y * t * z, z);
}

float2 projectToUv(EffectsCamera c, float3 p, float aspect)
{
    float t = tan(c.fovY * 0.5);
    float2 ndc = float2(p.x / (p.z * t * aspect), p.y / (p.z * t));
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

// The camera's axes in the world: right, up, forward.
float3x3 cameraBasis(EffectsCamera c)
{
    float3 forward = normalize(c.target - c.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    return float3x3(right, up, forward);
}

float3 viewToWorld(EffectsCamera c, float3 v)
{
    float3x3 b = cameraBasis(c);
    return c.eye + b[0] * v.x + b[1] * v.y + b[2] * v.z;
}

float3 worldToView(EffectsCamera c, float3 w)
{
    float3x3 b = cameraBasis(c);
    float3 d = w - c.eye;
    return float3(dot(d, b[0]), dot(d, b[1]), dot(d, b[2]));
}
