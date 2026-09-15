#pragma once

#include "utils.h"
#include "steam-controller.h"
#include "steam-keyboard.h"

#include <slang.h>
#include <slang-rhi.h>

#if SLANG_WINDOWS_FAMILY
#define GLFW_EXPOSE_NATIVE_WIN32
#elif SLANG_LINUX_FAMILY
#define GLFW_EXPOSE_NATIVE_X11
#elif SLANG_APPLE_FAMILY
#define GLFW_EXPOSE_NATIVE_COCOA
#endif
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#include <slang-rhi/glfw.h>

#include <string>
#include <vector>
#include <algorithm>

namespace rhi {

// Base class for examples.
// Derive from this class to implement an example.
class ExampleBase
{
public:
    virtual ~ExampleBase();

    // Called to initialize the example for the specified device type.
    virtual Result init(DeviceType deviceType) = 0;
    // Called to shut down the example.
    virtual void shutdown() = 0;
    // Called every frame to update the example.
    virtual Result update(double time) = 0;
    // Called every frame to render the example.
    virtual Result draw() = 0;

    // Event callbacks

    // Called when the window is resized.
    virtual void onResize(int width, int height, int framebufferWidth, int framebufferHeight) {}
    // Called when the mouse is moved.
    virtual void onMousePosition(float x, float y) {}
    // Called when a mouse button is pressed or released.
    virtual void onMouseButton(int button, int action, int mods) {}
    // Called when the mouse wheel is scrolled.
    virtual void onScroll(float x, float y) {}
    // Called when a key is pressed, released, or repeated.
    virtual void onKey(int key, int scancode, int action, int mods) {}
    // Called when a Steam Controller is connected to or disconnected from a slot.
    virtual void onControllerConnect(int slot, bool connected) {}
    // Called when a Steam Controller button is pressed or released.
    // `button` is one of SteamControllerButtons.
    virtual void onControllerButton(int slot, uint32_t button, bool pressed) {}

    // Accessors for Steam Controller state

    // Returns the state of the given controller slot.
    // Slots without a controller report a default (disconnected, all-zero) state.
    const SteamControllerState& getControllerState(int slot = 0) const
    {
        static const SteamControllerState kEmptyState;
        return (slot >= 0 && slot < kMaxSteamControllers) ? m_controllerStates[slot] : kEmptyState;
    }

    // Returns the state of the lowest slot with a connected controller, or a default
    // (disconnected, all-zero) state if no controller is connected.
    const SteamControllerState& getPrimaryControllerState() const
    {
        return getControllerState(m_primaryController);
    }

    // Returns the lowest slot with a connected controller, or -1 if there is none.
    int getPrimaryController() const { return m_primaryController; }

    // Returns true if the given controller slot has a connected controller.
    bool isControllerConnected(int slot = 0) const { return getControllerState(slot).connected; }

    // Returns true if the specified button (one of SteamControllerButtons) is currently
    // down on the given controller slot.
    bool isControllerButtonDown(uint32_t button, int slot = 0) const
    {
        return getControllerState(slot).button(button);
    }

    // Accessors for mouse state

    // Returns true if the specified mouse button is currently down.
    bool isMouseDown(int button) const
    {
        return (button >= 0 && button < SLANG_COUNT_OF(m_mouseDown)) ? m_mouseDown[button] : false;
    }

    // Returns the current mouse X position.
    float getMouseX() const { return m_mousePos[0]; }
    // Returns the current mouse Y position.
    float getMouseY() const { return m_mousePos[1]; }

    // Window management

    // Creates a window with the specified title and size.
    // Automatically appends device and adapter information to the title.
    Result createWindow(IDevice* device, const char* title, uint32_t width = 640, uint32_t height = 360);
    // Destroys the window.
    void destroyWindow();

    // Creates a surface for the window with the specified format.
    // Use Format::Undefined to use the preferred format.
    Result createSurface(IDevice* device, Format format, ISurface** outSurface);

public:
    GLFWwindow* m_window = nullptr;

    float m_mousePos[2] = {0.0f, 0.0f};
    bool m_mouseDown[3] = {false, false, false};

    // Escape gives the pointer back; see dispatchPendingKeyEvents() and
    // updateCursorModes(). m_cursorHidden tracks what has actually been applied, so
    // the mode is only set when it changes.
    bool m_cursorReleased = false;
    bool m_cursorHidden = false;

    // F11 fullscreen toggle: the windowed placement to put back, and which mode the
    // window is in now.
    int m_windowedRect[4] = {0, 0, 0, 0}; // x, y, width, height
    bool m_fullscreen = false;

    SteamControllerState m_controllerStates[kMaxSteamControllers];
    int m_primaryController = -1;
};

namespace detail {
static void glfwWindowPosCallback(GLFWwindow* window, int xpos, int ypos);
static void glfwWindowSizeCallback(GLFWwindow* window, int width, int height);
static void glfwWindowIconifyCallback(GLFWwindow* window, int iconified);
static void glfwWindowMaximizeCallback(GLFWwindow* window, int maximized);
static void glfwFramebufferSizeCallback(GLFWwindow* window, int width, int height);
static void glfwCursorPosCallback(GLFWwindow* window, double xpos, double ypos);
static void glfwMouseButtonCallback(GLFWwindow* window, int button, int action, int mods);
static void glfwScrollCallback(GLFWwindow* window, double xoffset, double yoffset);
static void glfwKeyCallback(GLFWwindow* window, int key, int scancode, int action, int mods);
static void glfwWindowCloseCallback(GLFWwindow* window);

static std::vector<ExampleBase*>& getExamples()
{
    static std::vector<ExampleBase*> examples;
    return examples;
}

static ExampleBase* mainExample = nullptr;

} // namespace detail


ExampleBase::~ExampleBase()
{
    destroyWindow();
}

Result ExampleBase::createWindow(IDevice* device, const char* title, uint32_t width, uint32_t height)
{
    const auto& deviceInfo = device->getInfo();
    char fullTitle[1024];
    snprintf(
        fullTitle,
        sizeof(fullTitle),
        "%s | %s (%s)",
        title,
        getRHI()->getDeviceTypeName(deviceInfo.deviceType),
        deviceInfo.adapterName
    );

    bool isMainExample = (this == detail::mainExample);
    glfwWindowHint(GLFW_RESIZABLE, isMainExample ? GLFW_TRUE : GLFW_FALSE);

    m_window = glfwCreateWindow(width, height, fullTitle, nullptr, nullptr);
    if (!m_window)
    {
        return SLANG_FAIL;
    }
    glfwSetWindowUserPointer(m_window, this);
    glfwSetWindowPosCallback(m_window, detail::glfwWindowPosCallback);
    glfwSetWindowSizeCallback(m_window, detail::glfwWindowSizeCallback);
    glfwSetWindowIconifyCallback(m_window, detail::glfwWindowIconifyCallback);
    glfwSetWindowMaximizeCallback(m_window, detail::glfwWindowMaximizeCallback);
    glfwSetFramebufferSizeCallback(m_window, detail::glfwFramebufferSizeCallback);
    glfwSetCursorPosCallback(m_window, detail::glfwCursorPosCallback);
    glfwSetMouseButtonCallback(m_window, detail::glfwMouseButtonCallback);
    glfwSetScrollCallback(m_window, detail::glfwScrollCallback);
    glfwSetKeyCallback(m_window, detail::glfwKeyCallback);
    glfwSetWindowCloseCallback(m_window, detail::glfwWindowCloseCallback);

    return SLANG_OK;
}

void ExampleBase::destroyWindow()
{
    if (m_window)
    {
        glfwDestroyWindow(m_window);
        m_window = nullptr;
    }
}

Result ExampleBase::createSurface(IDevice* device, Format format, ISurface** outSurface)
{
    ASSERT(m_window, "Window must be created before creating surface");

    int width, height;
    glfwGetFramebufferSize(m_window, &width, &height);

    SLANG_RETURN_ON_FAIL(device->createSurface(getWindowHandleFromGLFW(m_window), outSurface));
    SurfaceConfig surfaceConfig;
    surfaceConfig.width = width;
    surfaceConfig.height = height;
    surfaceConfig.format = format;
    SLANG_RETURN_ON_FAIL((*outSurface)->configure(surfaceConfig));

    return SLANG_OK;
}

namespace detail {

static bool layoutInProgress = false;

static void layoutWindows()
{
    if (getExamples().size() <= 1)
    {
        return;
    }

    static const int kMargin = 100;

    int wx, wy, ww, wh;
    GLFWmonitor* monitor = glfwGetPrimaryMonitor();
    glfwGetMonitorWorkarea(monitor, &wx, &wy, &ww, &wh);

    int frameLeft, frameTop, frameRight, frameBottom;
    glfwGetWindowFrameSize(mainExample->m_window, &frameLeft, &frameTop, &frameRight, &frameBottom);

    layoutInProgress = true;

    int x = wx + kMargin;
    int y = wy + kMargin;

    for (ExampleBase* example : getExamples())
    {
        int width, height;
        glfwGetWindowSize(example->m_window, &width, &height);
        width += frameLeft + frameRight;
        height += frameTop + frameBottom;

        if (x + width >= ww)
        {
            x = wx + kMargin;
            y += height;
        }
        glfwSetWindowPos(example->m_window, x, y);
        x += width;
    }

    layoutInProgress = false;
}

static void glfwWindowPosCallback(GLFWwindow* window, int xpos, int ypos)
{
    if (layoutInProgress)
    {
        return;
    }
    ExampleBase* srcExample = (ExampleBase*)glfwGetWindowUserPointer(window);
    if (srcExample == mainExample)
    {
        layoutWindows();
    }
}

static void glfwWindowSizeCallback(GLFWwindow* window, int width, int height)
{
    if (layoutInProgress)
    {
        return;
    }
    ExampleBase* srcExample = (ExampleBase*)glfwGetWindowUserPointer(window);
    for (ExampleBase* example : getExamples())
    {
        if (example != srcExample)
        {
            glfwSetWindowSize(example->m_window, width, height);
        }
    }
    if (srcExample == mainExample)
    {
        layoutWindows();
    }
}

static void glfwWindowIconifyCallback(GLFWwindow* window, int iconified)
{
    ExampleBase* srcExample = (ExampleBase*)glfwGetWindowUserPointer(window);
    for (ExampleBase* example : getExamples())
    {
        if (example != srcExample)
        {
            if (iconified)
            {
                glfwIconifyWindow(example->m_window);
            }
            else
            {
                glfwRestoreWindow(example->m_window);
            }
        }
    }
}

static void glfwWindowMaximizeCallback(GLFWwindow* window, int maximized)
{
    ExampleBase* srcExample = (ExampleBase*)glfwGetWindowUserPointer(window);
    for (ExampleBase* example : getExamples())
    {
        if (example != srcExample)
        {
            if (maximized)
            {
                glfwMaximizeWindow(example->m_window);
            }
            else
            {
                glfwRestoreWindow(example->m_window);
            }
        }
    }
}

static void glfwFramebufferSizeCallback(GLFWwindow* window, int width, int height)
{
    int windowWidth, windowHeight;
    glfwGetWindowSize(window, &windowWidth, &windowHeight);
    int framebufferWidth, framebufferHeight;
    glfwGetFramebufferSize(window, &framebufferWidth, &framebufferHeight);
    ExampleBase* example = (ExampleBase*)glfwGetWindowUserPointer(window);
    example->onResize(windowWidth, windowHeight, framebufferWidth, framebufferHeight);
}

static void glfwCursorPosCallback(GLFWwindow* window, double xpos, double ypos)
{
    for (ExampleBase* example : getExamples())
    {
        example->m_mousePos[0] = xpos;
        example->m_mousePos[1] = ypos;
        example->onMousePosition(xpos, ypos);
    }
}

static void glfwMouseButtonCallback(GLFWwindow* window, int button, int action, int mods)
{
    for (ExampleBase* example : getExamples())
    {
        if (button < SLANG_COUNT_OF(example->m_mouseDown))
            example->m_mouseDown[button] = (action == GLFW_PRESS);
        // A click re-arms the hiding that Escape released. GLFW only reports buttons
        // over the content area -- the title bar and frame belong to the window
        // manager and never reach here -- so this is already "in the body". Matched
        // on `window` so a click only re-arms the example it landed in.
        if (action == GLFW_PRESS && example->m_window == window)
        {
            example->m_cursorReleased = false;
        }
        example->onMouseButton(button, action, mods);
    }
}

static void glfwScrollCallback(GLFWwindow* window, double xoffset, double yoffset)
{
    for (ExampleBase* example : getExamples())
    {
        example->onScroll(xoffset, yoffset);
    }
}

// A Steam Controller's desktop emulation (the puck firmware's "lizard mode", and Steam
// Input's desktop layout) types on the keyboard for us: the d-pad and left stick send
// arrow keys, which reach the window as ordinary key events that no API distinguishes
// from a real keypress. Controller input is only meant to be displayed by the examples,
// never to drive them, so key events are queued here and dispatched later, once the
// controller has been polled and its state can be used to recognize them.
struct PendingKeyEvent
{
    int key;
    int scancode;
    int action;
    int mods;
};

static std::vector<PendingKeyEvent>& getPendingKeyEvents()
{
    static std::vector<PendingKeyEvent> pendingKeyEvents;
    return pendingKeyEvents;
}

// Close requests are queued for the same reason as key events: whatever the desktop
// layout types for the Menu button (Alt+F4 reaches us as a close request, not as keys)
// arrives before the controller has been polled, so the decision to honor it has to
// wait until its state is at least as recent as the request.
static std::vector<GLFWwindow*>& getPendingCloseRequests()
{
    static std::vector<GLFWwindow*> pendingCloseRequests;
    return pendingCloseRequests;
}

static void glfwKeyCallback(GLFWwindow* window, int key, int scancode, int action, int mods)
{
    getPendingKeyEvents().push_back({key, scancode, action, mods});
}

static void glfwWindowCloseCallback(GLFWwindow* window)
{
    // GLFW has already raised the close flag by the time this runs, so take it back
    // down and re-raise it in dispatchPendingCloseRequests() if the request survives.
    glfwSetWindowShouldClose(window, GLFW_FALSE);
    getPendingCloseRequests().push_back(window);
}

// The Steam Controller session is shared by all example windows, the same way GLFW input
// callbacks are broadcast to all of them: HID input has no notion of window focus, so
// every example sees the same controller state.
static SteamKeyboardGuard& getSteamKeyboardGuard()
{
    static SteamKeyboardGuard guard;
    return guard;
}

static StartMenuGuard& getStartMenuGuard()
{
    static StartMenuGuard guard;
    return guard;
}

static CursorMotionGuard& getCursorMotionGuard()
{
    static CursorMotionGuard guard;
    return guard;
}

static SteamControllerSession& getSteamControllerSession()
{
    static SteamControllerSession session;
    return session;
}

// Steam's desktop layout hands us the keystroke or close request a beat after the
// button that produced it, so sampling "is it held right now" at the moment the request
// arrives is not enough: a quick tap, or one of two buttons pressed together, lands when
// the pad already reads as idle and the request goes through.
//
// So these buttons are recorded on their press edge -- the event stream reports presses
// that are over before the next poll, which the polled state alone would miss entirely --
// and stay accountable for a grace window afterwards.
static constexpr double kQuitButtonGrace = 0.5; // seconds

static bool isQuitButton(uint32_t button)
{
    return button == SteamControllerButtons::Menu || button == SteamControllerButtons::View ||
           button == SteamControllerButtons::B;
}

static double& getLastQuitButtonTime()
{
    static double lastQuitButtonTime = -1000.0;
    return lastQuitButtonTime;
}

static void pollSteamControllers()
{
    SteamControllerSession& session = getSteamControllerSession();
    session.update();

    for (const SteamControllerEvent& event : session.getEvents())
    {
        if (event.type == SteamControllerEvent::Type::ButtonDown && isQuitButton(event.button))
        {
            getLastQuitButtonTime() = glfwGetTime();
        }
    }

    for (ExampleBase* example : getExamples())
    {
        for (int slot = 0; slot < kMaxSteamControllers; ++slot)
        {
            example->m_controllerStates[slot] = session.getState(slot);
        }
        example->m_primaryController = session.getPrimarySlot();

        for (const SteamControllerEvent& event : session.getEvents())
        {
            switch (event.type)
            {
            case SteamControllerEvent::Type::Connected:
                example->onControllerConnect(event.slot, true);
                break;
            case SteamControllerEvent::Type::Disconnected:
                example->onControllerConnect(event.slot, false);
                break;
            case SteamControllerEvent::Type::ButtonDown:
                example->onControllerButton(event.slot, event.button, true);
                break;
            case SteamControllerEvent::Type::ButtonUp:
                example->onControllerButton(event.slot, event.button, false);
                break;
            }
        }
    }
}

// Returns true if a quit-suppressing button is accountable for whatever just arrived --
// held right now, or pressed within the last kQuitButtonGrace seconds. Whatever the
// desktop layout does with these buttons, closing the window is not something the
// examples want from them.
static bool isControllerQuitSuppressed()
{
    SteamControllerSession& session = getSteamControllerSession();
    int slot = session.getPrimarySlot();
    if (slot < 0)
    {
        return false;
    }
    // Still held counts too, for a press that outlasts the grace window.
    const SteamControllerState& state = session.getState(slot);
    if (state.button(SteamControllerButtons::Menu) || state.button(SteamControllerButtons::View) ||
        state.button(SteamControllerButtons::B))
    {
        return true;
    }
    return (glfwGetTime() - getLastQuitButtonTime()) < kQuitButtonGrace;
}

// Honors the close requests queued during glfwPollEvents(), dropping the ones a
// controller button is accountable for. Must run after pollSteamControllers(), for the
// same reason dispatchPendingKeyEvents() must.
static void dispatchPendingCloseRequests()
{
    std::vector<GLFWwindow*>& pendingCloseRequests = getPendingCloseRequests();
    for (GLFWwindow* window : pendingCloseRequests)
    {
        if (isControllerQuitSuppressed())
        {
            continue;
        }
        glfwSetWindowShouldClose(window, GLFW_TRUE);
    }
    pendingCloseRequests.clear();
}


// Returns true if the current controller state accounts for this key event, i.e. the
// controller's desktop emulation synthesized it rather than someone pressing the key.
// Only the keys that emulation is known to produce are recognized; a controller that
// is disconnected (or whose state doesn't match) never suppresses a key.
static bool isControllerEmulatedKey(int key)
{
    SteamControllerSession& session = getSteamControllerSession();
    int slot = session.getPrimarySlot();
    if (slot < 0)
    {
        return false;
    }
    const SteamControllerState& state = session.getState(slot);
    // Emulation starts typing well before the stick is at its limit.
    static const float kDeadzone = 0.25f;
    switch (key)
    {
    case GLFW_KEY_LEFT:
        return state.button(SteamControllerButtons::DPadLeft) || state.leftStick[0] < -kDeadzone;
    case GLFW_KEY_RIGHT:
        return state.button(SteamControllerButtons::DPadRight) || state.leftStick[0] > kDeadzone;
    case GLFW_KEY_UP:
        return state.button(SteamControllerButtons::DPadUp) || state.leftStick[1] > kDeadzone;
    case GLFW_KEY_DOWN:
        return state.button(SteamControllerButtons::DPadDown) || state.leftStick[1] < -kDeadzone;
    // The desktop layout types Escape for B, and for Menu/View depending on how it is
    // configured, which dispatchPendingKeyEvents() would otherwise read as "quit". A
    // keyboard Escape with none of them recently pressed still closes the window.
    case GLFW_KEY_ESCAPE:
        return isControllerQuitSuppressed();
    default:
        return false;
    }
}

// Switches a window between fullscreen on the primary monitor and the placement it had
// before, remembering that placement on the way in.
//
// Fullscreen here is the "borderless at the monitor's current video mode" kind: the mode
// passed to glfwSetWindowMonitor() is the one already in use, so nothing changes
// resolution. Like the code this replaces, it always uses the primary monitor rather
// than the one the window happens to be sitting on -- GLFW has no call for the latter,
// it takes comparing the window's rect against every monitor's.
//
// This resizes the window, which fires the framebuffer callback and reconfigures the
// surface, so it must not run before the surface exists.
static void toggleFullscreen(ExampleBase* example)
{
    if (!example->m_window)
    {
        return;
    }
    if (example->m_fullscreen)
    {
        glfwSetWindowMonitor(
            example->m_window,
            nullptr,
            example->m_windowedRect[0],
            example->m_windowedRect[1],
            example->m_windowedRect[2],
            example->m_windowedRect[3],
            GLFW_DONT_CARE
        );
        example->m_fullscreen = false;
    }
    else
    {
        glfwGetWindowPos(example->m_window, &example->m_windowedRect[0], &example->m_windowedRect[1]);
        glfwGetWindowSize(example->m_window, &example->m_windowedRect[2], &example->m_windowedRect[3]);
        GLFWmonitor* monitor = glfwGetPrimaryMonitor();
        const GLFWvidmode* mode = monitor ? glfwGetVideoMode(monitor) : nullptr;
        if (!mode)
        {
            return;
        }
        glfwSetWindowMonitor(
            example->m_window,
            monitor,
            0,
            0,
            mode->width,
            mode->height,
            mode->refreshRate
        );
        example->m_fullscreen = true;
    }
}

// Delivers the key events queued during glfwPollEvents(), skipping the ones the
// controller typed. Must run after pollSteamControllers(), so that events are checked
// against controller state that is at least as recent as the events themselves.
static void dispatchPendingKeyEvents()
{
    std::vector<PendingKeyEvent>& pendingKeyEvents = getPendingKeyEvents();
    for (const PendingKeyEvent& event : pendingKeyEvents)
    {
        if (isControllerEmulatedKey(event.key))
        {
            continue;
        }
        for (ExampleBase* example : getExamples())
        {
            example->onKey(event.key, event.scancode, event.action, event.mods);
            if (event.key == GLFW_KEY_ESCAPE && event.action == GLFW_PRESS)
            {
                // The first Escape hands the pointer back, the second one quits, so
                // there's still a way out that doesn't need the mouse. A B press on a
                // Steam controller never gets this far -- isControllerEmulatedKey()
                // has already dropped the Escape its desktop layout types.
                if (!example->m_cursorReleased)
                {
                    example->m_cursorReleased = true;
                }
                else
                {
                    glfwSetWindowShouldClose(example->m_window, GLFW_TRUE);
                }
            }
            if (event.key == GLFW_KEY_F11 && event.action == GLFW_PRESS)
            {
                toggleFullscreen(example);
            }
        }
    }
    pendingKeyEvents.clear();
}

// Hides the pointer while a window has focus, so it doesn't sit over what the example
// is drawing, and shows it again once Escape has released it or focus has gone
// elsewhere.
//
// GLFW_CURSOR_HIDDEN, not GLFW_CURSOR_DISABLED: disabled would also grab the pointer
// and switch it to unbounded virtual motion, which would wreck the window-relative
// coordinates examples read through getMouseX()/getMouseY().
// Arms the desktop suppressions only while an example window has focus -- so a Steam
// keyboard opened over any other application is left alone, and the Windows key works
// normally everywhere else -- and puts focus back on the window that lost it when a
// keyboard is hidden.
static void updateSteamDesktopGuards()
{
    // Remembered across frames: once the keyboard has taken focus, nothing of ours is
    // focused any more, so "the window to restore" has to be the last one that was.
    static ExampleBase* lastFocused = nullptr;

    ExampleBase* focused = nullptr;
    for (ExampleBase* example : getExamples())
    {
        if (example->m_window && glfwGetWindowAttrib(example->m_window, GLFW_FOCUSED))
        {
            focused = example;
            break;
        }
    }
    if (focused)
    {
        lastFocused = focused;
    }

    SteamKeyboardGuard& guard = getSteamKeyboardGuard();
    guard.setArmed(focused != nullptr);
    getStartMenuGuard().setArmed(focused != nullptr);
    getCursorMotionGuard().setArmed(focused != nullptr);
    if (guard.takeFocusRequest() && lastFocused && lastFocused->m_window)
    {
        glfwFocusWindow(lastFocused->m_window);
    }
}

static void updateCursorModes()
{
    for (ExampleBase* example : getExamples())
    {
        if (!example->m_window)
        {
            continue;
        }
        bool focused = glfwGetWindowAttrib(example->m_window, GLFW_FOCUSED) != 0;
        bool hide = focused && !example->m_cursorReleased;
        if (hide != example->m_cursorHidden)
        {
            glfwSetInputMode(
                example->m_window,
                GLFW_CURSOR,
                hide ? GLFW_CURSOR_HIDDEN : GLFW_CURSOR_NORMAL
            );
            example->m_cursorHidden = hide;
        }
    }
}

template<typename Example>
static int main(int argc, const char** argv)
{
    glfwInit();
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);

    std::vector<DeviceType> deviceTypes = {
        DeviceType::D3D11,
        DeviceType::D3D12,
        DeviceType::Vulkan,
        DeviceType::Metal,
        DeviceType::CPU,
        DeviceType::CUDA,
        // Exclude for now as WGPU backend is not fully functional
        // DeviceType::WGPU,
    };

    std::vector<ExampleBase*>& examples = getExamples();

    // Create an example for each supported device type
    for (DeviceType deviceType : deviceTypes)
    {
        if (rhi::getRHI()->isDeviceTypeSupported(deviceType))
        {
            Example* example = new Example();
            ExampleBase* prevMainExample = mainExample;
            if (!mainExample)
            {
                mainExample = example;
            }
            if (SLANG_FAILED(example->init(deviceType)))
            {
                mainExample = prevMainExample;
                delete example;
                continue;
            }
            examples.push_back(example);
        }
    }

    layoutWindows();

    getSteamKeyboardGuard().install();
    getStartMenuGuard().install();
    getCursorMotionGuard().install();

    if (examples.size() > 0)
    {
        while (true)
        {
            bool shouldClose = false;
            for (ExampleBase* example : examples)
            {
                if (glfwWindowShouldClose(example->m_window))
                {
                    shouldClose = true;
                    break;
                }
            }
            if (shouldClose)
            {
                break;
            }

            glfwPollEvents();
            pollSteamControllers();
            dispatchPendingKeyEvents();
            dispatchPendingCloseRequests();
            updateSteamDesktopGuards();
            updateCursorModes();

            double time = glfwGetTime();

            for (ExampleBase* example : examples)
            {
                // TODO: handle errors
                example->update(time);
                example->draw();
            }
        }

        for (ExampleBase* example : examples)
        {
            example->shutdown();
            delete example;
        }
    }

    getSteamKeyboardGuard().uninstall();
    getStartMenuGuard().uninstall();
    getCursorMotionGuard().uninstall();
    glfwTerminate();

    return 0;
}

} // namespace detail

} // namespace rhi

#define EXAMPLE_MAIN(Example)                                                                                          \
    int main(int argc, const char** argv)                                                                              \
    {                                                                                                                  \
        return rhi::detail::main<Example>(argc, argv);                                                                 \
    }
