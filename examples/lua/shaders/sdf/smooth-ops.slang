// Smooth boolean composition of signed distance fields.
//
// The hard booleans are min (union), max (intersection) and max(a, -b) (subtraction). Their
// smooth versions round off the crease where two shapes meet, over a blend radius k (in
// world units; 0 gives the hard version): the polynomial smooth minimum, as popularized by
// Inigo Quilez ("smooth minimum", iquilezles.org).
//
// Each shape also carries a color, and the composition blends the colors with the same
// weight it blends the distances, so a rounded joint fades from one shape's color to the
// other's. A subtraction's cut faces take the color of the shape that was cut away.

#pragma once

struct SdfSample
{
    float distance;
    float3 color;
};

SdfSample sdfSample(float distance, float3 color)
{
    SdfSample s;
    s.distance = distance;
    s.color = color;
    return s;
}

// a ∪ b
SdfSample sdfUnion(SdfSample a, SdfSample b, float k)
{
    if (k <= 0)
    {
        return a.distance <= b.distance ? a : b;
    }
    float h = saturate(0.5 + 0.5 * (b.distance - a.distance) / k); // how much is a
    return sdfSample(lerp(b.distance, a.distance, h) - k * h * (1 - h), lerp(b.color, a.color, h));
}

// a ∩ b
SdfSample sdfIntersect(SdfSample a, SdfSample b, float k)
{
    if (k <= 0)
    {
        return a.distance >= b.distance ? a : b;
    }
    float h = saturate(0.5 - 0.5 * (b.distance - a.distance) / k); // how much is a
    return sdfSample(lerp(b.distance, a.distance, h) + k * h * (1 - h), lerp(b.color, a.color, h));
}

// a minus b: a intersected with the outside of b.
SdfSample sdfSubtract(SdfSample a, SdfSample b, float k)
{
    return sdfIntersect(a, sdfSample(-b.distance, b.color), k);
}
