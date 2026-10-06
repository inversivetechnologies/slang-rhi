// Lit pass: draws one object as seen by the camera, lit by the point light and shadowed
// by the shadow atlas the shadow pass rendered (see scene-common.slang).

#include "scene-common.slang"

struct Material
{
    float3 albedo;
    uint pattern;   // 0: plain, 1: the mesh's quad grid, 2: a checkerboard on the floor
    float emissive; // 1: unlit, glows in the light's color (the light's marker)
};

struct Camera
{
    float3 eye;
    float fovY;   // vertical field of view, radians
    float3 target;
};

StructuredBuffer<MeshVertex> vertices;
uniform Transform transform;
uniform Material material;
uniform Camera camera;
uniform float2 viewportSize; // provided by the host: the size of the viewport drawn into
Texture2D<float> shadowMap;
uniform uint shadowFaceSize;
uniform uint encodeGamma; // 1 if the window doesn't do the sRGB encoding itself

struct VertexOutput
{
    float4 position : SV_Position;
    float3 world : WORLD;
    float3 normal : NORMAL;
    nointerpolation float checker : CHECKER;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    MeshVertex vertex = vertices[vertexId];
    float3 world = transformPoint(transform, vertex.position.xyz);

    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float3 d = world - camera.eye;
    float3 view = float3(dot(d, right), dot(d, up), dot(d, forward));
    float focal = 1.0 / tan(camera.fovY * 0.5);
    const float zNear = 0.1;
    const float zFar = 100.0;

    VertexOutput output;
    output.position =
        float4(view.x * focal * viewportSize.y / viewportSize.x, view.y * focal, (view.z - zNear) * zFar / (zFar - zNear), view.z);
    output.world = world;
    output.normal = transformNormal(transform, vertex.normal.xyz);
    output.checker = vertex.position.w;
    return output;
}

// Fraction of the light reaching `world` (0: in shadow, 1: lit), averaged over a 3x3
// texel neighborhood for soft edges.
float shadowFactor(float3 world, float3 normal, float3 toLight, float3 lightPos)
{
    // Push the lookup off the surface along its normal, more so where the light grazes
    // it, so a surface doesn't shadow itself ("shadow acne").
    float grazing = 1.0 - saturate(dot(normal, toLight));
    float3 d = world + normal * (0.02 + 0.04 * grazing) - lightPos;
    float current = length(d);

    uint face = cubeFaceOf(d);
    float2 texel = shadowFaceTexel(d, face, shadowFaceSize);
    int2 origin = int2(shadowFaceOrigin(face, shadowFaceSize));
    int last = int(shadowFaceSize) - 1;

    float lit = 0;
    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            // Stay inside this face's cell: the next cell over is a different view.
            int2 p = clamp(int2(texel) + int2(x, y), int2(0, 0), int2(last, last));
            float occluder = shadowMap.Load(int3(origin + p, 0));
            lit += current - 0.02 <= occluder ? 1.0 : 0.0;
        }
    }
    return lit / 9.0;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float3 color;
    if (material.emissive > 0.5)
    {
        color = light.color * 1.5;
    }
    else
    {
        float3 albedo = material.albedo;
        if (material.pattern == 1)
        {
            albedo *= input.checker > 0.5 ? 0.8 : 1.0;
        }
        else if (material.pattern == 2)
        {
            int2 cell = int2(floor(input.world.xz * 2.0));
            albedo *= ((cell.x + cell.y) & 1) != 0 ? 0.55 : 1.0;
        }

        float3 normal = normalize(input.normal);
        float3 lightPos = lightPosition();
        float3 toLight = lightPos - input.world;
        float distanceToLight = length(toLight);
        toLight /= distanceToLight;
        float3 toEye = normalize(camera.eye - input.world);

        // Inverse-square falloff, faded to zero at the light's range.
        float window = saturate(1.0 - pow(distanceToLight / light.range, 4.0));
        float attenuation = light.intensity * window * window / (1.0 + distanceToLight * distanceToLight);

        float diffuse = saturate(dot(normal, toLight));
        float specular = pow(saturate(dot(normal, normalize(toLight + toEye))), 48.0) * 0.5 * (diffuse > 0 ? 1 : 0);
        float shadow = shadowFactor(input.world, normal, toLight, lightPos);

        float3 ambient = albedo * float3(0.05, 0.06, 0.08);
        color = ambient + (albedo * diffuse + specular) * light.color * attenuation * shadow;
    }

    color = color / (1.0 + color); // tone map: keep highlights from clipping
    if (encodeGamma != 0)
    {
        color = pow(max(color, 0.0), 1.0 / 2.2);
    }
    return float4(color, 1.0);
}
