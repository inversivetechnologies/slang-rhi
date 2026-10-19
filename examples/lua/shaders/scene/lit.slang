// Lit pass: draws one object as seen by the camera, lit by the point light and shadowed
// by the shadow maps (see shadow-lookup.slang).

#include "shadow-lookup.slang"

struct Material
{
    float3 albedo;
    uint pattern;   // 0: plain, 1: the mesh's quad grid, 2: a checkerboard on the floor,
                    // 3: a checkerboard on every face (4 squares a meter, in the world),
                    // 4: emissive: its color, unlit (a light's marker)
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
uniform uint encodeGamma; // 1 if the window doesn't do the sRGB encoding itself

struct VertexOutput
{
    float4 position : SV_Position;
    float3 world : WORLD;
    float3 normal : NORMAL;
    nointerpolation float checker : CHECKER;
    nointerpolation float4 bodyMaterial : MATERIAL; // bodyVertexMain: albedo, pattern
};

float4 clipPosition(float3 world)
{
    float3 forward = normalize(camera.target - camera.eye);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float3 d = world - camera.eye;
    float3 view = float3(dot(d, right), dot(d, up), dot(d, forward));
    float focal = 1.0 / tan(camera.fovY * 0.5);
    const float zNear = 0.1;
    const float zFar = 100.0;
    return float4(view.x * focal * viewportSize.y / viewportSize.x, view.y * focal, (view.z - zNear) * zFar / (zFar - zNear), view.z);
}

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    MeshVertex vertex = vertices[vertexId];
    float3 world = transformPoint(transform, vertex.position.xyz);
    VertexOutput output;
    output.position = clipPosition(world);
    output.world = world;
    output.normal = transformNormal(transform, vertex.normal.xyz);
    output.checker = vertex.position.w;
    output.bodyMaterial = float4(0, 0, 0, 0);
    return output;
}

// Physics bodies, instanced: instance i is body i of the `bodies` buffer (scene-common.slang),
// which also holds its color and pattern.
[shader("vertex")]
VertexOutput bodyVertexMain(uint vertexId: SV_VertexID, uint instance: SV_InstanceID)
{
    MeshVertex vertex = vertices[vertexId];
    float3 world = bodyPoint(instance, vertex.position.xyz);
    VertexOutput output;
    output.position = clipPosition(world);
    output.world = world;
    output.normal = bodyNormal(instance, vertex.normal.xyz);
    output.checker = vertex.position.w;
    output.bodyMaterial = bodies[instance * kBodyStride + 3];
    return output;
}

// Fraction of the light reaching `world` (0: in shadow, 1: lit).
float shadowFactor(float3 world, float3 normal, float3 toLight, float3 lightPos)
{
    // Push the lookup off the surface along its normal, more so where the light grazes
    // it, so a surface doesn't shadow itself ("shadow acne").
    float grazing = 1.0 - saturate(dot(normal, toLight));
    float3 d = world + normal * (0.02 + 0.04 * grazing) - lightPos;
    return shadowVisibility(d, 0.02);
}

// The lit color of a surface point with material m, as written to the target.
float4 shade(VertexOutput input, Material m)
{
    float3 color;
    if (m.emissive > 0.5)
    {
        color = light.color * 1.5;
    }
    else if (m.pattern == 4)
    {
        color = m.albedo * 1.5;
    }
    else
    {
        float3 albedo = m.albedo;
        if (m.pattern == 1)
        {
            albedo *= input.checker > 0.5 ? 0.8 : 1.0;
        }
        else if (m.pattern == 2)
        {
            int2 cell = int2(floor(input.world.xz * 2.0));
            albedo *= ((cell.x + cell.y) & 1) != 0 ? 0.55 : 1.0;
        }
        else if (m.pattern == 3)
        {
            // Just inside the surface, so a face on a square's edge picks one side.
            int3 cell = int3(floor((input.world - normalize(input.normal) * 0.001) * 4.0));
            albedo *= ((cell.x + cell.y + cell.z) & 1) != 0 ? 0.35 : 1.0;
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
        color += pointLightsRadiance(input.position.xy, input.world, normal, toEye, albedo, 1.0, 1.0); // the unshadowed ones
    }

    color = color / (1.0 + color); // tone map: keep highlights from clipping
    if (encodeGamma != 0)
    {
        color = pow(max(color, 0.0), 1.0 / 2.2);
    }
    return float4(color, 1.0);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    return shade(input, material);
}

[shader("fragment")]
float4 bodyFragmentMain(VertexOutput input) : SV_Target
{
    Material m;
    m.albedo = input.bodyMaterial.rgb;
    m.pattern = uint(input.bodyMaterial.w);
    m.emissive = 0;
    return shade(input, m);
}
