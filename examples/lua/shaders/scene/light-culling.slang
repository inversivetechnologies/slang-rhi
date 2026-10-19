// Tiled light culling: for each screen tile of a view, which of the scene's point lights
// can reach it. Shading (scene-common.slang's pointLightsRadiance) then adds only those.
//
// Dispatched over the view's pixels, in groups of 16 x 16: a group per smallest tile.
// Tiles are 16 pixels square unless the view has more of them than its buffer holds; then
// 32, 64, ... and only the groups at a tile's corner work. A group's threads test the
// lights between them, each light's sphere (its range) against the tile's frustum -- the
// four planes through the eye and the tile's edges, and the view's near and far planes --
// and append those that touch it to a list in groupshared memory.
//
// No depth bounds: the meshes shade in the same pass that writes their depth, so the
// tiles can't know it yet. A tile whose lights are many but far behind what it shows
// still loops over them; the range test in the shading drops them cheaply.

#include "light-tiles-layout.slang"

StructuredBuffer<float4> pointLightData;
uniform uint pointLightCount;
RWStructuredBuffer<uint> lightTiles;
uniform uint lightTileCapacity; // the tiles lightTiles holds

struct CullCamera
{
    float3 eye;
    float fovY;
    float3 target;
};
uniform CullCamera camera;      // the view block's
uniform float2 viewportSize;    // provided by the host: the view's size (the dispatch's texture)

static const float kNear = 0.1;
static const float kFar = 100.0;

groupshared uint gCount;
groupshared uint gList[kMaxLightsPerTile];

uint tileSizeFor(float2 size)
{
    uint tileSize = kLightTileSize;
    [loop]
    for (int i = 0; i < 8; ++i)
    {
        uint tiles = uint(ceil(size.x / float(tileSize))) * uint(ceil(size.y / float(tileSize)));
        if (tiles <= lightTileCapacity)
            break;
        tileSize *= 2;
    }
    return tileSize;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void cullMain(uint3 group: SV_GroupID, uint index: SV_GroupIndex)
{
    uint tileSize = tileSizeFor(viewportSize);
    uint tilesX = uint(ceil(viewportSize.x / float(tileSize)));
    uint tilesY = uint(ceil(viewportSize.y / float(tileSize)));
    uint2 origin = group.xy * kLightTileSize;
    bool corner = all(origin % tileSize == 0);
    uint2 tile = origin / tileSize;

    // ([branch]: fxc, for D3D11, fails on writes in branches it flattens.)
    [branch]
    if (index == 0)
    {
        gCount = 0;
        [branch]
        if (all(group.xy == 0))
        {
            lightTiles[0] = tilesX;
            lightTiles[1] = tilesY;
            lightTiles[2] = tileSize;
            lightTiles[3] = 0;
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // The tile's side planes, in view space (x right, y up, z forward), facing inward.
    float t = tan(camera.fovY * 0.5);
    float aspect = viewportSize.x / viewportSize.y;
    float x0 = (float(tile.x * tileSize) / viewportSize.x * 2 - 1) * t * aspect;
    float x1 = (float((tile.x + 1) * tileSize) / viewportSize.x * 2 - 1) * t * aspect;
    float y0 = (1 - float((tile.y + 1) * tileSize) / viewportSize.y * 2) * t; // bottom
    float y1 = (1 - float(tile.y * tileSize) / viewportSize.y * 2) * t;       // top
    float3 left = normalize(float3(1, 0, -x0));
    float3 right = normalize(float3(-1, 0, x1));
    float3 bottom = normalize(float3(0, 1, -y0));
    float3 top = normalize(float3(0, -1, y1));

    float3 forward = normalize(camera.target - camera.eye);
    float3 rightAxis = normalize(cross(float3(0, 1, 0), forward));
    float3 upAxis = cross(forward, rightAxis);

    [branch]
    if (corner)
    {
        [loop]
        for (uint i = index; i < min(pointLightCount, kMaxPointLights); i += 256)
        {
            float4 placement = pointLightData[2 * i];
            float3 d = placement.xyz - camera.eye;
            float3 c = float3(dot(d, rightAxis), dot(d, upAxis), dot(d, forward));
            float r = placement.w;
            bool inside = c.z + r > kNear && c.z - r < kFar && dot(left, c) > -r && dot(right, c) > -r &&
                          dot(bottom, c) > -r && dot(top, c) > -r;
            [branch]
            if (inside)
            {
                uint slot;
                InterlockedAdd(gCount, 1, slot);
                [branch]
                if (slot < kMaxLightsPerTile)
                    gList[slot] = i;
            }
        }
    }
    GroupMemoryBarrierWithGroupSync();

    uint tileIndex = tile.y * tilesX + tile.x;
    [branch]
    if (!corner || tileIndex >= lightTileCapacity)
        return;
    uint base = kTileHeader + tileIndex * kTileStride;
    uint count = min(gCount, kMaxLightsPerTile);
    [branch]
    if (index == 0)
        lightTiles[base] = count;
    [loop]
    for (uint k = index; k < count; k += 256)
        lightTiles[base + 1 + k] = gList[k];
}
