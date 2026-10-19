// The bodies' albedo, for the GI's G-buffer (lib/scene/gi.lua: what the indirect light is
// multiplied by): drawn again, as the motion pass draws them, each pixel its body's color
// with the patterns lit.slang gives it (the floor's checker, the checker on every face);
// an emissive body (pattern 4) takes none.

#include "scene-common.slang"

StructuredBuffer<MeshVertex> vertices;

struct AlbedoCamera
{
    float3 eye;
    float fovY;
    float3 target;
};
uniform AlbedoCamera camera;
uniform float2 viewportSize; // provided by the host

struct VertexOutput
{
    float4 position : SV_Position;
    float3 world : WORLD;
    float3 normal : NORMAL;
    nointerpolation float4 material : MATERIAL; // color, pattern
};

// As lit.slang projects.
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
VertexOutput bodyVertexMain(uint vertexId: SV_VertexID, uint instance: SV_InstanceID)
{
    MeshVertex vertex = vertices[vertexId];
    float3 world = bodyPoint(instance, vertex.position.xyz);
    VertexOutput output;
    output.position = clipPosition(world);
    output.world = world;
    output.normal = bodyNormal(instance, vertex.normal.xyz);
    output.material = bodies[instance * kBodyStride + 3];
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    float3 albedo = input.material.rgb;
    uint pattern = uint(input.material.w);
    if (pattern == 2)
    {
        int2 cell = int2(floor(input.world.xz * 2.0));
        albedo *= ((cell.x + cell.y) & 1) != 0 ? 0.55 : 1.0;
    }
    else if (pattern == 3)
    {
        int3 cell = int3(floor((input.world - normalize(input.normal) * 0.001) * 4.0));
        albedo *= ((cell.x + cell.y + cell.z) & 1) != 0 ? 0.35 : 1.0;
    }
    else if (pattern == 4)
    {
        albedo = float3(0, 0, 0);
    }
    return float4(albedo, 1.0);
}
