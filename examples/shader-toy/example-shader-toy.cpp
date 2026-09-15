#include "example-base.h"

#include <filesystem>
#include <fstream>
#include <future>
#include <memory>
#include <string>

using namespace rhi;

// List of shaders to cycle through using the left/right arrow keys.
static const std::vector<const char*> kShaders = {
    "circle.slang",
    "ocean.slang",
    "sdfs2d.slang",
    "controller.slang",
};

// Example for running "ShaderToy"-style shaders using a compute shader to render to a texture.
class ExampleShaderToy : public ExampleBase
{
public:
    Result init(DeviceType deviceType) override
    {
        // Only run on Vulkan.
        if (deviceType != DeviceType::Vulkan)
        {
            return SLANG_FAIL;
        }

        SLANG_RETURN_ON_FAIL(createDevice(deviceType, {Feature::Surface}, {}, m_device.writeRef()));
        SLANG_RETURN_ON_FAIL(createWindow(m_device, "ShaderToy"));
        SLANG_RETURN_ON_FAIL(createSurface(m_device, Format::Undefined, m_surface.writeRef()));

        SLANG_RETURN_ON_FAIL(m_device->getQueue(QueueType::Graphics, m_queue.writeRef()));

        m_blitter = std::make_unique<Blitter>(m_device);

        m_pipelines.resize(kShaders.size());
        m_watched.resize(kShaders.size());
        for (size_t i = 0; i < kShaders.size(); ++i)
        {
            std::error_code ec;
            m_watched[i].known = std::filesystem::last_write_time(shaderPath(i), ec);
        }
        printf("[shader-toy] watching '%s' for shader edits\n", EXAMPLE_DIR);
        fflush(stdout);

        loadShader();
        return SLANG_OK;
    }

    virtual void shutdown() override
    {
        m_queue->waitOnHost();
        m_queue.setNull();
        m_blitter.reset();
        m_surface.setNull();
        m_device.setNull();
    }

    virtual Result update(double time) override
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
            pollShaderFiles();
        }
        m_frameRate = 0.9 * m_frameRate + 0.1 * (m_timeDelta > 0.0 ? (1.0 / m_timeDelta) : 0.0);

        if (isMouseDown(0))
        {
            m_stickyMousePos[0] = getMouseX();
            m_stickyMousePos[1] = getMouseY();
        }
        bool wasMouseDown = m_combinedMouseDown;
        m_combinedMouseDown = isMouseDown(0) || isMouseDown(1) || isMouseDown(2);
        if (m_combinedMouseDown && !wasMouseDown)
        {
            m_combinedMouseClicked = true;
        }
        else
        {
            m_combinedMouseClicked = false;
        }
        return SLANG_OK;
    }

    virtual Result draw() override
    {
        // Wait for shader to be loaded
        if (m_future.valid())
        {
            Result result = m_future.get();
            SLANG_RETURN_ON_FAIL(result);
        }

        // Skip rendering if surface is not configured (eg. when window is minimized)
        if (!m_surface->getConfig())
        {
            return SLANG_OK;
        }

        // Acquire next image from the surface
        ComPtr<ITexture> image;
        m_surface->acquireNextImage(image.writeRef());
        if (!image)
        {
            return SLANG_OK;
        }

        uint32_t width = image->getDesc().size.width;
        uint32_t height = image->getDesc().size.height;

        // Create or resize render texture if needed
        if (!m_texture || m_texture->getDesc().size.width != width || m_texture->getDesc().size.height != height)
        {
            TextureDesc textureDesc = {};
            textureDesc.type = TextureType::Texture2D;
            textureDesc.size.width = width;
            textureDesc.size.height = height;
            textureDesc.format = Format::RGBA32Float;
            textureDesc.usage = TextureUsage::UnorderedAccess | TextureUsage::ShaderResource | TextureUsage::CopySource;
            m_device->createTexture(textureDesc, nullptr, m_texture.writeRef());
        }

        // Start command encoding
        ComPtr<ICommandEncoder> commandEncoder = m_queue->createCommandEncoder();

        // Start compute pass
        IComputePassEncoder* passEncoder = commandEncoder->beginComputePass();
        ShaderCursor cursor(passEncoder->bindPipeline(m_pipelines[m_shaderIndex]));
        float resolution[3] = {float(width), float(height), 1.0f};
        cursor["iResolution"].setData(resolution);
        cursor["iTime"].setData(float(m_time));
        cursor["iTimeDelta"].setData(float(m_timeDelta));
        cursor["iFrameRate"].setData(float(m_frameRate));
        cursor["iFrame"].setData(m_frame);
        float mouse[4] = {
            m_stickyMousePos[0],
            m_stickyMousePos[1],
            m_combinedMouseDown ? 1.f : 0.f,
            m_combinedMouseClicked ? 1.f : 0.f
        };
        cursor["iMouse"].setData(mouse);
        bindSteamControllerState(cursor["iController"], getPrimaryControllerState());
        cursor["texture"].setBinding(m_texture);
        passEncoder->dispatchCompute((width + 15) / 16, (height + 15) / 16, 1);
        passEncoder->end();

        // Blit result to the surface image
        m_blitter->blit(image, m_texture, commandEncoder);

        // Submit command buffer
        m_queue->submit(commandEncoder->finish());

        m_frame += 1;

        // Present the surface
        return m_surface->present();
    }

    virtual void onResize(int width, int height, int framebufferWidth, int framebufferHeight) override
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
    }

    virtual void onKey(int key, int scancode, int action, int mods) override
    {
        if (key == GLFW_KEY_RIGHT && action == GLFW_PRESS)
        {
            m_shaderIndex = (m_shaderIndex + 1) % kShaders.size();
            loadShader();
        }
        else if (key == GLFW_KEY_LEFT && action == GLFW_PRESS)
        {
            m_shaderIndex = (m_shaderIndex - 1 + kShaders.size()) % kShaders.size();
            loadShader();
        }
    }

    std::string shaderPath(size_t index) const
    {
        return std::string(EXAMPLE_DIR) + "/" + kShaders[index];
    }

    // Looks for edited shaders. A changed timestamp has to survive one further check
    // before it counts: editors write in more than one step, and compiling a half-written
    // file just produces errors for something that is about to be valid.
    void pollShaderFiles()
    {
        for (size_t i = 0; i < kShaders.size(); ++i)
        {
            std::error_code ec;
            std::filesystem::file_time_type stamp = std::filesystem::last_write_time(shaderPath(i), ec);
            if (ec)
            {
                continue; // mid-write, or gone: try again next time
            }
            WatchedShader& watched = m_watched[i];
            if (stamp == watched.known)
            {
                watched.hasPending = false;
                continue;
            }
            if (!watched.hasPending || stamp != watched.pending)
            {
                watched.pending = stamp;
                watched.hasPending = true;
                continue;
            }
            watched.known = stamp;
            watched.hasPending = false;
            onShaderFileChanged(i);
        }
    }

    void onShaderFileChanged(size_t index)
    {
        // The pipeline about to be replaced may still be referenced by work in flight.
        m_queue->waitOnHost();

        if (index == size_t(m_shaderIndex))
        {
            reloadCurrentShader();
        }
        else
        {
            // Not on screen: drop it so selecting it compiles the new source.
            m_pipelines[index].setNull();
        }
    }

    // Compiles the current shader afresh, keeping the running build if it doesn't
    // compile -- a syntax error while typing should cost you the frame, not the session.
    void reloadCurrentShader()
    {
        std::string path = shaderPath(m_shaderIndex);
        std::ifstream file(path, std::ios::binary);
        if (!file)
        {
            printf("[shader-toy] could not open '%s'\n", path.c_str());
            fflush(stdout);
            return;
        }
        std::string source((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());

        // The session keys loaded modules by name *and* by path, and holding either
        // against an already-loaded module is an error ("The key already exists in
        // Dictionary"), so both have to be new on every reload. The suffix goes on the
        // file name rather than the directory: #include is resolved relative to the
        // path's directory, which has to stay the real one.
        ++m_reloadSerial;
        char moduleName[256];
        snprintf(moduleName, sizeof(moduleName), "%s-reload%u", kShaders[m_shaderIndex], m_reloadSerial);
        char virtualPath[512];
        snprintf(virtualPath, sizeof(virtualPath), "%s-reload%u", path.c_str(), m_reloadSerial);

        SLANG_RHI_DEVICE_SCOPE(m_device);
        ComPtr<IComputePipeline> pipeline;
        if (SLANG_FAILED(createComputePipelineFromNamedSource(
                m_device,
                moduleName,
                virtualPath,
                source.c_str(),
                "mainCompute",
                pipeline.writeRef()
            )))
        {
            printf("[shader-toy] '%s' failed to compile, keeping the running build\n", kShaders[m_shaderIndex]);
            fflush(stdout);
            return;
        }

        m_pipelines[m_shaderIndex] = pipeline;
        printf("[shader-toy] reloaded '%s'\n", kShaders[m_shaderIndex]);
        fflush(stdout);
    }

    void loadShader()
    {
        if (m_pipelines[m_shaderIndex])
        {
            return;
        }
        // Load shader asynchronously
        m_future = std::async(
            [this]() -> Result
            {
                // Needed for CUDA-based devices to ensure the correct context
                // is current in this thread when creating the pipeline.
                SLANG_RHI_DEVICE_SCOPE(m_device);
                return createComputePipeline(
                    m_device,
                    kShaders[m_shaderIndex],
                    "mainCompute",
                    m_pipelines[m_shaderIndex].writeRef()
                );
            }
        );
    }

public:
    ComPtr<IDevice> m_device;
    ComPtr<ISurface> m_surface;
    ComPtr<ICommandQueue> m_queue;
    std::unique_ptr<Blitter> m_blitter;
    std::vector<ComPtr<IComputePipeline>> m_pipelines;
    ComPtr<ITexture> m_texture;

    std::future<Result> m_future;

    float m_stickyMousePos[2] = {0.0f, 0.0f};
    bool m_combinedMouseDown = false;
    bool m_combinedMouseClicked = false;

    double m_time = 0.0;
    double m_timeDelta = 0.0;
    double m_frameRate = 0.0;
    uint32_t m_frame = 0;

    int m_shaderIndex = 0;

    // Shader hot reload.
    static constexpr double kWatchInterval = 0.15; // seconds between checks
    struct WatchedShader
    {
        std::filesystem::file_time_type known{};
        std::filesystem::file_time_type pending{};
        bool hasPending = false;
    };
    std::vector<WatchedShader> m_watched;
    double m_lastWatchTime = 0.0;
    uint32_t m_reloadSerial = 0;
};

EXAMPLE_MAIN(ExampleShaderToy)
