// What DLSS reads besides the view's image, at the drawn size: the depth of what each pixel
// shows (the nearest of the three depth buffers, z/w as a depth buffer has it), and its
// motion vector -- in pixels, from where it is to where it was the frame before (the camera
// moved, and the surface by its own motion: reprojection.slang), as DLSS takes them.

#include "reprojection.slang"

uniform float2 viewportSize; // provided by the host: the drawn size (the dispatch's texture)

[shader("compute")]
[numthreads(8, 8, 1)]
void inputsMain(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float> dlssDepth, uniform RWTexture2D<float4> dlssMotion)
{
    if (tid.x >= uint(viewportSize.x) || tid.y >= uint(viewportSize.y))
        return;
    uint2 size = fullSize();
    int3 t = int3(tid.xy, 0);
    float depth = min(meshDepth.Load(t), min(splatDepth.Load(t), sdfDepth.Load(t)));
    dlssDepth[tid.xy] = depth;

    float aspect = float(size.x) / float(size.y);
    float z = viewDistance(depth);
    float2 uv = (float2(tid.xy) + 0.5) / float2(size);
    float3 world = viewToWorld(camera, viewPosition(camera, uv, z, aspect));
    float3 before = worldToView(prevCamera, previousWorld(int2(tid.xy), z, world));
    float2 motion = float2(0, 0);
    if (before.z > depthNear)
        motion = (projectToUv(prevCamera, before, aspect) - uv) * float2(size);
    dlssMotion[tid.xy] = float4(motion, 0, 0);
}
