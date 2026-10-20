// Scriptable example host: every example is a Lua script that drives slang-rhi.
//
// Scripts live in examples/lua/scripts and shaders in examples/lua/shaders. A script is
// picked on the command line: `example-lua scene` (scripts/scene.lua), or a path to any
// .lua file. The script and every shader it uses -- includes too -- reload when saved.
//
// See examples/lua/README.md for the script API.

#include "example-base.h"
#include "audio.h"
#include "physics.h"
#include "splat-lod.h"

// Lua is built as C++ (see CMakeLists.txt), so its headers are included without the
// extern "C" wrapper that lua.hpp adds.
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <iterator>
#include <set>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

using namespace rhi;
namespace fs = std::filesystem;

namespace {

// ---------------------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------------------

// The form a path is stored under, so the same file reached two ways compares equal.
std::string pathKey(const fs::path& path)
{
    std::error_code ec;
    fs::path canonical = fs::weakly_canonical(path, ec);
    return (ec ? path.lexically_normal() : canonical).generic_string();
}

// Watches files for edits. A changed timestamp has to survive one further check before it
// counts: editors write in more than one step, and compiling a half-written file just
// produces errors for something that is about to be valid.
class FileWatcher
{
public:
    void watch(const std::string& path)
    {
        if (m_files.count(path))
        {
            return;
        }
        std::error_code ec;
        m_files[path].known = fs::last_write_time(path, ec);
    }

    // Returns the files whose edits have settled since the last call.
    std::vector<std::string> poll()
    {
        std::vector<std::string> changed;
        for (auto& [path, file] : m_files)
        {
            std::error_code ec;
            fs::file_time_type stamp = fs::last_write_time(path, ec);
            if (ec)
            {
                continue; // mid-write, or gone: try again next time
            }
            if (stamp == file.known)
            {
                file.hasPending = false;
                continue;
            }
            if (!file.hasPending || stamp != file.pending)
            {
                file.pending = stamp;
                file.hasPending = true;
                continue;
            }
            file.known = stamp;
            file.hasPending = false;
            changed.push_back(path);
        }
        return changed;
    }

private:
    struct File
    {
        fs::file_time_type known{};
        fs::file_time_type pending{};
        bool hasPending = false;
    };
    std::map<std::string, File> m_files;
};

// Matches `#include "name"` and returns the name.
bool parseQuotedInclude(const std::string& line, std::string& outName)
{
    size_t i = line.find_first_not_of(" \t");
    if (i == std::string::npos || line[i] != '#')
    {
        return false;
    }
    i = line.find_first_not_of(" \t", i + 1);
    if (i == std::string::npos || line.compare(i, 7, "include") != 0)
    {
        return false;
    }
    i = line.find_first_not_of(" \t", i + 7);
    if (i == std::string::npos || line[i] != '"')
    {
        return false;
    }
    size_t end = line.find('"', i + 1);
    if (end == std::string::npos)
    {
        return false;
    }
    outName = line.substr(i + 1, end - i - 1);
    return true;
}

bool isPragmaOnce(const std::string& line)
{
    size_t i = line.find_first_not_of(" \t");
    if (i == std::string::npos || line[i] != '#')
    {
        return false;
    }
    i = line.find_first_not_of(" \t", i + 1);
    if (i == std::string::npos || line.compare(i, 6, "pragma") != 0)
    {
        return false;
    }
    i = line.find_first_not_of(" \t", i + 6);
    return i != std::string::npos && line.compare(i, 4, "once") == 0;
}

fs::path resolveInclude(const fs::path& fromDir, const std::string& name, const std::vector<fs::path>& searchDirs)
{
    std::error_code ec;
    if (fs::is_regular_file(fromDir / name, ec))
    {
        return fromDir / name;
    }
    for (const fs::path& dir : searchDirs)
    {
        if (fs::is_regular_file(dir / name, ec))
        {
            return dir / name;
        }
    }
    return {};
}

struct ShaderSource
{
    std::string text;
    // Every file read (or looked for), so all of them can be watched.
    std::vector<std::string> files;
    std::set<std::string> onceFiles;
};

// Reads a shader with its `#include "..."` files spliced in.
//
// Slang would resolve the includes itself, but its session keeps what it has read, so an
// edited include would never be seen again. Splicing them in here means every build reads
// every file afresh, and also tells us which files a pipeline depends on. #line
// directives keep diagnostics pointing at the real files.
bool readShaderSource(const fs::path& path, const std::vector<fs::path>& searchDirs, ShaderSource& out, int depth = 0);

// ---------------------------------------------------------------------------------------
// PLY files
// ---------------------------------------------------------------------------------------

struct PlyData
{
    uint32_t count = 0;
    std::vector<std::string> properties; // of the vertex element, in file order
    std::vector<float> data;             // count records of properties.size() floats
};

// The stand-in for a splat file that is missing (or doesn't read): a cube of side 1 at the
// origin, its faces covered by flat splats in a blue checker, 4 x 4 squares a face.
PlyData placeholderPly()
{
    const int perSide = 32;  // splats along a face's edge
    const int squares = 4;   // checker squares along a face's edge
    const float spacing = 1.0f / perSide;
    const float shC0 = 0.28209479f; // the 0th spherical harmonic: color = 0.5 + shC0 * f_dc
    const float blue[2][3] = {{0.08f, 0.25f, 0.85f}, {0.55f, 0.7f, 1.0f}};

    PlyData ply;
    ply.properties = {"x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                      "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"};
    for (int axis = 0; axis < 3; ++axis)
    {
        for (int side = 0; side < 2; ++side)
        {
            for (int i = 0; i < perSide; ++i)
            {
                for (int j = 0; j < perSide; ++j)
                {
                    float position[3];
                    position[axis] = side ? 0.5f : -0.5f;
                    position[(axis + 1) % 3] = (i + 0.5f) * spacing - 0.5f;
                    position[(axis + 2) % 3] = (j + 0.5f) * spacing - 0.5f;
                    const float* color = blue[(i * squares / perSide + j * squares / perSide + axis + side) % 2];
                    // Flat along the face's normal; wide enough to overlap their neighbors.
                    float scale[3];
                    scale[axis] = std::log(spacing * 0.05f);
                    scale[(axis + 1) % 3] = scale[(axis + 2) % 3] = std::log(spacing * 0.6f);
                    float record[] = {position[0], position[1], position[2],
                                      (color[0] - 0.5f) / shC0, (color[1] - 0.5f) / shC0, (color[2] - 0.5f) / shC0,
                                      6.0f, // logit: opaque
                                      scale[0], scale[1], scale[2], 1.0f, 0.0f, 0.0f, 0.0f};
                    ply.data.insert(ply.data.end(), std::begin(record), std::end(record));
                    ++ply.count;
                }
            }
        }
    }
    return ply;
}

// Reads the vertex element of a binary little-endian PLY file whose vertex properties are
// all floats -- the format Gaussian splatting scenes are stored in.
bool readPly(const fs::path& path, PlyData& out, std::string& error)
{
    std::ifstream file(path, std::ios::binary);
    if (!file)
    {
        error = "could not open the file";
        return false;
    }
    std::string line;
    std::getline(file, line);
    if (line.rfind("ply", 0) != 0)
    {
        error = "not a PLY file";
        return false;
    }
    bool inVertex = false;
    bool sawVertex = false;
    while (std::getline(file, line))
    {
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        std::istringstream words(line);
        std::string keyword;
        words >> keyword;
        if (keyword == "format")
        {
            std::string format;
            words >> format;
            if (format != "binary_little_endian")
            {
                error = "only binary_little_endian PLY files are supported, not " + format;
                return false;
            }
        }
        else if (keyword == "element")
        {
            std::string name;
            words >> name;
            if (name == "vertex")
            {
                if (sawVertex)
                {
                    error = "more than one vertex element";
                    return false;
                }
                words >> out.count;
                inVertex = sawVertex = true;
            }
            else
            {
                if (!sawVertex)
                {
                    // Its data would come first, and we don't read other elements' types.
                    error = "elements before the vertex element are not supported";
                    return false;
                }
                inVertex = false;
            }
        }
        else if (keyword == "property" && inVertex)
        {
            std::string type, name;
            words >> type >> name;
            if (type != "float" && type != "float32")
            {
                error = "only float vertex properties are supported ('" + type + " " + name + "')";
                return false;
            }
            out.properties.push_back(name);
        }
        else if (keyword == "end_header")
        {
            break;
        }
    }
    if (!sawVertex || out.properties.empty())
    {
        error = "no vertex element";
        return false;
    }
    out.data.resize(size_t(out.count) * out.properties.size());
    file.read(reinterpret_cast<char*>(out.data.data()), std::streamsize(out.data.size() * sizeof(float)));
    if (size_t(file.gcount()) != out.data.size() * sizeof(float))
    {
        error = "the file is shorter than its header says";
        return false;
    }
    return true;
}

bool readShaderSource(const fs::path& path, const std::vector<fs::path>& searchDirs, ShaderSource& out, int depth)
{
    std::string key = pathKey(path);
    out.files.push_back(key);
    std::ifstream file(path, std::ios::binary);
    if (!file)
    {
        printf("[lua] could not open '%s'\n", key.c_str());
        return false;
    }
    out.text += "#line 1 \"" + key + "\"\n";
    std::string line;
    int lineNumber = 0;
    while (std::getline(file, line))
    {
        ++lineNumber;
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        std::string includeName;
        if (depth < 32 && parseQuotedInclude(line, includeName))
        {
            fs::path resolved = resolveInclude(path.parent_path(), includeName, searchDirs);
            if (!resolved.empty())
            {
                if (!out.onceFiles.count(pathKey(resolved)) && !readShaderSource(resolved, searchDirs, out, depth + 1))
                {
                    return false;
                }
                out.text += "#line " + std::to_string(lineNumber + 1) + " \"" + key + "\"\n";
                continue;
            }
            // Not found: leave the line for Slang to report.
        }
        if (isPragmaOnce(line))
        {
            out.onceFiles.insert(key);
            out.text += '\n';
            continue;
        }
        out.text += line;
        out.text += '\n';
    }
    return true;
}

// ---------------------------------------------------------------------------------------
// Shader compilation
// ---------------------------------------------------------------------------------------

struct CompiledProgram
{
    ComPtr<IShaderProgram> program;
    uint32_t threadGroupSize[3] = {1, 1, 1};
};

// Compiles source text under a module name and path that are new on every build: the
// session keys loaded modules by both, and holding either against an already-loaded
// module is an error ("The key already exists in Dictionary").
Result compileProgram(
    IDevice* device,
    const std::string& path,
    const std::string& source,
    const std::vector<std::string>& entryPointNames,
    uint32_t serial,
    CompiledProgram& out
)
{
    std::string suffix = "-build" + std::to_string(serial);
    std::string moduleName = fs::path(path).filename().string() + suffix;
    std::string virtualPath = path + suffix;

    slang::ISession* session = device->getSlangSession();
    ComPtr<slang::IBlob> diagnostics;
    slang::IModule* module =
        session->loadModuleFromSourceString(moduleName.c_str(), virtualPath.c_str(), source.c_str(), diagnostics.writeRef());
    PRINT_DIAGNOSTICS(diagnostics);
    if (!module)
    {
        return SLANG_FAIL;
    }

    std::vector<ComPtr<slang::IEntryPoint>> entryPoints;
    std::vector<slang::IComponentType*> entryPointComponents;
    for (const std::string& name : entryPointNames)
    {
        ComPtr<slang::IEntryPoint> entryPoint;
        if (SLANG_FAILED(module->findEntryPointByName(name.c_str(), entryPoint.writeRef())))
        {
            printf("[lua] no entry point '%s' in '%s'\n", name.c_str(), path.c_str());
            return SLANG_FAIL;
        }
        entryPointComponents.push_back(entryPoint);
        entryPoints.push_back(entryPoint);
    }

    // The thread group size is needed to turn thread counts into dispatch sizes.
    std::vector<slang::IComponentType*> components = {module};
    components.insert(components.end(), entryPointComponents.begin(), entryPointComponents.end());
    ComPtr<slang::IComponentType> composite;
    diagnostics.setNull();
    if (SLANG_SUCCEEDED(session->createCompositeComponentType(
            components.data(),
            components.size(),
            composite.writeRef(),
            diagnostics.writeRef()
        )))
    {
        slang::ProgramLayout* layout = composite->getLayout();
        if (layout && layout->getEntryPointCount() > 0)
        {
            SlangUInt sizes[3] = {1, 1, 1};
            layout->getEntryPointByIndex(0)->getComputeThreadGroupSize(3, sizes);
            for (int i = 0; i < 3; ++i)
            {
                out.threadGroupSize[i] = std::max<uint32_t>(1, uint32_t(sizes[i]));
            }
        }
    }

    ShaderProgramDesc programDesc = {};
    programDesc.linkingStyle = LinkingStyle::SingleProgram;
    programDesc.slangEntryPoints = entryPointComponents.data();
    programDesc.slangEntryPointCount = entryPointComponents.size();
    programDesc.slangGlobalScope = module;
    diagnostics.setNull();
    device->createShaderProgram(programDesc, out.program.writeRef(), diagnostics.writeRef());
    PRINT_DIAGNOSTICS(diagnostics);
    return out.program ? SLANG_OK : SLANG_FAIL;
}

// ---------------------------------------------------------------------------------------
// Script-visible objects
// ---------------------------------------------------------------------------------------

struct FormatName
{
    const char* name;
    Format format;
    uint32_t size;
};

const FormatName kFormats[] = {
    {"r32f", Format::R32Float, 4},
    {"rg32f", Format::RG32Float, 8},
    {"rgb32f", Format::RGB32Float, 12},
    {"rgba32f", Format::RGBA32Float, 16},
    {"rgba16f", Format::RGBA16Float, 8},
    {"r16f", Format::R16Float, 2},
    {"rgba8", Format::RGBA8Unorm, 4},
    {"r32u", Format::R32Uint, 4},
};

const FormatName* findFormat(const char* name)
{
    for (const FormatName& format : kFormats)
    {
        if (strcmp(format.name, name) == 0)
        {
            return &format;
        }
    }
    return nullptr;
}

struct VertexAttribute
{
    std::string semantic;
    Format format;
    uint32_t offset;
};

struct Pipeline
{
    // What to build.
    fs::path path;
    std::vector<std::string> entryPoints;
    bool isCompute = true;
    std::vector<VertexAttribute> attributes;
    uint32_t vertexStride = 0;
    PrimitiveTopology topology = PrimitiveTopology::TriangleList;
    // Test and write the depth buffer of whatever the pipeline draws into.
    bool depth = false;
    // Color target format; Undefined means the window's.
    Format colorFormat = Format::Undefined;
    // More color targets (SV_Target1, ...: `formats`), blended as the first.
    std::vector<Format> extraFormats;
    enum class Blend
    {
        None,
        Alpha,         // color * a + target * (1 - a)
        Premultiplied, // color + target * (1 - a): the shader has multiplied color by a
        Additive,      // color + target
        Accumulate,    // rgb: color + target; a: min(a, target a) -- sums and a nearest value
    };
    Blend blend = Blend::None;
    // No color target at all (format = "none"): for depth-only passes.
    bool depthOnly = false;

    // The latest build that compiled; kept when an edit doesn't.
    ComPtr<IComputePipeline> compute;
    ComPtr<IRenderPipeline> render;
    uint32_t threadGroupSize[3] = {1, 1, 1};
    // Number of successful builds, so scripts can tell when a pipeline was reloaded.
    uint32_t version = 0;

    // Files the latest build read.
    std::vector<std::string> files;

    bool isBuilt() const { return compute || render; }
};

struct Texture
{
    ComPtr<ITexture> texture;
    Format format = Format::RGBA32Float;
    // Render targets are resized with the window, to `scale` times its size.
    bool followsSurface = false;
    float scale = 1.0f;
    // Square: both sides `scale` times the window's height (render_target(..., "square")).
    bool square = false;
    // Depth buffer for depth-tested draws into this texture, created on first use.
    ComPtr<ITexture> depth;
    // A depth buffer itself (rhi.depth_target): drawn into as a pass's depth_target, and
    // readable by shaders as a Texture2D<float> of depth values in [0, 1].
    bool isDepth = false;
};

struct Buffer
{
    ComPtr<IBuffer> buffer;
    uint64_t size = 0;
    // buffer:write's data, uploaded before the next frame's passes: offset (bytes), floats.
    std::vector<std::pair<uint64_t, std::vector<float>>> pendingWrites;
};

// A shader parameter value captured from Lua, so it can be applied without the Lua state:
// by the render graph every frame, or straight away by frame:draw() and frame:dispatch().
// A sampler (rhi.sampler), for shaders that filter textures (Sample) rather than Load them.
struct Sampler
{
    ComPtr<ISampler> sampler;
};

struct ParamValue
{
    enum class Kind
    {
        Numbers,
        Table,
        Texture,
        Buffer,
        Controller,
        Sampler,
    };
    Kind kind = Kind::Numbers;
    std::vector<double> numbers; // Numbers
    // Table: the string-keyed fields, and the elements 1..n.
    std::vector<std::string> fieldNames;
    std::vector<ParamValue> fieldValues;
    std::vector<ParamValue> elements;
    std::shared_ptr<Texture> texture;
    std::shared_ptr<Buffer> buffer;
    std::shared_ptr<Sampler> sampler;
    int controllerSlot = -1;
};

// Named shader parameter values, shared by every draw and dispatch that lists the block.
// Changing a value in it changes what all of them get from the next frame on.
struct ParamBlock
{
    std::vector<std::string> names;
    std::vector<ParamValue> values;

    void set(const std::string& name, ParamValue value)
    {
        auto it = std::find(names.begin(), names.end(), name);
        if (it != names.end())
        {
            values[it - names.begin()] = std::move(value);
            return;
        }
        names.push_back(name);
        values.push_back(std::move(value));
    }
};

// ---------------------------------------------------------------------------------------
// Physics
//
// A physics world (physics.h, on Jolt) with groups of bodies. A group is a set of bodies
// drawn together: the host steps the world every frame and writes each group's transforms
// into the group's GPU buffer, kBodyFloats floats per body, as scene/scene-common.slang
// reads them (`bodies`). A draw instanced over the group then draws every body. Each body
// also keeps the transform it had the frame before, for motion vectors.
// ---------------------------------------------------------------------------------------

static constexpr uint32_t kBodyFloats = 24;

struct PhysicsWorld;

// A group entry with this id is not a physics body but a "visual" one: drawn like the
// others, placed by the script (group:set_transform), colliding with nothing.
static constexpr uint32_t kVisualBody = UINT32_MAX;

struct BodyGroup
{
    std::weak_ptr<PhysicsWorld> world;
    uint32_t capacity = 0;
    std::vector<uint32_t> ids; // physics body ids (or kVisualBody), in instance order
    // Per body: position xyz, rotation xyzw -- used for the visual ones only.
    std::vector<float> placements;
    // Per body: scale xyz, pattern, color rgb, unused -- what doesn't come from the physics.
    std::vector<float> looks;
    std::shared_ptr<Buffer> buffer;
    std::vector<float> staging;   // what was uploaded last: this frame's previous transforms
    size_t uploadedCount = 0;     // the bodies it holds a transform for
};

struct PhysicsWorld
{
    std::unique_ptr<physics::World> world;
    std::vector<std::weak_ptr<BodyGroup>> groups;
    bool paused = false;
    float timeScale = 1.0f;
};

// A script's handle on one of a world's characters.
struct CharacterHandle
{
    std::weak_ptr<PhysicsWorld> world;
    uint32_t index = 0;
    float gravityScale = 1.0f;
    float maxFallSpeed = 0.0f;
    float move[2] = {0, 0};
};

// ---------------------------------------------------------------------------------------
// Render graph
//
// Built by the script (normally once, in init()) and run by the host every frame, without
// calling into Lua: a list of compute dispatches and render passes, each render pass a
// list of draws. Their inputs are parameter blocks, which the script can change at any time.
// ---------------------------------------------------------------------------------------

struct GraphDraw
{
    std::shared_ptr<Pipeline> pipeline;
    std::shared_ptr<Buffer> vertices;
    uint32_t count = 3;
    // Instances: a fixed number, or as many as a body group has bodies, frame by frame.
    uint32_t instances = 1;
    std::shared_ptr<BodyGroup> instanceGroup;
    std::vector<std::shared_ptr<ParamBlock>> params;
    bool enabled = true;
    // An error was printed for this draw; don't repeat it every frame.
    bool reported = false;
};

struct GraphNode
{
    std::string name;
    bool enabled = true;
    bool isDispatch = false;
    bool reported = false;

    // Render pass.
    std::shared_ptr<Texture> target;      // null: the window
    std::vector<std::shared_ptr<Texture>> extraTargets; // more color targets (`targets`), the size of the first
    std::shared_ptr<Texture> depthTarget; // null: the host's depth buffer for the target
    bool depthOnly = false;               // no color attachment; needs depthTarget
    bool clear = false;
    float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    enum class ViewportMode
    {
        Full,
        Pixels,
        Fraction, // of the target's size
    };
    ViewportMode viewportMode = ViewportMode::Full;
    float viewport[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    std::vector<std::shared_ptr<GraphDraw>> draws;

    // Dispatch.
    std::shared_ptr<Pipeline> pipeline;
    std::vector<std::shared_ptr<ParamBlock>> params;
    uint32_t threads[3] = {1, 1, 1};
    // Or one thread per window pixel, whatever the window's size (threads = "window").
    bool threadsPerPixel = false;
    // Or one thread per texel of a texture, whatever its size (threads = texture).
    std::shared_ptr<Texture> threadsTexture;
    // Run once, then again only when asked (rerun()) or when the pipeline is rebuilt.
    bool once = false;
    // Timed: the host measures the node's GPU time with timestamps (rhi.graph's `timed`),
    // and reads it back a few frames later: gpuTime, in milliseconds, smoothed; < 0 until
    // the first measurement arrives.
    bool timed = false;
    double gpuTime = -1.0;
    bool pending = true;
    uint32_t ranVersion = 0;
};

struct Graph
{
    std::vector<std::shared_ptr<GraphNode>> nodes;
};

const char* kPipelineType = "rhi.Pipeline";
const char* kTextureType = "rhi.Texture";
const char* kBufferType = "rhi.Buffer";
const char* kControllerType = "rhi.Controller";
const char* kFrameType = "rhi.Frame";
const char* kParamsType = "rhi.Params";
const char* kGraphType = "rhi.Graph";
const char* kNodeType = "rhi.Pass";
const char* kDrawType = "rhi.Draw";
const char* kPhysicsType = "rhi.PhysicsWorld";
const char* kBodyGroupType = "rhi.BodyGroup";
const char* kCharacterType = "rhi.Character";
const char* kSoundType = "rhi.Sound";
const char* kSamplerType = "rhi.Sampler";

// Script handles hold a shared_ptr to the host-side object.
template<typename T>
void pushHandle(lua_State* L, std::shared_ptr<T> object, const char* type)
{
    void* memory = lua_newuserdatauv(L, sizeof(std::shared_ptr<T>), 0);
    new (memory) std::shared_ptr<T>(std::move(object));
    luaL_setmetatable(L, type);
}

template<typename T>
std::shared_ptr<T> testShared(lua_State* L, int index, const char* type)
{
    auto* handle = static_cast<std::shared_ptr<T>*>(luaL_testudata(L, index, type));
    return handle ? *handle : nullptr;
}

template<typename T>
std::shared_ptr<T> checkShared(lua_State* L, int index, const char* type)
{
    return *static_cast<std::shared_ptr<T>*>(luaL_checkudata(L, index, type));
}

template<typename T>
T* testHandle(lua_State* L, int index, const char* type)
{
    auto* handle = static_cast<std::shared_ptr<T>*>(luaL_testudata(L, index, type));
    return handle ? handle->get() : nullptr;
}

template<typename T>
T* checkHandle(lua_State* L, int index, const char* type)
{
    return static_cast<std::shared_ptr<T>*>(luaL_checkudata(L, index, type))->get();
}

template<typename T>
int collectHandle(lua_State* L)
{
    static_cast<std::shared_ptr<T>*>(lua_touserdata(L, 1))->~shared_ptr<T>();
    return 0;
}

// Ends a pass however the function recording it is left, including by a script error.
template<typename T>
struct PassScope
{
    T* pass;
    ~PassScope() { pass->end(); }
};

std::string lowercase(std::string text)
{
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    return text;
}

int traceback(lua_State* L)
{
    const char* message = lua_tostring(L, 1);
    luaL_traceback(L, L, message ? message : "(error object is not a string)", 1);
    return 1;
}

} // namespace

// ---------------------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------------------

// The engine runs on Vulkan only, for now: the graphics device to pick is the GPU.
static const DeviceType kEngineDeviceType = DeviceType::Vulkan;

// A restart on another GPU, asked for by rhi.restart: main() runs the script again on it.
struct RestartRequest
{
    bool pending = false;
    std::string adapter;
};
static RestartRequest g_restart;

// Runs one script on one device, in its own window and Lua state.
class LuaApp : public ExampleBase
{
public:
    // `adapterName`: the graphics adapter to run on, by name; empty (or not found): the
    // device type's default.
    explicit LuaApp(fs::path scriptPath, std::string adapterName = {})
        : m_scriptPath(std::move(scriptPath))
        , m_scriptDir(m_scriptPath.parent_path())
        , m_adapterName(std::move(adapterName))
    {
    }

    ~LuaApp() override { closeScript(); }

    Result init(DeviceType deviceType) override
    {
        // The script has to run first: its config describes the window and device.
        m_lua = openScript();
        if (!m_lua)
        {
            return SLANG_FAIL;
        }

        std::string title = m_scriptPath.stem().string();
        int width = 640;
        int height = 360;
        std::vector<Feature> features = {Feature::Surface};
        readConfig(title, width, height, features);

        IAdapter* adapter = nullptr;
        for (uint32_t i = 0; !m_adapterName.empty(); ++i)
        {
            IAdapter* candidate = getRHI()->getAdapter(deviceType, i);
            if (!candidate)
                break;
            if (m_adapterName == candidate->getInfo().name)
            {
                adapter = candidate;
                break;
            }
        }
        if (!m_adapterName.empty() && !adapter)
        {
            printf("[lua] no adapter '%s' for %s: the default one\n", m_adapterName.c_str(), getRHI()->getDeviceTypeName(deviceType));
        }
        SLANG_RETURN_ON_FAIL(createDevice(
            deviceType,
            features,
            {},
            m_device.writeRef(),
            {m_scriptDir.string(), LUA_SHADERS_DIR},
            adapter
        ));
        SLANG_RETURN_ON_FAIL(createWindow(m_device, title.c_str(), width, height));
        SLANG_RETURN_ON_FAIL(createSurface(m_device, Format::Undefined, m_surface.writeRef()));
        SLANG_RETURN_ON_FAIL(m_device->getQueue(QueueType::Graphics, m_queue.writeRef()));
        m_blitter = std::make_unique<Blitter>(m_device);

        m_watcher.watch(pathKey(m_scriptPath));
        printf(
            "[lua] running '%s' on %s, watching it and its shaders for edits\n",
            pathKey(m_scriptPath).c_str(),
            getRHI()->getDeviceTypeName(deviceType)
        );
        fflush(stdout);

        callScript("init");
        return SLANG_OK;
    }

    void shutdown() override
    {
        m_queue->waitOnHost();
        callScript("shutdown");
        closeScript();
        m_graph.reset();
        m_physics.reset();
        m_pipelines.clear();
        m_renderTargets.clear();
        m_blitter.reset();
        m_depthTexture.setNull();
        m_queue.setNull();
        m_surface.setNull();
        m_device.setNull();
    }

    Result update(double time) override
    {
        if (m_time == 0.0)
        {
            m_time = time;
        }
        m_timeDelta = time - m_time;
        m_time = time;

        if (time - m_lastWatchTime >= kWatchInterval)
        {
            m_lastWatchTime = time;
            pollFiles();
        }
        if (m_reloadRequested)
        {
            // rhi.reload(): here, outside the script, rather than from inside its call.
            m_reloadRequested = false;
            m_queue->waitOnHost();
            reloadScript();
        }

        if (!m_paused)
        {
            m_shaderTime += m_timeDelta;
        }
        if (m_physics && !m_physics->paused && !m_paused)
        {
            m_physics->world->step(m_timeDelta * m_physics->timeScale);
        }

        callScript("update", m_time, m_timeDelta);
        return SLANG_OK;
    }

    // Writes every body group's transforms into its GPU buffer, ahead of the frame's passes.
    // buffer:write's data, ahead of the frame's passes.
    void uploadBufferWrites(ICommandEncoder* encoder)
    {
        for (auto it = m_writtenBuffers.begin(); it != m_writtenBuffers.end();)
        {
            std::shared_ptr<Buffer> buffer = it->lock();
            if (buffer)
            {
                for (auto& [offset, floats] : buffer->pendingWrites)
                {
                    encoder->uploadBufferData(buffer->buffer, offset, floats.size() * sizeof(float), floats.data());
                }
                buffer->pendingWrites.clear();
            }
            it = m_writtenBuffers.erase(it);
        }
    }

    void uploadBodies(ICommandEncoder* encoder)
    {
        if (!m_physics)
        {
            return;
        }
        auto& groups = m_physics->groups;
        groups.erase(
            std::remove_if(groups.begin(), groups.end(), [](const auto& g) { return g.expired(); }),
            groups.end()
        );
        for (const std::weak_ptr<BodyGroup>& weak : groups)
        {
            std::shared_ptr<BodyGroup> group = weak.lock();
            size_t count = group->ids.size();
            if (count == 0)
            {
                continue;
            }
            group->staging.resize(count * kBodyFloats);
            for (size_t i = 0; i < count; ++i)
            {
                float* body = &group->staging[i * kBodyFloats];
                const float* looks = &group->looks[i * 8];
                // Last frame's transform becomes the previous one ([4], [5]).
                bool hadOne = i < group->uploadedCount;
                if (hadOne)
                {
                    std::copy_n(body, 3, body + 16);
                    std::copy_n(body + 4, 4, body + 20);
                }
                if (group->ids[i] == kVisualBody)
                {
                    std::copy_n(&group->placements[i * 7], 3, body);
                    std::copy_n(&group->placements[i * 7 + 3], 4, body + 4);
                }
                else
                    m_physics->world->getTransform(group->ids[i], body, body + 4);
                body[3] = 0;
                body[8] = looks[0];
                body[9] = looks[1];
                body[10] = looks[2];
                body[11] = 0;
                body[12] = looks[4];
                body[13] = looks[5];
                body[14] = looks[6];
                body[15] = looks[3];
                if (!hadOne)
                {
                    // New: no motion yet.
                    std::copy_n(body, 3, body + 16);
                    std::copy_n(body + 4, 4, body + 20);
                }
                body[19] = 0;
            }
            group->uploadedCount = count;
            encoder->uploadBufferData(group->buffer->buffer, 0, count * kBodyFloats * sizeof(float), group->staging.data());
        }
    }

    Result draw() override
    {
        // Skip rendering if surface is not configured (eg. when window is minimized), or
        // while the script is waiting to be fixed -- unless it set up a render graph, which
        // runs without it.
        if (!m_surface->getConfig() || !m_lua || (m_scriptFailed && !m_graph))
        {
            return SLANG_OK;
        }

        ComPtr<ITexture> image;
        m_surface->acquireNextImage(image.writeRef());
        if (!image)
        {
            return SLANG_OK;
        }

        uint32_t width = image->getDesc().size.width;
        uint32_t height = image->getDesc().size.height;
        resizeRenderTargets(width, height);

        ComPtr<ICommandEncoder> commandEncoder = m_queue->createCommandEncoder();
        m_frame.encoder = commandEncoder;
        m_frame.image = image;
        m_frame.width = width;
        m_frame.height = height;
        m_frame.active = true;
        uploadBodies(commandEncoder);
        uploadBufferWrites(commandEncoder);
        if (m_graph)
        {
            runGraph(*m_graph);
        }
        callScript("draw", FrameArg{});
        m_frame = {};

        m_queue->submit(commandEncoder->finish());
        m_frameIndex += 1;
        return m_surface->present();
    }

    void onResize(int width, int height, int framebufferWidth, int framebufferHeight) override
    {
        // Wait for GPU to be idle before resizing
        m_device->getQueue(QueueType::Graphics)->waitOnHost();
        // Configure or unconfigure the surface based on the new framebuffer size
        if (framebufferWidth > 0 && framebufferHeight > 0)
        {
            SurfaceConfig surfaceConfig;
            surfaceConfig.width = framebufferWidth;
            surfaceConfig.height = framebufferHeight;
            m_surface->configure(surfaceConfig);
        }
        else
        {
            m_surface->unconfigure();
        }
        callScript("on_resize", framebufferWidth, framebufferHeight);
    }

    void onMousePosition(float x, float y) override { callScript("on_mouse_move", x, y); }
    void onMouseButton(int button, int action, int mods) override
    {
        callScript("on_mouse_button", button, action, mods);
    }
    void onScroll(float x, float y) override { callScript("on_scroll", x, y); }
    void onKey(int key, int scancode, int action, int mods) override { callScript("on_key", key, action, mods); }
    void onControllerConnect(int slot, bool connected) override
    {
        callScript("on_controller_connect", slot, connected);
    }
    void onControllerButton(int slot, uint32_t button, bool pressed) override
    {
        callScript("on_controller_button", slot, button, pressed);
    }

    // -----------------------------------------------------------------------------------
    // Script lifetime
    // -----------------------------------------------------------------------------------

    static LuaApp* get(lua_State* L) { return *static_cast<LuaApp**>(lua_getextraspace(L)); }

    // Creates a Lua state with the API installed and runs the script's top level.
    lua_State* openScript()
    {
        lua_State* L = luaL_newstate();
        *static_cast<LuaApp**>(lua_getextraspace(L)) = this;
        luaL_openlibs(L);
        registerApi(L);

        // Let scripts require() modules that sit next to them.
        lua_getglobal(L, "package");
        lua_getfield(L, -1, "path");
        std::string path = (m_scriptDir / "?.lua").generic_string() + ";" + lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_pushstring(L, path.c_str());
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);

        lua_pushcfunction(L, traceback);
        std::string scriptPath = m_scriptPath.string();
        if (luaL_loadfile(L, scriptPath.c_str()) != LUA_OK || lua_pcall(L, 0, 0, -2) != LUA_OK)
        {
            printf("[lua] %s\n", lua_tostring(L, -1));
            fflush(stdout);
            lua_close(L);
            return nullptr;
        }
        lua_pop(L, 1);
        return L;
    }

    void closeScript()
    {
        if (m_lua)
        {
            lua_close(m_lua);
            m_lua = nullptr;
        }
    }

    // Replaces the running script with a fresh load of the file, keeping the running one
    // if the new one doesn't load. Window and device stay; changes to `config` need a
    // restart. Pipelines are cached by the host, so the new script gets them back without
    // recompiling.
    void reloadScript()
    {
        lua_State* L = openScript();
        if (!L)
        {
            printf("[lua] '%s' failed to load, keeping the running script\n", m_scriptPath.filename().string().c_str());
            fflush(stdout);
            return;
        }
        callScript("shutdown");
        closeScript();
        m_graph.reset(); // the new script sets up its own
        m_physics.reset();
        m_paused = false; // nor does a pause or a menu's pointer outlive the script
        m_pointerShown = false;
        m_lua = L;
        m_scriptFailed = false;
        printf("[lua] reloaded '%s'\n", m_scriptPath.filename().string().c_str());
        fflush(stdout);
        callScript("init");
    }

    // Reads the window and device settings from the script's global `config` table.
    // (The engine runs on Vulkan only, for now: `config.device` isn't read.)
    void readConfig(std::string& title, int& width, int& height, std::vector<Feature>& features)
    {
        lua_State* L = m_lua;
        if (lua_getglobal(L, "config") != LUA_TTABLE)
        {
            lua_pop(L, 1);
            return;
        }

        if (lua_getfield(L, -1, "title") == LUA_TSTRING)
        {
            title = lua_tostring(L, -1);
        }
        lua_pop(L, 1);
        if (lua_getfield(L, -1, "width") == LUA_TNUMBER)
        {
            width = int(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);
        if (lua_getfield(L, -1, "height") == LUA_TNUMBER)
        {
            height = int(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);

        if (lua_getfield(L, -1, "features") == LUA_TTABLE)
        {
            for (lua_Integer i = 1; i <= lua_Integer(lua_rawlen(L, -1)); ++i)
            {
                lua_rawgeti(L, -1, i);
                const char* entry = lua_tostring(L, -1);
                bool found = false;
                for (int f = 0; entry && f < int(Feature::_Count); ++f)
                {
                    if (strcmp(getRHI()->getFeatureName(Feature(f)), entry) == 0)
                    {
                        features.push_back(Feature(f));
                        found = true;
                    }
                }
                if (!found)
                {
                    printf("[lua] unknown feature '%s' in config.features\n", entry ? entry : "?");
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 2);
    }

    // The GPU the user picked in the settings (lib/settings.lua's graphicsDevice: an
    // adapter's name), if there is a settings file and the script can include
    // lib/settings.lua; empty: none. Runs the script's top level in a state of its own,
    // before any window exists, so the GPU can be picked before anything is created.
    std::string readSavedAdapter()
    {
        lua_State* L = openScript();
        if (!L)
        {
            return {};
        }
        lua_settop(L, 0);
        static const char* kSaved =
            "local ok, values = pcall(function() return rhi.include('lib/settings.lua').load() end)\n"
            "local d = ok and type(values) == 'table' and values.graphicsDevice\n"
            "if type(d) == 'table' then return d.adapter end\n";
        std::string adapter;
        if (luaL_dostring(L, kSaved) == LUA_OK && lua_type(L, 1) == LUA_TSTRING)
        {
            adapter = lua_tostring(L, 1);
        }
        lua_close(L);
        return adapter;
    }

    // Tag for passing the frame object to draw().
    struct FrameArg
    {
    };

    template<typename T>
    static void pushArg(lua_State* L, T value)
    {
        if constexpr (std::is_same_v<T, FrameArg>)
        {
            lua_newuserdatauv(L, 0, 0);
            luaL_setmetatable(L, kFrameType);
        }
        else if constexpr (std::is_same_v<T, bool>)
        {
            lua_pushboolean(L, value);
        }
        else if constexpr (std::is_integral_v<T>)
        {
            lua_pushinteger(L, lua_Integer(value));
        }
        else
        {
            lua_pushnumber(L, lua_Number(value));
        }
    }

    // Calls a global script function, if the script defines it. A script error pauses
    // the script until its file is saved again, rather than repeating every frame.
    template<typename... Args>
    void callScript(const char* name, Args... args)
    {
        if (!m_lua || m_scriptFailed)
        {
            return;
        }
        lua_State* L = m_lua;
        int top = lua_gettop(L);
        lua_pushcfunction(L, traceback);
        if (lua_getglobal(L, name) == LUA_TFUNCTION)
        {
            (pushArg(L, args), ...);
            if (lua_pcall(L, int(sizeof...(Args)), 0, top + 1) != LUA_OK)
            {
                printf("[lua] %s\n[lua] script paused, save it to reload\n", lua_tostring(L, -1));
                fflush(stdout);
                m_scriptFailed = true;
            }
        }
        lua_settop(L, top);
    }

    // -----------------------------------------------------------------------------------
    // Hot reload
    // -----------------------------------------------------------------------------------

    void pollFiles()
    {
        std::vector<std::string> changed = m_watcher.poll();
        if (changed.empty())
        {
            return;
        }
        std::set<std::string> changedFiles(changed.begin(), changed.end());

        // Pipelines about to be replaced may still be referenced by work in flight.
        m_queue->waitOnHost();

        for (auto& [key, pipeline] : m_pipelines)
        {
            bool affected = std::any_of(
                pipeline->files.begin(),
                pipeline->files.end(),
                [&](const std::string& file) { return changedFiles.count(file) != 0; }
            );
            if (!affected)
            {
                continue;
            }
            std::string name = pipeline->path.filename().string();
            if (SLANG_SUCCEEDED(buildPipeline(*pipeline)))
            {
                printf("[lua] reloaded '%s'\n", name.c_str());
            }
            else
            {
                printf("[lua] '%s' failed to compile, keeping the running build\n", name.c_str());
            }
            fflush(stdout);
        }

        bool scriptChanged = changedFiles.count(pathKey(m_scriptPath)) != 0;
        for (const std::string& file : m_includedScripts)
        {
            scriptChanged = scriptChanged || changedFiles.count(file) != 0;
        }
        if (scriptChanged)
        {
            reloadScript();
        }
    }

    // Builds (or rebuilds) a pipeline from its source files. On failure the previous
    // build, if any, stays in place.
    Result buildPipeline(Pipeline& pipeline)
    {
        ShaderSource source;
        bool read = readShaderSource(pipeline.path, {m_scriptDir, fs::path(LUA_SHADERS_DIR)}, source);
        pipeline.files = source.files;
        for (const std::string& file : source.files)
        {
            m_watcher.watch(file);
        }
        if (!read)
        {
            return SLANG_FAIL;
        }

        SLANG_RHI_DEVICE_SCOPE(m_device);
        CompiledProgram compiled;
        SLANG_RETURN_ON_FAIL(compileProgram(
            m_device,
            pathKey(pipeline.path),
            source.text,
            pipeline.entryPoints,
            ++m_buildSerial,
            compiled
        ));

        if (pipeline.isCompute)
        {
            ComputePipelineDesc desc = {};
            desc.program = compiled.program;
            ComPtr<IComputePipeline> compute;
            SLANG_RETURN_ON_FAIL(m_device->createComputePipeline(desc, compute.writeRef()));
            pipeline.compute = compute;
            std::copy_n(compiled.threadGroupSize, 3, pipeline.threadGroupSize);
            pipeline.version += 1;
            return SLANG_OK;
        }

        ComPtr<IInputLayout> inputLayout;
        if (!pipeline.attributes.empty())
        {
            VertexStreamDesc stream = {pipeline.vertexStride, InputSlotClass::PerVertex, 0};
            std::vector<InputElementDesc> elements;
            for (const VertexAttribute& attribute : pipeline.attributes)
            {
                elements.push_back({attribute.semantic.c_str(), 0, attribute.format, attribute.offset, 0});
            }
            InputLayoutDesc layoutDesc = {};
            layoutDesc.inputElements = elements.data();
            layoutDesc.inputElementCount = uint32_t(elements.size());
            layoutDesc.vertexStreams = &stream;
            layoutDesc.vertexStreamCount = 1;
            SLANG_RETURN_ON_FAIL(m_device->createInputLayout(layoutDesc, inputLayout.writeRef()));
        }

        ColorTargetDesc colorTarget = {};
        colorTarget.format = resolveColorFormat(pipeline);
        if (pipeline.blend != Pipeline::Blend::None)
        {
            colorTarget.enableBlend = true;
            BlendFactor src = pipeline.blend == Pipeline::Blend::Alpha ? BlendFactor::SrcAlpha : BlendFactor::One;
            BlendFactor dst = pipeline.blend == Pipeline::Blend::Additive ? BlendFactor::One : BlendFactor::InvSrcAlpha;
            colorTarget.color = {src, dst, BlendOp::Add};
            colorTarget.alpha = {BlendFactor::One, dst, BlendOp::Add};
            if (pipeline.blend == Pipeline::Blend::Accumulate)
            {
                colorTarget.color = {BlendFactor::One, BlendFactor::One, BlendOp::Add};
                colorTarget.alpha = {BlendFactor::One, BlendFactor::One, BlendOp::Min};
            }
        }
        std::vector<ColorTargetDesc> colorTargets = {colorTarget};
        for (Format format : pipeline.extraFormats)
        {
            colorTargets.push_back(colorTarget);
            colorTargets.back().format = format;
        }
        RenderPipelineDesc desc = {};
        desc.program = compiled.program;
        desc.inputLayout = inputLayout;
        desc.primitiveTopology = pipeline.topology;
        desc.targets = pipeline.depthOnly ? nullptr : colorTargets.data();
        desc.targetCount = pipeline.depthOnly ? 0 : uint32_t(colorTargets.size());
        if (pipeline.depth)
        {
            desc.depthStencil.format = kDepthFormat;
            desc.depthStencil.depthTestEnable = true;
            desc.depthStencil.depthWriteEnable = true;
            desc.depthStencil.depthFunc = ComparisonFunc::Less;
        }
        else
        {
            desc.depthStencil.depthTestEnable = false;
            desc.depthStencil.depthWriteEnable = false;
        }
        ComPtr<IRenderPipeline> render;
        SLANG_RETURN_ON_FAIL(m_device->createRenderPipeline(desc, render.writeRef()));
        pipeline.render = render;
        pipeline.version += 1;
        return SLANG_OK;
    }

    // Returns the cached pipeline matching `desc`, building it on first use. A pipeline
    // that fails to build is still returned: it is retried when one of its files is saved.
    std::shared_ptr<Pipeline> getPipeline(std::shared_ptr<Pipeline> desc)
    {
        std::string key = (desc->isCompute ? "compute|" : "render|") + pathKey(desc->path);
        for (const std::string& entryPoint : desc->entryPoints)
        {
            key += "|" + entryPoint;
        }
        for (const VertexAttribute& attribute : desc->attributes)
        {
            key += "|" + attribute.semantic + ":" + std::to_string(int(attribute.format));
        }
        key += "|" + std::to_string(int(desc->topology));
        key += desc->depth ? "|depth" : "";
        key += "|" + std::to_string(int(desc->colorFormat));
        for (Format format : desc->extraFormats)
        {
            key += "+" + std::to_string(int(format));
        }
        key += "|blend" + std::to_string(int(desc->blend));
        key += desc->depthOnly ? "|depthonly" : "";

        auto it = m_pipelines.find(key);
        if (it != m_pipelines.end())
        {
            return it->second;
        }
        if (SLANG_FAILED(buildPipeline(*desc)))
        {
            printf("[lua] '%s' failed to build, it will be retried when saved\n", desc->path.filename().string().c_str());
            fflush(stdout);
        }
        m_pipelines[key] = desc;
        return desc;
    }

    // -----------------------------------------------------------------------------------
    // Resources
    // -----------------------------------------------------------------------------------

    // A 3D texture (rhi.texture with a depth): read and written by shaders, sampled with
    // filtering; not drawn into. Starts out undefined: what uses it writes it first.
    Result allocateVolume(Texture& texture, uint32_t width, uint32_t height, uint32_t depth)
    {
        TextureDesc desc = {};
        desc.type = TextureType::Texture3D;
        desc.size.width = std::max<uint32_t>(width, 1);
        desc.size.height = std::max<uint32_t>(height, 1);
        desc.size.depth = std::max<uint32_t>(depth, 1);
        desc.format = texture.format;
        desc.usage = TextureUsage::UnorderedAccess | TextureUsage::ShaderResource | TextureUsage::CopySource |
                     TextureUsage::CopyDestination;
        desc.label = "Volume Texture";
        ComPtr<ITexture> created;
        SLANG_RETURN_ON_FAIL(m_device->createTexture(desc, nullptr, created.writeRef()));
        texture.texture = created;
        return SLANG_OK;
    }

    Result allocateTexture(Texture& texture, uint32_t width, uint32_t height)
    {
        TextureDesc desc = {};
        desc.type = TextureType::Texture2D;
        desc.size.width = std::max<uint32_t>(width, 1);
        desc.size.height = std::max<uint32_t>(height, 1);
        desc.format = texture.format;
        if (texture.isDepth)
        {
            // Cleared by the first pass that uses it each frame, like the host's own.
            desc.usage = TextureUsage::DepthStencil | TextureUsage::ShaderResource;
            desc.defaultState = ResourceState::DepthWrite;
            desc.label = "Depth Target";
            ComPtr<ITexture> created;
            SLANG_RETURN_ON_FAIL(m_device->createTexture(desc, nullptr, created.writeRef()));
            texture.texture = created;
            return SLANG_OK;
        }
        desc.usage = TextureUsage::UnorderedAccess | TextureUsage::ShaderResource | TextureUsage::RenderTarget |
                     TextureUsage::CopySource | TextureUsage::CopyDestination;
        ComPtr<ITexture> created;
        SLANG_RETURN_ON_FAIL(m_device->createTexture(desc, nullptr, created.writeRef()));

        // D3D12 requires a texture that can be a render target to be cleared before
        // anything else uses it; this also means every texture starts out zeroed. Submitted
        // on its own, so it lands before whatever frame uses the texture.
        ComPtr<ICommandEncoder> encoder = m_queue->createCommandEncoder();
        float zero[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        encoder->clearTextureFloat(created, kEntireTexture, zero);
        m_queue->submit(encoder->finish());

        texture.texture = created;
        return SLANG_OK;
    }

    static uint32_t scaledSize(uint32_t size, float scale)
    {
        return std::max<uint32_t>(1, uint32_t(float(size) * scale + 0.5f));
    }

    void resizeRenderTargets(uint32_t width, uint32_t height)
    {
        auto expired = [](const std::weak_ptr<Texture>& weak) { return weak.expired(); };
        m_renderTargets.erase(
            std::remove_if(m_renderTargets.begin(), m_renderTargets.end(), expired),
            m_renderTargets.end()
        );
        for (const std::weak_ptr<Texture>& weak : m_renderTargets)
        {
            std::shared_ptr<Texture> texture = weak.lock();
            uint32_t scaledWidth = scaledSize(texture->square ? height : width, texture->scale);
            uint32_t scaledHeight = scaledSize(height, texture->scale);
            const TextureDesc& desc = texture->texture->getDesc();
            if (desc.size.width != scaledWidth || desc.size.height != scaledHeight)
            {
                allocateTexture(*texture, scaledWidth, scaledHeight);
            }
        }
    }

    const SteamControllerState& controllerState(int slot) const
    {
        return slot < 0 ? getPrimaryControllerState() : getControllerState(slot);
    }

    Format resolveColorFormat(const Pipeline& pipeline) const
    {
        return pipeline.colorFormat == Format::Undefined ? m_surface->getInfo().preferredFormat : pipeline.colorFormat;
    }

    // What a render pass draws into: the window image, or a texture.
    struct Destination
    {
        ITexture* color = nullptr; // null: depth only
        Format format = Format::Undefined;
        uint32_t width = 0;
        uint32_t height = 0;
        // Where the destination's depth buffer lives.
        ComPtr<ITexture>* depth = nullptr;
        // The depth buffer is the script's (a depth_target): used as it is, never replaced.
        bool scriptDepth = false;
    };

    Destination windowDestination()
    {
        return {m_frame.image, m_surface->getInfo().preferredFormat, m_frame.width, m_frame.height, std::addressof(m_depthTexture)};
    }

    static Destination textureDestination(Texture& texture)
    {
        const TextureDesc& desc = texture.texture->getDesc();
        return {texture.texture, texture.format, desc.size.width, desc.size.height, std::addressof(texture.depth)};
    }

    // Makes `slot` a depth buffer of the given size.
    Result ensureDepthTexture(ComPtr<ITexture>& slot, uint32_t width, uint32_t height)
    {
        if (slot && slot->getDesc().size.width == width && slot->getDesc().size.height == height)
        {
            return SLANG_OK;
        }
        TextureDesc desc = {};
        desc.type = TextureType::Texture2D;
        desc.size.width = std::max<uint32_t>(width, 1);
        desc.size.height = std::max<uint32_t>(height, 1);
        desc.format = kDepthFormat;
        desc.usage = TextureUsage::DepthStencil;
        desc.defaultState = ResourceState::DepthWrite;
        desc.label = "Depth Buffer";
        slot.setNull();
        return m_device->createTexture(desc, nullptr, slot.writeRef());
    }

    // Begins a pass on a destination. A clear color clears it (and its depth buffer, if
    // the pass uses it); otherwise the pass draws over what is there. A depth buffer is
    // also cleared the first time it is used in a frame.
    IRenderPassEncoder* beginRenderPass(
        const Destination& destination,
        const float* clearColor,
        bool depth = false,
        const std::vector<std::shared_ptr<Texture>>* extraTargets = nullptr
    )
    {
        std::vector<RenderPassColorAttachment> colorAttachments;
        RenderPassDesc renderPass = {};
        if (destination.color)
        {
            std::vector<ITexture*> textures = {destination.color};
            if (extraTargets)
            {
                for (const std::shared_ptr<Texture>& extra : *extraTargets)
                    textures.push_back(extra->texture);
            }
            for (ITexture* texture : textures)
            {
                RenderPassColorAttachment colorAttachment = {};
                colorAttachment.view = texture->getDefaultView();
                colorAttachment.loadOp = clearColor ? LoadOp::Clear : LoadOp::Load;
                if (clearColor)
                {
                    std::copy_n(clearColor, 4, colorAttachment.clearValue);
                }
                colorAttachments.push_back(colorAttachment);
            }
            renderPass.colorAttachments = colorAttachments.data();
            renderPass.colorAttachmentCount = uint32_t(colorAttachments.size());
        }
        if (clearColor && *destination.depth)
        {
            m_frame.validDepth.erase(destination.depth->get());
        }

        RenderPassDepthStencilAttachment depthAttachment = {};
        bool haveDepth = destination.scriptDepth
                             ? bool(*destination.depth)
                             : SLANG_SUCCEEDED(ensureDepthTexture(*destination.depth, destination.width, destination.height));
        if (depth && haveDepth)
        {
            ITexture* depthTexture = destination.depth->get();
            depthAttachment.view = depthTexture->getDefaultView();
            depthAttachment.depthLoadOp = m_frame.validDepth.count(depthTexture) ? LoadOp::Load : LoadOp::Clear;
            depthAttachment.depthClearValue = 1.0f;
            renderPass.depthStencilAttachment = &depthAttachment;
            m_frame.validDepth.insert(depthTexture);
        }
        return m_frame.encoder->beginRenderPass(renderPass);
    }

    // -----------------------------------------------------------------------------------
    // Shader parameters
    // -----------------------------------------------------------------------------------

    static void collectNumbers(lua_State* L, int index, std::vector<lua_Number>& out)
    {
        switch (lua_type(L, index))
        {
        case LUA_TNUMBER:
            out.push_back(lua_tonumber(L, index));
            break;
        case LUA_TBOOLEAN:
            out.push_back(lua_toboolean(L, index) ? 1.0 : 0.0);
            break;
        case LUA_TTABLE:
        {
            index = lua_absindex(L, index);
            lua_Integer count = lua_Integer(lua_rawlen(L, index));
            for (lua_Integer i = 1; i <= count; ++i)
            {
                lua_rawgeti(L, index, i);
                collectNumbers(L, -1, out);
                lua_pop(L, 1);
            }
            break;
        }
        default:
            break;
        }
    }

    template<typename T>
    static void appendValue(std::vector<uint8_t>& bytes, T value)
    {
        const uint8_t* p = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), p, p + sizeof(T));
    }

    // Sets a scalar, vector or matrix from numbers, converted to the shader's type.
    // Matrices are taken as tightly packed rows.
    static bool setNumbers(const ShaderCursor& cursor, const std::vector<lua_Number>& values)
    {
        slang::TypeLayoutReflection* typeLayout = cursor.getTypeLayout();
        slang::TypeReflection* type = typeLayout->getType();
        size_t count = 1;
        switch (typeLayout->getKind())
        {
        case slang::TypeReflection::Kind::Scalar:
            break;
        case slang::TypeReflection::Kind::Vector:
            count = type->getElementCount();
            break;
        case slang::TypeReflection::Kind::Matrix:
            count = size_t(type->getRowCount()) * type->getColumnCount();
            break;
        default:
            return false;
        }
        slang::TypeLayoutReflection* leaf = typeLayout;
        while (leaf && (leaf->getKind() == slang::TypeReflection::Kind::Vector ||
                        leaf->getKind() == slang::TypeReflection::Kind::Matrix))
        {
            leaf = leaf->getElementTypeLayout();
        }
        if (!leaf)
        {
            return false;
        }

        std::vector<uint8_t> bytes;
        for (size_t i = 0; i < count; ++i)
        {
            lua_Number value = i < values.size() ? values[i] : 0.0;
            switch (leaf->getType()->getScalarType())
            {
            case slang::TypeReflection::ScalarType::Int32:
                appendValue(bytes, int32_t(value));
                break;
            case slang::TypeReflection::ScalarType::UInt32:
            case slang::TypeReflection::ScalarType::Bool:
                appendValue(bytes, uint32_t(value));
                break;
            case slang::TypeReflection::ScalarType::Int64:
                appendValue(bytes, int64_t(value));
                break;
            case slang::TypeReflection::ScalarType::UInt64:
                appendValue(bytes, uint64_t(value));
                break;
            case slang::TypeReflection::ScalarType::Float64:
                appendValue(bytes, double(value));
                break;
            case slang::TypeReflection::ScalarType::Float32:
                appendValue(bytes, float(value));
                break;
            default:
                return false;
            }
        }
        cursor.setData(bytes.data(), bytes.size());
        return true;
    }

    // Captures the Lua value at `index` as a ParamValue.
    static ParamValue toParamValue(lua_State* L, int index)
    {
        index = lua_absindex(L, index);
        ParamValue value;
        if (auto texture = testShared<Texture>(L, index, kTextureType))
        {
            value.kind = ParamValue::Kind::Texture;
            value.texture = texture;
            return value;
        }
        if (auto sampler = testShared<Sampler>(L, index, kSamplerType))
        {
            value.kind = ParamValue::Kind::Sampler;
            value.sampler = sampler;
            return value;
        }
        if (auto buffer = testShared<Buffer>(L, index, kBufferType))
        {
            value.kind = ParamValue::Kind::Buffer;
            value.buffer = buffer;
            return value;
        }
        if (int* slot = static_cast<int*>(luaL_testudata(L, index, kControllerType)))
        {
            value.kind = ParamValue::Kind::Controller;
            value.controllerSlot = *slot;
            return value;
        }
        switch (lua_type(L, index))
        {
        case LUA_TNUMBER:
            value.numbers.push_back(lua_tonumber(L, index));
            return value;
        case LUA_TBOOLEAN:
            value.numbers.push_back(lua_toboolean(L, index) ? 1.0 : 0.0);
            return value;
        case LUA_TTABLE:
        {
            value.kind = ParamValue::Kind::Table;
            lua_Integer count = lua_Integer(lua_rawlen(L, index));
            for (lua_Integer i = 1; i <= count; ++i)
            {
                lua_rawgeti(L, index, i);
                value.elements.push_back(toParamValue(L, -1));
                lua_pop(L, 1);
            }
            lua_pushnil(L);
            while (lua_next(L, index))
            {
                if (lua_type(L, -2) == LUA_TSTRING)
                {
                    value.fieldNames.push_back(lua_tostring(L, -2));
                    value.fieldValues.push_back(toParamValue(L, -1));
                }
                lua_pop(L, 1);
            }
            return value;
        }
        default:
            luaL_error(L, "a %s can't be a shader parameter", luaL_typename(L, index));
            return value;
        }
    }

    // All the numbers in a value, depth first, for scalars, vectors and matrices.
    static void flattenNumbers(const ParamValue& value, std::vector<double>& out)
    {
        out.insert(out.end(), value.numbers.begin(), value.numbers.end());
        for (const ParamValue& element : value.elements)
        {
            flattenNumbers(element, out);
        }
    }

    // Sets one shader parameter, following the shader's type: tables of named fields fill
    // structs, arrays fill arrays, numbers fill scalars/vectors/matrices, and handles bind
    // resources. Parameters the shader doesn't declare are skipped, so one set of values
    // can feed shaders that use different subsets. Returns an error message, or "".
    std::string applyParam(const ParamValue& value, const ShaderCursor& cursor, const std::string& name)
    {
        if (!cursor.isValid())
        {
            return {};
        }
        switch (value.kind)
        {
        case ParamValue::Kind::Texture:
            cursor.setBinding(value.texture->texture);
            return {};
        case ParamValue::Kind::Buffer:
            cursor.setBinding(value.buffer->buffer);
            return {};
        case ParamValue::Kind::Sampler:
            cursor.setBinding(Binding(value.sampler->sampler.get()));
            return {};
        case ParamValue::Kind::Controller:
            bindSteamControllerState(cursor, controllerState(value.controllerSlot));
            return {};
        default:
            break;
        }

        switch (cursor.getTypeLayout()->getKind())
        {
        case slang::TypeReflection::Kind::Struct:
            if (value.kind != ParamValue::Kind::Table)
            {
                return "shader parameter '" + name + "' is a struct, pass a table";
            }
            return applyFields(value, cursor);
        case slang::TypeReflection::Kind::Array:
            if (value.kind == ParamValue::Kind::Table && !value.elements.empty())
            {
                size_t count = value.elements.size();
                size_t capacity = cursor.getTypeLayout()->getElementCount();
                if (capacity != 0)
                {
                    count = std::min(count, capacity);
                }
                for (size_t i = 0; i < count; ++i)
                {
                    std::string error = applyParam(value.elements[i], cursor.getElement(uint32_t(i)), name);
                    if (!error.empty())
                    {
                        return error;
                    }
                }
                return {};
            }
            break;
        default:
        {
            std::vector<double> numbers;
            flattenNumbers(value, numbers);
            if (!numbers.empty() && setNumbers(cursor, numbers))
            {
                return {};
            }
            break;
        }
        }
        return "can't set shader parameter '" + name + "' from this value";
    }

    // Sets the shader parameters named by a table's fields.
    std::string applyFields(const ParamValue& table, const ShaderCursor& cursor)
    {
        for (size_t i = 0; i < table.fieldNames.size(); ++i)
        {
            const std::string& name = table.fieldNames[i];
            std::string error = applyParam(table.fieldValues[i], cursor[name.c_str()], name);
            if (!error.empty())
            {
                return error;
            }
        }
        return {};
    }

    std::string applyBlocks(const ShaderCursor& root, const std::vector<std::shared_ptr<ParamBlock>>& blocks)
    {
        for (const std::shared_ptr<ParamBlock>& block : blocks)
        {
            for (size_t i = 0; i < block->names.size(); ++i)
            {
                const std::string& name = block->names[i];
                std::string error = applyParam(block->values[i], root[name.c_str()], name);
                if (!error.empty())
                {
                    return error;
                }
            }
        }
        return {};
    }

    // Values the host provides to every draw and dispatch, if the shader declares them:
    // `time` (seconds), `timeDelta` (the seconds `time` moved since the last frame: 0
    // while paused), `frameCounter` (a uint: frames drawn so far) and `viewportSize`
    // (pixels). Set before the script's parameters,
    // which can override them.
    void applyBuiltins(const ShaderCursor& root, float viewportWidth, float viewportHeight)
    {
        ShaderCursor time = root["time"];
        if (time.isValid())
        {
            setNumbers(time, {m_shaderTime});
        }
        ShaderCursor frameCounter = root["frameCounter"];
        if (frameCounter.isValid())
        {
            uint32_t frame = m_frameIndex;
            frameCounter.setData(&frame, sizeof(frame));
        }
        ShaderCursor timeDelta = root["timeDelta"];
        if (timeDelta.isValid())
        {
            setNumbers(timeDelta, {m_paused ? 0.0 : m_timeDelta});
        }
        ShaderCursor viewportSize = root["viewportSize"];
        if (viewportSize.isValid())
        {
            setNumbers(viewportSize, {viewportWidth, viewportHeight});
        }
    }

    // Sets the shader parameters named by the keys of the table at `index`.
    static void setParams(lua_State* L, int index, const ShaderCursor& cursor)
    {
        luaL_checktype(L, index, LUA_TTABLE);
        ParamValue table = toParamValue(L, index);
        std::string error = get(L)->applyFields(table, cursor);
        if (!error.empty())
        {
            luaL_error(L, "%s", error.c_str());
        }
    }

    // -----------------------------------------------------------------------------------
    // Running the render graph
    // -----------------------------------------------------------------------------------

    static void report(bool& reported, const std::string& where, const std::string& error)
    {
        if (!error.empty() && !reported)
        {
            printf("[lua] graph '%s': %s\n", where.c_str(), error.c_str());
            fflush(stdout);
            reported = true;
        }
    }

    static RenderState renderStateFor(const float viewport[4])
    {
        RenderState renderState = {};
        Viewport& vp = renderState.viewports[0];
        vp.originX = viewport[0];
        vp.originY = viewport[1];
        vp.extentX = viewport[2];
        vp.extentY = viewport[3];
        vp.minZ = 0.0f;
        vp.maxZ = 1.0f;
        renderState.viewportCount = 1;
        ScissorRect& scissor = renderState.scissorRects[0];
        scissor.minX = uint32_t(std::max(0.0f, viewport[0]));
        scissor.minY = uint32_t(std::max(0.0f, viewport[1]));
        scissor.maxX = uint32_t(std::max(0.0f, viewport[0] + viewport[2]));
        scissor.maxY = uint32_t(std::max(0.0f, viewport[1] + viewport[3]));
        renderState.scissorRectCount = 1;
        return renderState;
    }

    void runDispatch(GraphNode& node)
    {
        Pipeline* pipeline = node.pipeline.get();
        // The size the dispatch covers: the window's, unless it covers a texture.
        float coverage[2] = {float(m_frame.width), float(m_frame.height)};
        if (node.threadsTexture)
        {
            const TextureDesc& desc = node.threadsTexture->texture->getDesc();
            coverage[0] = float(desc.size.width);
            coverage[1] = float(desc.size.height);
        }
        if (node.threadsPerPixel || node.threadsTexture)
        {
            node.threads[0] = uint32_t(coverage[0]);
            node.threads[1] = uint32_t(coverage[1]);
            node.threads[2] = 1;
        }
        if (!pipeline->compute || node.threads[0] == 0 || node.threads[1] == 0 || node.threads[2] == 0)
        {
            return;
        }
        if (node.once && !node.pending && node.ranVersion == pipeline->version)
        {
            return;
        }
        IComputePassEncoder* pass = m_frame.encoder->beginComputePass();
        PassScope<IComputePassEncoder> scope{pass};
        ShaderCursor root(pass->bindPipeline(pipeline->compute));
        applyBuiltins(root, coverage[0], coverage[1]);
        report(node.reported, node.name, applyBlocks(root, node.params));
        pass->dispatchCompute(
            divRoundUp(node.threads[0], pipeline->threadGroupSize[0]),
            divRoundUp(node.threads[1], pipeline->threadGroupSize[1]),
            divRoundUp(node.threads[2], pipeline->threadGroupSize[2])
        );
        node.pending = false;
        node.ranVersion = pipeline->version;
    }

    void runRenderPass(GraphNode& node)
    {
        Destination destination = node.target ? textureDestination(*node.target) : windowDestination();
        if (node.depthTarget)
        {
            destination.depth = std::addressof(node.depthTarget->texture);
            destination.scriptDepth = true;
        }
        if (node.depthOnly)
        {
            const TextureDesc& desc = node.depthTarget->texture->getDesc();
            destination.color = nullptr;
            destination.format = Format::Undefined;
            destination.width = desc.size.width;
            destination.height = desc.size.height;
        }
        float viewport[4] = {0.0f, 0.0f, float(destination.width), float(destination.height)};
        if (node.viewportMode == GraphNode::ViewportMode::Pixels)
        {
            std::copy_n(node.viewport, 4, viewport);
        }
        else if (node.viewportMode == GraphNode::ViewportMode::Fraction)
        {
            viewport[0] = node.viewport[0] * destination.width;
            viewport[1] = node.viewport[1] * destination.height;
            viewport[2] = node.viewport[2] * destination.width;
            viewport[3] = node.viewport[3] * destination.height;
        }

        // A depth-only pass always has its depth buffer, and so does a pass that clears a
        // depth target of the script's (so that the clear happens even with nothing drawn);
        // others when a draw tests depth.
        bool depth = node.depthOnly || (node.depthTarget && node.clear);
        for (const std::shared_ptr<GraphDraw>& draw : node.draws)
        {
            depth = depth || (draw->enabled && draw->pipeline->depth);
        }

        IRenderPassEncoder* pass = beginRenderPass(destination, node.clear ? node.clearColor : nullptr, depth, &node.extraTargets);
        PassScope<IRenderPassEncoder> scope{pass};
        for (const std::shared_ptr<GraphDraw>& draw : node.draws)
        {
            Pipeline* pipeline = draw->pipeline.get();
            uint32_t instances = draw->instanceGroup ? uint32_t(draw->instanceGroup->ids.size()) : draw->instances;
            if (!draw->enabled || !pipeline->render || draw->count == 0 || instances == 0)
            {
                continue;
            }
            bool extrasMatch = pipeline->extraFormats.size() == node.extraTargets.size();
            for (size_t i = 0; extrasMatch && i < node.extraTargets.size(); ++i)
            {
                extrasMatch = pipeline->extraFormats[i] == node.extraTargets[i]->format;
            }
            if (pipeline->depthOnly != node.depthOnly ||
                (!pipeline->depthOnly && (resolveColorFormat(*pipeline) != destination.format || !extrasMatch)))
            {
                report(draw->reported, node.name, "a draw's pipeline format doesn't match the pass's target");
                continue;
            }
            ShaderCursor root(pass->bindPipeline(pipeline->render));
            applyBuiltins(root, viewport[2], viewport[3]);
            report(draw->reported, node.name, applyBlocks(root, draw->params));

            RenderState renderState = renderStateFor(viewport);
            if (draw->vertices)
            {
                renderState.vertexBuffers[0].buffer = draw->vertices->buffer;
                renderState.vertexBufferCount = 1;
            }
            pass->setRenderState(renderState);
            DrawArguments drawArgs = {};
            drawArgs.vertexCount = draw->count;
            drawArgs.instanceCount = instances;
            pass->draw(drawArgs);
        }
    }

    // GPU timing of graph nodes: timestamps before and after every timed node, in a ring
    // of kTimingFrames frames of query slots, so that a frame's results are read (without
    // waiting) when its slots come round again.
    static constexpr uint32_t kTimingFrames = 3;
    static constexpr uint32_t kMaxTimedNodes = 32;
    struct TimedNode
    {
        std::weak_ptr<GraphNode> node;
        uint32_t slot = 0; // its first timestamp: the second is the next slot
    };
    ComPtr<IQueryPool> m_timestamps;
    bool m_timestampsTried = false;
    double m_timestampFrequency = 0.0;
    std::vector<TimedNode> m_timedNodes[kTimingFrames];

    IQueryPool* timestampPool()
    {
        if (!m_timestampsTried)
        {
            m_timestampsTried = true;
            m_timestampFrequency = double(m_device->getInfo().timestampFrequency);
            if (m_device->hasFeature(Feature::TimestampQuery) && m_timestampFrequency > 0.0)
            {
                QueryPoolDesc desc = {};
                desc.type = QueryType::Timestamp;
                desc.count = kTimingFrames * kMaxTimedNodes * 2;
                desc.label = "Graph node timing";
                if (SLANG_FAILED(m_device->createQueryPool(desc, m_timestamps.writeRef())))
                    m_timestamps = nullptr;
            }
            if (!m_timestamps)
            {
                printf("[lua] this device has no timestamp queries: timed nodes have no gpu_time\n");
                fflush(stdout);
            }
        }
        return m_timestamps.get();
    }

    // Reads what the timed nodes of the frame that last used this ring slot measured, if
    // it is ready; then the slot is free for this frame.
    void collectTimings(uint32_t ring)
    {
        std::vector<TimedNode>& timed = m_timedNodes[ring];
        for (const TimedNode& t : timed)
        {
            std::shared_ptr<GraphNode> node = t.node.lock();
            if (!node)
                continue;
            QueryResultState state;
            if (SLANG_FAILED(m_timestamps->getResultState(t.slot, 2, &state)) || state != QueryResultState::Resolved)
                continue;
            uint64_t ticks[2];
            if (SLANG_FAILED(m_timestamps->getResult(t.slot, 2, ticks)) || ticks[1] < ticks[0])
                continue;
            double ms = double(ticks[1] - ticks[0]) / m_timestampFrequency * 1000.0;
            // Smoothed; a `once` node's is its last run's.
            node->gpuTime = node->gpuTime < 0.0 || node->once ? ms : node->gpuTime * 0.9 + ms * 0.1;
        }
        timed.clear();
    }

    // Whether runDispatch will skip the node this frame: no pipeline to run, or a `once`
    // dispatch that has run already. Timing it would time nothing.
    static bool dispatchSkips(const GraphNode& node)
    {
        const Pipeline* pipeline = node.pipeline.get();
        return !pipeline || !pipeline->compute || (node.once && !node.pending && node.ranVersion == pipeline->version);
    }

    void runGraph(Graph& graph)
    {
        IQueryPool* pool = nullptr;
        uint32_t ring = uint32_t(m_frameIndex % kTimingFrames);
        for (const std::shared_ptr<GraphNode>& node : graph.nodes)
        {
            if (node->timed)
            {
                pool = timestampPool();
                break;
            }
        }
        if (pool)
            collectTimings(ring);

        for (const std::shared_ptr<GraphNode>& node : graph.nodes)
        {
            if (!node->enabled)
            {
                continue;
            }
            uint32_t slot = 0;
            bool timing = pool && node->timed && m_timedNodes[ring].size() < kMaxTimedNodes &&
                          !(node->isDispatch && dispatchSkips(*node));
            if (timing)
            {
                slot = (ring * kMaxTimedNodes + uint32_t(m_timedNodes[ring].size())) * 2;
                m_frame.encoder->writeTimestamp(pool, slot);
            }
            if (node->isDispatch)
            {
                runDispatch(*node);
            }
            else
            {
                runRenderPass(*node);
            }
            if (timing)
            {
                m_frame.encoder->writeTimestamp(pool, slot + 1);
                m_timedNodes[ring].push_back({node, slot});
            }
        }
    }

    // -----------------------------------------------------------------------------------
    // API: rhi.*
    // -----------------------------------------------------------------------------------

    // An asset path from a script: relative to the script if there is such a file there,
    // else relative to the shared assets folder.
    fs::path resolveAssetPath(const std::string& name) const
    {
        std::error_code ec;
        fs::path local = m_scriptDir / name;
        if (fs::path(name).is_absolute() || fs::is_regular_file(local, ec))
        {
            return local;
        }
        return fs::path(LUA_ASSETS_DIR) / name;
    }

    // An asset that is missing (or doesn't read), standing in for which is `instead`: said
    // once per file, and the file is watched like an include, so the script reloads when
    // it turns up.
    void warnMissingAsset(const fs::path& path, const std::string& error, const char* instead = "a placeholder")
    {
        std::string key = pathKey(path);
        if (m_warnedAssets.insert(key).second)
        {
            printf("[lua] %s: %s; using %s until it is there\n", path.generic_string().c_str(), error.c_str(), instead);
            fflush(stdout);
        }
        m_watcher.watch(key);
        m_includedScripts.insert(key);
    }

    // A shader path from a script: relative to the script if there is such a file there,
    // else relative to the shared shaders folder.
    fs::path resolveShaderPath(const std::string& name) const
    {
        std::error_code ec;
        fs::path local = m_scriptDir / name;
        if (fs::path(name).is_absolute() || fs::is_regular_file(local, ec))
        {
            return local;
        }
        return fs::path(LUA_SHADERS_DIR) / name;
    }

    static LuaApp* requireDevice(lua_State* L)
    {
        LuaApp* app = get(L);
        if (!app->m_device)
        {
            luaL_error(L, "GPU resources can be created from init() on, not while the script loads");
        }
        return app;
    }

    static const FormatName* checkFormat(lua_State* L, const char* name)
    {
        const FormatName* format = findFormat(name);
        if (!format)
        {
            luaL_error(L, "unknown format '%s'", name);
        }
        return format;
    }

    // rhi.compute_pipeline(path [, entryPoint = "mainCompute"])
    static int apiComputePipeline(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto desc = std::make_shared<Pipeline>();
        desc->path = app->resolveShaderPath(luaL_checkstring(L, 1));
        desc->entryPoints = {luaL_optstring(L, 2, "mainCompute")};
        desc->isCompute = true;
        pushHandle(L, app->getPipeline(desc), kPipelineType);
        return 1;
    }

    // rhi.render_pipeline{ shader = path, vertex = "vertexMain", fragment = "fragmentMain",
    //                      layout = { {semantic, format}, ... }, topology = "triangles",
    //                      format = "rgba16f" | formats = { "rgba16f", ... } (more targets:
    //                      SV_Target1, ..., blended as the first), depth, blend }
    static int apiRenderPipeline(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        auto desc = std::make_shared<Pipeline>();
        desc->isCompute = false;

        lua_getfield(L, 1, "shader");
        desc->path = app->resolveShaderPath(luaL_checkstring(L, -1));
        lua_getfield(L, 1, "vertex");
        lua_getfield(L, 1, "fragment");
        desc->entryPoints = {luaL_optstring(L, -2, "vertexMain"), luaL_optstring(L, -1, "fragmentMain")};
        lua_pop(L, 3);

        if (lua_getfield(L, 1, "layout") == LUA_TTABLE)
        {
            for (lua_Integer i = 1; i <= lua_Integer(lua_rawlen(L, -1)); ++i)
            {
                lua_rawgeti(L, -1, i);
                luaL_checktype(L, -1, LUA_TTABLE);
                lua_rawgeti(L, -1, 1);
                lua_rawgeti(L, -2, 2);
                const FormatName* format = checkFormat(L, luaL_checkstring(L, -1));
                desc->attributes.push_back({luaL_checkstring(L, -2), format->format, desc->vertexStride});
                desc->vertexStride += format->size;
                lua_pop(L, 3);
            }
        }
        lua_pop(L, 1);

        static const std::pair<const char*, PrimitiveTopology> kTopologies[] = {
            {"triangles", PrimitiveTopology::TriangleList},
            {"triangle-strip", PrimitiveTopology::TriangleStrip},
            {"lines", PrimitiveTopology::LineList},
            {"line-strip", PrimitiveTopology::LineStrip},
            {"points", PrimitiveTopology::PointList},
        };
        lua_getfield(L, 1, "topology");
        const char* topology = luaL_optstring(L, -1, "triangles");
        auto found = std::find_if(
            std::begin(kTopologies),
            std::end(kTopologies),
            [&](const auto& entry) { return strcmp(entry.first, topology) == 0; }
        );
        if (found == std::end(kTopologies))
        {
            luaL_error(L, "unknown topology '%s'", topology);
        }
        desc->topology = found->second;
        lua_pop(L, 1);

        lua_getfield(L, 1, "depth");
        desc->depth = lua_toboolean(L, -1);
        lua_pop(L, 1);

        if (lua_getfield(L, 1, "formats") == LUA_TTABLE)
        {
            int count = int(lua_rawlen(L, -1));
            if (count == 0)
                luaL_error(L, "formats needs at least one format");
            for (int i = 1; i <= count; ++i)
            {
                lua_rawgeti(L, -1, i);
                Format format = checkFormat(L, luaL_checkstring(L, -1))->format;
                if (i == 1)
                    desc->colorFormat = format;
                else
                    desc->extraFormats.push_back(format);
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        if (lua_getfield(L, 1, "format") != LUA_TNIL)
        {
            const char* format = luaL_checkstring(L, -1);
            if (strcmp(format, "none") == 0)
            {
                desc->depthOnly = true;
                desc->depth = true;
            }
            else
            {
                desc->colorFormat = checkFormat(L, format)->format;
            }
        }
        lua_pop(L, 1);

        static const std::pair<const char*, Pipeline::Blend> kBlends[] = {
            {"none", Pipeline::Blend::None},
            {"alpha", Pipeline::Blend::Alpha},
            {"premultiplied", Pipeline::Blend::Premultiplied},
            {"additive", Pipeline::Blend::Additive},
            {"accumulate", Pipeline::Blend::Accumulate},
        };
        lua_getfield(L, 1, "blend");
        const char* blend = luaL_optstring(L, -1, "none");
        auto foundBlend = std::find_if(
            std::begin(kBlends),
            std::end(kBlends),
            [&](const auto& entry) { return strcmp(entry.first, blend) == 0; }
        );
        if (foundBlend == std::end(kBlends))
        {
            luaL_error(L, "unknown blend '%s'", blend);
        }
        desc->blend = foundBlend->second;
        lua_pop(L, 1);

        pushHandle(L, app->getPipeline(desc), kPipelineType);
        return 1;
    }

    // A window-following target's shape: "square" makes both sides scale x the window's
    // height; nothing (or "window") keeps the window's aspect.
    static bool checkSquare(lua_State* L, int index)
    {
        const char* shape = luaL_optstring(L, index, "window");
        if (strcmp(shape, "square") != 0 && strcmp(shape, "window") != 0)
            luaL_error(L, "shape must be \"window\" or \"square\"");
        return strcmp(shape, "square") == 0;
    }

    void initialTargetSize(const Texture& texture, uint32_t& width, uint32_t& height)
    {
        const SurfaceConfig* config = m_surface->getConfig();
        uint32_t windowWidth = config ? config->width : 1;
        uint32_t windowHeight = config ? config->height : 1;
        width = scaledSize(texture.square ? windowHeight : windowWidth, texture.scale);
        height = scaledSize(windowHeight, texture.scale);
    }

    // rhi.render_target([format = "rgba32f" [, scale = 1 [, "square"]]]): a texture that
    // follows the window size (times `scale`) -- or, "square", scale x the window's height
    // on both sides.
    static int apiRenderTarget(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto texture = std::make_shared<Texture>();
        texture->format = checkFormat(L, luaL_optstring(L, 1, "rgba32f"))->format;
        texture->followsSurface = true;
        texture->scale = float(luaL_optnumber(L, 2, 1.0));
        texture->square = checkSquare(L, 3);
        if (texture->scale <= 0.0f)
        {
            luaL_error(L, "render_target scale must be positive");
        }
        uint32_t width, height;
        app->initialTargetSize(*texture, width, height);
        if (SLANG_FAILED(app->allocateTexture(*texture, width, height)))
        {
            luaL_error(L, "could not create render target");
        }
        app->m_renderTargets.push_back(texture);
        pushHandle(L, texture, kTextureType);
        return 1;
    }

    // rhi.depth_target([scale = 1 [, "square"]]): a depth buffer that follows the window
    // size (times `scale`; "square" as for render_target), for a render pass's
    // depth_target; shaders read it as Texture2D<float>.
    static int apiDepthTarget(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto texture = std::make_shared<Texture>();
        texture->format = kDepthFormat;
        texture->isDepth = true;
        texture->followsSurface = true;
        texture->scale = float(luaL_optnumber(L, 1, 1.0));
        texture->square = checkSquare(L, 2);
        if (texture->scale <= 0.0f)
        {
            luaL_error(L, "depth_target scale must be positive");
        }
        uint32_t width, height;
        app->initialTargetSize(*texture, width, height);
        if (SLANG_FAILED(app->allocateTexture(*texture, width, height)))
        {
            luaL_error(L, "could not create depth target");
        }
        app->m_renderTargets.push_back(texture);
        pushHandle(L, texture, kTextureType);
        return 1;
    }

    // rhi.texture{ width = w, height = h, [depth = d,] format = "rgba32f" }: with a depth,
    // a 3D texture (Texture3D / RWTexture3D in shaders).
    static int apiTexture(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_getfield(L, 1, "width");
        lua_getfield(L, 1, "height");
        lua_getfield(L, 1, "format");
        lua_getfield(L, 1, "depth");
        auto texture = std::make_shared<Texture>();
        texture->format = checkFormat(L, luaL_optstring(L, -2, "rgba32f"))->format;
        uint32_t width = uint32_t(luaL_checkinteger(L, -4));
        uint32_t height = uint32_t(luaL_checkinteger(L, -3));
        bool volume = !lua_isnil(L, -1);
        uint32_t depth = volume ? uint32_t(luaL_checkinteger(L, -1)) : 1;
        lua_pop(L, 4);
        Result result = volume ? app->allocateVolume(*texture, width, height, depth)
                               : app->allocateTexture(*texture, width, height);
        if (SLANG_FAILED(result))
        {
            luaL_error(L, "could not create texture");
        }
        pushHandle(L, texture, kTextureType);
        return 1;
    }

    static std::vector<float> checkFloats(lua_State* L, int index)
    {
        luaL_checktype(L, index, LUA_TTABLE);
        std::vector<lua_Number> numbers;
        collectNumbers(L, index, numbers);
        std::vector<float> floats;
        for (lua_Number number : numbers)
        {
            floats.push_back(float(number));
        }
        return floats;
    }

    // rhi.vertex_buffer{ floats... }
    static int apiVertexBuffer(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        std::vector<float> data = checkFloats(L, 1);
        auto buffer = std::make_shared<Buffer>();
        BufferDesc desc = {};
        desc.size = std::max<size_t>(data.size(), 1) * sizeof(float);
        desc.usage = BufferUsage::VertexBuffer;
        desc.defaultState = ResourceState::VertexBuffer;
        desc.label = "Vertex Buffer";
        data.resize(desc.size / sizeof(float));
        if (SLANG_FAILED(app->m_device->createBuffer(desc, data.data(), buffer->buffer.writeRef())))
        {
            luaL_error(L, "could not create vertex buffer");
        }
        buffer->size = desc.size;
        pushHandle(L, buffer, kBufferType);
        return 1;
    }

    // rhi.buffer(sizeInBytes) or rhi.buffer{ floats... }: a read/write shader buffer.
    static int apiBuffer(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        std::vector<float> data;
        if (lua_istable(L, 1))
        {
            data = checkFloats(L, 1);
        }
        else
        {
            data.resize((size_t(luaL_checkinteger(L, 1)) + sizeof(float) - 1) / sizeof(float));
        }
        data.resize(std::max<size_t>(data.size(), 1));
        auto buffer = std::make_shared<Buffer>();
        BufferDesc desc = {};
        desc.size = data.size() * sizeof(float);
        desc.usage = BufferUsage::ShaderResource | BufferUsage::UnorderedAccess | BufferUsage::CopySource |
                     BufferUsage::CopyDestination;
        desc.defaultState = ResourceState::UnorderedAccess;
        if (SLANG_FAILED(app->m_device->createBuffer(desc, data.data(), buffer->buffer.writeRef())))
        {
            luaL_error(L, "could not create buffer");
        }
        buffer->size = desc.size;
        pushHandle(L, buffer, kBufferType);
        return 1;
    }

    static int apiDevice(lua_State* L)
    {
        LuaApp* app = get(L);
        lua_pushstring(L, app->m_device ? getRHI()->getDeviceTypeName(app->m_device->getInfo().deviceType) : "");
        return 1;
    }

    // rhi.adapter(): the name of the graphics adapter the device runs on.
    static int apiAdapter(lua_State* L)
    {
        LuaApp* app = get(L);
        lua_pushstring(L, app->m_device ? app->m_device->getInfo().adapterName : "");
        return 1;
    }

    // rhi.devices(): the GPUs the script could run on -- { { adapter = name, type =
    // "discrete" | "integrated" | "unknown" }, ... }: the hardware adapters Vulkan has (no
    // software renderers), each once by name (adapters are picked by name, and some
    // drivers list one twice).
    static int apiDevices(lua_State* L)
    {
        lua_newtable(L);
        int n = 0;
        std::set<std::string> seen;
        for (uint32_t i = 0;; ++i)
        {
            IAdapter* adapter = getRHI()->getAdapter(kEngineDeviceType, i);
            if (!adapter)
                break;
            const AdapterInfo& info = adapter->getInfo();
            if (info.adapterType == AdapterType::Software || !seen.insert(info.name).second)
                continue;
            const char* kind = info.adapterType == AdapterType::Discrete     ? "discrete"
                               : info.adapterType == AdapterType::Integrated ? "integrated"
                                                                             : "unknown";
            lua_newtable(L);
            lua_pushstring(L, info.name);
            lua_setfield(L, -2, "adapter");
            lua_pushstring(L, kind);
            lua_setfield(L, -2, "type");
            lua_rawseti(L, -2, ++n);
        }
        return 1;
    }

    // rhi.restart{ adapter = name }: closes the window, and runs the script again on that
    // GPU (a new device, window and Lua state). The adapter may be left out (the default).
    static int apiRestart(lua_State* L)
    {
        LuaApp* app = get(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_getfield(L, 1, "adapter");
        g_restart.adapter = luaL_optstring(L, -1, "");
        g_restart.pending = true;
        if (app->m_window)
            glfwSetWindowShouldClose(app->m_window, GLFW_TRUE);
        return 0;
    }

    static int apiTime(lua_State* L)
    {
        lua_pushnumber(L, glfwGetTime());
        return 1;
    }

    // rhi.include(path): runs a Lua file (relative to the script) and returns what it
    // returns. Saving the file reloads the script, as for the script itself.
    static int apiInclude(lua_State* L)
    {
        LuaApp* app = get(L);
        fs::path path = app->m_scriptDir / luaL_checkstring(L, 1);
        std::string key = pathKey(path);
        app->m_watcher.watch(key);
        app->m_includedScripts.insert(key);
        lua_settop(L, 1);
        if (luaL_loadfile(L, path.string().c_str()) != LUA_OK)
        {
            lua_error(L);
        }
        lua_call(L, 0, 1);
        return 1;
    }

    // rhi.read_asset(path): a text file's contents, looked up as rhi.load_ply's files are
    // (next to the script, then in assets/). The file is watched like an include: saving
    // it reloads the script. For data the script parses itself (scenes, prefabs). A missing
    // file is an error, but is watched all the same: the script reloads when it is there.
    static int apiReadAsset(lua_State* L)
    {
        LuaApp* app = get(L);
        fs::path path = app->resolveAssetPath(luaL_checkstring(L, 1));
        std::string key = pathKey(path);
        app->m_watcher.watch(key);
        app->m_includedScripts.insert(key);
        std::ifstream file(path, std::ios::binary);
        if (!file)
            luaL_error(L, "%s: no such file", path.generic_string().c_str());
        std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        lua_pushlstring(L, text.data(), text.size());
        return 1;
    }

    // rhi.list_assets(folder [, extension]): the names of the files in assets/<folder>
    // (and in <folder> next to the script), sorted, without the folder; only those ending
    // in `extension` if given.
    static int apiListAssets(lua_State* L)
    {
        LuaApp* app = get(L);
        std::string folder = luaL_checkstring(L, 1);
        std::string extension = luaL_optstring(L, 2, "");
        std::set<std::string> names;
        for (const fs::path& root : {app->m_scriptDir / folder, fs::path(LUA_ASSETS_DIR) / folder})
        {
            std::error_code ec;
            if (!fs::is_directory(root, ec))
                continue;
            for (const fs::directory_entry& entry : fs::directory_iterator(root, ec))
            {
                std::string name = entry.path().filename().string();
                if (entry.is_regular_file(ec) && name.size() >= extension.size() &&
                    name.compare(name.size() - extension.size(), extension.size(), extension) == 0)
                    names.insert(name);
            }
        }
        lua_createtable(L, int(names.size()), 0);
        int i = 1;
        for (const std::string& name : names)
        {
            lua_pushstring(L, name.c_str());
            lua_rawseti(L, -2, i++);
        }
        return 1;
    }

    // -----------------------------------------------------------------------------------
    // API: parameter blocks and render graphs
    // -----------------------------------------------------------------------------------

    // A block from the string keys of the table at `index`.
    static std::shared_ptr<ParamBlock> blockFromTable(lua_State* L, int index)
    {
        index = lua_absindex(L, index);
        auto block = std::make_shared<ParamBlock>();
        lua_pushnil(L);
        while (lua_next(L, index))
        {
            if (lua_type(L, -2) == LUA_TSTRING)
            {
                block->set(lua_tostring(L, -2), toParamValue(L, -1));
            }
            lua_pop(L, 1);
        }
        return block;
    }

    // A `params` option: a block, a list of blocks and tables, or one table of values.
    static std::vector<std::shared_ptr<ParamBlock>> checkBlocks(lua_State* L, int index)
    {
        index = lua_absindex(L, index);
        std::vector<std::shared_ptr<ParamBlock>> blocks;
        if (lua_isnoneornil(L, index))
        {
            return blocks;
        }
        if (auto block = testShared<ParamBlock>(L, index, kParamsType))
        {
            blocks.push_back(block);
            return blocks;
        }
        luaL_checktype(L, index, LUA_TTABLE);
        lua_Integer count = lua_Integer(lua_rawlen(L, index));
        if (count == 0)
        {
            blocks.push_back(blockFromTable(L, index));
            return blocks;
        }
        for (lua_Integer i = 1; i <= count; ++i)
        {
            lua_rawgeti(L, index, i);
            if (auto block = testShared<ParamBlock>(L, -1, kParamsType))
            {
                blocks.push_back(block);
            }
            else
            {
                luaL_checktype(L, -1, LUA_TTABLE);
                blocks.push_back(blockFromTable(L, -1));
            }
            lua_pop(L, 1);
        }
        return blocks;
    }

    // rhi.params{ name = value, ... }
    static int apiParams(lua_State* L)
    {
        std::shared_ptr<ParamBlock> block =
            lua_isnoneornil(L, 1) ? std::make_shared<ParamBlock>() : (luaL_checktype(L, 1, LUA_TTABLE), blockFromTable(L, 1));
        pushHandle(L, block, kParamsType);
        return 1;
    }

    // block.name = value
    static int paramsNewIndex(lua_State* L)
    {
        auto block = checkShared<ParamBlock>(L, 1, kParamsType);
        block->set(luaL_checkstring(L, 2), toParamValue(L, 3));
        return 0;
    }

    // block:set{ name = value, ... }
    static int paramsSet(lua_State* L)
    {
        auto block = checkShared<ParamBlock>(L, 1, kParamsType);
        luaL_checktype(L, 2, LUA_TTABLE);
        std::shared_ptr<ParamBlock> values = blockFromTable(L, 2);
        for (size_t i = 0; i < values->names.size(); ++i)
        {
            block->set(values->names[i], values->values[i]);
        }
        return 0;
    }

    static int paramsIndex(lua_State* L)
    {
        lua_pushvalue(L, lua_upvalueindex(1));
        lua_getfield(L, -1, luaL_checkstring(L, 2));
        return 1;
    }

    // rhi.graph()
    static int apiGraph(lua_State* L)
    {
        pushHandle(L, std::make_shared<Graph>(), kGraphType);
        return 1;
    }

    // rhi.set_graph(graph or nil): the graph the host runs every frame, before draw().
    static int apiSetGraph(lua_State* L)
    {
        get(L)->m_graph = lua_isnoneornil(L, 1) ? nullptr : checkShared<Graph>(L, 1, kGraphType);
        return 0;
    }

    static void readColor(lua_State* L, int index, float color[4])
    {
        for (int i = 0; i < 4; ++i)
        {
            lua_rawgeti(L, index, i + 1);
            color[i] = float(luaL_optnumber(L, -1, color[i]));
            lua_pop(L, 1);
        }
    }

    static void readThreads(lua_State* L, int index, uint32_t threads[3])
    {
        luaL_checktype(L, index, LUA_TTABLE);
        for (int i = 0; i < 3; ++i)
        {
            lua_rawgeti(L, index, i + 1);
            threads[i] = uint32_t(luaL_optinteger(L, -1, 1));
            lua_pop(L, 1);
        }
    }

    // A dispatch's `threads`: {x, y, z}; "window" for one thread per window pixel; or a
    // texture, for one thread per texel (its size is then the dispatch's viewportSize).
    static void readDispatchThreads(lua_State* L, int index, GraphNode& node)
    {
        node.threadsPerPixel = false;
        node.threadsTexture = nullptr;
        if (lua_type(L, index) == LUA_TSTRING)
        {
            if (strcmp(lua_tostring(L, index), "window") != 0)
                luaL_error(L, "threads must be {x, y, z}, \"window\" or a texture");
            node.threadsPerPixel = true;
            return;
        }
        if (auto texture = testShared<Texture>(L, index, kTextureType))
        {
            node.threadsTexture = texture;
            return;
        }
        readThreads(L, index, node.threads);
    }

    // A texture to draw color into: any texture but a depth target.
    static std::shared_ptr<Texture> checkColorTexture(lua_State* L, int index)
    {
        auto texture = checkShared<Texture>(L, index, kTextureType);
        if (texture->isDepth)
            luaL_error(L, "a depth target can't be drawn into as a color target (use depth_target)");
        return texture;
    }

    // graph:render_pass{ name, target = texture | targets = { texture, ... } (more color
    //                    targets, for pipelines with as many formats; the size of the
    //                    first; cleared alike), depth_target = depthTexture, color = true,
    //                    clear = {r,g,b,a}, viewport = {x,y,w,h} | viewport_fraction = {x,y,w,h} }
    static int graphRenderPass(lua_State* L)
    {
        auto graph = checkShared<Graph>(L, 1, kGraphType);
        if (lua_isnoneornil(L, 2))
        {
            lua_newtable(L);
            lua_replace(L, 2);
        }
        luaL_checktype(L, 2, LUA_TTABLE);
        auto node = std::make_shared<GraphNode>();
        node->name = "render pass " + std::to_string(graph->nodes.size() + 1);

        if (lua_getfield(L, 2, "name") == LUA_TSTRING)
            node->name = lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "timed");
        node->timed = lua_toboolean(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "target");
        if (!lua_isnil(L, -1))
            node->target = checkColorTexture(L, -1);
        lua_pop(L, 1);
        if (lua_getfield(L, 2, "targets") == LUA_TTABLE)
        {
            int count = int(lua_rawlen(L, -1));
            if (node->target || count == 0)
                luaL_error(L, "a pass has a target or a list of targets (at least one)");
            for (int i = 1; i <= count; ++i)
            {
                lua_rawgeti(L, -1, i);
                auto texture = checkColorTexture(L, -1);
                if (i == 1)
                    node->target = texture;
                else
                    node->extraTargets.push_back(texture);
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
        lua_getfield(L, 2, "depth_target");
        if (!lua_isnil(L, -1))
        {
            node->depthTarget = checkShared<Texture>(L, -1, kTextureType);
            if (!node->depthTarget->isDepth)
                luaL_error(L, "depth_target needs a texture made by rhi.depth_target()");
        }
        lua_pop(L, 1);
        lua_getfield(L, 2, "color");
        node->depthOnly = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (node->depthOnly && (!node->depthTarget || node->target))
            luaL_error(L, "a pass with color = false draws only into its depth_target, and has no target");
        if (lua_getfield(L, 2, "clear") == LUA_TTABLE)
        {
            node->clear = true;
            readColor(L, lua_gettop(L), node->clearColor);
        }
        lua_pop(L, 1);
        if (lua_getfield(L, 2, "viewport") == LUA_TTABLE)
        {
            node->viewportMode = GraphNode::ViewportMode::Pixels;
            readColor(L, lua_gettop(L), node->viewport);
        }
        lua_pop(L, 1);
        if (lua_getfield(L, 2, "viewport_fraction") == LUA_TTABLE)
        {
            node->viewportMode = GraphNode::ViewportMode::Fraction;
            readColor(L, lua_gettop(L), node->viewport);
        }
        lua_pop(L, 1);

        graph->nodes.push_back(node);
        pushHandle(L, node, kNodeType);
        return 1;
    }

    // graph:dispatch{ name, pipeline, params, threads = {x,y,z}, once = false }
    static int graphDispatch(lua_State* L)
    {
        auto graph = checkShared<Graph>(L, 1, kGraphType);
        luaL_checktype(L, 2, LUA_TTABLE);
        auto node = std::make_shared<GraphNode>();
        node->isDispatch = true;
        node->name = "dispatch " + std::to_string(graph->nodes.size() + 1);

        if (lua_getfield(L, 2, "name") == LUA_TSTRING)
            node->name = lua_tostring(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "pipeline");
        node->pipeline = checkShared<Pipeline>(L, -1, kPipelineType);
        lua_pop(L, 1);
        if (!node->pipeline->isCompute)
            luaL_error(L, "dispatch needs a compute pipeline");
        lua_getfield(L, 2, "params");
        node->params = checkBlocks(L, -1);
        lua_pop(L, 1);
        if (lua_getfield(L, 2, "threads") != LUA_TNIL)
            readDispatchThreads(L, lua_gettop(L), *node);
        lua_pop(L, 1);
        lua_getfield(L, 2, "once");
        node->once = lua_toboolean(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "timed");
        node->timed = lua_toboolean(L, -1);
        lua_pop(L, 1);

        graph->nodes.push_back(node);
        pushHandle(L, node, kNodeType);
        return 1;
    }

    // pass:draw{ pipeline, vertices, count = 3, params }
    static int nodeDraw(lua_State* L)
    {
        auto node = checkShared<GraphNode>(L, 1, kNodeType);
        if (node->isDispatch)
            luaL_error(L, "draw() is for render passes");
        luaL_checktype(L, 2, LUA_TTABLE);
        auto draw = std::make_shared<GraphDraw>();

        lua_getfield(L, 2, "pipeline");
        draw->pipeline = checkShared<Pipeline>(L, -1, kPipelineType);
        lua_pop(L, 1);
        if (draw->pipeline->isCompute)
            luaL_error(L, "draw needs a render pipeline");
        lua_getfield(L, 2, "vertices");
        if (!lua_isnil(L, -1))
            draw->vertices = checkShared<Buffer>(L, -1, kBufferType);
        lua_pop(L, 1);
        lua_getfield(L, 2, "count");
        uint32_t defaultCount = (draw->vertices && draw->pipeline->vertexStride)
                                    ? uint32_t(draw->vertices->size / draw->pipeline->vertexStride)
                                    : 3;
        draw->count = uint32_t(luaL_optinteger(L, -1, defaultCount));
        lua_pop(L, 1);
        lua_getfield(L, 2, "params");
        draw->params = checkBlocks(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "instances");
        setInstances(L, lua_gettop(L), *draw);
        lua_pop(L, 1);

        node->draws.push_back(draw);
        pushHandle(L, draw, kDrawType);
        return 1;
    }

    // node:rerun(): runs a `once` dispatch again on the next frame.
    static int nodeRerun(lua_State* L)
    {
        checkShared<GraphNode>(L, 1, kNodeType)->pending = true;
        return 0;
    }

    static int nodeIndex(lua_State* L)
    {
        auto node = checkShared<GraphNode>(L, 1, kNodeType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "enabled") == 0)
            lua_pushboolean(L, node->enabled);
        else if (strcmp(key, "name") == 0)
            lua_pushstring(L, node->name.c_str());
        else if (strcmp(key, "timed") == 0)
            lua_pushboolean(L, node->timed);
        else if (strcmp(key, "gpu_time") == 0)
        {
            if (node->gpuTime >= 0.0)
                lua_pushnumber(L, node->gpuTime);
            else
                lua_pushnil(L);
        }
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // node.enabled = bool, node.threads = {x,y,z}, node.clear = {r,g,b,a} or false,
    // node.viewport = ..., node.viewport_fraction = ...
    static int nodeNewIndex(lua_State* L)
    {
        auto node = checkShared<GraphNode>(L, 1, kNodeType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "enabled") == 0)
            node->enabled = lua_toboolean(L, 3);
        else if (strcmp(key, "timed") == 0)
            node->timed = lua_toboolean(L, 3);
        else if (strcmp(key, "threads") == 0)
            readDispatchThreads(L, 3, *node);
        else if (strcmp(key, "clear") == 0)
        {
            node->clear = lua_istable(L, 3);
            if (node->clear)
                readColor(L, 3, node->clearColor);
        }
        else if (strcmp(key, "viewport") == 0 || strcmp(key, "viewport_fraction") == 0)
        {
            if (lua_isnil(L, 3))
                node->viewportMode = GraphNode::ViewportMode::Full;
            else
            {
                luaL_checktype(L, 3, LUA_TTABLE);
                node->viewportMode = strcmp(key, "viewport") == 0 ? GraphNode::ViewportMode::Pixels
                                                                  : GraphNode::ViewportMode::Fraction;
                readColor(L, 3, node->viewport);
            }
        }
        else
            luaL_error(L, "can't set '%s' on a graph pass", key);
        return 0;
    }

    // A draw's `instances`: a number, or a body group (as many as it has bodies).
    static void setInstances(lua_State* L, int index, GraphDraw& draw)
    {
        draw.instanceGroup = nullptr;
        draw.instances = 1;
        if (lua_isnoneornil(L, index))
            return;
        if (auto group = testShared<BodyGroup>(L, index, kBodyGroupType))
            draw.instanceGroup = group;
        else
            draw.instances = uint32_t(luaL_checkinteger(L, index));
    }

    static int drawIndex(lua_State* L)
    {
        auto draw = checkShared<GraphDraw>(L, 1, kDrawType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "count") == 0)
            lua_pushinteger(L, draw->count);
        else if (strcmp(key, "enabled") == 0)
            lua_pushboolean(L, draw->enabled);
        else
            lua_pushnil(L);
        return 1;
    }

    // draw.count = n, draw.enabled = bool
    static int drawNewIndex(lua_State* L)
    {
        auto draw = checkShared<GraphDraw>(L, 1, kDrawType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "count") == 0)
            draw->count = uint32_t(luaL_checkinteger(L, 3));
        else if (strcmp(key, "enabled") == 0)
            draw->enabled = lua_toboolean(L, 3);
        else if (strcmp(key, "instances") == 0)
            setInstances(L, 3, *draw);
        else
            luaL_error(L, "can't set '%s' on a graph draw", key);
        return 0;
    }

    // -----------------------------------------------------------------------------------
    // API: physics
    // -----------------------------------------------------------------------------------

    static void readFloats(lua_State* L, int table, const char* field, float* out, int count)
    {
        if (lua_getfield(L, table, field) == LUA_TTABLE)
        {
            for (int i = 0; i < count; ++i)
            {
                lua_rawgeti(L, -1, i + 1);
                out[i] = float(luaL_optnumber(L, -1, out[i]));
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }

    static float readFloat(lua_State* L, int table, const char* field, float fallback)
    {
        lua_getfield(L, table, field);
        float value = float(luaL_optnumber(L, -1, fallback));
        lua_pop(L, 1);
        return value;
    }

    // rhi.physics_world{ gravity = {0, -9.81, 0}, max_bodies = 4096 }
    static int apiPhysicsWorld(lua_State* L)
    {
        float gravity[3] = {0.0f, -9.81f, 0.0f};
        uint32_t maxBodies = 4096;
        if (lua_istable(L, 1))
        {
            readFloats(L, 1, "gravity", gravity, 3);
            maxBodies = uint32_t(readFloat(L, 1, "max_bodies", float(maxBodies)));
        }
        auto world = std::make_shared<PhysicsWorld>();
        world->world = std::make_unique<physics::World>(gravity, maxBodies);
        pushHandle(L, world, kPhysicsType);
        return 1;
    }

    // rhi.set_physics(world or nil): the world the host steps every frame.
    static int apiSetPhysics(lua_State* L)
    {
        get(L)->m_physics = lua_isnoneornil(L, 1) ? nullptr : checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        return 0;
    }

    // world:group{ capacity = 256 }
    static int physicsGroup(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto world = checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        uint32_t capacity = lua_istable(L, 2) ? uint32_t(readFloat(L, 2, "capacity", 256)) : 256;
        auto group = std::make_shared<BodyGroup>();
        group->world = world;
        group->capacity = std::max<uint32_t>(capacity, 1);
        group->buffer = std::make_shared<Buffer>();
        BufferDesc desc = {};
        desc.size = group->capacity * kBodyFloats * sizeof(float);
        desc.usage = BufferUsage::ShaderResource | BufferUsage::CopyDestination;
        desc.defaultState = ResourceState::ShaderResource;
        desc.label = "Body transforms";
        if (SLANG_FAILED(app->m_device->createBuffer(desc, nullptr, group->buffer->buffer.writeRef())))
            luaL_error(L, "could not create a body group's buffer");
        group->buffer->size = desc.size;
        world->groups.push_back(group);
        pushHandle(L, group, kBodyGroupType);
        return 1;
    }

    // world:character{ radius = 0.35, height = 1.8, position = {x, y, z} (the feet),
    //                  max_slope = 50 (degrees), mass = 90, strength = 600 }
    static int physicsCharacter(lua_State* L)
    {
        auto world = checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        physics::CharacterDesc desc;
        if (lua_istable(L, 2))
        {
            desc.radius = readFloat(L, 2, "radius", desc.radius);
            desc.height = readFloat(L, 2, "height", desc.height);
            readFloats(L, 2, "position", desc.position, 3);
            desc.maxSlopeDegrees = readFloat(L, 2, "max_slope", desc.maxSlopeDegrees);
            desc.mass = readFloat(L, 2, "mass", desc.mass);
            desc.maxStrength = readFloat(L, 2, "strength", desc.maxStrength);
        }
        auto handle = std::make_shared<CharacterHandle>();
        handle->world = world;
        handle->index = world->world->addCharacter(desc);
        pushHandle(L, handle, kCharacterType);
        return 1;
    }

    // world:raycast({x, y, z}, {dx, dy, dz}, max_distance) -> distance, point, normal,
    // moving (whether the body hit can move); nil if nothing is hit. Characters are ignored.
    static int physicsRaycast(lua_State* L)
    {
        auto world = checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        float origin[3], direction[3];
        checkVector(L, 2, origin, 3);
        checkVector(L, 3, direction, 3);
        float maxDistance = float(luaL_checknumber(L, 4));
        physics::RayHit hit;
        if (!world->world->castRay(origin, direction, maxDistance, hit))
        {
            lua_pushnil(L);
            return 1;
        }
        lua_pushnumber(L, hit.distance);
        pushNumbers(L, hit.point, 3);
        pushNumbers(L, hit.normal, 3);
        lua_pushboolean(L, hit.moving);
        return 4;
    }

    static std::shared_ptr<PhysicsWorld> characterWorld(lua_State* L, CharacterHandle& handle)
    {
        auto world = handle.world.lock();
        if (!world)
            luaL_error(L, "the character's physics world is gone");
        return world;
    }

    // character:jump(speed): sets the vertical velocity on the next step.
    static int characterJump(lua_State* L)
    {
        auto handle = checkShared<CharacterHandle>(L, 1, kCharacterType);
        characterWorld(L, *handle)->world->jumpCharacter(handle->index, float(luaL_checknumber(L, 2)));
        return 0;
    }

    static int characterIndex(lua_State* L)
    {
        auto handle = checkShared<CharacterHandle>(L, 1, kCharacterType);
        const char* key = luaL_checkstring(L, 2);
        physics::CharacterState state;
        characterWorld(L, *handle)->world->getCharacter(handle->index, state);
        if (strcmp(key, "position") == 0)
            pushNumbers(L, state.position, 3);
        else if (strcmp(key, "velocity") == 0)
            pushNumbers(L, state.velocity, 3);
        else if (strcmp(key, "on_ground") == 0)
            lua_pushboolean(L, state.ground == physics::Ground::OnGround);
        else if (strcmp(key, "ground") == 0)
        {
            static const char* kNames[] = {"ground", "steep", "unsupported", "air"};
            lua_pushstring(L, kNames[int(state.ground)]);
        }
        else if (strcmp(key, "move") == 0)
            pushNumbers(L, handle->move, 2);
        else if (strcmp(key, "gravity_scale") == 0)
            lua_pushnumber(L, handle->gravityScale);
        else if (strcmp(key, "max_fall_speed") == 0)
            lua_pushnumber(L, handle->maxFallSpeed);
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // character.move = {x, z} (horizontal velocity, m/s), .gravity_scale, .max_fall_speed
    // (0: none), .position = {x, y, z} (teleports), .velocity = {x, y, z}
    static int characterNewIndex(lua_State* L)
    {
        auto handle = checkShared<CharacterHandle>(L, 1, kCharacterType);
        const char* key = luaL_checkstring(L, 2);
        physics::World& world = *characterWorld(L, *handle)->world;
        if (strcmp(key, "move") == 0)
        {
            checkVector(L, 3, handle->move, 2);
            world.setCharacterMove(handle->index, handle->move[0], handle->move[1]);
        }
        else if (strcmp(key, "gravity_scale") == 0 || strcmp(key, "max_fall_speed") == 0)
        {
            (key[0] == 'g' ? handle->gravityScale : handle->maxFallSpeed) = float(luaL_checknumber(L, 3));
            world.setCharacterGravity(handle->index, handle->gravityScale, handle->maxFallSpeed);
        }
        else if (strcmp(key, "position") == 0 || strcmp(key, "velocity") == 0)
        {
            float v[3];
            checkVector(L, 3, v, 3);
            if (key[0] == 'p')
                world.setCharacterPosition(handle->index, v);
            else
                world.setCharacterVelocity(handle->index, v);
        }
        else
            luaL_error(L, "can't set '%s' on a character", key);
        return 0;
    }

    static int physicsIndex(lua_State* L)
    {
        auto world = checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "paused") == 0)
            lua_pushboolean(L, world->paused);
        else if (strcmp(key, "time_scale") == 0)
            lua_pushnumber(L, world->timeScale);
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // world.paused = bool, world.time_scale = s, world.gravity = {x, y, z}
    static int physicsNewIndex(lua_State* L)
    {
        auto world = checkShared<PhysicsWorld>(L, 1, kPhysicsType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "paused") == 0)
            world->paused = lua_toboolean(L, 3);
        else if (strcmp(key, "time_scale") == 0)
            world->timeScale = float(luaL_checknumber(L, 3));
        else if (strcmp(key, "gravity") == 0)
        {
            luaL_checktype(L, 3, LUA_TTABLE);
            float gravity[3] = {0, 0, 0};
            for (int i = 0; i < 3; ++i)
            {
                lua_rawgeti(L, 3, i + 1);
                gravity[i] = float(luaL_checknumber(L, -1));
                lua_pop(L, 1);
            }
            world->world->setGravity(gravity);
        }
        else
            luaL_error(L, "can't set '%s' on a physics world", key);
        return 0;
    }

    static std::shared_ptr<PhysicsWorld> groupWorld(lua_State* L, BodyGroup& group)
    {
        auto world = group.world.lock();
        if (!world)
            luaL_error(L, "the body group's physics world is gone");
        return world;
    }

    // group:add{ shape = "box" | "sphere", half_extents = {x,y,z} | radius = r,
    //            motion = "dynamic" | "static" | "kinematic", position, rotation = {x,y,z,w},
    //            velocity, angular_velocity, friction, restitution, density,
    //            color = {r,g,b}, pattern = 0 }
    // Returns the body's index in the group (from 0), or nil if the group or world is full.
    static int groupAdd(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        luaL_checktype(L, 2, LUA_TTABLE);
        auto world = groupWorld(L, *group);
        if (group->ids.size() >= group->capacity)
        {
            lua_pushnil(L);
            return 1;
        }

        physics::BodyDesc desc;
        lua_getfield(L, 2, "shape");
        const char* shape = luaL_optstring(L, -1, "box");
        if (strcmp(shape, "sphere") == 0)
            desc.shape = physics::Shape::Sphere;
        else if (strcmp(shape, "box") != 0)
            luaL_error(L, "unknown body shape '%s' (box, sphere)", shape);
        lua_pop(L, 1);
        lua_getfield(L, 2, "motion");
        const char* motion = luaL_optstring(L, -1, "dynamic");
        if (strcmp(motion, "static") == 0)
            desc.motion = physics::Motion::Static;
        else if (strcmp(motion, "kinematic") == 0)
            desc.motion = physics::Motion::Kinematic;
        bool visual = strcmp(motion, "visual") == 0;
        if (!visual && strcmp(motion, "static") != 0 && strcmp(motion, "kinematic") != 0 && strcmp(motion, "dynamic") != 0)
            luaL_error(L, "unknown body motion '%s' (dynamic, static, kinematic, visual)", motion);
        lua_pop(L, 1);
        readFloats(L, 2, "half_extents", desc.halfExtents, 3);
        desc.radius = readFloat(L, 2, "radius", desc.radius);
        readFloats(L, 2, "position", desc.position, 3);
        readFloats(L, 2, "rotation", desc.rotation, 4);
        readFloats(L, 2, "velocity", desc.linearVelocity, 3);
        readFloats(L, 2, "angular_velocity", desc.angularVelocity, 3);
        desc.friction = readFloat(L, 2, "friction", desc.friction);
        desc.restitution = readFloat(L, 2, "restitution", desc.restitution);
        desc.density = readFloat(L, 2, "density", desc.density);
        float color[3] = {0.8f, 0.8f, 0.8f};
        readFloats(L, 2, "color", color, 3);
        float pattern = readFloat(L, 2, "pattern", 0);

        uint32_t id = visual ? kVisualBody : world->world->addBody(desc);
        if (!visual && id == UINT32_MAX)
        {
            lua_pushnil(L);
            return 1;
        }
        group->placements.insert(group->placements.end(), desc.position, desc.position + 3);
        group->placements.insert(group->placements.end(), desc.rotation, desc.rotation + 4);
        // The unit meshes are -1..1 cubes and radius 1 spheres; the scale makes them the body.
        bool sphere = desc.shape == physics::Shape::Sphere;
        group->looks.insert(group->looks.end(), {
            sphere ? desc.radius : desc.halfExtents[0],
            sphere ? desc.radius : desc.halfExtents[1],
            sphere ? desc.radius : desc.halfExtents[2],
            pattern, color[0], color[1], color[2], 0.0f,
        });
        group->ids.push_back(id);
        lua_pushinteger(L, lua_Integer(group->ids.size() - 1));
        return 1;
    }

    // group:clear(): removes every body of the group from the world.
    static int groupClear(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        auto world = groupWorld(L, *group);
        for (uint32_t id : group->ids)
            if (id != kVisualBody)
                world->world->removeBody(id);
        group->ids.clear();
        group->looks.clear();
        group->placements.clear();
        return 0;
    }

    static size_t checkBodyIndex(lua_State* L, BodyGroup& group, int index)
    {
        lua_Integer i = luaL_checkinteger(L, index);
        if (i < 0 || size_t(i) >= group.ids.size())
            luaL_error(L, "no body %d in the group", int(i));
        return size_t(i);
    }

    // The physics body at `index`: not a visual one, which has none.
    static uint32_t checkBodyId(lua_State* L, BodyGroup& group, int index)
    {
        uint32_t id = group.ids[checkBodyIndex(L, group, index)];
        if (id == kVisualBody)
            luaL_error(L, "body %d is visual: it has no physics", int(lua_tointeger(L, index)));
        return id;
    }

    static void checkVector(lua_State* L, int index, float* out, int count)
    {
        luaL_checktype(L, index, LUA_TTABLE);
        for (int i = 0; i < count; ++i)
        {
            lua_rawgeti(L, index, i + 1);
            out[i] = float(luaL_checknumber(L, -1));
            lua_pop(L, 1);
        }
    }

    // group:set_transform(i, {x, y, z}, {qx, qy, qz, qw} [, {sx, sy, sz}]): places a
    // visual body (and rescales it: half extents, or the radius on every axis).
    static int groupSetTransform(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        size_t i = checkBodyIndex(L, *group, 2);
        if (group->ids[i] != kVisualBody)
            luaL_error(L, "set_transform is for visual bodies; physics moves the others");
        checkVector(L, 3, &group->placements[i * 7], 3);
        if (!lua_isnoneornil(L, 4))
            checkVector(L, 4, &group->placements[i * 7 + 3], 4);
        if (!lua_isnoneornil(L, 5))
            checkVector(L, 5, &group->looks[i * 8], 3);
        return 0;
    }

    // group:set_velocity(i, {x, y, z}) and group:impulse(i, {x, y, z})
    static int groupSetVelocity(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        uint32_t id = checkBodyId(L, *group, 2);
        float v[3] = {0, 0, 0};
        luaL_checktype(L, 3, LUA_TTABLE);
        for (int i = 0; i < 3; ++i)
        {
            lua_rawgeti(L, 3, i + 1);
            v[i] = float(luaL_checknumber(L, -1));
            lua_pop(L, 1);
        }
        groupWorld(L, *group)->world->setLinearVelocity(id, v);
        return 0;
    }

    static int groupImpulse(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        uint32_t id = checkBodyId(L, *group, 2);
        float v[3] = {0, 0, 0};
        luaL_checktype(L, 3, LUA_TTABLE);
        for (int i = 0; i < 3; ++i)
        {
            lua_rawgeti(L, 3, i + 1);
            v[i] = float(luaL_checknumber(L, -1));
            lua_pop(L, 1);
        }
        groupWorld(L, *group)->world->addImpulse(id, v);
        return 0;
    }

    // group:position(i) -> x, y, z (the body's current position)
    static int groupPosition(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        size_t i = checkBodyIndex(L, *group, 2);
        float position[3], rotation[4];
        if (group->ids[i] == kVisualBody)
            std::copy_n(&group->placements[i * 7], 3, position);
        else
            groupWorld(L, *group)->world->getTransform(group->ids[i], position, rotation);
        lua_pushnumber(L, position[0]);
        lua_pushnumber(L, position[1]);
        lua_pushnumber(L, position[2]);
        return 3;
    }

    static int groupIndex(lua_State* L)
    {
        auto group = checkShared<BodyGroup>(L, 1, kBodyGroupType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "count") == 0)
            lua_pushinteger(L, lua_Integer(group->ids.size()));
        else if (strcmp(key, "capacity") == 0)
            lua_pushinteger(L, group->capacity);
        else if (strcmp(key, "buffer") == 0)
            pushHandle(L, group->buffer, kBufferType);
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // A read-only structured buffer holding `bytes` of `contents`.
    static std::shared_ptr<Buffer> createDataBuffer(lua_State* L, const void* contents, size_t bytes, const char* label)
    {
        LuaApp* app = get(L);
        auto buffer = std::make_shared<Buffer>();
        BufferDesc desc = {};
        desc.size = std::max<size_t>(bytes, 4);
        desc.usage = BufferUsage::ShaderResource | BufferUsage::CopyDestination;
        desc.defaultState = ResourceState::ShaderResource;
        desc.label = label;
        if (SLANG_FAILED(app->m_device->createBuffer(desc, bytes ? contents : nullptr, buffer->buffer.writeRef())))
        {
            luaL_error(L, "could not create a buffer for %s", label);
        }
        buffer->size = desc.size;
        return buffer;
    }

    // rhi.load_ply(path [, { lod = true }]): loads the vertex element of a binary PLY file
    // into a buffer of floats, one record of `stride` floats per vertex, in the file's
    // property order. Returns { buffer, count, stride, properties = { name = offset, ... },
    // center = {x, y, z}, radius } -- center and radius summarize the x/y/z properties
    // (mean, and the root of the summed variances), for framing a camera.
    //
    // A file of Gaussian splats (x, y, z, scale_*, rot_*, opacity, f_dc_*) also gets
    // levels of detail (splat-lod.h), unless `lod = false`: its splats reordered (to the
    // tree's order), merged splats appended to the buffer after the file's `count`, and
    // `lod = { count, nodes, levels, bounds, parents, level, seconds }` -- count is all
    // entries (file's splats and merged ones), nodes the merged ones, bounds a buffer of a
    // float4 per merged splat (its bounding sphere), parents and level buffers of a uint
    // per entry (its parent's entry, 0xFFFFFFFF at the root; its level), seconds the time
    // the build or the cache read took.
    static int apiLoadPly(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        fs::path path = app->resolveAssetPath(luaL_checkstring(L, 1));
        bool wantLod = true;
        if (lua_istable(L, 2))
        {
            lua_getfield(L, 2, "lod");
            wantLod = lua_isnil(L, -1) || lua_toboolean(L, -1);
            lua_pop(L, 1);
        }
        PlyData ply;
        std::string error;
        bool missing = !readPly(path, ply, error);
        if (missing)
        {
            // A blue checkered cube in its place; the file is watched, so the script
            // reloads with it once it is there (or fixed).
            app->warnMissingAsset(path, error);
            ply = placeholderPly();
        }
        uint32_t stride = uint32_t(ply.properties.size());

        // Levels of detail, for splats: merged splats appended to the records.
        splatlod::Result lod;
        double lodSeconds = 0.0;
        splatlod::Layout layout = splatlod::findLayout(ply.properties);
        bool hasLod = wantLod && layout.isSplats() && ply.count > 1;
        if (hasLod && missing)
        {
            lod = splatlod::build(layout, ply.data, ply.count); // small: not worth a cache
        }
        else if (hasLod)
        {
            // Cached between runs in the temp directory, keyed by the file's size and time.
            std::error_code ec;
            uint64_t sourceKey = uint64_t(fs::file_size(path, ec)) * 1000003ull ^
                                 uint64_t(fs::last_write_time(path, ec).time_since_epoch().count());
            fs::path cacheDir = fs::temp_directory_path(ec) / "slang-rhi-lua-lod";
            fs::create_directories(cacheDir, ec);
            fs::path cachePath = cacheDir / (path.filename().string() + ".lod");
            bool cached = false;
            auto start = std::chrono::steady_clock::now();
            lod = splatlod::buildCached(layout, ply.data, ply.count, cachePath.string(), sourceKey, cached);
            lodSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            printf(
                "[lua] %s: levels of detail: %u splats + %u merged, %u levels, %s in %.2f s\n",
                path.filename().generic_string().c_str(),
                lod.leafCount,
                lod.entryCount - lod.leafCount,
                lod.levels,
                cached ? "read from the cache" : "built",
                lodSeconds
            );
            fflush(stdout);
        }

        auto buffer = createDataBuffer(L, ply.data.data(), ply.data.size() * sizeof(float), "PLY data");

        lua_newtable(L);
        pushHandle(L, buffer, kBufferType);
        lua_setfield(L, -2, "buffer");
        if (hasLod)
        {
            lua_newtable(L);
            lua_pushinteger(L, lod.entryCount);
            lua_setfield(L, -2, "count");
            lua_pushinteger(L, lod.entryCount - lod.leafCount);
            lua_setfield(L, -2, "nodes");
            lua_pushinteger(L, lod.levels);
            lua_setfield(L, -2, "levels");
            lua_pushnumber(L, lodSeconds);
            lua_setfield(L, -2, "seconds");
            pushHandle(L, createDataBuffer(L, lod.nodeBounds.data(), lod.nodeBounds.size() * sizeof(float), "Splat LOD bounds"), kBufferType);
            lua_setfield(L, -2, "bounds");
            pushHandle(L, createDataBuffer(L, lod.parent.data(), lod.parent.size() * sizeof(uint32_t), "Splat LOD parents"), kBufferType);
            lua_setfield(L, -2, "parents");
            pushHandle(L, createDataBuffer(L, lod.level.data(), lod.level.size() * sizeof(uint32_t), "Splat LOD levels"), kBufferType);
            lua_setfield(L, -2, "level");
            lua_setfield(L, -2, "lod");
        }
        lua_pushinteger(L, ply.count);
        lua_setfield(L, -2, "count");
        lua_pushinteger(L, stride);
        lua_setfield(L, -2, "stride");
        lua_newtable(L);
        for (uint32_t i = 0; i < stride; ++i)
        {
            lua_pushinteger(L, i);
            lua_setfield(L, -2, ply.properties[i].c_str());
        }
        lua_setfield(L, -2, "properties");
        if (missing)
        {
            lua_pushstring(L, error.c_str());
            lua_setfield(L, -2, "missing");
        }

        // Where the points are, for framing them.
        auto find = [&](const char* name) -> int
        {
            auto it = std::find(ply.properties.begin(), ply.properties.end(), name);
            return it == ply.properties.end() ? -1 : int(it - ply.properties.begin());
        };
        int axes[3] = {find("x"), find("y"), find("z")};
        if (axes[0] >= 0 && axes[1] >= 0 && axes[2] >= 0 && ply.count > 0)
        {
            double sum[3] = {0, 0, 0};
            double sumSquares[3] = {0, 0, 0};
            for (uint32_t v = 0; v < ply.count; ++v)
            {
                for (int a = 0; a < 3; ++a)
                {
                    double value = ply.data[size_t(v) * stride + axes[a]];
                    sum[a] += value;
                    sumSquares[a] += value * value;
                }
            }
            double variance = 0.0;
            lua_createtable(L, 3, 0);
            for (int a = 0; a < 3; ++a)
            {
                double mean = sum[a] / ply.count;
                variance += std::max(0.0, sumSquares[a] / ply.count - mean * mean);
                lua_pushnumber(L, mean);
                lua_rawseti(L, -2, a + 1);
            }
            lua_setfield(L, -2, "center");
            lua_pushnumber(L, std::sqrt(variance));
            lua_setfield(L, -2, "radius");
        }
        return 1;
    }

    // rhi.sound(path [, { loop = false, volume = 1, play = false }]): a sound from a file
    // (WAV, FLAC or MP3, by its contents), looked up as rhi.load_ply's files are, and
    // streamed from disk as it plays (audio.h). Without an audio device it still works,
    // silently. The sound stops when its handle is collected (or the script reloads). A
    // missing file (or one that doesn't decode) gives nil, with a warning, and is watched:
    // the script reloads when it is there.
    static int apiSound(lua_State* L)
    {
        LuaApp* app = get(L);
        fs::path path = app->resolveAssetPath(luaL_checkstring(L, 1));
        std::string error;
        bool silent = false;
        std::unique_ptr<audio::Sound> sound = audio::Sound::load(path, error, silent);
        if (!sound)
        {
            app->warnMissingAsset(path, error, "silence");
            lua_pushnil(L);
            return 1;
        }
        static bool warned = false;
        if (silent && !warned)
        {
            printf("[lua] no audio device could be started: sounds are silent\n");
            fflush(stdout);
            warned = true;
        }
        bool play = false;
        if (lua_istable(L, 2))
        {
            sound->setLooping(lua_getfield(L, 2, "loop") != LUA_TNIL && lua_toboolean(L, -1));
            lua_pop(L, 1);
            sound->setVolume(readFloat(L, 2, "volume", 1.0f));
            play = lua_getfield(L, 2, "play") != LUA_TNIL && lua_toboolean(L, -1);
            lua_pop(L, 1);
        }
        if (play)
            sound->play();
        pushHandle(L, std::shared_ptr<audio::Sound>(std::move(sound)), kSoundType);
        return 1;
    }

    // sound:play(), sound:pause(), sound:stop() (pause, back to the start), sound:seek(seconds)
    static int soundPlay(lua_State* L)
    {
        checkShared<audio::Sound>(L, 1, kSoundType)->play();
        return 0;
    }
    static int soundPause(lua_State* L)
    {
        checkShared<audio::Sound>(L, 1, kSoundType)->pause();
        return 0;
    }
    static int soundStop(lua_State* L)
    {
        auto sound = checkShared<audio::Sound>(L, 1, kSoundType);
        sound->pause();
        sound->seek(0.0);
        return 0;
    }
    static int soundSeek(lua_State* L)
    {
        checkShared<audio::Sound>(L, 1, kSoundType)->seek(luaL_checknumber(L, 2));
        return 0;
    }

    // sound.playing, sound.position, sound.length (seconds), sound.volume, sound.loop
    // buffer.size (bytes), and its methods.
    static int bufferIndex(lua_State* L)
    {
        auto buffer = checkShared<Buffer>(L, 1, kBufferType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "size") == 0)
        {
            lua_pushinteger(L, lua_Integer(buffer->size));
            return 1;
        }
        lua_pushvalue(L, lua_upvalueindex(1));
        lua_getfield(L, -1, key);
        return 1;
    }

    // buffer:write(floats [, offset]): writes the floats into the buffer from float `offset`
    // (default 0), before the next frame's passes -- for data Lua changes every frame (the
    // scene's lights). Writes past the end are cut off.
    static int bufferWrite(lua_State* L)
    {
        LuaApp* app = get(L);
        std::shared_ptr<Buffer> buffer = checkShared<Buffer>(L, 1, kBufferType);
        std::vector<float> floats = checkFloats(L, 2);
        uint64_t offset = uint64_t(luaL_optinteger(L, 3, 0)) * sizeof(float);
        if (offset >= buffer->size || floats.empty())
        {
            return 0;
        }
        floats.resize(std::min<size_t>(floats.size(), size_t((buffer->size - offset) / sizeof(float))));
        buffer->pendingWrites.emplace_back(offset, std::move(floats));
        app->m_writtenBuffers.push_back(buffer);
        return 0;
    }

    static int soundIndex(lua_State* L)
    {
        auto sound = checkShared<audio::Sound>(L, 1, kSoundType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "playing") == 0)
            lua_pushboolean(L, sound->playing());
        else if (strcmp(key, "position") == 0)
            lua_pushnumber(L, sound->position());
        else if (strcmp(key, "length") == 0)
            lua_pushnumber(L, sound->length());
        else if (strcmp(key, "volume") == 0)
            lua_pushnumber(L, sound->volume());
        else if (strcmp(key, "loop") == 0)
            lua_pushboolean(L, sound->looping());
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // sound.volume = v, sound.loop = bool
    static int soundNewIndex(lua_State* L)
    {
        auto sound = checkShared<audio::Sound>(L, 1, kSoundType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "volume") == 0)
            sound->setVolume(float(luaL_checknumber(L, 3)));
        else if (strcmp(key, "loop") == 0)
            sound->setLooping(lua_toboolean(L, 3));
        else
            luaL_error(L, "can't set '%s' on a sound", key);
        return 0;
    }

    // rhi.window_srgb(): true if the window's format encodes sRGB itself.
    static int apiWindowSrgb(lua_State* L)
    {
        LuaApp* app = get(L);
        lua_pushboolean(L, app->m_surface && getFormatInfo(app->m_surface->getInfo().preferredFormat).isSrgb);
        return 1;
    }

    // rhi.window_size(): width, height of the window's image in pixels.
    static int apiWindowSize(lua_State* L)
    {
        LuaApp* app = get(L);
        const SurfaceConfig* config = app->m_surface ? app->m_surface->getConfig() : nullptr;
        lua_pushinteger(L, config ? config->width : 0);
        lua_pushinteger(L, config ? config->height : 0);
        return 2;
    }

    // rhi.set_title(text): the device and adapter are appended, as for config.title.
    static int apiSetTitle(lua_State* L)
    {
        LuaApp* app = get(L);
        const char* title = luaL_checkstring(L, 1);
        if (app->m_window && app->m_device)
        {
            const DeviceInfo& info = app->m_device->getInfo();
            std::string fullTitle = std::string(title) + " | " + getRHI()->getDeviceTypeName(info.deviceType) + " (" +
                                    info.adapterName + ")";
            glfwSetWindowTitle(app->m_window, fullTitle.c_str());
        }
        return 0;
    }

    // rhi.set_paused(paused): stops (or restarts) the `time` the shaders get and the
    // physics; update() and input still run, with real time. rhi.paused() says which.
    static int apiSetPaused(lua_State* L)
    {
        get(L)->m_paused = lua_toboolean(L, 1) != 0;
        return 0;
    }

    static int apiPaused(lua_State* L)
    {
        lua_pushboolean(L, get(L)->m_paused);
        return 1;
    }

    // rhi.show_pointer(shown): keeps the mouse pointer visible (true) whatever Escape and
    // clicks do, as a menu needs; false hands it back to them (hidden over the window).
    static int apiShowPointer(lua_State* L)
    {
        LuaApp* app = get(L);
        app->m_pointerShown = lua_toboolean(L, 1) != 0;
        if (!app->m_pointerShown)
        {
            app->m_cursorReleased = false;
        }
        return 0;
    }

    // rhi.reload(): runs the script again from the start before the next frame, as saving
    // it does -- for changes its graph is built around (the pause menu's shadow quality).
    static int apiReload(lua_State* L)
    {
        get(L)->m_reloadRequested = true;
        return 0;
    }

    // A half float's value.
    static float halfToFloat(uint16_t h)
    {
        uint32_t sign = uint32_t(h & 0x8000) << 16;
        uint32_t exponent = (h >> 10) & 0x1F;
        uint32_t mantissa = h & 0x3FF;
        uint32_t bits;
        if (exponent == 0)
        {
            if (mantissa == 0)
                bits = sign;
            else
            {
                // Subnormal: normalize it.
                exponent = 127 - 15 + 1;
                while ((mantissa & 0x400) == 0)
                {
                    mantissa <<= 1;
                    --exponent;
                }
                bits = sign | (exponent << 23) | ((mantissa & 0x3FF) << 13);
            }
        }
        else if (exponent == 31)
            bits = sign | 0x7F800000 | (mantissa << 13);
        else
            bits = sign | ((exponent + 127 - 15) << 23) | (mantissa << 13);
        float f;
        std::memcpy(&f, &bits, sizeof(f));
        return f;
    }

    // rhi.save_texture(texture, path): reads the texture back (as the GPU last left it) and
    // writes it to `path`, for measuring: "RHIF", width and height (uint32), then RGBA as
    // float32, row by row. rgba16f, rgba32f, r32f and rgba8 textures. A debugging aid: it
    // waits for the GPU.
    static int apiSaveTexture(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto texture = checkShared<Texture>(L, 1, kTextureType);
        const char* path = luaL_checkstring(L, 2);
        app->m_queue->waitOnHost();
        ComPtr<ISlangBlob> blob;
        SubresourceLayout layout;
        if (SLANG_FAILED(app->m_device->readTexture(texture->texture, 0, 0, blob.writeRef(), &layout)))
            luaL_error(L, "could not read the texture back");
        uint32_t width = uint32_t(layout.size.width), height = uint32_t(layout.size.height);
        std::vector<float> rgba(size_t(width) * height * 4, 0.0f);
        const uint8_t* bytes = static_cast<const uint8_t*>(blob->getBufferPointer());
        for (uint32_t y = 0; y < height; ++y)
        {
            const uint8_t* row = bytes + size_t(y) * layout.rowPitch;
            for (uint32_t x = 0; x < width; ++x)
            {
                float* out = &rgba[(size_t(y) * width + x) * 4];
                switch (texture->format)
                {
                case Format::RGBA16Float:
                    for (int c = 0; c < 4; ++c)
                    {
                        uint16_t h;
                        std::memcpy(&h, row + x * 8 + c * 2, 2);
                        out[c] = halfToFloat(h);
                    }
                    break;
                case Format::RGBA32Float:
                    std::memcpy(out, row + x * 16, 16);
                    break;
                case Format::R32Float:
                    std::memcpy(out, row + x * 4, 4);
                    break;
                case Format::RGBA8Unorm:
                    for (int c = 0; c < 4; ++c)
                        out[c] = row[x * 4 + c] / 255.0f;
                    break;
                default:
                    luaL_error(L, "save_texture: unsupported format");
                }
            }
        }
        std::ofstream file(path, std::ios::binary);
        if (!file)
            luaL_error(L, "could not write %s", path);
        file.write("RHIF", 4);
        file.write(reinterpret_cast<const char*>(&width), 4);
        file.write(reinterpret_cast<const char*>(&height), 4);
        file.write(reinterpret_cast<const char*>(rgba.data()), std::streamsize(rgba.size() * sizeof(float)));
        return 0;
    }

    // rhi.quit(): closes the window, ending the program after this frame.
    static int apiQuit(lua_State* L)
    {
        LuaApp* app = get(L);
        if (app->m_window)
        {
            glfwSetWindowShouldClose(app->m_window, GLFW_TRUE);
        }
        return 0;
    }

    // rhi.display(): { width, height (the window's size), fullscreen, modes } -- modes are
    // the primary monitor's sizes, { {width, height}, ... }, distinct, smallest first.
    static int apiDisplay(lua_State* L)
    {
        LuaApp* app = get(L);
        int width = 0, height = 0;
        if (app->m_window)
        {
            glfwGetWindowSize(app->m_window, &width, &height);
        }
        lua_newtable(L);
        lua_pushinteger(L, width);
        lua_setfield(L, -2, "width");
        lua_pushinteger(L, height);
        lua_setfield(L, -2, "height");
        lua_pushboolean(L, app->m_fullscreen);
        lua_setfield(L, -2, "fullscreen");
        std::vector<std::pair<int, int>> sizes;
        if (GLFWmonitor* monitor = glfwGetPrimaryMonitor())
        {
            int count = 0;
            const GLFWvidmode* modes = glfwGetVideoModes(monitor, &count);
            for (int i = 0; i < count; ++i)
            {
                sizes.emplace_back(modes[i].width, modes[i].height);
            }
        }
        std::sort(sizes.begin(), sizes.end());
        sizes.erase(std::unique(sizes.begin(), sizes.end()), sizes.end());
        lua_createtable(L, int(sizes.size()), 0);
        for (size_t i = 0; i < sizes.size(); ++i)
        {
            lua_createtable(L, 2, 0);
            lua_pushinteger(L, sizes[i].first);
            lua_rawseti(L, -2, 1);
            lua_pushinteger(L, sizes[i].second);
            lua_rawseti(L, -2, 2);
            lua_rawseti(L, -2, lua_Integer(i + 1));
        }
        lua_setfield(L, -2, "modes");
        return 1;
    }

    // rhi.set_display{ width, height, fullscreen }: the window's size, or with fullscreen,
    // the primary monitor's video mode (the nearest it has) with the window covering it.
    // Leaving fullscreen puts the window back where it was. Missing fields keep theirs.
    // F11 still toggles the borderless fullscreen of the monitor's current mode.
    static int apiSetDisplay(lua_State* L)
    {
        LuaApp* app = get(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        if (!app->m_window)
        {
            return 0;
        }
        int width = 0, height = 0;
        glfwGetWindowSize(app->m_window, &width, &height);
        width = int(readFloat(L, 1, "width", float(width)));
        height = int(readFloat(L, 1, "height", float(height)));
        bool fullscreen = app->m_fullscreen;
        if (lua_getfield(L, 1, "fullscreen") != LUA_TNIL)
        {
            fullscreen = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);
        if (width <= 0 || height <= 0)
        {
            return 0;
        }

        GLFWmonitor* monitor = glfwGetPrimaryMonitor();
        if (fullscreen && monitor)
        {
            if (!app->m_fullscreen)
            {
                glfwGetWindowPos(app->m_window, &app->m_windowedRect[0], &app->m_windowedRect[1]);
                glfwGetWindowSize(app->m_window, &app->m_windowedRect[2], &app->m_windowedRect[3]);
            }
            glfwSetWindowMonitor(app->m_window, monitor, 0, 0, width, height, GLFW_DONT_CARE);
            app->m_fullscreen = true;
        }
        else if (app->m_fullscreen)
        {
            glfwSetWindowMonitor(
                app->m_window,
                nullptr,
                app->m_windowedRect[0],
                app->m_windowedRect[1],
                width,
                height,
                GLFW_DONT_CARE
            );
            app->m_fullscreen = false;
        }
        else
        {
            glfwSetWindowSize(app->m_window, width, height);
        }
        return 0;
    }

    // -----------------------------------------------------------------------------------
    // API: input.*
    // -----------------------------------------------------------------------------------

    static int inputMouse(lua_State* L)
    {
        LuaApp* app = get(L);
        lua_pushnumber(L, app->getMouseX());
        lua_pushnumber(L, app->getMouseY());
        return 2;
    }

    static int inputMouseDown(lua_State* L)
    {
        lua_pushboolean(L, get(L)->isMouseDown(int(luaL_optinteger(L, 1, 0))));
        return 1;
    }

    static int inputKeyDown(lua_State* L)
    {
        LuaApp* app = get(L);
        int key = int(luaL_checkinteger(L, 1));
        lua_pushboolean(L, app->m_window && glfwGetKey(app->m_window, key) == GLFW_PRESS);
        return 1;
    }

    // input.controller([slot]): a live view of a Steam Controller; without a slot, the
    // primary (lowest connected) one. Also bindable as a ControllerState parameter.
    static int inputController(lua_State* L)
    {
        int slot = int(luaL_optinteger(L, 1, -1));
        *static_cast<int*>(lua_newuserdatauv(L, sizeof(int), 0)) = slot;
        luaL_setmetatable(L, kControllerType);
        return 1;
    }

    // -----------------------------------------------------------------------------------
    // Object fields and methods
    // -----------------------------------------------------------------------------------

    static void pushNumbers(lua_State* L, const float* values, int count)
    {
        lua_createtable(L, count, 0);
        for (int i = 0; i < count; ++i)
        {
            lua_pushnumber(L, values[i]);
            lua_rawseti(L, -2, i + 1);
        }
    }

    static int controllerIndex(lua_State* L)
    {
        int slot = *static_cast<int*>(luaL_checkudata(L, 1, kControllerType));
        const SteamControllerState& state = get(L)->controllerState(slot);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "connected") == 0)
            lua_pushboolean(L, state.connected);
        else if (strcmp(key, "buttons") == 0)
            lua_pushinteger(L, state.buttons);
        else if (strcmp(key, "left_stick") == 0)
            pushNumbers(L, state.leftStick, 2);
        else if (strcmp(key, "right_stick") == 0)
            pushNumbers(L, state.rightStick, 2);
        else if (strcmp(key, "left_trigger") == 0)
            lua_pushnumber(L, state.leftTrigger);
        else if (strcmp(key, "right_trigger") == 0)
            lua_pushnumber(L, state.rightTrigger);
        else if (strcmp(key, "left_pad") == 0)
            pushNumbers(L, state.leftPad, 3);
        else if (strcmp(key, "right_pad") == 0)
            pushNumbers(L, state.rightPad, 3);
        else if (strcmp(key, "accel") == 0)
            pushNumbers(L, state.accel, 3);
        else if (strcmp(key, "gyro") == 0)
            pushNumbers(L, state.gyro, 3);
        else if (strcmp(key, "quat") == 0)
            pushNumbers(L, state.quat, 4);
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // controller:button(buttons.A)
    static int controllerButton(lua_State* L)
    {
        int slot = *static_cast<int*>(luaL_checkudata(L, 1, kControllerType));
        lua_pushboolean(L, get(L)->controllerState(slot).button(uint32_t(luaL_checkinteger(L, 2))));
        return 1;
    }

    static int pipelineIndex(lua_State* L)
    {
        Pipeline* pipeline = checkHandle<Pipeline>(L, 1, kPipelineType);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "built") == 0)
            lua_pushboolean(L, pipeline->isBuilt());
        else if (strcmp(key, "version") == 0)
            lua_pushinteger(L, pipeline->version);
        else if (strcmp(key, "thread_group_size") == 0)
        {
            lua_createtable(L, 3, 0);
            for (int i = 0; i < 3; ++i)
            {
                lua_pushinteger(L, pipeline->threadGroupSize[i]);
                lua_rawseti(L, -2, i + 1);
            }
        }
        else
            lua_pushnil(L);
        return 1;
    }

    static int textureIndex(lua_State* L)
    {
        Texture* texture = checkHandle<Texture>(L, 1, kTextureType);
        const char* key = luaL_checkstring(L, 2);
        const TextureDesc& desc = texture->texture->getDesc();
        if (strcmp(key, "width") == 0)
            lua_pushinteger(L, desc.size.width);
        else if (strcmp(key, "height") == 0)
            lua_pushinteger(L, desc.size.height);
        else if (strcmp(key, "depth") == 0)
            lua_pushinteger(L, desc.size.depth);
        else
            lua_pushnil(L);
        return 1;
    }

    // rhi.sampler{ filter = "linear" | "point", address = "clamp" | "wrap" }: for shaders
    // that Sample textures (SamplerState), bound like any other parameter.
    static int apiSampler(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        SamplerDesc desc = {};
        const char* filter = "linear";
        const char* address = "clamp";
        if (lua_istable(L, 1))
        {
            lua_getfield(L, 1, "filter");
            filter = luaL_optstring(L, -1, filter);
            lua_getfield(L, 1, "address");
            address = luaL_optstring(L, -1, address);
            lua_pop(L, 2);
        }
        TextureFilteringMode mode = TextureFilteringMode::Linear;
        if (strcmp(filter, "point") == 0)
            mode = TextureFilteringMode::Point;
        else if (strcmp(filter, "linear") != 0)
            luaL_error(L, "unknown sampler filter '%s' (linear, point)", filter);
        TextureAddressingMode wrap = TextureAddressingMode::ClampToEdge;
        if (strcmp(address, "wrap") == 0)
            wrap = TextureAddressingMode::Wrap;
        else if (strcmp(address, "clamp") != 0)
            luaL_error(L, "unknown sampler address '%s' (clamp, wrap)", address);
        desc.minFilter = desc.magFilter = desc.mipFilter = mode;
        desc.addressU = desc.addressV = desc.addressW = wrap;
        desc.label = "Lua Sampler";
        auto sampler = std::make_shared<Sampler>();
        if (SLANG_FAILED(app->m_device->createSampler(desc, sampler->sampler.writeRef())))
            luaL_error(L, "could not create a sampler");
        pushHandle(L, sampler, kSamplerType);
        return 1;
    }

    static LuaApp* checkFrame(lua_State* L)
    {
        luaL_checkudata(L, 1, kFrameType);
        LuaApp* app = get(L);
        if (!app->m_frame.active)
        {
            luaL_error(L, "the frame can only be used during draw()");
        }
        return app;
    }

    static int frameIndex(lua_State* L)
    {
        LuaApp* app = get(L);
        const char* key = luaL_checkstring(L, 2);
        if (strcmp(key, "width") == 0)
            lua_pushinteger(L, app->m_frame.width);
        else if (strcmp(key, "height") == 0)
            lua_pushinteger(L, app->m_frame.height);
        else if (strcmp(key, "index") == 0)
            lua_pushinteger(L, app->m_frameIndex);
        else if (strcmp(key, "srgb") == 0)
            lua_pushboolean(L, app->m_surface && getFormatInfo(app->m_surface->getInfo().preferredFormat).isSrgb);
        else
        {
            lua_pushvalue(L, lua_upvalueindex(1));
            lua_getfield(L, -1, key);
        }
        return 1;
    }

    // The destination named by a `target` value: the window if nil, else a texture.
    static Destination checkDestination(lua_State* L, int index)
    {
        LuaApp* app = get(L);
        if (lua_isnoneornil(L, index))
        {
            return app->windowDestination();
        }
        return textureDestination(*checkColorTexture(L, index));
    }

    // frame:clear(r, g, b [, a = 1 [, target = window]])
    static int frameClear(lua_State* L)
    {
        LuaApp* app = checkFrame(L);
        float color[4] = {
            float(luaL_optnumber(L, 2, 0.0)),
            float(luaL_optnumber(L, 3, 0.0)),
            float(luaL_optnumber(L, 4, 0.0)),
            float(luaL_optnumber(L, 5, 1.0)),
        };
        app->beginRenderPass(checkDestination(L, 6), color)->end();
        return 0;
    }

    // frame:dispatch(pipeline [, params [, threadsX = width, threadsY = height, threadsZ = 1]])
    static int frameDispatch(lua_State* L)
    {
        LuaApp* app = checkFrame(L);
        Pipeline* pipeline = checkHandle<Pipeline>(L, 2, kPipelineType);
        if (!pipeline->isCompute)
        {
            luaL_error(L, "dispatch() needs a compute pipeline");
        }
        uint32_t threads[3] = {
            uint32_t(luaL_optinteger(L, 4, app->m_frame.width)),
            uint32_t(luaL_optinteger(L, 5, app->m_frame.height)),
            uint32_t(luaL_optinteger(L, 6, 1)),
        };
        if (!pipeline->compute)
        {
            return 0; // never compiled: nothing to run until it does
        }
        IComputePassEncoder* pass = app->m_frame.encoder->beginComputePass();
        PassScope<IComputePassEncoder> scope{pass};
        ShaderCursor cursor(pass->bindPipeline(pipeline->compute));
        app->applyBuiltins(cursor, float(app->m_frame.width), float(app->m_frame.height));
        if (!lua_isnoneornil(L, 3))
        {
            setParams(L, 3, cursor);
        }
        pass->dispatchCompute(
            divRoundUp(threads[0], pipeline->threadGroupSize[0]),
            divRoundUp(threads[1], pipeline->threadGroupSize[1]),
            divRoundUp(threads[2], pipeline->threadGroupSize[2])
        );
        return 0;
    }

    // frame:draw(pipeline, { vertices = buffer, count = n, params = {...}, clear = {r,g,b,a},
    //                       target = texture, viewport = {x, y, width, height} })
    static int frameDraw(lua_State* L)
    {
        LuaApp* app = checkFrame(L);
        Pipeline* pipeline = checkHandle<Pipeline>(L, 2, kPipelineType);
        if (pipeline->isCompute)
        {
            luaL_error(L, "draw() needs a render pipeline");
        }
        if (lua_isnoneornil(L, 3))
        {
            lua_newtable(L);
            lua_replace(L, 3);
        }
        luaL_checktype(L, 3, LUA_TTABLE);

        lua_getfield(L, 3, "vertices");
        Buffer* vertices = lua_isnil(L, -1) ? nullptr : checkHandle<Buffer>(L, -1, kBufferType);
        lua_getfield(L, 3, "count");
        uint32_t defaultCount = (vertices && pipeline->vertexStride) ? uint32_t(vertices->size / pipeline->vertexStride) : 3;
        uint32_t count = uint32_t(luaL_optinteger(L, -1, defaultCount));
        lua_getfield(L, 3, "clear");
        bool clear = lua_istable(L, -1);
        float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        for (int i = 0; clear && i < 4; ++i)
        {
            lua_rawgeti(L, -1, i + 1);
            clearColor[i] = float(luaL_optnumber(L, -1, clearColor[i]));
            lua_pop(L, 1);
        }
        // The vertex buffer handle stays referenced by the options table.
        lua_pop(L, 3);

        lua_getfield(L, 3, "target");
        Destination destination = checkDestination(L, -1);
        lua_pop(L, 1);
        if (pipeline->render && app->resolveColorFormat(*pipeline) != destination.format)
        {
            luaL_error(L, "the pipeline's format doesn't match the target's (see render_pipeline's `format`)");
        }

        float viewport[4] = {0.0f, 0.0f, float(destination.width), float(destination.height)};
        if (lua_getfield(L, 3, "viewport") == LUA_TTABLE)
        {
            for (int i = 0; i < 4; ++i)
            {
                lua_rawgeti(L, -1, i + 1);
                viewport[i] = float(luaL_checknumber(L, -1));
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        if (!pipeline->render)
        {
            // Never compiled: still honor the clear, so the window shows something.
            if (clear)
            {
                app->beginRenderPass(destination, clearColor)->end();
            }
            return 0;
        }

        IRenderPassEncoder* pass = app->beginRenderPass(destination, clear ? clearColor : nullptr, pipeline->depth);
        PassScope<IRenderPassEncoder> scope{pass};
        ShaderCursor cursor(pass->bindPipeline(pipeline->render));
        app->applyBuiltins(cursor, viewport[2], viewport[3]);
        if (lua_getfield(L, 3, "params") != LUA_TNIL)
        {
            setParams(L, -1, cursor);
        }
        lua_pop(L, 1);

        RenderState renderState = {};
        Viewport& vp = renderState.viewports[0];
        vp.originX = viewport[0];
        vp.originY = viewport[1];
        vp.extentX = viewport[2];
        vp.extentY = viewport[3];
        vp.minZ = 0.0f;
        vp.maxZ = 1.0f;
        renderState.viewportCount = 1;
        ScissorRect& scissor = renderState.scissorRects[0];
        scissor.minX = uint32_t(std::max(0.0f, viewport[0]));
        scissor.minY = uint32_t(std::max(0.0f, viewport[1]));
        scissor.maxX = uint32_t(std::max(0.0f, viewport[0] + viewport[2]));
        scissor.maxY = uint32_t(std::max(0.0f, viewport[1] + viewport[3]));
        renderState.scissorRectCount = 1;
        if (vertices)
        {
            renderState.vertexBuffers[0].buffer = vertices->buffer;
            renderState.vertexBufferCount = 1;
        }
        pass->setRenderState(renderState);

        DrawArguments drawArgs = {};
        drawArgs.vertexCount = count;
        pass->draw(drawArgs);
        return 0;
    }

    // frame:blit(texture): copies a texture onto the window, scaled to fit.
    static int frameBlit(lua_State* L)
    {
        LuaApp* app = checkFrame(L);
        Texture* texture = checkHandle<Texture>(L, 2, kTextureType);
        app->m_blitter->blit(app->m_frame.image, texture->texture, app->m_frame.encoder);
        return 0;
    }

    // -----------------------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------------------

    static void setFunctions(lua_State* L, const luaL_Reg* functions)
    {
        luaL_setfuncs(L, functions, 0);
    }

    // Creates a metatable whose __index is `index`, with `methods` reachable from it.
    static void newType(lua_State* L, const char* name, lua_CFunction index, const luaL_Reg* methods, lua_CFunction gc)
    {
        luaL_newmetatable(L, name);
        lua_newtable(L);
        if (methods)
        {
            setFunctions(L, methods);
        }
        lua_pushcclosure(L, index, 1);
        lua_setfield(L, -2, "__index");
        if (gc)
        {
            lua_pushcfunction(L, gc);
            lua_setfield(L, -2, "__gc");
        }
        lua_pop(L, 1);
    }

    static void setNewIndex(lua_State* L, const char* type, lua_CFunction newIndex)
    {
        luaL_getmetatable(L, type);
        lua_pushcfunction(L, newIndex);
        lua_setfield(L, -2, "__newindex");
        lua_pop(L, 1);
    }

    static void registerApi(lua_State* L)
    {
        static const luaL_Reg kRhi[] = {
            {"compute_pipeline", apiComputePipeline},
            {"render_pipeline", apiRenderPipeline},
            {"render_target", apiRenderTarget},
            {"depth_target", apiDepthTarget},
            {"texture", apiTexture},
            {"vertex_buffer", apiVertexBuffer},
            {"buffer", apiBuffer},
            {"device", apiDevice},
            {"adapter", apiAdapter},
            {"devices", apiDevices},
            {"restart", apiRestart},
            {"time", apiTime},
            {"set_title", apiSetTitle},
            {"set_paused", apiSetPaused},
            {"paused", apiPaused},
            {"show_pointer", apiShowPointer},
            {"quit", apiQuit},
            {"save_texture", apiSaveTexture},
            {"reload", apiReload},
            {"display", apiDisplay},
            {"set_display", apiSetDisplay},
            {"window_size", apiWindowSize},
            {"sound", apiSound},
            {"sampler", apiSampler},
            {"read_asset", apiReadAsset},
            {"list_assets", apiListAssets},
            {"include", apiInclude},
            {"params", apiParams},
            {"graph", apiGraph},
            {"set_graph", apiSetGraph},
            {"window_srgb", apiWindowSrgb},
            {"physics_world", apiPhysicsWorld},
            {"set_physics", apiSetPhysics},
            {"load_ply", apiLoadPly},
            {nullptr, nullptr},
        };
        lua_newtable(L);
        setFunctions(L, kRhi);
        lua_setglobal(L, "rhi");

        static const luaL_Reg kInput[] = {
            {"mouse", inputMouse},
            {"mouse_down", inputMouseDown},
            {"key_down", inputKeyDown},
            {"controller", inputController},
            {nullptr, nullptr},
        };
        lua_newtable(L);
        setFunctions(L, kInput);
        auto setInteger = [L](const char* name, lua_Integer value)
        {
            lua_pushinteger(L, value);
            lua_setfield(L, -2, name);
        };
        setInteger("RELEASE", GLFW_RELEASE);
        setInteger("PRESS", GLFW_PRESS);
        setInteger("REPEAT", GLFW_REPEAT);
        setInteger("MOUSE_LEFT", GLFW_MOUSE_BUTTON_LEFT);
        setInteger("MOUSE_RIGHT", GLFW_MOUSE_BUTTON_RIGHT);
        setInteger("MOUSE_MIDDLE", GLFW_MOUSE_BUTTON_MIDDLE);
        lua_setglobal(L, "input");

        // keys.A .. keys.Z, keys["0"] .. keys["9"], keys.F1 .. keys.F12, and named keys.
        lua_newtable(L);
        char name[8];
        for (int i = 0; i < 26; ++i)
        {
            snprintf(name, sizeof(name), "%c", 'A' + i);
            setInteger(name, GLFW_KEY_A + i);
        }
        for (int i = 0; i < 10; ++i)
        {
            snprintf(name, sizeof(name), "%d", i);
            setInteger(name, GLFW_KEY_0 + i);
        }
        for (int i = 0; i < 12; ++i)
        {
            snprintf(name, sizeof(name), "F%d", i + 1);
            setInteger(name, GLFW_KEY_F1 + i);
        }
        static const std::pair<const char*, int> kNamedKeys[] = {
            {"SPACE", GLFW_KEY_SPACE},
            {"ESCAPE", GLFW_KEY_ESCAPE},
            {"ENTER", GLFW_KEY_ENTER},
            {"TAB", GLFW_KEY_TAB},
            {"BACKSPACE", GLFW_KEY_BACKSPACE},
            {"LEFT", GLFW_KEY_LEFT},
            {"RIGHT", GLFW_KEY_RIGHT},
            {"UP", GLFW_KEY_UP},
            {"DOWN", GLFW_KEY_DOWN},
            {"PAGE_UP", GLFW_KEY_PAGE_UP},
            {"PAGE_DOWN", GLFW_KEY_PAGE_DOWN},
            {"HOME", GLFW_KEY_HOME},
            {"END", GLFW_KEY_END},
            {"LEFT_SHIFT", GLFW_KEY_LEFT_SHIFT},
            {"LEFT_CONTROL", GLFW_KEY_LEFT_CONTROL},
            {"LEFT_ALT", GLFW_KEY_LEFT_ALT},
            {"MINUS", GLFW_KEY_MINUS},
            {"EQUAL", GLFW_KEY_EQUAL},
            {"LEFT_BRACKET", GLFW_KEY_LEFT_BRACKET},
            {"RIGHT_BRACKET", GLFW_KEY_RIGHT_BRACKET},
            {"COMMA", GLFW_KEY_COMMA},
            {"PERIOD", GLFW_KEY_PERIOD},
            {"SLASH", GLFW_KEY_SLASH},
            {"KP_ADD", GLFW_KEY_KP_ADD},
            {"KP_SUBTRACT", GLFW_KEY_KP_SUBTRACT},
        };
        for (const auto& [keyName, key] : kNamedKeys)
        {
            setInteger(keyName, key);
        }
        lua_setglobal(L, "keys");

        // buttons.A, buttons.DPadLeft, ...: SteamControllerButtons bits.
        static const std::pair<const char*, uint32_t> kButtons[] = {
            {"A", SteamControllerButtons::A},
            {"B", SteamControllerButtons::B},
            {"X", SteamControllerButtons::X},
            {"Y", SteamControllerButtons::Y},
            {"QAM", SteamControllerButtons::QAM},
            {"R3", SteamControllerButtons::R3},
            {"View", SteamControllerButtons::View},
            {"R4", SteamControllerButtons::R4},
            {"R5", SteamControllerButtons::R5},
            {"RB", SteamControllerButtons::RB},
            {"DPadDown", SteamControllerButtons::DPadDown},
            {"DPadRight", SteamControllerButtons::DPadRight},
            {"DPadLeft", SteamControllerButtons::DPadLeft},
            {"DPadUp", SteamControllerButtons::DPadUp},
            {"Menu", SteamControllerButtons::Menu},
            {"L3", SteamControllerButtons::L3},
            {"Steam", SteamControllerButtons::Steam},
            {"L4", SteamControllerButtons::L4},
            {"L5", SteamControllerButtons::L5},
            {"LB", SteamControllerButtons::LB},
            {"RightStickTouch", SteamControllerButtons::RightStickTouch},
            {"RightPadTouch", SteamControllerButtons::RightPadTouch},
            {"RightPadClick", SteamControllerButtons::RightPadClick},
            {"RightTriggerClick", SteamControllerButtons::RightTriggerClick},
            {"LeftStickTouch", SteamControllerButtons::LeftStickTouch},
            {"LeftPadTouch", SteamControllerButtons::LeftPadTouch},
            {"LeftPadClick", SteamControllerButtons::LeftPadClick},
            {"LeftTriggerClick", SteamControllerButtons::LeftTriggerClick},
            {"RightGripTouch", SteamControllerButtons::RightGripTouch},
            {"LeftGripTouch", SteamControllerButtons::LeftGripTouch},
        };
        lua_newtable(L);
        for (const auto& [buttonName, bit] : kButtons)
        {
            setInteger(buttonName, bit);
        }
        lua_setglobal(L, "buttons");

        newType(L, kPipelineType, pipelineIndex, nullptr, collectHandle<Pipeline>);
        newType(L, kTextureType, textureIndex, nullptr, collectHandle<Texture>);
        static const luaL_Reg kBufferMethods[] = {
            {"write", bufferWrite},
            {nullptr, nullptr},
        };
        newType(L, kBufferType, bufferIndex, kBufferMethods, collectHandle<Buffer>);

        static const luaL_Reg kControllerMethods[] = {
            {"button", controllerButton},
            {nullptr, nullptr},
        };
        newType(L, kControllerType, controllerIndex, kControllerMethods, nullptr);

        static const luaL_Reg kFrameMethods[] = {
            {"clear", frameClear},
            {"dispatch", frameDispatch},
            {"draw", frameDraw},
            {"blit", frameBlit},
            {nullptr, nullptr},
        };
        newType(L, kFrameType, frameIndex, kFrameMethods, nullptr);

        static const luaL_Reg kParamsMethods[] = {
            {"set", paramsSet},
            {nullptr, nullptr},
        };
        newType(L, kParamsType, paramsIndex, kParamsMethods, collectHandle<ParamBlock>);
        setNewIndex(L, kParamsType, paramsNewIndex);

        static const luaL_Reg kGraphMethods[] = {
            {"render_pass", graphRenderPass},
            {"dispatch", graphDispatch},
            {nullptr, nullptr},
        };
        newType(L, kGraphType, paramsIndex, kGraphMethods, collectHandle<Graph>);

        static const luaL_Reg kNodeMethods[] = {
            {"draw", nodeDraw},
            {"rerun", nodeRerun},
            {nullptr, nullptr},
        };
        newType(L, kNodeType, nodeIndex, kNodeMethods, collectHandle<GraphNode>);
        setNewIndex(L, kNodeType, nodeNewIndex);

        newType(L, kDrawType, drawIndex, nullptr, collectHandle<GraphDraw>);

        static const luaL_Reg kPhysicsMethods[] = {
            {"group", physicsGroup},
            {"character", physicsCharacter},
            {"raycast", physicsRaycast},
            {nullptr, nullptr},
        };
        newType(L, kPhysicsType, physicsIndex, kPhysicsMethods, collectHandle<PhysicsWorld>);
        setNewIndex(L, kPhysicsType, physicsNewIndex);

        static const luaL_Reg kGroupMethods[] = {
            {"add", groupAdd},
            {"clear", groupClear},
            {"set_velocity", groupSetVelocity},
            {"impulse", groupImpulse},
            {"position", groupPosition},
            {"set_transform", groupSetTransform},
            {nullptr, nullptr},
        };
        newType(L, kBodyGroupType, groupIndex, kGroupMethods, collectHandle<BodyGroup>);

        static const luaL_Reg kCharacterMethods[] = {
            {"jump", characterJump},
            {nullptr, nullptr},
        };
        newType(L, kCharacterType, characterIndex, kCharacterMethods, collectHandle<CharacterHandle>);
        setNewIndex(L, kCharacterType, characterNewIndex);

        static const luaL_Reg kSoundMethods[] = {
            {"play", soundPlay},
            {"pause", soundPause},
            {"stop", soundStop},
            {"seek", soundSeek},
            {nullptr, nullptr},
        };
        newType(L, kSoundType, soundIndex, kSoundMethods, collectHandle<audio::Sound>);
        newType(L, kSamplerType, [](lua_State* L) { return lua_pushnil(L), 1; }, nullptr, collectHandle<Sampler>);
        setNewIndex(L, kSoundType, soundNewIndex);
        setNewIndex(L, kDrawType, drawNewIndex);
    }

public:
    fs::path m_scriptPath;
    fs::path m_scriptDir;
    std::string m_adapterName; // the adapter asked for (see the constructor)
    lua_State* m_lua = nullptr;
    bool m_scriptFailed = false;

    ComPtr<IDevice> m_device;
    ComPtr<ISurface> m_surface;
    ComPtr<ICommandQueue> m_queue;
    std::unique_ptr<Blitter> m_blitter;
    ComPtr<ITexture> m_depthTexture;
    static constexpr Format kDepthFormat = Format::D32Float;

    std::map<std::string, std::shared_ptr<Pipeline>> m_pipelines;
    // The render graph run every frame, if the script set one (rhi.set_graph).
    std::shared_ptr<Graph> m_graph;
    // The physics world the host steps every frame, if the script set one (rhi.set_physics).
    std::shared_ptr<PhysicsWorld> m_physics;
    // Lua files loaded with rhi.include(); saving one reloads the script.
    std::set<std::string> m_includedScripts;
    std::set<std::string> m_warnedAssets; // missing assets already reported
    std::vector<std::weak_ptr<Texture>> m_renderTargets;

    // The frame being recorded; only valid during the script's draw().
    struct Frame
    {
        ICommandEncoder* encoder = nullptr;
        ITexture* image = nullptr;
        uint32_t width = 0;
        uint32_t height = 0;
        bool active = false;
        // Depth buffers cleared since the frame began; later passes load them.
        std::set<ITexture*> validDepth;
    };
    Frame m_frame;
    uint32_t m_frameIndex = 0;

    double m_time = 0.0;
    double m_timeDelta = 0.0;
    // rhi.set_paused: the shaders' `time` and the physics stop; the script still runs.
    bool m_paused = false;
    double m_shaderTime = 0.0; // the `time` builtin: seconds run while not paused
    bool m_reloadRequested = false; // rhi.reload(), done at the next update
    std::vector<std::weak_ptr<Buffer>> m_writtenBuffers; // with buffer:write data to upload

    // Hot reload.
    static constexpr double kWatchInterval = 0.15; // seconds between checks
    FileWatcher m_watcher;
    double m_lastWatchTime = 0.0;
    uint32_t m_buildSerial = 0;
};

// ---------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------

// Resolves the script argument: a path to a .lua file, or the name of a script in
// examples/lua/scripts.
static fs::path findScript(const std::string& arg)
{
    std::error_code ec;
    if (fs::is_regular_file(arg, ec))
    {
        return fs::absolute(arg);
    }
    fs::path named = fs::path(LUA_SCRIPTS_DIR) / (arg + ".lua");
    if (fs::is_regular_file(named, ec))
    {
        return named;
    }
    return {};
}

static void listExamples()
{
    printf("examples:\n");
    std::error_code ec;
    for (const fs::directory_entry& entry : fs::directory_iterator(LUA_SCRIPTS_DIR, ec))
    {
        if (entry.is_regular_file(ec) && entry.path().extension() == ".lua")
        {
            printf("  %s\n", entry.path().stem().string().c_str());
        }
    }
}

// The backends a script can ask for, by the name slang-rhi gives them.
static const DeviceType kDeviceTypes[] = {
    DeviceType::D3D11,
    DeviceType::D3D12,
    DeviceType::Vulkan,
    DeviceType::Metal,
    DeviceType::CPU,
    DeviceType::CUDA,
    DeviceType::WGPU,
};

static bool findDeviceType(const std::string& name, DeviceType& outType)
{
    for (DeviceType type : kDeviceTypes)
    {
        if (lowercase(getRHI()->getDeviceTypeName(type)) == lowercase(name))
        {
            outType = type;
            return true;
        }
    }
    return false;
}

static void printUsage()
{
    printf("usage: example-lua [--api vulkan] [example name | path to .lua script]\n");
    printf("the engine runs on Vulkan only, for now; the GPU is picked in the settings (Display)\n");
    listExamples();
}

int main(int argc, const char** argv)
{
    std::string arg = "showcase";
    std::string api;
    for (int i = 1; i < argc; ++i)
    {
        std::string current = argv[i];
        if (current == "-h" || current == "--help")
        {
            printUsage();
            return 0;
        }
        if (current == "--api" && i + 1 < argc)
        {
            api = argv[++i];
            continue;
        }
        arg = current;
    }

    fs::path script = findScript(arg);
    if (script.empty())
    {
        printf("could not find a script '%s'\n", arg.c_str());
        listExamples();
        return 1;
    }

    // One window, on Vulkan (the engine's only API, for now), on the GPU picked in the
    // settings, else the default one. rhi.restart runs the script again on another; a GPU
    // that can't start falls back to the one before, a saved one to the default.
    if (!api.empty())
    {
        DeviceType asked;
        if (!findDeviceType(api, asked) || asked != kEngineDeviceType)
        {
            printf("the engine runs on Vulkan only, for now (not '%s')\n", api.c_str());
            return 1;
        }
    }
    if (!getRHI()->isDeviceTypeSupported(kEngineDeviceType))
    {
        printf("Vulkan is not supported by this build or machine\n");
        return 1;
    }
    std::string savedAdapter = LuaApp(script).readSavedAdapter();
    std::string adapter = savedAdapter;
    std::string previousAdapter;
    bool restarted = false;
    int result = 0;
    while (true)
    {
        result = rhi::detail::runExamples(
            [&]() -> ExampleBase* { return new LuaApp(script, adapter); },
            {kEngineDeviceType}
        );
        if (result != 0)
        {
            printf(
                "could not start '%s' on %s\n",
                script.filename().string().c_str(),
                adapter.empty() ? "the default GPU" : adapter.c_str()
            );
        }
        if (g_restart.pending)
        {
            g_restart.pending = false;
            previousAdapter = adapter;
            adapter = g_restart.adapter;
            restarted = true;
            continue;
        }
        if (result != 0 && restarted)
        {
            // The GPU restarted on didn't start: back to the one before.
            adapter = previousAdapter;
            restarted = false;
            continue;
        }
        if (result != 0 && !savedAdapter.empty() && adapter == savedAdapter)
        {
            // The GPU picked in the settings didn't start: the default one.
            savedAdapter.clear();
            adapter.clear();
            continue;
        }
        break;
    }
    return result;
}
