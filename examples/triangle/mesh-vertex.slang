// A vertex of a generated mesh, as spherified-cube.slang writes it and mesh.slang reads it.
//
// Only float4s, so the layout (32 bytes) is the same on every backend: a float3 would be
// padded differently by D3D and Vulkan structured buffers.
struct MeshVertex
{
    float4 position; // xyz: position, w: checker parity of the quad (0 or 1)
    float4 normal;   // xyz: unit normal, w: index of the cube face (0..5)
};
