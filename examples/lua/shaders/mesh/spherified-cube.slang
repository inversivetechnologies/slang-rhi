// Generates a spherified cube: every face of a cube is split into a grid of
// subdivision x subdivision quads, and each vertex is pushed onto the sphere by normalizing
// it.
//
// The mesh is a plain triangle list -- 6 vertices per quad, no index buffer -- so it can be
// drawn straight from the buffer with SV_VertexID. Quad (x, y) of face f starts at vertex
// ((f * subdivision + y) * subdivision + x) * 6.

#include "mesh-vertex.slang"

uniform uint subdivision; // quads along each edge of a cube face
uniform float radius;
RWStructuredBuffer<MeshVertex> vertices; // 6 * subdivision^2 * 6 vertices

// Each face as an outward normal and the two axes spanning it, with cross(u, v) == normal
// so that all faces wind the same way.
static const float3 kFaceNormal[6] = {
    float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0), float3(0, -1, 0), float3(0, 0, 1), float3(0, 0, -1),
};
static const float3 kFaceU[6] = {
    float3(0, 0, -1), float3(0, 0, 1), float3(1, 0, 0), float3(1, 0, 0), float3(1, 0, 0), float3(-1, 0, 0),
};
static const float3 kFaceV[6] = {
    float3(0, 1, 0), float3(0, 1, 0), float3(0, 0, -1), float3(0, 0, 1), float3(0, 1, 0), float3(0, 1, 0),
};

// Grid point (i, j) of a face, in [0, subdivision]^2, on the unit sphere.
float3 spherePoint(uint face, uint i, uint j)
{
    float2 uv = float2(i, j) / float(subdivision) * 2.0 - 1.0;
    float3 cubePoint = kFaceNormal[face] + uv.x * kFaceU[face] + uv.y * kFaceV[face];
    return normalize(cubePoint);
}

// One thread per quad: x and y pick the quad on its face, z is the face.
[shader("compute")]
[numthreads(8, 8, 1)]
void generateMain(uint3 tid: SV_DispatchThreadID)
{
    if (tid.x >= subdivision || tid.y >= subdivision || tid.z >= 6)
    {
        return;
    }
    uint face = tid.z;

    float3 corners[4] = {
        spherePoint(face, tid.x, tid.y),
        spherePoint(face, tid.x + 1, tid.y),
        spherePoint(face, tid.x + 1, tid.y + 1),
        spherePoint(face, tid.x, tid.y + 1),
    };
    // Two triangles per quad.
    const uint kCorner[6] = {0, 1, 2, 0, 2, 3};

    float checker = float((tid.x + tid.y) & 1);
    uint first = ((face * subdivision + tid.y) * subdivision + tid.x) * 6;
    for (uint k = 0; k < 6; ++k)
    {
        float3 direction = corners[kCorner[k]];
        MeshVertex vertex;
        vertex.position = float4(direction * radius, checker);
        vertex.normal = float4(direction, float(face));
        vertices[first + k] = vertex;
    }
}
