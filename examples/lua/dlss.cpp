// NVIDIA DLSS Super Resolution for the Lua host: see dlss.h.

#include "dlss.h"

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <vulkan/vulkan.h>

#include <nvsdk_ngx_vk.h>
#include <nvsdk_ngx_helpers_vk.h>

#include <cstdio>
#include <cstring>

namespace dlss {

using namespace rhi;

static constexpr uint32_t kNvidiaVendorId = 0x10DE;
// NGX wants a GUID-like project ID from an app with no NVIDIA application ID.
static const char* kProjectId = "6f1d3c2a-9b47-4e58-a1d6-2c7e8f90b3a4";

void requiredExtensions(const AdapterInfo& adapter, std::vector<const char*>& instance, std::vector<const char*>& device)
{
    if (adapter.vendorID != kNvidiaVendorId)
        return;
    unsigned int instanceCount = 0, deviceCount = 0;
    const char** instanceExtensions = nullptr;
    const char** deviceExtensions = nullptr;
    if (NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_RequiredExtensions(&instanceCount, &instanceExtensions, &deviceCount, &deviceExtensions)))
        return;
    for (unsigned int i = 0; i < instanceCount; ++i)
        instance.push_back(instanceExtensions[i]);
    for (unsigned int i = 0; i < deviceCount; ++i)
    {
        // slang-rhi enables buffer device addresses as Vulkan 1.2 has them, which may not be
        // enabled along with the EXT extension NGX also lists.
        if (strcmp(deviceExtensions[i], "VK_EXT_buffer_device_address") == 0)
            continue;
        device.push_back(deviceExtensions[i]);
    }
}

struct Context::State
{
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    PFN_vkGetInstanceProcAddr getInstanceProcAddr = nullptr;
    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
    PFN_vkCreateCommandPool createCommandPool = nullptr;
    PFN_vkDestroyCommandPool destroyCommandPool = nullptr;
    PFN_vkAllocateCommandBuffers allocateCommandBuffers = nullptr;
    PFN_vkResetCommandBuffer resetCommandBuffer = nullptr;
    PFN_vkBeginCommandBuffer beginCommandBuffer = nullptr;
    PFN_vkEndCommandBuffer endCommandBuffer = nullptr;
    PFN_vkCmdPipelineBarrier cmdPipelineBarrier = nullptr;
    PFN_vkQueueSubmit queueSubmit = nullptr;
    PFN_vkCreateFence createFence = nullptr;
    PFN_vkDestroyFence destroyFence = nullptr;
    PFN_vkWaitForFences waitForFences = nullptr;
    PFN_vkResetFences resetFences = nullptr;
    PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;

    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    bool submitted = false; // the command buffer is in flight (its fence not waited on yet)

    bool ngxInitialized = false;
    NVSDK_NGX_Parameter* parameters = nullptr;
    NVSDK_NGX_Handle* feature = nullptr;
    // What the feature was made for (made again when any changes).
    uint32_t renderWidth = 0, renderHeight = 0, outputWidth = 0, outputHeight = 0;
    Quality quality = Quality::Quality;

    ~State()
    {
        if (device && deviceWaitIdle)
            deviceWaitIdle(device);
        if (feature)
            NVSDK_NGX_VULKAN_ReleaseFeature(feature);
        if (parameters)
            NVSDK_NGX_VULKAN_DestroyParameters(parameters);
        if (ngxInitialized)
            NVSDK_NGX_VULKAN_Shutdown1(device);
        if (fence)
            destroyFence(device, fence, nullptr);
        if (pool)
            destroyCommandPool(device, pool, nullptr);
    }
};

Context::Context(std::unique_ptr<State> state)
    : m_state(std::move(state))
{
}

Context::~Context() = default;

static VkFormat vkFormatOf(Format format)
{
    switch (format)
    {
    case Format::RGBA16Float:
        return VK_FORMAT_R16G16B16A16_SFLOAT;
    case Format::RGBA32Float:
        return VK_FORMAT_R32G32B32A32_SFLOAT;
    case Format::RG32Float:
        return VK_FORMAT_R32G32_SFLOAT;
    case Format::R32Float:
        return VK_FORMAT_R32_SFLOAT;
    case Format::R16Float:
        return VK_FORMAT_R16_SFLOAT;
    default:
        return VK_FORMAT_UNDEFINED;
    }
}

static NVSDK_NGX_PerfQuality_Value perfQualityOf(Quality quality)
{
    switch (quality)
    {
    case Quality::Balanced:
        return NVSDK_NGX_PerfQuality_Value_Balanced;
    case Quality::Performance:
        return NVSDK_NGX_PerfQuality_Value_MaxPerf;
    case Quality::UltraPerformance:
        return NVSDK_NGX_PerfQuality_Value_UltraPerformance;
    default:
        return NVSDK_NGX_PerfQuality_Value_MaxQuality;
    }
}

std::unique_ptr<Context> Context::create(IDevice* device, ICommandQueue* queue, std::string& why)
{
    if (device->getInfo().deviceType != DeviceType::Vulkan)
    {
        why = "DLSS runs on Vulkan here";
        return nullptr;
    }
    auto state = std::make_unique<State>();
    DeviceNativeHandles handles = {};
    NativeHandle queueHandle = {};
    if (SLANG_FAILED(device->getNativeDeviceHandles(&handles)) || SLANG_FAILED(queue->getNativeHandle(&queueHandle)))
    {
        why = "no native Vulkan handles";
        return nullptr;
    }
    state->instance = (VkInstance)handles.handles[0].value;
    state->physicalDevice = (VkPhysicalDevice)handles.handles[1].value;
    state->device = (VkDevice)handles.handles[2].value;
    state->queue = (VkQueue)queueHandle.value;

#if defined(_WIN32)
    HMODULE vulkan = GetModuleHandleA("vulkan-1.dll");
    if (vulkan)
        state->getInstanceProcAddr = (PFN_vkGetInstanceProcAddr)GetProcAddress(vulkan, "vkGetInstanceProcAddr");
#endif
    if (!state->getInstanceProcAddr)
    {
        why = "no Vulkan loader";
        return nullptr;
    }
    auto gipa = state->getInstanceProcAddr;
    state->getDeviceProcAddr = (PFN_vkGetDeviceProcAddr)gipa(state->instance, "vkGetDeviceProcAddr");
    auto getQueueFamilies = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)gipa(state->instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    auto gdpa = state->getDeviceProcAddr;
#define LOAD(member, name) state->member = (PFN_##name)gdpa(state->device, #name)
    LOAD(createCommandPool, vkCreateCommandPool);
    LOAD(destroyCommandPool, vkDestroyCommandPool);
    LOAD(allocateCommandBuffers, vkAllocateCommandBuffers);
    LOAD(resetCommandBuffer, vkResetCommandBuffer);
    LOAD(beginCommandBuffer, vkBeginCommandBuffer);
    LOAD(endCommandBuffer, vkEndCommandBuffer);
    LOAD(cmdPipelineBarrier, vkCmdPipelineBarrier);
    LOAD(queueSubmit, vkQueueSubmit);
    LOAD(createFence, vkCreateFence);
    LOAD(destroyFence, vkDestroyFence);
    LOAD(waitForFences, vkWaitForFences);
    LOAD(resetFences, vkResetFences);
    LOAD(deviceWaitIdle, vkDeviceWaitIdle);
#undef LOAD

    // The queue's family: the first that draws and computes, as slang-rhi picks it.
    uint32_t familyCount = 0;
    getQueueFamilies(state->physicalDevice, &familyCount, nullptr);
    std::vector<VkQueueFamilyProperties> families(familyCount);
    getQueueFamilies(state->physicalDevice, &familyCount, families.data());
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < familyCount && family == UINT32_MAX; ++i)
    {
        VkQueueFlags wanted = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
        if ((families[i].queueFlags & wanted) == wanted)
            family = i;
    }
    VkCommandPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolInfo.queueFamilyIndex = family;
    VkCommandBufferAllocateInfo allocateInfo = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocateInfo.commandBufferCount = 1;
    VkFenceCreateInfo fenceInfo = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (family == UINT32_MAX || state->createCommandPool(state->device, &poolInfo, nullptr, &state->pool) != VK_SUCCESS ||
        (allocateInfo.commandPool = state->pool,
         state->allocateCommandBuffers(state->device, &allocateInfo, &state->commandBuffer) != VK_SUCCESS) ||
        state->createFence(state->device, &fenceInfo, nullptr, &state->fence) != VK_SUCCESS)
    {
        why = "no command buffer for DLSS";
        return nullptr;
    }

    NVSDK_NGX_Result result = NVSDK_NGX_VULKAN_Init_with_ProjectID(
        kProjectId,
        NVSDK_NGX_ENGINE_TYPE_CUSTOM,
        "1.0",
        L".",
        state->instance,
        state->physicalDevice,
        state->device,
        gipa,
        gdpa
    );
    if (NVSDK_NGX_FAILED(result))
    {
        why = "NGX didn't start (not an NVIDIA RTX GPU, or no NGX runtime)";
        return nullptr;
    }
    state->ngxInitialized = true;
    if (NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_GetCapabilityParameters(&state->parameters)))
    {
        why = "NGX has no capability parameters";
        return nullptr;
    }
    int needsDriver = 0, available = 0;
    NVSDK_NGX_Parameter_GetI(state->parameters, NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver, &needsDriver);
    NVSDK_NGX_Parameter_GetI(state->parameters, NVSDK_NGX_Parameter_SuperSampling_Available, &available);
    if (needsDriver)
    {
        why = "DLSS needs a newer NVIDIA driver";
        return nullptr;
    }
    if (!available)
    {
        why = "DLSS isn't available on this GPU (or nvngx_dlss.dll is missing)";
        return nullptr;
    }
    return std::unique_ptr<Context>(new Context(std::move(state)));
}

static NVSDK_NGX_Resource_VK resourceOf(ITexture* texture, bool readWrite)
{
    const TextureDesc& desc = texture->getDesc();
    NativeHandle image = {}, view = {};
    texture->getNativeHandle(&image);
    texture->getDefaultView()->getNativeHandle(&view);
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return NVSDK_NGX_Create_ImageView_Resource_VK(
        (VkImageView)view.value,
        (VkImage)image.value,
        range,
        vkFormatOf(desc.format),
        desc.size.width,
        desc.size.height,
        readWrite
    );
}

// Everything before (and after) made visible to everything after: DLSS's submission sits
// between the host's, on the same queue, with nothing else ordering their memory.
static void fullBarrier(Context::State& s)
{
    VkMemoryBarrier barrier = {VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    s.cmdPipelineBarrier(
        s.commandBuffer,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        1,
        &barrier,
        0,
        nullptr,
        0,
        nullptr
    );
}

bool Context::evaluate(const Inputs& in, std::string& error)
{
    State& s = *m_state;
    if (s.submitted)
    {
        s.waitForFences(s.device, 1, &s.fence, VK_TRUE, UINT64_MAX);
        s.resetFences(s.device, 1, &s.fence);
        s.submitted = false;
    }
    const TextureDesc& colorDesc = in.color->getDesc();
    const TextureDesc& outputDesc = in.output->getDesc();
    s.resetCommandBuffer(s.commandBuffer, 0);
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    s.beginCommandBuffer(s.commandBuffer, &begin);
    fullBarrier(s);

    bool reset = in.reset;
    if (!s.feature || s.renderWidth != colorDesc.size.width || s.renderHeight != colorDesc.size.height ||
        s.outputWidth != outputDesc.size.width || s.outputHeight != outputDesc.size.height || s.quality != in.quality)
    {
        if (s.feature)
        {
            s.deviceWaitIdle(s.device);
            NVSDK_NGX_VULKAN_ReleaseFeature(s.feature);
            s.feature = nullptr;
        }
        NVSDK_NGX_DLSS_Create_Params create = {};
        create.Feature.InWidth = colorDesc.size.width;
        create.Feature.InHeight = colorDesc.size.height;
        create.Feature.InTargetWidth = outputDesc.size.width;
        create.Feature.InTargetHeight = outputDesc.size.height;
        create.Feature.InPerfQualityValue = perfQualityOf(in.quality);
        // Motion vectors at the drawn size, not jittered; the image's exposure worked out.
        create.InFeatureCreateFlags = NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
        NVSDK_NGX_Result result = NGX_VULKAN_CREATE_DLSS_EXT1(s.device, s.commandBuffer, 1, 1, &s.feature, s.parameters, &create);
        if (NVSDK_NGX_FAILED(result))
        {
            s.endCommandBuffer(s.commandBuffer);
            error = "DLSS couldn't be made for this size";
            s.feature = nullptr;
            return false;
        }
        s.renderWidth = colorDesc.size.width;
        s.renderHeight = colorDesc.size.height;
        s.outputWidth = outputDesc.size.width;
        s.outputHeight = outputDesc.size.height;
        s.quality = in.quality;
        reset = true;
        // The feature made (its own resources set up) in a submission of its own, done
        // before it first runs.
        s.endCommandBuffer(s.commandBuffer);
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &s.commandBuffer;
        if (s.queueSubmit(s.queue, 1, &submit, s.fence) != VK_SUCCESS)
        {
            error = "DLSS's creation couldn't be submitted";
            return false;
        }
        s.waitForFences(s.device, 1, &s.fence, VK_TRUE, UINT64_MAX);
        s.resetFences(s.device, 1, &s.fence);
        s.resetCommandBuffer(s.commandBuffer, 0);
        s.beginCommandBuffer(s.commandBuffer, &begin);
        fullBarrier(s);
    }

    NVSDK_NGX_Resource_VK color = resourceOf(in.color, false);
    NVSDK_NGX_Resource_VK depth = resourceOf(in.depth, false);
    NVSDK_NGX_Resource_VK motion = resourceOf(in.motion, false);
    NVSDK_NGX_Resource_VK output = resourceOf(in.output, true);
    NVSDK_NGX_VK_DLSS_Eval_Params eval = {};
    eval.Feature.pInColor = &color;
    eval.Feature.pInOutput = &output;
    eval.pInDepth = &depth;
    eval.pInMotionVectors = &motion;
    eval.InJitterOffsetX = in.jitter[0];
    eval.InJitterOffsetY = in.jitter[1];
    eval.InRenderSubrectDimensions = {colorDesc.size.width, colorDesc.size.height};
    eval.InReset = reset ? 1 : 0;
    eval.InMVScaleX = 1.0f; // already in pixels
    eval.InMVScaleY = 1.0f;
    NVSDK_NGX_Result result = NGX_VULKAN_EVALUATE_DLSS_EXT(s.commandBuffer, s.feature, s.parameters, &eval);
    fullBarrier(s);
    s.endCommandBuffer(s.commandBuffer);
    if (NVSDK_NGX_FAILED(result))
    {
        error = "DLSS couldn't run";
        return false;
    }
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &s.commandBuffer;
    if (s.queueSubmit(s.queue, 1, &submit, s.fence) != VK_SUCCESS)
    {
        error = "DLSS's submission failed";
        return false;
    }
    s.submitted = true;
    return true;
}

} // namespace dlss
