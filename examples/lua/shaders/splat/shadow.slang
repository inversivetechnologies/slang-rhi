// Splat shadows, step 2: draws the splats into one cube face of a translucent shadow map
// -- an atlas laid out like the scene's (scene/scene-common.slang), with its own texture.
//
// A Gaussian has no hard surface: light passing through splats is dimmed by each in turn,
// to a transmittance of prod(1 - alpha_i). So the splats aren't drawn as solid casters.
// Each texel of the map holds two things instead, both gathered by blending ("accumulate":
// rgb adds, alpha keeps the minimum):
//
//   r  optical depth: the sum of -ln(1 - alpha_i) over every splat in that direction, so
//      that the transmittance through all of them is exp(-r)
//   a  the distance from the light to the nearest of those splats
//
// scene/lit.slang then dims a point by exp(-r) if it is farther from the light than `a`,
// i.e. behind the splats -- softly and without gaps, because faint splats count too.
//
// layersFragmentMain draws the same splats again, into the deep opacity map
// (splatShadowLayers, see scene/shadow-lookup.slang): it reads the nearest splat's distance
// from the map above, and adds a splat's optical depth to every layer that reaches past
// it. That says how much of the splats lies in front of a point -- what a splat behind
// others needs to be shadowed by them.
//
// Each splat is drawn as its actual Gaussian, seen from the light: its 3D covariance is
// projected onto the plane facing the light, and one triangle covers the resulting
// ellipse out to 3 sigma. Splats this cube face can't see collapse to nothing in the
// vertex shader.
//
// Which splats: the ones shadow-select.slang picked this frame (the levels of detail, seen
// from the light), with their instances, packed in `shadowList`. Each is placed by its
// instance here. Triangles past the picked ones draw nothing.

#include "scene/shadow-lookup.slang"
#include "splat/ply.slang"
#include "splat/clip.slang"

StructuredBuffer<float4> shadowCasters; // see shadow-casters.slang: in the file's frame
StructuredBuffer<uint2> shadowList;     // the splats to draw and their instances (shadow-select.slang)
StructuredBuffer<uint> shadowCount;     // [0]: how many (maybe more than fit)
uniform uint shadowCapacity;            // how many fit
uniform uint face;                      // which cube face this draw renders

struct VertexOutput
{
    float4 position : SV_Position;
    float3 world : WORLD;
    float2 offset : OFFSET; // position on the ellipse, in units of its 3-sigma half axes
    nointerpolation float opacity : OPACITY;
    // Clipping per pixel (clip.slang), as render.slang does, along rays from the light:
    // the picked splat's slot in shadowList + 1, or 0 not to clip.
    nointerpolation uint clipSlot : CLIP;
};

// A picked splat's center and covariance in the world: its caster, placed by its instance.
void placedCaster(uint2 picked, out float4 centerOpacity, out float3x3 covariance)
{
    centerOpacity = shadowCasters[3 * picked.x];
    float4 c0 = shadowCasters[3 * picked.x + 1];
    float4 c1 = shadowCasters[3 * picked.x + 2];
    float3x3 fileCovariance = float3x3(c0.x, c0.y, c0.z, c0.y, c0.w, c1.x, c0.z, c1.x, c1.y);
    beginInstance(picked.y);
    centerOpacity.xyz = splatPlace(centerOpacity.xyz);
    float3x3 yaw = splatYaw();
    covariance = mul(yaw, mul(fileCovariance, transpose(yaw))) * (placement.scale * placement.scale);
}

// Whether the fragment is clipped away: the splat's densest point along the ray from the
// light through it is outside what the clip field keeps.
bool clippedAway(VertexOutput input)
{
    if (input.clipSlot == 0)
    {
        return false;
    }
    float4 centerOpacity;
    float3x3 covariance;
    placedCaster(shadowList[input.clipSlot - 1], centerOpacity, covariance);
    float3 lightPos = lightPosition();
    float3 ray = normalize(input.world - lightPos);
    return clipAtRay(lightPos, ray, centerOpacity.xyz, covariance) < 0;
}

// How opaque a splat must be at a texel to count as the nearest splat there.
static const float kNearestOpacity = 0.2;

// An equilateral triangle around the unit circle.
static const float2 kTriangle[3] = { float2(0, 2), float2(-1.7320508, -1), float2(1.7320508, -1) };

[shader("vertex")]
VertexOutput vertexMain(uint vertexId: SV_VertexID)
{
    VertexOutput output;
    output.position = float4(0, 0, 0, 1); // nothing drawn, unless the splat is in view
    output.world = float3(0, 0, 0);
    output.offset = float2(0, 0);
    output.opacity = 0;
    output.clipSlot = 0;

    uint slot = vertexId / 3;
    if (slot >= min(shadowCount[0], shadowCapacity))
    {
        return output;
    }
    // Into the world, by its instance: turned and scaled like its center.
    float4 centerOpacity;
    float3x3 covariance;
    placedCaster(shadowList[slot], centerOpacity, covariance);
    if (centerOpacity.w <= 0)
    {
        return output;
    }

    float3 lightPos = lightPosition();
    float3 d = centerOpacity.xyz - lightPos;

    // Skip splats this face can't see: behind it, or outside its 90-degree frustum. Three
    // sigma along the largest axis bounds the splat.
    float extent = 3.0 * sqrt(max(covariance[0][0], max(covariance[1][1], covariance[2][2])) * 3.0);
    uint clipClass = clipClassify(centerOpacity.xyz, extent);
    if (clipClass == 2)
    {
        return output; // cut away wholly: casts nothing
    }
    CubeFace f = cubeFace(face);
    float z = dot(d, f.forward);
    if (z + extent < kShadowNear || abs(dot(d, f.right)) > z + 2 * extent || abs(dot(d, f.up)) > z + 2 * extent)
    {
        return output;
    }

    // The covariance seen from the light: projected onto the plane facing it.
    float3 normal = normalize(d);
    float3 u = normalize(cross(abs(normal.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0), normal));
    float3 v = cross(normal, u);
    float a = dot(u, mul(covariance, u));
    float b = dot(u, mul(covariance, v));
    float c = dot(v, mul(covariance, v));

    // Its ellipse: the eigenvectors of that 2x2 covariance, at 3 sigma.
    float mid = 0.5 * (a + c);
    float spread = sqrt(max(mid * mid - (a * c - b * b), 0.0));
    float lambda1 = mid + spread;
    float lambda2 = max(mid - spread, 1e-10);
    float2 axis = abs(b) > 1e-12 ? normalize(float2(b, lambda1 - a)) : (a >= c ? float2(1, 0) : float2(0, 1));
    float3 axis1 = (u * axis.x + v * axis.y) * 3.0 * sqrt(lambda1);
    float3 axis2 = (u * -axis.y + v * axis.x) * 3.0 * sqrt(lambda2);

    float2 corner = kTriangle[vertexId % 3];
    float3 world = centerOpacity.xyz + axis1 * corner.x + axis2 * corner.y;

    output.position = cubeFaceClip(face, world - lightPos, light.range);
    output.world = world;
    output.offset = corner;
    output.opacity = centerOpacity.w;
    output.clipSlot = clipClass == 1 ? slot + 1 : 0;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    // The Gaussian falls off over the half axes, which are 3 sigma long: exp(-(3r)^2 / 2).
    float alpha = min(0.99, input.opacity * exp(-4.5 * dot(input.offset, input.offset)));
    if (alpha < 1.0 / 255.0 || clippedAway(input))
    {
        discard;
    }
    // Only splats that are fairly opaque here count as the nearest: a few faint strays in
    // front of a surface would otherwise put every splat of it "behind", in the shadow of
    // everything. They still dim the light.
    float nearest = alpha >= kNearestOpacity ? distance(input.world, lightPosition()) : 60000.0;
    return float4(-log(1.0 - alpha), 0, 0, nearest);
}

// For the deep opacity map, drawn with "additive" blending after fragmentMain's map is
// complete; that map is read here (splatShadowMap) at the same atlas texel.
[shader("fragment")]
float4 layersFragmentMain(VertexOutput input) : SV_Target
{
    float alpha = min(0.99, input.opacity * exp(-4.5 * dot(input.offset, input.offset)));
    if (alpha < 1.0 / 255.0 || clippedAway(input))
    {
        discard;
    }
    float opticalDepth = -log(1.0 - alpha);
    float nearest = splatShadowMap.Load(int3(int2(input.position.xy), 0)).a;
    float behind = distance(input.world, lightPosition()) - nearest;
    float4 layers;
    [unroll]
    for (int k = 0; k < 4; ++k)
    {
        layers[k] = behind < kSplatLayerBounds[k] ? opticalDepth : 0.0;
    }
    return layers;
}
