// Shadow pass: renders one object into one face of the light's shadow atlas, writing the
// distance from the light (see scene-common.slang). Drawn into an r32f target with depth
// testing, so each texel keeps the nearest surface.

#include "scene-common.slang"

StructuredBuffer<MeshVertex> vertices;
uniform Transform transform;
uniform uint face; // which cube face this draw renders (its viewport picks the atlas cell)

struct VertexOutput
{
    float4 position : SV_Position;
    float3 world : WORLD;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    float3 world = transformPoint(transform, vertices[vertexId].position.xyz);
    VertexOutput output;
    output.position = cubeFaceClip(face, world - lightPosition(), light.range);
    output.world = world;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    return float4(distance(input.world, lightPosition()), 0, 0, 0);
}
