// Levels of detail for Gaussian splats: see splat-lod.h.

#include "splat-lod.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <functional>

namespace splatlod {

namespace {

constexpr uint32_t kBranching = 8; // children per node: three median splits
constexpr float kMinScale = 1e-7f;

using Vec3 = std::array<double, 3>;
// A symmetric 3x3 matrix: xx, xy, xz, yy, yz, zz.
using Sym3 = std::array<double, 6>;

// What merging needs of an entry, leaf or node.
struct Gaussian
{
    Vec3 mean;
    Sym3 covariance;
    double alpha;  // opacity
    double area;   // s0 s1 + s1 s2 + s0 s2: proportional to its mean projected area
    double radius; // a sphere around it: its children's, or 3 sigma for a leaf
};

double sigmoid(double x)
{
    return 1.0 / (1.0 + std::exp(-x));
}

// The 3x3 rotation of a unit quaternion (w, x, y, z), as ply.slang builds it.
void quaternionToMatrix(const double q[4], double m[3][3])
{
    double w = q[0], x = q[1], y = q[2], z = q[3];
    m[0][0] = 1 - 2 * (y * y + z * z);
    m[0][1] = 2 * (x * y - w * z);
    m[0][2] = 2 * (x * z + w * y);
    m[1][0] = 2 * (x * y + w * z);
    m[1][1] = 1 - 2 * (x * x + z * z);
    m[1][2] = 2 * (y * z - w * x);
    m[2][0] = 2 * (x * z - w * y);
    m[2][1] = 2 * (y * z + w * x);
    m[2][2] = 1 - 2 * (x * x + y * y);
}

// The unit quaternion (w, x, y, z) of a rotation matrix (Shepperd's method).
void matrixToQuaternion(const double m[3][3], double q[4])
{
    double trace = m[0][0] + m[1][1] + m[2][2];
    if (trace > 0)
    {
        double s = 0.5 / std::sqrt(trace + 1.0);
        q[0] = 0.25 / s;
        q[1] = (m[2][1] - m[1][2]) * s;
        q[2] = (m[0][2] - m[2][0]) * s;
        q[3] = (m[1][0] - m[0][1]) * s;
    }
    else if (m[0][0] > m[1][1] && m[0][0] > m[2][2])
    {
        double s = 2.0 * std::sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]);
        q[0] = (m[2][1] - m[1][2]) / s;
        q[1] = 0.25 * s;
        q[2] = (m[0][1] + m[1][0]) / s;
        q[3] = (m[0][2] + m[2][0]) / s;
    }
    else if (m[1][1] > m[2][2])
    {
        double s = 2.0 * std::sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]);
        q[0] = (m[0][2] - m[2][0]) / s;
        q[1] = (m[0][1] + m[1][0]) / s;
        q[2] = 0.25 * s;
        q[3] = (m[1][2] + m[2][1]) / s;
    }
    else
    {
        double s = 2.0 * std::sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]);
        q[0] = (m[1][0] - m[0][1]) / s;
        q[1] = (m[0][2] + m[2][0]) / s;
        q[2] = (m[1][2] + m[2][1]) / s;
        q[3] = 0.25 * s;
    }
    double length = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    for (int i = 0; i < 4; ++i)
        q[i] /= length;
}

// Eigenvalues and eigenvectors (the columns of `vectors`) of a symmetric matrix, by
// cyclic Jacobi rotations.
void eigenSymmetric(const Sym3& s, double values[3], double vectors[3][3])
{
    double a[3][3] = {{s[0], s[1], s[2]}, {s[1], s[3], s[4]}, {s[2], s[4], s[5]}};
    double v[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
    for (int sweep = 0; sweep < 32; ++sweep)
    {
        double off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2];
        double scale = a[0][0] * a[0][0] + a[1][1] * a[1][1] + a[2][2] * a[2][2];
        if (off <= 1e-24 * scale || off == 0.0)
            break;
        for (int p = 0; p < 2; ++p)
        {
            for (int q = p + 1; q < 3; ++q)
            {
                if (a[p][q] == 0.0)
                    continue;
                double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                double t = (theta >= 0 ? 1.0 : -1.0) / (std::abs(theta) + std::sqrt(theta * theta + 1.0));
                double c = 1.0 / std::sqrt(t * t + 1.0);
                double sn = t * c;
                for (int k = 0; k < 3; ++k)
                {
                    double akp = a[k][p], akq = a[k][q];
                    a[k][p] = c * akp - sn * akq;
                    a[k][q] = sn * akp + c * akq;
                }
                for (int k = 0; k < 3; ++k)
                {
                    double apk = a[p][k], aqk = a[q][k];
                    a[p][k] = c * apk - sn * aqk;
                    a[q][k] = sn * apk + c * aqk;
                }
                for (int k = 0; k < 3; ++k)
                {
                    double vkp = v[k][p], vkq = v[k][q];
                    v[k][p] = c * vkp - sn * vkq;
                    v[k][q] = sn * vkp + c * vkq;
                }
            }
        }
    }
    for (int i = 0; i < 3; ++i)
    {
        values[i] = a[i][i];
        for (int k = 0; k < 3; ++k)
            vectors[k][i] = v[k][i];
    }
}

struct Builder
{
    const Layout& layout;
    std::vector<float>& data;
    uint32_t leafCount;
    std::vector<Gaussian> entries;
    std::vector<uint32_t> parent; // per entry; UINT32_MAX at the root
    std::vector<uint32_t> level;
    std::vector<uint32_t> order;  // leaf indices, partitioned in place by the splits

    Builder(const Layout& layout_, std::vector<float>& data_, uint32_t leafCount_)
        : layout(layout_)
        , data(data_)
        , leafCount(leafCount_)
    {
    }

    const float* record(uint32_t entry) const { return &data[size_t(entry) * layout.stride]; }

    Gaussian leafGaussian(uint32_t i) const
    {
        const float* r = record(i);
        Gaussian g;
        for (int a = 0; a < 3; ++a)
            g.mean[a] = r[layout.position + a];
        double s[3];
        for (int a = 0; a < 3; ++a)
            s[a] = std::max(double(std::exp(r[layout.scale + a])), double(kMinScale));
        double q[4];
        double length = 0;
        for (int a = 0; a < 4; ++a)
        {
            q[a] = r[layout.rotation + a];
            length += q[a] * q[a];
        }
        length = std::sqrt(length);
        if (length < 1e-12)
        {
            q[0] = 1, q[1] = q[2] = q[3] = 0;
        }
        else
        {
            for (int a = 0; a < 4; ++a)
                q[a] /= length;
        }
        double m[3][3];
        quaternionToMatrix(q, m);
        // R S S^T R^T
        auto entry = [&](int i, int j)
        {
            double sum = 0;
            for (int k = 0; k < 3; ++k)
                sum += m[i][k] * m[j][k] * s[k] * s[k];
            return sum;
        };
        g.covariance = {entry(0, 0), entry(0, 1), entry(0, 2), entry(1, 1), entry(1, 2), entry(2, 2)};
        g.alpha = sigmoid(r[layout.opacity]);
        g.area = s[0] * s[1] + s[1] * s[2] + s[0] * s[2];
        g.radius = 3.0 * std::max({s[0], s[1], s[2]});
        return g;
    }

    // Splits order[begin, end) into up to kBranching parts at the median of the longest
    // axis of their centers, three times over.
    void split(uint32_t begin, uint32_t end, std::vector<std::pair<uint32_t, uint32_t>>& parts)
    {
        parts.assign(1, {begin, end});
        for (int round = 0; round < 3; ++round)
        {
            std::vector<std::pair<uint32_t, uint32_t>> next;
            for (auto [b, e] : parts)
            {
                if (e - b < 2)
                {
                    next.push_back({b, e});
                    continue;
                }
                Vec3 lo = {1e300, 1e300, 1e300}, hi = {-1e300, -1e300, -1e300};
                for (uint32_t k = b; k < e; ++k)
                {
                    const Vec3& p = entries[order[k]].mean;
                    for (int a = 0; a < 3; ++a)
                    {
                        lo[a] = std::min(lo[a], p[a]);
                        hi[a] = std::max(hi[a], p[a]);
                    }
                }
                int axis = 0;
                for (int a = 1; a < 3; ++a)
                    if (hi[a] - lo[a] > hi[axis] - lo[axis])
                        axis = a;
                uint32_t mid = b + (e - b) / 2;
                std::nth_element(
                    order.begin() + b,
                    order.begin() + mid,
                    order.begin() + e,
                    [&](uint32_t x, uint32_t y) { return entries[x].mean[axis] < entries[y].mean[axis]; }
                );
                next.push_back({b, mid});
                next.push_back({mid, e});
            }
            parts.swap(next);
        }
    }

    // Merges `children` into a new entry, appending its record to `data`.
    uint32_t merge(const std::vector<uint32_t>& children)
    {
        // Weights: opacity times area, so faint and tiny splats count for less.
        double total = 0;
        for (uint32_t c : children)
            total += entries[c].alpha * entries[c].area;
        if (total <= 0)
            total = 1e-30;

        Gaussian g;
        g.mean = {0, 0, 0};
        for (uint32_t c : children)
        {
            double w = entries[c].alpha * entries[c].area / total;
            for (int a = 0; a < 3; ++a)
                g.mean[a] += w * entries[c].mean[a];
        }
        g.covariance = {0, 0, 0, 0, 0, 0};
        g.radius = 0;
        for (uint32_t c : children)
        {
            const Gaussian& child = entries[c];
            double w = child.alpha * child.area / total;
            Vec3 d = {child.mean[0] - g.mean[0], child.mean[1] - g.mean[1], child.mean[2] - g.mean[2]};
            Sym3 outer = {d[0] * d[0], d[0] * d[1], d[0] * d[2], d[1] * d[1], d[1] * d[2], d[2] * d[2]};
            for (int k = 0; k < 6; ++k)
                g.covariance[k] += w * (child.covariance[k] + outer[k]);
            double reach = std::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) + child.radius;
            g.radius = std::max(g.radius, reach);
        }

        // Its axes and scales: the covariance's eigenvectors and the roots of its
        // eigenvalues, as a rotation (a right-handed frame) and a scale.
        double values[3], vectors[3][3];
        eigenSymmetric(g.covariance, values, vectors);
        double s[3];
        for (int a = 0; a < 3; ++a)
            s[a] = std::sqrt(std::max(values[a], double(kMinScale) * kMinScale));
        double det = vectors[0][0] * (vectors[1][1] * vectors[2][2] - vectors[1][2] * vectors[2][1]) -
                     vectors[0][1] * (vectors[1][0] * vectors[2][2] - vectors[1][2] * vectors[2][0]) +
                     vectors[0][2] * (vectors[1][0] * vectors[2][1] - vectors[1][1] * vectors[2][0]);
        if (det < 0)
        {
            for (int k = 0; k < 3; ++k)
                vectors[k][2] = -vectors[k][2];
        }
        double q[4];
        matrixToQuaternion(vectors, q);
        // A little more, so that rounding to floats can't put a child's sphere outside.
        g.radius = std::max(g.radius, 3.0 * std::max({s[0], s[1], s[2]})) * 1.0001;
        g.area = s[0] * s[1] + s[1] * s[2] + s[0] * s[2];
        // About the same coverage: the children's opacity times area, spread over the
        // merged splat's area -- but no more transparent than its most opaque child. The
        // merged Gaussian is wider and softer than the children it stands for; spreading
        // their opacity over all of it would let a solid surface turn see-through (the
        // background showing through in specks, light leaking through the shadow maps).
        double mostOpaque = 0;
        for (uint32_t c : children)
            mostOpaque = std::max(mostOpaque, entries[c].alpha);
        g.alpha = std::clamp(std::max(total / std::max(g.area, 1e-30), mostOpaque), 1e-4, 0.99);

        // Its record: every property a weighted average of the children's (the spherical
        // harmonics among them), then position, scale, rotation and opacity set.
        uint32_t index = uint32_t(entries.size());
        size_t base = data.size();
        data.resize(base + layout.stride, 0.0f);
        for (uint32_t c : children)
        {
            double w = entries[c].alpha * entries[c].area / total;
            const float* r = record(c);
            for (uint32_t k = 0; k < layout.stride; ++k)
                data[base + k] += float(w * r[k]);
        }
        float* out = &data[base];
        for (int a = 0; a < 3; ++a)
        {
            out[layout.position + a] = float(g.mean[a]);
            out[layout.scale + a] = float(std::log(s[a]));
        }
        for (int a = 0; a < 4; ++a)
            out[layout.rotation + a] = float(q[a]);
        out[layout.opacity] = float(std::log(g.alpha / (1.0 - g.alpha)));

        uint32_t height = 0;
        for (uint32_t c : children)
        {
            parent[c] = index;
            height = std::max(height, level[c] + 1);
        }
        entries.push_back(g);
        parent.push_back(UINT32_MAX);
        level.push_back(height);
        return index;
    }

    // The entry for order[begin, end): a leaf if it is one splat, else a merged node.
    uint32_t buildRange(uint32_t begin, uint32_t end)
    {
        if (end - begin == 1)
            return order[begin];
        std::vector<uint32_t> children;
        if (end - begin <= kBranching)
        {
            for (uint32_t k = begin; k < end; ++k)
                children.push_back(order[k]);
        }
        else
        {
            std::vector<std::pair<uint32_t, uint32_t>> parts;
            split(begin, end, parts);
            for (auto [b, e] : parts)
                if (e > b)
                    children.push_back(buildRange(b, e));
        }
        return merge(children);
    }
};

int findProperty(const std::vector<std::string>& properties, const char* name)
{
    auto it = std::find(properties.begin(), properties.end(), name);
    return it == properties.end() ? -1 : int(it - properties.begin());
}

} // namespace

Layout findLayout(const std::vector<std::string>& properties)
{
    Layout layout;
    layout.stride = uint32_t(properties.size());
    layout.position = findProperty(properties, "x");
    layout.scale = findProperty(properties, "scale_0");
    layout.rotation = findProperty(properties, "rot_0");
    layout.opacity = findProperty(properties, "opacity");
    layout.dc = findProperty(properties, "f_dc_0");
    layout.rest = findProperty(properties, "f_rest_0");
    while (findProperty(properties, ("f_rest_" + std::to_string(layout.restCount)).c_str()) >= 0)
        ++layout.restCount;
    // The consecutive properties the shaders and this file read as groups.
    auto consecutive = [&](int first, const char* prefix, int count, int start)
    {
        for (int i = 0; i < count; ++i)
            if (findProperty(properties, (prefix + std::to_string(start + i)).c_str()) != first + i)
                return false;
        return true;
    };
    if (layout.position >= 0 &&
        (findProperty(properties, "y") != layout.position + 1 || findProperty(properties, "z") != layout.position + 2))
        layout.position = -1;
    if (layout.scale >= 0 && !consecutive(layout.scale, "scale_", 3, 0))
        layout.scale = -1;
    if (layout.rotation >= 0 && !consecutive(layout.rotation, "rot_", 4, 0))
        layout.rotation = -1;
    if (layout.dc >= 0 && !consecutive(layout.dc, "f_dc_", 3, 0))
        layout.dc = -1;
    return layout;
}

// Reorders the first order.size() records in place: record k becomes the one that was at
// order[k]. Follows each cycle of the permutation with one record of scratch.
void permuteRecords(std::vector<float>& data, uint32_t stride, const std::vector<uint32_t>& order)
{
    std::vector<bool> done(order.size(), false);
    std::vector<float> scratch(stride);
    for (size_t start = 0; start < order.size(); ++start)
    {
        if (done[start] || order[start] == start)
        {
            done[start] = true;
            continue;
        }
        std::copy_n(&data[start * stride], stride, scratch.data());
        size_t k = start;
        while (true)
        {
            done[k] = true;
            size_t from = order[k];
            if (from == start)
            {
                std::copy_n(scratch.data(), stride, &data[k * stride]);
                break;
            }
            std::copy_n(&data[from * stride], stride, &data[k * stride]);
            k = from;
        }
    }
}

Result build(const Layout& layout, std::vector<float>& data, uint32_t leafCount)
{
    Result result;
    result.leafCount = leafCount;
    if (leafCount == 0 || !layout.isSplats())
    {
        result.entryCount = leafCount;
        return result;
    }

    Builder b(layout, data, leafCount);
    // An eight-way tree has about a seventh as many nodes as leaves; reserve for that, so
    // the records don't move while they grow.
    size_t expected = size_t(leafCount) + leafCount / 6 + 64;
    data.reserve(expected * layout.stride);
    b.entries.reserve(expected);
    b.parent.reserve(expected);
    b.level.reserve(expected);
    for (uint32_t i = 0; i < leafCount; ++i)
    {
        b.entries.push_back(b.leafGaussian(i));
        b.parent.push_back(UINT32_MAX);
        b.level.push_back(0);
    }
    b.order.resize(leafCount);
    for (uint32_t i = 0; i < leafCount; ++i)
        b.order[i] = i;

    uint32_t root = b.buildRange(0, leafCount);

    result.entryCount = uint32_t(b.entries.size());
    result.levels = b.level[root] + 1;
    result.level = b.level;
    uint32_t nodeCount = result.entryCount - leafCount;
    result.nodeBounds.resize(size_t(nodeCount) * 4);
    for (uint32_t k = 0; k < nodeCount; ++k)
    {
        const Gaussian& g = b.entries[leafCount + k];
        for (int a = 0; a < 3; ++a)
            result.nodeBounds[size_t(k) * 4 + a] = float(g.mean[a]);
        result.nodeBounds[size_t(k) * 4 + 3] = float(g.radius);
    }

    // The leaves in the tree's order: leaf k is the file's splat order[k].
    result.parent.resize(result.entryCount);
    for (uint32_t k = 0; k < leafCount; ++k)
        result.parent[k] = b.parent[b.order[k]];
    for (uint32_t e = leafCount; e < result.entryCount; ++e)
        result.parent[e] = b.parent[e];
    permuteRecords(data, layout.stride, b.order);
    result.order = std::move(b.order);
    return result;
}

namespace {

// The cache file: this header, then the leaves' order, the merged records, the parents,
// the nodes' bounds and the levels.
struct CacheHeader
{
    char magic[8] = {'S', 'P', 'L', 'A', 'T', 'L', 'O', 'D'};
    uint32_t version = 3;
    uint32_t stride = 0;
    uint32_t leafCount = 0;
    uint32_t entryCount = 0;
    uint32_t levels = 0;
    uint32_t reserved = 0;
    uint64_t sourceKey = 0;
};

template<typename T>
bool readArray(std::ifstream& file, T* out, size_t count)
{
    return bool(file.read(reinterpret_cast<char*>(out), std::streamsize(count * sizeof(T))));
}

template<typename T>
void writeArray(std::ofstream& file, const T* data, size_t count)
{
    file.write(reinterpret_cast<const char*>(data), std::streamsize(count * sizeof(T)));
}

bool readCache(const std::string& path, const CacheHeader& expected, std::vector<float>& data, Result& result)
{
    std::ifstream file(path, std::ios::binary);
    if (!file)
        return false;
    CacheHeader header;
    if (!file.read(reinterpret_cast<char*>(&header), sizeof(header)))
        return false;
    if (std::memcmp(header.magic, expected.magic, 8) != 0 || header.version != expected.version ||
        header.stride != expected.stride || header.leafCount != expected.leafCount ||
        header.sourceKey != expected.sourceKey || header.entryCount < header.leafCount)
        return false;
    size_t nodes = header.entryCount - header.leafCount;
    size_t leafFloats = size_t(header.leafCount) * header.stride;
    Result r;
    r.leafCount = header.leafCount;
    r.entryCount = header.entryCount;
    r.levels = header.levels;
    r.order.resize(header.leafCount);
    r.parent.resize(header.entryCount);
    r.nodeBounds.resize(nodes * 4);
    r.level.resize(header.entryCount);
    std::vector<float> merged(nodes * header.stride);
    if (!readArray(file, r.order.data(), r.order.size()) || !readArray(file, merged.data(), merged.size()) ||
        !readArray(file, r.parent.data(), r.parent.size()) || !readArray(file, r.nodeBounds.data(), r.nodeBounds.size()) ||
        !readArray(file, r.level.data(), r.level.size()))
        return false;
    for (uint32_t k = 0; k < header.leafCount; ++k)
        if (r.order[k] >= header.leafCount)
            return false;
    data.resize(leafFloats);
    permuteRecords(data, header.stride, r.order);
    data.insert(data.end(), merged.begin(), merged.end());
    result = std::move(r);
    return true;
}

void writeCache(const std::string& path, CacheHeader header, const std::vector<float>& data, const Result& result)
{
    header.entryCount = result.entryCount;
    header.levels = result.levels;
    std::string temporary = path + ".partial";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file)
            return;
        size_t leafFloats = size_t(result.leafCount) * header.stride;
        file.write(reinterpret_cast<const char*>(&header), sizeof(header));
        writeArray(file, result.order.data(), result.order.size());
        writeArray(file, data.data() + leafFloats, data.size() - leafFloats);
        writeArray(file, result.parent.data(), result.parent.size());
        writeArray(file, result.nodeBounds.data(), result.nodeBounds.size());
        writeArray(file, result.level.data(), result.level.size());
        if (!file)
            return;
    }
    // Whole or not at all: another run never reads a half-written cache.
    std::remove(path.c_str());
    std::rename(temporary.c_str(), path.c_str());
}

} // namespace

Result buildCached(
    const Layout& layout,
    std::vector<float>& data,
    uint32_t leafCount,
    const std::string& cachePath,
    uint64_t sourceKey,
    bool& cached
)
{
    CacheHeader header;
    header.stride = layout.stride;
    header.leafCount = leafCount;
    header.sourceKey = sourceKey;
    Result result;
    cached = layout.isSplats() && readCache(cachePath, header, data, result);
    if (cached)
        return result;
    result = build(layout, data, leafCount);
    if (result.entryCount > leafCount)
        writeCache(cachePath, header, data, result);
    return result;
}

} // namespace splatlod
