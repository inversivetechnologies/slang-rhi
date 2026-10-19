// The layout the tiled light culling (scene/light-culling.slang) writes and the shading
// (scene-common.slang's pointLightsRadiance) reads.
//
// The point lights: a buffer of 2 float4s a light (pointLightData), pointLightCount of them:
//   [2i]     position.xyz, range        [2i + 1]  color.rgb, intensity
//
// A view's tiles (lightTiles, in its view block): a header, then kTileStride uints a tile,
// row by row:
//   header   [0] tiles across  [1] tiles down  [2] tile size (pixels)  [3] unused
//   a tile   [0] how many lights reach it (at most kMaxLightsPerTile), then their indices

#pragma once

static const uint kMaxPointLights = 1024;
static const uint kLightTileSize = 16;    // the smallest tile; larger if a view has more tiles than fit
static const uint kMaxLightsPerTile = 127;
static const uint kTileStride = 128;      // the count and kMaxLightsPerTile indices
static const uint kTileHeader = 4;
