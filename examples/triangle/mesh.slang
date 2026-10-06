// Draws a mesh generated into a buffer (see spherified-cube.slang), spinning in front of a
// perspective camera. Vertices are fetched by SV_VertexID, so the pipeline has no vertex
// layout.

#include "mesh-vertex.slang"

StructuredBuffer<MeshVertex> vertices;
uniform float time;   // seconds, drives the spin
uniform float aspect; // window width / height

struct VertexOutput
{
    float4 position : SV_Position;
    float3 normal : NORMAL;
    nointerpolation float face : FACE;
    nointerpolation float checker : CHECKER;
};

float3 rotateY(float3 p, float angle)
{
    float c = cos(angle), s = sin(angle);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

float3 rotateX(float3 p, float angle)
{
    float c = cos(angle), s = sin(angle);
    return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    MeshVertex vertex = vertices[vertexId];
    float yaw = time * 0.5;
    float pitch = 0.45;
    float3 position = rotateX(rotateY(vertex.position.xyz, yaw), pitch);
    float3 normal = rotateX(rotateY(vertex.normal.xyz, yaw), pitch);

    // Camera at the origin looking down +z, the mesh 3 units in front of it.
    float3 view = position + float3(0, 0, 3);
    const float focal = 1.0 / tan(radians(30.0)); // 60 degree vertical field of view
    const float zNear = 0.1;
    const float zFar = 100.0;

    VertexOutput output;
    output.position = float4(view.x * focal / aspect, view.y * focal, (view.z - zNear) * zFar / (zFar - zNear), view.z);
    output.normal = normal;
    output.face = vertex.normal.w;
    output.checker = vertex.position.w;
    return output;
}

static const float3 kFaceColors[6] = {
    float3(0.90, 0.30, 0.25), float3(0.25, 0.70, 0.35), float3(0.25, 0.45, 0.90),
    float3(0.95, 0.75, 0.20), float3(0.70, 0.35, 0.85), float3(0.20, 0.75, 0.80),
};

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The light sits up and to the left of the camera.
    float3 toLight = normalize(float3(-0.5, 0.8, -0.6));
    float diffuse = saturate(dot(normalize(input.normal), toLight));
    // Alternate quads are darker, so the subdivision shows.
    float3 color = kFaceColors[uint(input.face)] * (input.checker > 0.5 ? 0.75 : 1.0);
    return float4(color * (0.25 + 0.75 * diffuse), 1.0);
}
