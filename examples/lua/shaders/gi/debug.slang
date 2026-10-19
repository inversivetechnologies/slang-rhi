// The GI's debug views (lib/scene/gi.lua; the viewer's V): drawn over the main view's
// final image, one at a time (giDebugMode):
//
//   1  normals      the G-buffer's view-space normals, as colors (x red, y green, z blue)
//   2  Hi-Z         a level of the pyramid (giDebugLevel): its nearest view depth, near
//                   bright, as gray
//   3  global SDF   the volume, sphere-traced from the camera: its albedo, lit by the key
//                   light (no shadows); dark blue where a ray leaves it
//   4  DDGI         the probes' irradiance at each pixel's surface (tone mapped)
//   5-8 cascade i   cascade i's atlas, stretched over the view: each probe's directions
//                   as a little tile (tone mapped; merged with the cascades above)
//   9  albedo       the G-buffer's albedo (what the indirect light is multiplied by)

#include "post/ssao-common.slang"
#include "scene/scene-common.slang"
#include "global-sdf.slang"
#include "ddgi.slang"

uniform uint giDebugMode;
uniform uint giDebugLevel;
uniform uint outputEncodeGamma; // 1 if the window doesn't encode sRGB itself
uniform float2 viewportSize;    // provided by the host

Texture2D<float4> gbuffer;
Texture2D<float> hiz0;
Texture2D<float> hiz1;
Texture2D<float> hiz2;
Texture2D<float> hiz3;
Texture2D<float> hiz4;
Texture2D<float4> cascade0;
Texture2D<float4> cascade1;
Texture2D<float4> cascade2;
Texture2D<float4> cascade3;
Texture2D<float4> albedo;

struct VertexOutput
{
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    VertexOutput output;
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}

float hizSample(uint level, float2 uv)
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

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float2 uv = input.position.xy / viewportSize;
    uint w, h;
    gbuffer.GetDimensions(w, h);
    float4 g = gbuffer.Load(int3(int2(uv * float2(w, h)), 0));
    float3 color = float3(0, 0, 0);
    if (giDebugMode == 1)
    {
        color = isBackground(g.w) ? float3(0, 0, 0) : g.xyz * 0.5 + 0.5;
    }
    else if (giDebugMode == 2)
    {
        float z = hizSample(giDebugLevel, uv);
        color = isBackground(z) ? float3(0.05, 0.0, 0.1) : saturate(1.0 - z / 15.0).xxx;
    }
    else if (giDebugMode == 3)
    {
        // The ray through this pixel, from the camera.
        float3 forward = normalize(camera.target - camera.eye);
        float3 right = normalize(cross(float3(0, 1, 0), forward));
        float3 up = cross(forward, right);
        float t = tan(camera.fovY * 0.5);
        float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
        float3 dir = normalize(forward + right * ndc.x * t * viewportSize.x / viewportSize.y + up * ndc.y * t);
        float hit;
        color = float3(0.02, 0.03, 0.12);
        if (gsdfTrace(camera.eye, dir, 60.0, hit))
        {
            float3 p = camera.eye + dir * hit;
            float3 n = gsdfNormal(p);
            float3 l = normalize(lightPosition() - p);
            color = gsdfAlbedo(p) * (0.2 + 0.8 * saturate(dot(n, l)));
            color = pow(max(color, 0.0), 1.0 / 2.2);
        }
    }
    else if (giDebugMode == 4)
    {
        if (!isBackground(g.w))
        {
            uint2 size = fullSize();
            float aspect = float(size.x) / float(size.y);
            float3 world = viewToWorld(camera, viewPosition(camera, uv, g.w, aspect));
            float3x3 basis = cameraBasis(camera);
            float3 n = normalize(basis[0] * g.x + basis[1] * g.y + basis[2] * g.z);
            float3 e = ddgiSampleIrradiance(world, n);
            color = pow(max(e / (1.0 + e), 0.0), 1.0 / 2.2);
        }
    }
    else if (giDebugMode >= 5 && giDebugMode <= 8)
    {
        float4 r;
        uint cw, ch;
        switch (giDebugMode)
        {
        case 5: cascade0.GetDimensions(cw, ch); r = cascade0.Load(int3(int2(uv * float2(cw, ch)), 0)); break;
        case 6: cascade1.GetDimensions(cw, ch); r = cascade1.Load(int3(int2(uv * float2(cw, ch)), 0)); break;
        case 7: cascade2.GetDimensions(cw, ch); r = cascade2.Load(int3(int2(uv * float2(cw, ch)), 0)); break;
        default: cascade3.GetDimensions(cw, ch); r = cascade3.Load(int3(int2(uv * float2(cw, ch)), 0)); break;
        }
        color = pow(max(r.rgb / (1.0 + r.rgb), 0.0), 1.0 / 2.2);
    }
    else if (giDebugMode == 9)
    {
        color = pow(max(albedo.Load(int3(int2(uv * float2(w, h)), 0)).rgb, 0.0), 1.0 / 2.2);
    }
    if (outputEncodeGamma == 0)
        color = pow(max(color, 0.0), 2.2); // the window encodes: hand it linear values
    return float4(color, 1.0);
}
