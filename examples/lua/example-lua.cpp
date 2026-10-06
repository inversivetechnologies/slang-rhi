// Scriptable example host: every example is a Lua script that drives slang-rhi.
//
// A script lives next to its shaders (examples/<name>/<name>.lua) and is picked on the
// command line: `example-lua scene`, or a path to any .lua file. The script and every
// shader it uses -- includes too -- reload when saved.
//
// See examples/lua/README.md for the script API.

#include "example-base.h"

// Lua is built as C++ (see CMakeLists.txt), so its headers are included without the
// extern "C" wrapper that lua.hpp adds.
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
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
bool readShaderSource(const fs::path& path, const std::vector<fs::path>& searchDirs, ShaderSource& out, int depth = 0)
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
    // Depth buffer for depth-tested draws into this texture, created on first use.
    ComPtr<ITexture> depth;
};

struct Buffer
{
    ComPtr<IBuffer> buffer;
    uint64_t size = 0;
};

// A shader parameter value captured from Lua, so it can be applied without the Lua state:
// by the render graph every frame, or straight away by frame:draw() and frame:dispatch().
struct ParamValue
{
    enum class Kind
    {
        Numbers,
        Table,
        Texture,
        Buffer,
        Controller,
    };
    Kind kind = Kind::Numbers;
    std::vector<double> numbers; // Numbers
    // Table: the string-keyed fields, and the elements 1..n.
    std::vector<std::string> fieldNames;
    std::vector<ParamValue> fieldValues;
    std::vector<ParamValue> elements;
    std::shared_ptr<Texture> texture;
    std::shared_ptr<Buffer> buffer;
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
    std::shared_ptr<Texture> target; // null: the window
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
    // Run once, then again only when asked (rerun()) or when the pipeline is rebuilt.
    bool once = false;
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

// Runs one script on one device, in its own window and Lua state.
class LuaApp : public ExampleBase
{
public:
    explicit LuaApp(fs::path scriptPath)
        : m_scriptPath(std::move(scriptPath))
        , m_scriptDir(m_scriptPath.parent_path())
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

        SLANG_RETURN_ON_FAIL(createDevice(deviceType, features, {}, m_device.writeRef(), {m_scriptDir.string()}));
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

        callScript("update", m_time, m_timeDelta);
        return SLANG_OK;
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
        m_lua = L;
        m_scriptFailed = false;
        printf("[lua] reloaded '%s'\n", m_scriptPath.filename().string().c_str());
        fflush(stdout);
        callScript("init");
    }

    // Reads the window and device settings from the script's global `config` table.
    // (`config.device` is read up front by main(), see readConfiguredDevice().)
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

    // Returns the script's `config.device`, or an empty string if it doesn't set one (or
    // doesn't load). Runs the script's top level in a state of its own, before any window
    // exists, so the backend can be picked before anything is created.
    std::string readConfiguredDevice()
    {
        lua_State* L = openScript();
        if (!L)
        {
            return {};
        }
        std::string device;
        if (lua_getglobal(L, "config") == LUA_TTABLE && lua_getfield(L, -1, "device") == LUA_TSTRING)
        {
            device = lua_tostring(L, -1);
        }
        lua_close(L);
        return device;
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
        bool read = readShaderSource(pipeline.path, {m_scriptDir}, source);
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
        RenderPipelineDesc desc = {};
        desc.program = compiled.program;
        desc.inputLayout = inputLayout;
        desc.primitiveTopology = pipeline.topology;
        desc.targets = &colorTarget;
        desc.targetCount = 1;
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

    Result allocateTexture(Texture& texture, uint32_t width, uint32_t height)
    {
        TextureDesc desc = {};
        desc.type = TextureType::Texture2D;
        desc.size.width = std::max<uint32_t>(width, 1);
        desc.size.height = std::max<uint32_t>(height, 1);
        desc.format = texture.format;
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
            uint32_t scaledWidth = scaledSize(width, texture->scale);
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
        ITexture* color = nullptr;
        Format format = Format::Undefined;
        uint32_t width = 0;
        uint32_t height = 0;
        // Where the destination's depth buffer lives.
        ComPtr<ITexture>* depth = nullptr;
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
    IRenderPassEncoder* beginRenderPass(const Destination& destination, const float* clearColor, bool depth = false)
    {
        RenderPassColorAttachment colorAttachment = {};
        colorAttachment.view = destination.color->getDefaultView();
        colorAttachment.loadOp = clearColor ? LoadOp::Clear : LoadOp::Load;
        if (clearColor)
        {
            std::copy_n(clearColor, 4, colorAttachment.clearValue);
            if (*destination.depth)
            {
                m_frame.validDepth.erase(destination.depth->get());
            }
        }
        RenderPassDesc renderPass = {};
        renderPass.colorAttachments = &colorAttachment;
        renderPass.colorAttachmentCount = 1;

        RenderPassDepthStencilAttachment depthAttachment = {};
        if (depth && SLANG_SUCCEEDED(ensureDepthTexture(*destination.depth, destination.width, destination.height)))
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
    // `time` (seconds) and `viewportSize` (pixels). Set before the script's parameters,
    // which can override them.
    void applyBuiltins(const ShaderCursor& root, float viewportWidth, float viewportHeight)
    {
        ShaderCursor time = root["time"];
        if (time.isValid())
        {
            setNumbers(time, {glfwGetTime()});
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
        applyBuiltins(root, float(m_frame.width), float(m_frame.height));
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

        bool depth = false;
        for (const std::shared_ptr<GraphDraw>& draw : node.draws)
        {
            depth = depth || (draw->enabled && draw->pipeline->depth);
        }

        IRenderPassEncoder* pass = beginRenderPass(destination, node.clear ? node.clearColor : nullptr, depth);
        PassScope<IRenderPassEncoder> scope{pass};
        for (const std::shared_ptr<GraphDraw>& draw : node.draws)
        {
            Pipeline* pipeline = draw->pipeline.get();
            if (!draw->enabled || !pipeline->render || draw->count == 0)
            {
                continue;
            }
            if (resolveColorFormat(*pipeline) != destination.format)
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
            pass->draw(drawArgs);
        }
    }

    void runGraph(Graph& graph)
    {
        for (const std::shared_ptr<GraphNode>& node : graph.nodes)
        {
            if (!node->enabled)
            {
                continue;
            }
            if (node->isDispatch)
            {
                runDispatch(*node);
            }
            else
            {
                runRenderPass(*node);
            }
        }
    }

    // -----------------------------------------------------------------------------------
    // API: rhi.*
    // -----------------------------------------------------------------------------------

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
        desc->path = app->m_scriptDir / luaL_checkstring(L, 1);
        desc->entryPoints = {luaL_optstring(L, 2, "mainCompute")};
        desc->isCompute = true;
        pushHandle(L, app->getPipeline(desc), kPipelineType);
        return 1;
    }

    // rhi.render_pipeline{ shader = path, vertex = "vertexMain", fragment = "fragmentMain",
    //                      layout = { {semantic, format}, ... }, topology = "triangles" }
    static int apiRenderPipeline(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        auto desc = std::make_shared<Pipeline>();
        desc->isCompute = false;

        lua_getfield(L, 1, "shader");
        desc->path = app->m_scriptDir / luaL_checkstring(L, -1);
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

        if (lua_getfield(L, 1, "format") != LUA_TNIL)
        {
            desc->colorFormat = checkFormat(L, luaL_checkstring(L, -1))->format;
        }
        lua_pop(L, 1);

        pushHandle(L, app->getPipeline(desc), kPipelineType);
        return 1;
    }

    // rhi.render_target([format = "rgba32f" [, scale = 1]]): a texture that follows the
    // window size (times `scale`).
    static int apiRenderTarget(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        auto texture = std::make_shared<Texture>();
        texture->format = checkFormat(L, luaL_optstring(L, 1, "rgba32f"))->format;
        texture->followsSurface = true;
        texture->scale = float(luaL_optnumber(L, 2, 1.0));
        if (texture->scale <= 0.0f)
        {
            luaL_error(L, "render_target scale must be positive");
        }
        const SurfaceConfig* config = app->m_surface->getConfig();
        uint32_t width = scaledSize(config ? config->width : 1, texture->scale);
        uint32_t height = scaledSize(config ? config->height : 1, texture->scale);
        if (SLANG_FAILED(app->allocateTexture(*texture, width, height)))
        {
            luaL_error(L, "could not create render target");
        }
        app->m_renderTargets.push_back(texture);
        pushHandle(L, texture, kTextureType);
        return 1;
    }

    // rhi.texture{ width = w, height = h, format = "rgba32f" }
    static int apiTexture(lua_State* L)
    {
        LuaApp* app = requireDevice(L);
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_getfield(L, 1, "width");
        lua_getfield(L, 1, "height");
        lua_getfield(L, 1, "format");
        auto texture = std::make_shared<Texture>();
        texture->format = checkFormat(L, luaL_optstring(L, -1, "rgba32f"))->format;
        uint32_t width = uint32_t(luaL_checkinteger(L, -3));
        uint32_t height = uint32_t(luaL_checkinteger(L, -2));
        lua_pop(L, 3);
        if (SLANG_FAILED(app->allocateTexture(*texture, width, height)))
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

    // graph:render_pass{ name, target = texture, clear = {r,g,b,a},
    //                    viewport = {x,y,w,h} | viewport_fraction = {x,y,w,h} }
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
        lua_getfield(L, 2, "target");
        if (!lua_isnil(L, -1))
            node->target = checkShared<Texture>(L, -1, kTextureType);
        lua_pop(L, 1);
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
            readThreads(L, lua_gettop(L), node->threads);
        lua_pop(L, 1);
        lua_getfield(L, 2, "once");
        node->once = lua_toboolean(L, -1);
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
        else if (strcmp(key, "threads") == 0)
            readThreads(L, 3, node->threads);
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
        else
            luaL_error(L, "can't set '%s' on a graph draw", key);
        return 0;
    }

    // rhi.window_srgb(): true if the window's format encodes sRGB itself.
    static int apiWindowSrgb(lua_State* L)
    {
        LuaApp* app = get(L);
        lua_pushboolean(L, app->m_surface && getFormatInfo(app->m_surface->getInfo().preferredFormat).isSrgb);
        return 1;
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
        else
            lua_pushnil(L);
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
        return textureDestination(*checkHandle<Texture>(L, index, kTextureType));
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
            {"texture", apiTexture},
            {"vertex_buffer", apiVertexBuffer},
            {"buffer", apiBuffer},
            {"device", apiDevice},
            {"time", apiTime},
            {"set_title", apiSetTitle},
            {"include", apiInclude},
            {"params", apiParams},
            {"graph", apiGraph},
            {"set_graph", apiSetGraph},
            {"window_srgb", apiWindowSrgb},
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
        newType(L, kBufferType, [](lua_State* L) { return lua_pushnil(L), 1; }, nullptr, collectHandle<Buffer>);

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
        setNewIndex(L, kDrawType, drawNewIndex);
    }

public:
    fs::path m_scriptPath;
    fs::path m_scriptDir;
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
    // Lua files loaded with rhi.include(); saving one reloads the script.
    std::set<std::string> m_includedScripts;
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

    // Hot reload.
    static constexpr double kWatchInterval = 0.15; // seconds between checks
    FileWatcher m_watcher;
    double m_lastWatchTime = 0.0;
    uint32_t m_buildSerial = 0;
};

// ---------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------

// Resolves the script argument: a path to a .lua file, or the name of an example
// (examples/<name>/<name>.lua, or a script in examples/lua/).
static fs::path findScript(const std::string& arg)
{
    std::error_code ec;
    if (fs::is_regular_file(arg, ec))
    {
        return fs::absolute(arg);
    }
    for (const fs::path& named : {
             fs::path(EXAMPLES_ROOT) / arg / (arg + ".lua"),
             fs::path(EXAMPLES_ROOT) / "lua" / (arg + ".lua"),
         })
    {
        if (fs::is_regular_file(named, ec))
        {
            return named;
        }
    }
    return {};
}

static void listExamples()
{
    printf("examples:\n");
    std::error_code ec;
    for (const fs::directory_entry& entry : fs::directory_iterator(EXAMPLES_ROOT, ec))
    {
        std::string name = entry.path().filename().string();
        if (fs::is_regular_file(entry.path() / (name + ".lua"), ec))
        {
            printf("  %s\n", name.c_str());
        }
    }
    for (const fs::directory_entry& entry : fs::directory_iterator(fs::path(EXAMPLES_ROOT) / "lua", ec))
    {
        if (entry.path().extension() == ".lua")
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
    printf("usage: example-lua [--api <name>] [example name | path to .lua script]\n");
    printf("apis:");
    for (DeviceType type : kDeviceTypes)
    {
        printf(" %s", lowercase(getRHI()->getDeviceTypeName(type)).c_str());
    }
    printf(" (default: the script's config.device, else vulkan)\n");
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

    // One window, on one graphics API: the command line's, else the script's, else Vulkan.
    if (api.empty())
    {
        api = LuaApp(script).readConfiguredDevice();
    }
    if (api.empty())
    {
        api = "vulkan";
    }
    DeviceType deviceType;
    if (!findDeviceType(api, deviceType))
    {
        printf("unknown api '%s'\n", api.c_str());
        printUsage();
        return 1;
    }
    if (!getRHI()->isDeviceTypeSupported(deviceType))
    {
        printf("%s is not supported by this build or machine\n", getRHI()->getDeviceTypeName(deviceType));
        return 1;
    }

    int result = rhi::detail::runExamples([&]() -> ExampleBase* { return new LuaApp(script); }, {deviceType});
    if (result != 0)
    {
        printf("could not start '%s' on %s\n", script.filename().string().c_str(), getRHI()->getDeviceTypeName(deviceType));
    }
    return result;
}
