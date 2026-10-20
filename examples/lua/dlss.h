#pragma once

// NVIDIA DLSS Super Resolution for the Lua host, through NVIDIA's NGX SDK on Vulkan
// (external/dlss: NVIDIA's DLSS SDK, under its own license, fetched separately -- see
// examples/lua/README.md). Built only when the SDK is there (SLANG_RHI_LUA_DLSS).
//
// NGX needs instance and device extensions of its own, so a device that may run DLSS is
// made with them (requiredExtensions). DLSS then runs in a submission of its own to the
// device's graphics queue (Context::evaluate), between what the host submitted before and
// what it submits after: its inputs must be in the states DLSS reads them in (the color,
// depth and motion as shader resources, the output as unordered access).

#include <slang-rhi.h>

#include <memory>
#include <string>
#include <vector>

namespace dlss {

// The Vulkan instance and device extensions NGX needs, for a device on `adapter`: none but
// on NVIDIA's GPUs (DLSS runs on their RTX ones).
void requiredExtensions(const rhi::AdapterInfo& adapter, std::vector<const char*>& instance, std::vector<const char*>& device);

// The quality modes, as the settings name them: how much smaller the image is drawn.
enum class Quality
{
    Quality,          // 1.5 x
    Balanced,         // 1.7 x
    Performance,      // 2 x
    UltraPerformance, // 3 x
};

struct Inputs
{
    rhi::ITexture* color = nullptr;  // the drawn image (linear, about 0..1), rgba16f
    rhi::ITexture* depth = nullptr;  // its depth, z/w (near 0, far 1), r32f
    rhi::ITexture* motion = nullptr; // in pixels, from where each pixel is to where it was: xy of rgba16f or rg32f
    rhi::ITexture* output = nullptr; // the window's size, rgba16f, unordered access
    float jitter[2] = {0.0f, 0.0f};  // the camera's offset this frame, drawn pixels
    bool reset = false;              // a cut: nothing of the frames before
    Quality quality = Quality::Quality;
};

// DLSS on one device. Made once per device; nothing of it outlives the device.
class Context
{
public:
    // DLSS on `device` (drawing with `queue`); null if it can't run there (not an NVIDIA RTX
    // GPU, no NGX runtime, an old driver) -- `why` says.
    static std::unique_ptr<Context> create(rhi::IDevice* device, rhi::ICommandQueue* queue, std::string& why);
    ~Context();

    // Upscales `in.color` into `in.output`, submitted to the queue after what is there. On
    // failure, false and `error`.
    bool evaluate(const Inputs& in, std::string& error);

    struct State;

private:
    explicit Context(std::unique_ptr<State> state);
    std::unique_ptr<State> m_state;
};

} // namespace dlss
