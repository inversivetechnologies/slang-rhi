// Clipping Gaussian splats by a signed distance field, per pixel: the splats' equivalent
// of clip() in a fragment shader.
//
// A splat's fragment isn't a point: it is the 3D Gaussian integrated along the pixel's
// ray. So it gets the point where the Gaussian is densest along that ray -- for the
// flat, surface-hugging splats a capture is made of, a point on the surface:
//
//     t* = dot(mu - o, inv(Sigma) d) / dot(d, inv(Sigma) d),    p = o + t* d
//
// and that point is tested against the field: clip(clipSide(p)). Every pixel of a splat
// tests its own ray, so the cut follows the field exactly, across a splat, whatever its
// size -- a merged splat of the levels of detail too.
//
// The vertices of a splat to clip hand their fragments only which splat it is (one flat
// value); those fragments read the splat again, to find its center and covariance.
//
// Most splats are wholly on one side, which the field says without a pixel's help: a
// signed distance field changes by at most the distance moved, so a splat whose center is
// farther from the surface than its 3-sigma extent is wholly in or out. Only the splats
// across it are tested per pixel (clipClassify).
//
// The field: a union of spheres and boxes (clipShapes), each moving to and fro along an
// axis, the boxes turning, all by `time`. The host provides no per-frame data for it.

#pragma once

#include "common/time.slang"

// Three float4s per shape:
//   [0] xyz: center (in the world), w: 0 a sphere, 1 a box
//   [1] xyz: radius (x) or half extents, w: turning speed about y (radians per second)
//   [2] xyz: how far it moves to either side of the center, w: how fast (radians per second)
StructuredBuffer<float4> clipShapes;
uniform uint clipShapeCount;
// 0: no clipping. 1: carve the shapes out (cut away what is inside them). 2: keep only
// what is inside them.
uniform uint clipMode;

float clipShapeDistance(uint k, float3 p)
{
    float4 a = clipShapes[3 * k];
    float4 b = clipShapes[3 * k + 1];
    float4 c = clipShapes[3 * k + 2];
    float3 center = a.xyz + c.xyz * sin(time * c.w);
    float3 q = p - center;
    if (a.w < 0.5)
    {
        return length(q) - b.x;
    }
    // A box, turned about y: into its frame.
    float angle = time * b.w;
    float cs = cos(angle), sn = sin(angle);
    q = float3(cs * q.x - sn * q.z, q.y, sn * q.x + cs * q.z);
    float3 d = abs(q) - b.xyz;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

// The field: the union of the shapes (negative inside).
float clipDistance(float3 p)
{
    float d = 1e30;
    for (uint k = 0; k < clipShapeCount; ++k)
    {
        d = min(d, clipShapeDistance(k, p));
    }
    return d;
}

// What is kept is where this is >= 0, as for clip(): outside the shapes when carving,
// inside them when keeping.
float clipSide(float3 p)
{
    float d = clipDistance(p);
    return clipMode == 2 ? -d : d;
}

// A splat centered at `center`, reaching `extent` (3 sigma) from it: 0 wholly kept (or no
// clipping), 1 across the surface (to clip per pixel), 2 wholly cut away.
uint clipClassify(float3 center, float extent)
{
    if (clipMode == 0)
    {
        return 0;
    }
    float side = clipSide(center);
    if (side >= extent)
    {
        return 0;
    }
    if (side <= -extent)
    {
        return 2;
    }
    return 1;
}

// The inverse of a splat's covariance (symmetric), as a float3x3; a touch of its largest
// entry is added to the diagonal so that very flat splats stay invertible.
float3x3 clipInverseCovariance(float3x3 m)
{
    float epsilon = 1e-6 * max(m[0][0], max(m[1][1], m[2][2]));
    m[0][0] += epsilon;
    m[1][1] += epsilon;
    m[2][2] += epsilon;
    float3x3 adjugate = float3x3(
        m[1][1] * m[2][2] - m[1][2] * m[2][1], m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1],
        m[1][2] * m[2][0] - m[1][0] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2],
        m[1][0] * m[2][1] - m[1][1] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]
    );
    float det = m[0][0] * adjugate[0][0] + m[0][1] * adjugate[1][0] + m[0][2] * adjugate[2][0];
    return adjugate / det;
}

// Where along the ray from `origin` in `direction` the splat (center `mu`, inverse
// covariance `inverse`) is densest.
float3 clipRayPeak(float3 origin, float3 direction, float3 mu, float3x3 inverse)
{
    float3 w = mul(inverse, direction);
    float t = dot(mu - origin, w) / max(dot(direction, w), 1e-30);
    return origin + direction * t;
}

// The pixel's verdict for a splat (center `mu`, covariance `covariance`, in the world)
// along a ray: >= 0 kept. For clip(). The splat's data isn't handed down from its
// vertices -- a dozen more values for every vertex of millions of small quads would cost
// more than the clipping -- but read again here, by the few fragments that need it.
float clipAtRay(float3 origin, float3 direction, float3 mu, float3x3 covariance)
{
    return clipSide(clipRayPeak(origin, direction, mu, clipInverseCovariance(covariance)));
}
