// The global SDF's voxels while it is built (global-sdf-bake.slang, global-sdf-splats.slang):
// one uint each, its distance quantized to 16 bits (over [-band, band]) above its albedo
// (RGB 5:6:5), so that an atomic min keeps the nearest distance and its owner's color.

#pragma once

uniform float3 gsdfOrigin;
uniform float gsdfVoxel;
uniform uint gsdfResolution;
uniform float gsdfBand;

RWStructuredBuffer<uint> gsdfVoxels;


uint encodeVoxel(float d, float3 color)
{
    uint q = uint(saturate((d + gsdfBand) / (2.0 * gsdfBand)) * 65535.0 + 0.5);
    uint3 c = uint3(saturate(color) * float3(31.0, 63.0, 31.0) + 0.5);
    return (q << 16) | (c.r << 11) | (c.g << 5) | c.b;
}

float decodeDistance(uint v)
{
    return float(v >> 16) / 65535.0 * 2.0 * gsdfBand - gsdfBand;
}

float3 decodeAlbedo(uint v)
{
    return float3((v >> 11) & 31u, (v >> 5) & 63u, v & 31u) / float3(31.0, 63.0, 31.0);
}

uint voxelIndex(uint3 v)
{
    return (v.z * gsdfResolution + v.y) * gsdfResolution + v.x;
}

float3 voxelCenter(uint3 v)
{
    return gsdfOrigin + (float3(v) + 0.5) * gsdfVoxel;
}

