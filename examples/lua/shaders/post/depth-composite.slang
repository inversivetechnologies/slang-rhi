// Depth compositing: merges two separately rendered images -- each with its own color and
// depth buffer -- into one, per pixel, by which is nearer the camera.
//
// The fusion example renders the mesh scene (opaque, lit) and the Gaussian splats
// (blended, with premultiplied alpha) in passes of their own, then combines them here:
//
//   splats nearer:  splats over the mesh, by their alpha
//   mesh nearer:    the mesh; splats behind it are hidden
//
// Both depth buffers hold perspective depth (z/w) over the same near and far planes, so
// both are turned back into view distances to compare them.

Texture2D<float4> meshColor;  // linear color
Texture2D<float> meshDepth;
Texture2D<float4> splatColor; // display-space color, premultiplied alpha; 0 where no splat
Texture2D<float> splatDepth;
uniform float depthNear;
uniform float depthFar;
uniform uint encodeGamma; // 1 if the window doesn't do the sRGB encoding itself
uniform uint showMode;    // 0: combined, 1: mesh only, 2: splats only, 3: the depth buffers

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

// A depth buffer value back to the distance along the view direction.
float viewDistance(float depth)
{
    return depthNear * depthFar / (depthFar - depth * (depthFar - depthNear));
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    int3 texel = int3(int2(input.position.xy), 0);
    float3 mesh = meshColor.Load(texel).rgb;
    float meshDistance = viewDistance(meshDepth.Load(texel));
    float splatDistance = viewDistance(splatDepth.Load(texel));

    // The splats' color in linear space: undo the premultiplication to decode it.
    float4 splat = splatColor.Load(texel);
    float3 splatLinear = splat.a > 0 ? pow(max(splat.rgb / splat.a, 0.0), 2.2) * splat.a : float3(0, 0, 0);

    float3 color;
    if (showMode == 1)
    {
        color = mesh;
    }
    else if (showMode == 2)
    {
        color = splatLinear;
    }
    else if (showMode == 3)
    {
        // Nearer is brighter; the mesh's depth in blue, the splats' in orange.
        float meshShade = saturate(1.0 - meshDistance / 12.0);
        float splatShade = saturate(1.0 - splatDistance / 12.0);
        color = float3(0.25, 0.55, 1.0) * meshShade;
        if (splatDistance < meshDistance)
        {
            color = float3(1.0, 0.55, 0.15) * splatShade;
        }
    }
    else
    {
        // Where no splat is opaque enough to be in the splats' depth buffer, its depth is
        // the far plane; faint fringes there still go over whatever the mesh shows.
        color = splatDistance <= meshDistance ? splatLinear + (1.0 - splat.a) * mesh : mesh;
    }

    if (encodeGamma != 0)
    {
        color = pow(max(color, 0.0), 1.0 / 2.2);
    }
    return float4(color, 1.0);
}
