// A composition of SDF shapes as a DAG in a buffer, evaluated at a point.
//
// The script builds the composition in Lua (scripts/lib/sdf.lua) and compiles it to a flat
// list of nodes in evaluation order -- every node after the ones it reads. A node is either
// a primitive from common/sdfs.slang, or a smooth boolean (smooth-ops.slang) of two earlier
// nodes. Shared subtrees are compiled once, so a node's result may be read by several
// later ones: a DAG, not a tree.
//
// Results live in a small set of registers ("slots"): every node writes one, and reads its
// operands from others. The compiler reuses a slot once nothing reads it any more, so a
// composition of any size needs only as many slots as are alive at once.
//
// A node is kSdfNodeStride float4s:
//
//   [0]      op, input slot a, input slot b, output slot
//   [1..3]   parameters: a primitive's sizes, or an operator's blend radius in [1].x
//   [4..6]   primitives: the rows of the world-to-local affine transform (3 x 4)
//   [7]      primitives: rgb color, and the factor that turns local distances into world
//            ones (the transform's uniform scale)

#pragma once

#include "common/sdfs.slang"
#include "smooth-ops.slang"

static const uint kSdfNodeStride = 8;
static const uint kSdfMaxSlots = 16;

// Op codes; scripts/lib/sdf.lua has the same table.
static const uint kSdfSphere = 0;      // [1].x radius
static const uint kSdfCube = 1;        // [1].x half size
static const uint kSdfBox = 2;         // [1].xyz half sizes
static const uint kSdfEllipsoid = 3;   // [1].xyz radii
static const uint kSdfCapsule = 4;     // [1].x radius, [2].xyz a, [3].xyz b
static const uint kSdfPlane = 5;       // [1].xyz point, [2].xyz unit normal
static const uint kSdfCylinder = 6;    // [1].x radius, [1].y height (along y)
static const uint kSdfPrism = 7;       // [1].x sides, [1].y height (along y, circumradius 1)
static const uint kSdfTetrahedron = 8; // [1].xyz a, [2].xyz b, [3].xyz c, ([1].w, [2].w, [3].w) d
static const uint kSdfUnion = 16;      // [1].x blend radius
static const uint kSdfSubtract = 17;
static const uint kSdfIntersect = 18;

StructuredBuffer<float4> sdfNodes;
uniform uint sdfNodeCount;
uniform uint sdfResultSlot; // where the last node leaves the whole composition's result
uniform float smoothScale;  // multiplies every blend radius (1: as built)

float sdfPrimitive(uint op, float4 a, float4 b, float4 c, float3 q)
{
    switch (op)
    {
    case kSdfSphere: return SDF(Sphere(a.x), q);
    case kSdfCube: return SDF(Cube(a.x), q);
    case kSdfBox: return SDF(Box3D(a.xyz), q);
    case kSdfEllipsoid: return SDF(Elipse3D(a.xyz), q);
    case kSdfCapsule: return SDF(Capsule3D(a.x, b.xyz, c.xyz), q);
    case kSdfPlane: return SDF(Plane3D(a.xyz, b.xyz), q);
    case kSdfCylinder: return SDF(Cylinder(a.x, a.y), q);
    case kSdfPrism: return SDF(Prism(int(a.x), a.y), q);
    case kSdfTetrahedron: return SDF(Tetrah(a.xyz, b.xyz, c.xyz, float3(a.w, b.w, c.w)), q);
    default: return 1e9;
    }
}

// The composition's distance and color at p (in the composition's own space).
SdfSample evaluateSdf(float3 p)
{
    SdfSample slots[kSdfMaxSlots];
    [loop]
    for (uint i = 0; i < sdfNodeCount; ++i)
    {
        uint base = i * kSdfNodeStride;
        float4 header = sdfNodes[base];
        uint op = uint(header.x);
        uint output = min(uint(header.w), kSdfMaxSlots - 1);
        SdfSample result;
        if (op >= kSdfUnion)
        {
            SdfSample a = slots[min(uint(header.y), kSdfMaxSlots - 1)];
            SdfSample b = slots[min(uint(header.z), kSdfMaxSlots - 1)];
            float k = sdfNodes[base + 1].x * smoothScale;
            if (op == kSdfUnion)
                result = sdfUnion(a, b, k);
            else if (op == kSdfSubtract)
                result = sdfSubtract(a, b, k);
            else
                result = sdfIntersect(a, b, k);
        }
        else
        {
            float4 row0 = sdfNodes[base + 4];
            float4 row1 = sdfNodes[base + 5];
            float4 row2 = sdfNodes[base + 6];
            float3 q = float3(dot(row0.xyz, p) + row0.w, dot(row1.xyz, p) + row1.w, dot(row2.xyz, p) + row2.w);
            float4 colorScale = sdfNodes[base + 7];
            float d = sdfPrimitive(op, sdfNodes[base + 1], sdfNodes[base + 2], sdfNodes[base + 3], q);
            result = sdfSample(d * colorScale.w, colorScale.rgb);
        }
        slots[output] = result;
    }
    return slots[min(sdfResultSlot, kSdfMaxSlots - 1)];
}
