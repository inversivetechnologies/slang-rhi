// Screen-space ambient occlusion (SSAO) and screen-space indirect light (SSGI), for a view
// whose surfaces were merged by depth (post/depth-composite.slang): the meshes', the SDFs'
// and the splats' depth buffers give the nearest surface in each pixel, and the composite's
// image (linear, before encoding) the light leaving it.
//
//   effectsMain   at half resolution: per pixel, its position and normal (rebuilt from
//                 depth), and kSamples directions over the normal's hemisphere,
//                 cosine-weighted (a golden-angle spiral, turned per pixel by a noise).
//                 AO: a point a short way along each direction, occluded where the
//                 depth buffer has something in front of it (counted less, the farther
//                 that is from the pixel's depth: no halos round foreground objects).
//                 GI: a point a longer way along it; where the depth buffer has a
//                 surface in front of that point (the direction is blocked) and that
//                 surface faces the pixel, its light, by the cosine at the pixel and a
//                 falloff with distance, is bounced onto the pixel.
//                 -> effects: rgb the indirect light, a the ambient visibility (1: open)
//   blurMain      a 5 x 5 blur that keeps to similar depths, against the noise
//
// post/ssao-apply.slang puts them on the image: color x visibility + indirect light.

static const int kSamples = 12;
static const float kPi = 3.14159265;

Texture2D<float> meshDepth;   // z/w, over depthNear .. depthFar
Texture2D<float> splatDepth;
Texture2D<float> sdfDepth;
Texture2D<float4> litColor;   // the view's merged image, linear
uniform float depthNear;
uniform float depthFar;

// The view's camera (its view block): only the field of view is needed.
struct EffectsCamera
{
    float3 eye;
    float fovY;
    float3 target;
};
uniform EffectsCamera camera;

uniform uint aoEnabled;
uniform uint giEnabled;
uniform float aoRadius;   // world units
uniform float aoStrength; // 1: fully occluded where every sample is
uniform float giRadius;   // world units

uniform float2 viewportSize; // provided by the host: the effects texture's size

// Each entry point's own textures are its parameters (bound by name, as the globals are),
// so that neither has the other's to bind.

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

// View space: x right, y up, z forward (the view depth).
float3 viewPosition(float2 uv, float z, float aspect)
{
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float t = tan(camera.fovY * 0.5);
    return float3(ndc.x * t * aspect * z, ndc.y * t * z, z);
}

float2 projectToUv(float3 p, float aspect)
{
    float t = tan(camera.fovY * 0.5);
    float2 ndc = float2(p.x / (p.z * t * aspect), p.y / (p.z * t));
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

// The normal, from the neighbors' positions: on each axis the side whose depth is nearer
// the pixel's, so that edges don't bend it.
float3 viewNormal(int2 p, float3 position, uint2 size, float aspect)
{
    float2 texel = 1.0 / float2(size);
    float2 uv = (float2(p) + 0.5) * texel;
    float zl = sceneZ(p - int2(1, 0), size), zr = sceneZ(p + int2(1, 0), size);
    float zu = sceneZ(p - int2(0, 1), size), zd = sceneZ(p + int2(0, 1), size);
    float3 dx = abs(zr - position.z) < abs(zl - position.z)
        ? viewPosition(uv + float2(texel.x, 0), zr, aspect) - position
        : position - viewPosition(uv - float2(texel.x, 0), zl, aspect);
    float3 dy = abs(zd - position.z) < abs(zu - position.z)
        ? viewPosition(uv + float2(0, texel.y), zd, aspect) - position
        : position - viewPosition(uv - float2(0, texel.y), zu, aspect);
    float3 n = normalize(cross(dx, dy));
    return dot(n, position) > 0 ? -n : n; // facing the camera
}

// A different turn per pixel, in [0, 1): a 4 x 4 Bayer pattern, which the 5 x 5 blur
// covers whole, so its structure averages out.
float noise(uint2 p)
{
    static const float kBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    return (kBayer[(p.y & 3) * 4 + (p.x & 3)] + 0.5) / 16.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void effectsMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> effects)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;

    uint2 size = fullSize();
    float aspect = float(size.x) / float(size.y);
    int2 p = int2((float2(tid.xy) + 0.5) * float2(size) / viewportSize);
    float z = sceneZ(p, size);
    if (z > depthFar * 0.9)
    {
        effects[tid.xy] = float4(0, 0, 0, 1); // the background
        return;
    }
    float3 position = viewPosition((float2(p) + 0.5) / float2(size), z, aspect);
    float3 normal = viewNormal(p, position, size, aspect);
    float3 tangent = normalize(abs(normal.y) < 0.99 ? cross(normal, float3(0, 1, 0)) : cross(normal, float3(1, 0, 0)));
    float3 bitangent = cross(normal, tangent);

    float turn = noise(tid.xy) * 2 * kPi;
    float jitter = noise(tid.yx + uint2(1, 2));
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

        if (aoEnabled != 0)
        {
            float3 s = position + direction * aoRadius * reach;
            float2 suv = projectToUv(s, aspect);
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
            float2 suv = projectToUv(s, aspect);
            if (all(suv > 0) && all(suv < 1) && s.z > depthNear)
            {
                int2 q = int2(suv * float2(size));
                float qz = sceneZ(q, size);
                // Blocked: something in front of the point, not far in front of it.
                if (qz < s.z - 0.01 * s.z && s.z - qz < 2.0 * giRadius)
                {
                    float3 emitter = viewPosition((float2(q) + 0.5) / float2(size), qz, aspect);
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
    float visibility = saturate(1.0 - aoStrength * occlusion / float(kSamples));
    effects[tid.xy] = float4(indirect * (2.0 / float(kSamples)), visibility);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void blurMain(uint3 tid: SV_DispatchThreadID, uniform Texture2D<float4> effectsIn, uniform RWTexture2D<float4> effectsOut)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint2 size = fullSize();
    float2 toFull = float2(size) / viewportSize;
    float center = sceneZ(int2((float2(tid.xy) + 0.5) * toFull), size);
    float4 sum = float4(0, 0, 0, 0);
    float weights = 0;
    for (int y = -2; y <= 2; ++y)
    {
        for (int x = -2; x <= 2; ++x)
        {
            int2 t = clamp(int2(tid.xy) + int2(x, y), int2(0, 0), int2(viewportSize) - 1);
            float z = sceneZ(int2((float2(t) + 0.5) * toFull), size);
            float w = exp(-abs(z - center) / (0.03 * center + 1e-3)) * (3.0 - 0.4 * float(abs(x) + abs(y)));
            sum += effectsIn.Load(int3(t, 0)) * w;
            weights += w;
        }
    }
    effectsOut[tid.xy] = weights > 0 ? sum / weights : effectsIn.Load(int3(tid.xy, 0));
}
