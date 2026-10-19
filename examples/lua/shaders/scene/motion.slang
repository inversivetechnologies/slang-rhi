// Motion vectors for physics bodies (scene-common.slang's `bodies`): each pixel of a body
// gets how far its surface point moved since the frame before, in the world -- the
// previous position minus the current one (0 for one that stood still). The camera's own
// motion isn't in it: the screen-space effects' temporal pass (post/ssao.slang) adds that.
//
// A body moves rigidly, so the motion is affine over each triangle: per vertex, then
// interpolated, it is exact.

#include "scene-common.slang"

StructuredBuffer<MeshVertex> vertices;

struct MotionCamera
{
    float3 eye;
    float fovY;
    float3 target;
};
uniform MotionCamera camera;
uniform float2 viewportSize; // provided by the host

struct VertexOutput
{
    float4 position : SV_Position;
    float3 motion : MOTION;
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
    output.motion = bodyPreviousPoint(instance, vertex.position.xyz) - world;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    return float4(input.motion, 1.0);
}
