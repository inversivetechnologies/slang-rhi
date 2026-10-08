#pragma once

// Levels of detail for Gaussian splats, built when a splat PLY file is imported
// (rhi.load_ply in example-lua.cpp).
//
// The splats are clustered into a tree: split top-down at the median of their longest
// axis, eight children per node, until every leaf is one of the file's splats. Each inner
// node is one more Gaussian, merged from its children so that it keeps their weighted mean
// and covariance (moment matching), their averaged color (all spherical harmonics bands)
// and about their coverage. It is appended to the file's records in the same layout, so
// every shader that reads a splat reads a merged one the same way.
//
// For choosing which splats to draw, every node gets a bounding sphere, which contains its
// children's (a leaf's is a point: it is always small enough), and every entry knows its
// parent. So any measure of on-screen size that grows with radius and shrinks with
// distance never grows from a node to its children. Drawing an entry exactly when it is
// small enough and its parent isn't then draws one entry on every path from the root to a
// leaf: a consistent cut through the tree, decided by each entry on its own (in parallel,
// on the GPU: shaders/splat/lod.slang).
//
// The file's splats are reordered to the tree's order: siblings are next to each other, so
// that neighboring GPU threads read the same parent.

#include <cstdint>
#include <string>
#include <vector>

namespace splatlod {

// Where a 3DGS file's properties sit in a record (offsets in floats; -1 if missing).
struct Layout
{
    uint32_t stride = 0;
    int position = -1; // x, y, z
    int scale = -1;    // scale_0..2: log of the scale
    int rotation = -1; // rot_0..3: quaternion w, x, y, z
    int opacity = -1;  // logit of the opacity
    int dc = -1;       // f_dc_0..2
    int rest = -1;     // f_rest_*
    int restCount = 0;

    bool isSplats() const { return stride > 0 && position >= 0 && scale >= 0 && rotation >= 0 && opacity >= 0 && dc >= 0; }
};

Layout findLayout(const std::vector<std::string>& properties);

struct Result
{
    uint32_t leafCount = 0;  // the file's splats: entries 0 .. leafCount - 1
    uint32_t entryCount = 0; // leaves and inner nodes
    uint32_t levels = 0;     // the tree's depth: leaves are level 0
    // Per entry, its parent's entry index; UINT32_MAX at the root.
    std::vector<uint32_t> parent;
    // Per node (entry leafCount + k is node k), 4 floats: its bounding sphere's center and
    // radius, in the file's frame.
    std::vector<float> nodeBounds;
    // Per entry, its level: 0 for a leaf, the height above the leaves for a node.
    std::vector<uint32_t> level;
    // The reordering: leaf k is the file's splat order[k].
    std::vector<uint32_t> order;
};

// Reorders the file's records in `data` (leafCount records of layout.stride floats) to the
// tree's order, and appends the inner nodes' records.
Result build(const Layout& layout, std::vector<float>& data, uint32_t leafCount);

// As build, but through a cache file: if `cachePath` holds levels built for the same
// source (`sourceKey`: e.g. its size and modification time) and layout, they are read
// from it; else they are built and written to it. `cached` says which happened.
Result buildCached(
    const Layout& layout,
    std::vector<float>& data,
    uint32_t leafCount,
    const std::string& cachePath,
    uint64_t sourceKey,
    bool& cached
);

} // namespace splatlod
