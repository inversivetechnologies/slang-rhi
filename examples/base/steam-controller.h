#pragma once

// Steam Controller 2 ("puck" wireless dongle) input support for the examples.
//
// The report IDs, input report layout and button bits are taken from the `sc2`
// header-only library, which implements the community reverse-engineered puck
// protocol (cross-checked there against SDL's hidapi/steam driver and Linux's
// mainline hid-steam.c). Only the input path is implemented here (no haptics,
// no feature commands) since that is all the examples need.
//
// Unlike `sc2` this does not depend on hidapi: a small read-only HID backend is
// implemented inline (Win32 SetupAPI/HID on Windows, hidraw on Linux) so the
// examples don't gain an external dependency. Other platforms compile to a stub
// that never reports a controller.

#include <slang.h>
#include <slang-rhi.h>
#include <slang-rhi/shader-cursor.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#if SLANG_WINDOWS_FAMILY
#define SLANG_RHI_HAS_STEAM_CONTROLLER 1
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <hidsdi.h>
#include <setupapi.h>
#elif SLANG_LINUX_FAMILY
#define SLANG_RHI_HAS_STEAM_CONTROLLER 1
#include <dirent.h>
#include <fcntl.h>
#include <linux/hidraw.h>
#include <sys/ioctl.h>
#include <unistd.h>
#else
#define SLANG_RHI_HAS_STEAM_CONTROLLER 0
#endif

namespace rhi {

// ---------------------------------------------------------------------------------------
// Device identification
// ---------------------------------------------------------------------------------------

// The puck dongle exposes up to 4 independent controller slots.
static constexpr int kMaxSteamControllers = 4;

static constexpr uint16_t kSteamControllerVendorId = 0x28DE;
// Legacy "Steam Controller" (2015) receiver PID, reported by a puck while Steam has it
// claimed in classic-driver compatibility mode.
static constexpr uint16_t kSteamControllerProductIdLegacy = 0x1142;
// Native SC2 ("Ibex" family) PIDs: IBEX, IBEX_BLE, PROTEUS, NEREID.
static constexpr uint16_t kSteamControllerProductIdsNative[] = {0x1302, 0x1303, 0x1304, 0x1305};

// ---------------------------------------------------------------------------------------
// Button bits (as reported in `SteamControllerState::buttons`)
// ---------------------------------------------------------------------------------------

struct SteamControllerButtons
{
    enum : uint32_t
    {
        A = 0x00000001,
        B = 0x00000002,
        X = 0x00000004,
        Y = 0x00000008,
        QAM = 0x00000010, // Quick Access Menu
        R3 = 0x00000020,
        View = 0x00000040,
        R4 = 0x00000080,
        R5 = 0x00000100,
        RB = 0x00000200,
        DPadDown = 0x00000400,
        DPadRight = 0x00000800,
        DPadLeft = 0x00001000,
        DPadUp = 0x00002000,
        Menu = 0x00004000,
        L3 = 0x00008000,
        Steam = 0x00010000,
        L4 = 0x00020000,
        L5 = 0x00040000,
        LB = 0x00080000,
        RightStickTouch = 0x00100000,
        RightPadTouch = 0x00200000,
        RightPadClick = 0x00400000,
        RightTriggerClick = 0x00800000,
        LeftStickTouch = 0x01000000,
        LeftPadTouch = 0x02000000,
        LeftPadClick = 0x04000000,
        LeftTriggerClick = 0x08000000,
        RightGripTouch = 0x10000000,
        LeftGripTouch = 0x20000000,
    };
};

// Number of defined button bits (bit 0 .. bit kSteamControllerButtonCount-1).
static constexpr uint32_t kSteamControllerButtonCount = 30;

// ---------------------------------------------------------------------------------------
// Controller state
// ---------------------------------------------------------------------------------------

// Full state of one controller slot, with all axes normalized for direct use in shaders.
struct SteamControllerState
{
    // True while the slot has a controller linked and sending input.
    bool connected = false;

    // Bitfield of SteamControllerButtons (includes the pad/stick/grip touch and
    // pad/trigger click bits).
    uint32_t buttons = 0;

    float leftStick[2] = {0.0f, 0.0f};  // [-1,1]
    float rightStick[2] = {0.0f, 0.0f}; // [-1,1]

    float leftTrigger = 0.0f;  // [0,1]
    float rightTrigger = 0.0f; // [0,1]

    float leftPad[3] = {0.0f, 0.0f, 0.0f};  // x, y in [-1,1], pressure in [0,1]
    float rightPad[3] = {0.0f, 0.0f, 0.0f}; // x, y in [-1,1], pressure in [0,1]

    // IMU, normalized to [-1,1] over the sensor's full 16-bit range (the device's
    // physical scale factors are not documented upstream).
    float accel[3] = {0.0f, 0.0f, 0.0f};
    float gyro[3] = {0.0f, 0.0f, 0.0f};
    // Orientation quaternion (w,x,y,z). Only sent by "Ibex"-family firmware
    // (report 0x42); left as identity otherwise.
    float quat[4] = {1.0f, 0.0f, 0.0f, 0.0f};

    // Input report sequence counter, wrapping at 256.
    uint32_t sequence = 0;
    // Device IMU timestamp, in seconds (assumed microsecond ticks), wrapped to keep
    // float precision usable in shaders.
    float imuTime = 0.0f;

    // RF link strength in dBm (typically -30 .. -90), 0 if not reported yet.
    float rssi = 0.0f;

    bool button(uint32_t b) const { return (buttons & b) != 0; }
};

// ---------------------------------------------------------------------------------------
// Shader-facing layout
// ---------------------------------------------------------------------------------------

// Mirrors `struct ControllerState` in examples/shader-toy/shader-toy.slang. Laid out so
// that every member lands on a 16-byte boundary under standard constant buffer packing
// rules, which keeps the layout identical across backends.
struct SteamControllerShaderData
{
    uint32_t buttons;  // SteamControllerButtons bitfield
    uint32_t flags;    // bit 0: connected
    float sequence;    // [0,1), input report counter wrapped to a ramp
    float rssi;        // link strength in dBm, 0 if unknown
    float sticks[4];   // left.xy, right.xy in [-1,1]
    float triggers[4]; // left, right in [0,1]; left click, right click as 0/1
    float leftPad[4];  // x, y in [-1,1], pressure in [0,1], touched as 0/1
    float rightPad[4]; // x, y in [-1,1], pressure in [0,1], touched as 0/1
    float accel[4];    // x, y, z in [-1,1], w: IMU timestamp in seconds
    float gyro[4];     // x, y, z in [-1,1], w: unused
    float quat[4];     // w, x, y, z orientation
};

inline SteamControllerShaderData getSteamControllerShaderData(const SteamControllerState& state)
{
    SteamControllerShaderData data = {};
    data.buttons = state.buttons;
    data.flags = state.connected ? 1u : 0u;
    data.sequence = float(state.sequence) / 256.0f;
    data.rssi = state.rssi;
    data.sticks[0] = state.leftStick[0];
    data.sticks[1] = state.leftStick[1];
    data.sticks[2] = state.rightStick[0];
    data.sticks[3] = state.rightStick[1];
    data.triggers[0] = state.leftTrigger;
    data.triggers[1] = state.rightTrigger;
    data.triggers[2] = state.button(SteamControllerButtons::LeftTriggerClick) ? 1.0f : 0.0f;
    data.triggers[3] = state.button(SteamControllerButtons::RightTriggerClick) ? 1.0f : 0.0f;
    data.leftPad[0] = state.leftPad[0];
    data.leftPad[1] = state.leftPad[1];
    data.leftPad[2] = state.leftPad[2];
    data.leftPad[3] = state.button(SteamControllerButtons::LeftPadTouch) ? 1.0f : 0.0f;
    data.rightPad[0] = state.rightPad[0];
    data.rightPad[1] = state.rightPad[1];
    data.rightPad[2] = state.rightPad[2];
    data.rightPad[3] = state.button(SteamControllerButtons::RightPadTouch) ? 1.0f : 0.0f;
    data.accel[0] = state.accel[0];
    data.accel[1] = state.accel[1];
    data.accel[2] = state.accel[2];
    data.accel[3] = state.imuTime;
    data.gyro[0] = state.gyro[0];
    data.gyro[1] = state.gyro[1];
    data.gyro[2] = state.gyro[2];
    data.gyro[3] = 0.0f;
    data.quat[0] = state.quat[0];
    data.quat[1] = state.quat[1];
    data.quat[2] = state.quat[2];
    data.quat[3] = state.quat[3];
    return data;
}

// Writes the controller state into a shader parameter of type `ControllerState`.
// Fields are written individually so this doesn't rely on the host struct and the
// shader struct having identical layout.
inline void bindSteamControllerState(const ShaderCursor& cursor, const SteamControllerState& state)
{
    // Shaders that don't declare the controller parameter are fine, just skip them.
    if (!cursor.isValid())
    {
        return;
    }
    SteamControllerShaderData data = getSteamControllerShaderData(state);
    auto setField = [&cursor](const char* name, const void* value, Size size)
    {
        ShaderCursor field = cursor[name];
        if (field.isValid())
        {
            field.setData(value, size);
        }
    };
    setField("buttons", &data.buttons, sizeof(data.buttons));
    setField("flags", &data.flags, sizeof(data.flags));
    setField("sequence", &data.sequence, sizeof(data.sequence));
    setField("rssi", &data.rssi, sizeof(data.rssi));
    setField("sticks", data.sticks, sizeof(data.sticks));
    setField("triggers", data.triggers, sizeof(data.triggers));
    setField("leftPad", data.leftPad, sizeof(data.leftPad));
    setField("rightPad", data.rightPad, sizeof(data.rightPad));
    setField("accel", data.accel, sizeof(data.accel));
    setField("gyro", data.gyro, sizeof(data.gyro));
    setField("quat", data.quat, sizeof(data.quat));
}

// ---------------------------------------------------------------------------------------
// Report parsing
// ---------------------------------------------------------------------------------------

namespace detail {

enum SteamControllerReportId : uint8_t
{
    kReportInputControllerV2 = 0x42, // primary gamepad state, "Ibex" firmware, 54 bytes
    kReportInputController = 0x45,   // primary gamepad state, legacy firmware, 46 bytes
    kReportConnectionEdge = 0x79,    // edge-triggered connect/disconnect
    kReportConnectionStatus = 0x7B,  // periodic (~2s) link status, incl. RSSI
};

inline uint16_t readU16LE(const uint8_t* p)
{
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}

inline int16_t readS16LE(const uint8_t* p)
{
    return int16_t(readU16LE(p));
}

inline uint32_t readU32LE(const uint8_t* p)
{
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

// Sticks/pads/IMU are signed 16-bit; normalize to [-1,1].
inline float normalizeAxis(int16_t v)
{
    return v < 0 ? float(v) / 32768.0f : float(v) / 32767.0f;
}

// Triggers are unsigned 16-bit; normalize to [0,1]. The controller may not use the
// full range, so clamp defensively.
inline float normalizeTrigger(uint16_t v)
{
    return std::min(float(v) / 32767.0f, 1.0f);
}

// Pad pressure is signed on the wire; the meaning of the sign isn't confirmed upstream,
// so fold it away and normalize the magnitude to [0,1].
inline float normalizePressure(int16_t v)
{
    return std::min(float(v < 0 ? -v : v) / 32767.0f, 1.0f);
}

// Decodes input report 0x45 (46 bytes, legacy firmware) or 0x42 (54 bytes, "Ibex"
// firmware) into `state`. Both share the same layout through the IMU fields; 0x42
// additionally carries an orientation quaternion at the end.
inline bool parseSteamControllerInputReport(const uint8_t* buf, size_t len, SteamControllerState& state)
{
    bool isV2 = buf[0] == kReportInputControllerV2;
    if (!isV2 && buf[0] != kReportInputController)
    {
        return false;
    }
    if (len < (isV2 ? 54u : 46u))
    {
        return false;
    }

    state.sequence = buf[0x01];
    state.buttons = readU32LE(buf + 0x02);
    state.leftTrigger = normalizeTrigger(readU16LE(buf + 0x06));
    state.rightTrigger = normalizeTrigger(readU16LE(buf + 0x08));
    state.leftStick[0] = normalizeAxis(readS16LE(buf + 0x0A));
    state.leftStick[1] = normalizeAxis(readS16LE(buf + 0x0C));
    state.rightStick[0] = normalizeAxis(readS16LE(buf + 0x0E));
    state.rightStick[1] = normalizeAxis(readS16LE(buf + 0x10));
    state.leftPad[0] = normalizeAxis(readS16LE(buf + 0x12));
    state.leftPad[1] = normalizeAxis(readS16LE(buf + 0x14));
    state.leftPad[2] = normalizePressure(readS16LE(buf + 0x16));
    state.rightPad[0] = normalizeAxis(readS16LE(buf + 0x18));
    state.rightPad[1] = normalizeAxis(readS16LE(buf + 0x1A));
    state.rightPad[2] = normalizePressure(readS16LE(buf + 0x1C));
    // Assumed to be microsecond ticks; wrapped so the value stays float-friendly.
    state.imuTime = float(std::fmod(double(readU32LE(buf + 0x1E)) * 1e-6, 1024.0));
    state.accel[0] = normalizeAxis(readS16LE(buf + 0x22));
    state.accel[1] = normalizeAxis(readS16LE(buf + 0x24));
    state.accel[2] = normalizeAxis(readS16LE(buf + 0x26));
    state.gyro[0] = normalizeAxis(readS16LE(buf + 0x28));
    state.gyro[1] = normalizeAxis(readS16LE(buf + 0x2A));
    state.gyro[2] = normalizeAxis(readS16LE(buf + 0x2C));
    if (isV2)
    {
        state.quat[0] = normalizeAxis(readS16LE(buf + 0x2E));
        state.quat[1] = normalizeAxis(readS16LE(buf + 0x30));
        state.quat[2] = normalizeAxis(readS16LE(buf + 0x32));
        state.quat[3] = normalizeAxis(readS16LE(buf + 0x34));
    }
    return true;
}

// ---------------------------------------------------------------------------------------
// Minimal read-only HID backend
// ---------------------------------------------------------------------------------------

struct HidDeviceInfo
{
    std::string path;
    // USB interface number, used to order the dongle's slots. -1 if unknown.
    int interfaceNumber = -1;
    // Size of one input report, 0 if unknown.
    uint32_t inputReportLength = 0;
};

inline bool isSteamControllerProductId(uint16_t productId)
{
    if (productId == kSteamControllerProductIdLegacy)
    {
        return true;
    }
    for (uint16_t pid : kSteamControllerProductIdsNative)
    {
        if (productId == pid)
        {
            return true;
        }
    }
    return false;
}

#if SLANG_WINDOWS_FAMILY

// Each slot's interface path carries its USB interface number as "&mi_XX".
inline int parseInterfaceNumber(const std::string& path)
{
    static const char* kTag = "mi_";
    for (size_t i = 0; i + 4 < path.size(); ++i)
    {
        if (tolower(path[i]) != kTag[0] || tolower(path[i + 1]) != kTag[1] || path[i + 2] != kTag[2])
        {
            continue;
        }
        int value = 0;
        for (size_t j = i + 3; j < i + 5; ++j)
        {
            char c = path[j];
            int digit = (c >= '0' && c <= '9') ? (c - '0') : (tolower(c) >= 'a' && tolower(c) <= 'f' ? tolower(c) - 'a' + 10 : -1);
            if (digit < 0)
            {
                return -1;
            }
            value = value * 16 + digit;
        }
        return value;
    }
    return -1;
}

inline std::vector<HidDeviceInfo> hidEnumerateSteamControllers()
{
    std::vector<HidDeviceInfo> result;

    GUID hidGuid;
    HidD_GetHidGuid(&hidGuid);
    HDEVINFO devInfoSet = SetupDiGetClassDevsA(&hidGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfoSet == INVALID_HANDLE_VALUE)
    {
        return result;
    }

    SP_DEVICE_INTERFACE_DATA interfaceData = {};
    interfaceData.cbSize = sizeof(interfaceData);
    for (DWORD index = 0; SetupDiEnumDeviceInterfaces(devInfoSet, nullptr, &hidGuid, index, &interfaceData); ++index)
    {
        DWORD requiredSize = 0;
        SetupDiGetDeviceInterfaceDetailA(devInfoSet, &interfaceData, nullptr, 0, &requiredSize, nullptr);
        if (requiredSize == 0)
        {
            continue;
        }
        std::vector<uint8_t> storage(requiredSize);
        auto* interfaceDetail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_A*>(storage.data());
        interfaceDetail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_A);
        if (!SetupDiGetDeviceInterfaceDetailA(devInfoSet, &interfaceData, interfaceDetail, requiredSize, nullptr, nullptr))
        {
            continue;
        }

        // Requesting no access is enough to query attributes, and still succeeds when
        // another process (e.g. Steam) holds the device open.
        HANDLE handle = CreateFileA(
            interfaceDetail->DevicePath,
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            0,
            nullptr
        );
        if (handle == INVALID_HANDLE_VALUE)
        {
            continue;
        }

        HIDD_ATTRIBUTES attributes = {};
        attributes.Size = sizeof(attributes);
        bool matches = HidD_GetAttributes(handle, &attributes) && attributes.VendorID == kSteamControllerVendorId &&
                       isSteamControllerProductId(attributes.ProductID);

        USAGE usagePage = 0;
        USAGE usage = 0;
        uint32_t inputReportLength = 0;
        if (matches)
        {
            PHIDP_PREPARSED_DATA preparsedData = nullptr;
            if (HidD_GetPreparsedData(handle, &preparsedData))
            {
                HIDP_CAPS caps = {};
                if (HidP_GetCaps(preparsedData, &caps) == HIDP_STATUS_SUCCESS)
                {
                    usagePage = caps.UsagePage;
                    usage = caps.Usage;
                    inputReportLength = caps.InputReportByteLength;
                }
                HidD_FreePreparsedData(preparsedData);
            }
        }
        CloseHandle(handle);

        // Each slot's interface also exposes decoy mouse/keyboard collections for OS
        // compatibility; only the vendor-defined collection (usage page 0xFF00, usage
        // 0x0001) carries controller reports. Usage 0x0002 on the same page is the
        // dongle's shared control interface, not a per-slot device.
        if (!matches || usagePage != 0xFF00 || usage != 0x0001)
        {
            continue;
        }

        HidDeviceInfo info;
        info.path = interfaceDetail->DevicePath;
        info.interfaceNumber = parseInterfaceNumber(info.path);
        info.inputReportLength = inputReportLength;
        result.push_back(std::move(info));
    }

    SetupDiDestroyDeviceInfoList(devInfoSet);

    std::sort(
        result.begin(),
        result.end(),
        [](const HidDeviceInfo& a, const HidDeviceInfo& b)
        {
            return a.interfaceNumber != b.interfaceNumber ? a.interfaceNumber < b.interfaceNumber : a.path < b.path;
        }
    );
    return result;
}

// Non-blocking reader for a single HID interface.
class HidDevice
{
public:
    HidDevice() = default;
    HidDevice(const HidDevice&) = delete;
    HidDevice& operator=(const HidDevice&) = delete;
    ~HidDevice() { close(); }

    bool open(const HidDeviceInfo& info)
    {
        m_handle = CreateFileA(
            info.path.c_str(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED,
            nullptr
        );
        if (m_handle == INVALID_HANDLE_VALUE)
        {
            return false;
        }
        m_event = CreateEventA(nullptr, TRUE, FALSE, nullptr);
        if (!m_event)
        {
            close();
            return false;
        }
        memset(&m_overlapped, 0, sizeof(m_overlapped));
        m_overlapped.hEvent = m_event;
        m_readLength = info.inputReportLength > 0 && info.inputReportLength <= sizeof(m_buffer)
                           ? info.inputReportLength
                           : uint32_t(sizeof(m_buffer));
        return true;
    }

    bool isOpen() const { return m_handle != INVALID_HANDLE_VALUE; }

    void close()
    {
        if (m_handle != INVALID_HANDLE_VALUE)
        {
            if (m_readPending)
            {
                CancelIo(m_handle);
            }
            CloseHandle(m_handle);
            m_handle = INVALID_HANDLE_VALUE;
        }
        if (m_event)
        {
            CloseHandle(m_event);
            m_event = nullptr;
        }
        m_readPending = false;
    }

    // Returns the number of bytes read, 0 if no report is pending, or -1 if the
    // device went away.
    int read(uint8_t* buffer, size_t size)
    {
        if (!isOpen())
        {
            return -1;
        }
        if (!m_readPending)
        {
            ResetEvent(m_event);
            DWORD bytesRead = 0;
            if (!ReadFile(m_handle, m_buffer, m_readLength, &bytesRead, &m_overlapped) &&
                GetLastError() != ERROR_IO_PENDING)
            {
                return -1;
            }
            m_readPending = true;
        }
        if (WaitForSingleObject(m_event, 0) != WAIT_OBJECT_0)
        {
            return 0;
        }
        DWORD bytesRead = 0;
        BOOL success = GetOverlappedResult(m_handle, &m_overlapped, &bytesRead, FALSE);
        m_readPending = false;
        if (!success)
        {
            return -1;
        }
        size_t count = std::min(size, size_t(bytesRead));
        memcpy(buffer, m_buffer, count);
        return int(count);
    }

private:
    HANDLE m_handle = INVALID_HANDLE_VALUE;
    HANDLE m_event = nullptr;
    OVERLAPPED m_overlapped = {};
    bool m_readPending = false;
    uint32_t m_readLength = 0;
    uint8_t m_buffer[256] = {};
};

#elif SLANG_LINUX_FAMILY

// On Linux each USB interface is a single hidraw node (the decoy mouse/keyboard
// collections share it), so unlike on Windows no usage filtering is needed or
// possible without parsing the report descriptor. Reports from the decoy
// collections simply don't match the input report IDs we look for.
inline std::vector<HidDeviceInfo> hidEnumerateSteamControllers()
{
    std::vector<HidDeviceInfo> result;

    DIR* dir = opendir("/dev");
    if (!dir)
    {
        return result;
    }
    while (dirent* entry = readdir(dir))
    {
        if (strncmp(entry->d_name, "hidraw", 6) != 0)
        {
            continue;
        }
        std::string path = std::string("/dev/") + entry->d_name;
        int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK);
        if (fd < 0)
        {
            continue;
        }
        hidraw_devinfo devInfo = {};
        bool matches = ioctl(fd, HIDIOCGRAWINFO, &devInfo) >= 0 &&
                       uint16_t(devInfo.vendor) == kSteamControllerVendorId &&
                       isSteamControllerProductId(uint16_t(devInfo.product));
        ::close(fd);
        if (!matches)
        {
            continue;
        }
        HidDeviceInfo info;
        info.path = std::move(path);
        // "hidrawN": order slots by N so they stay stable across rescans.
        info.interfaceNumber = atoi(entry->d_name + 6);
        result.push_back(std::move(info));
    }
    closedir(dir);

    std::sort(
        result.begin(),
        result.end(),
        [](const HidDeviceInfo& a, const HidDeviceInfo& b) { return a.interfaceNumber < b.interfaceNumber; }
    );
    return result;
}

class HidDevice
{
public:
    HidDevice() = default;
    HidDevice(const HidDevice&) = delete;
    HidDevice& operator=(const HidDevice&) = delete;
    ~HidDevice() { close(); }

    bool open(const HidDeviceInfo& info)
    {
        m_fd = ::open(info.path.c_str(), O_RDONLY | O_NONBLOCK);
        return m_fd >= 0;
    }

    bool isOpen() const { return m_fd >= 0; }

    void close()
    {
        if (m_fd >= 0)
        {
            ::close(m_fd);
            m_fd = -1;
        }
    }

    int read(uint8_t* buffer, size_t size)
    {
        if (!isOpen())
        {
            return -1;
        }
        ssize_t bytesRead = ::read(m_fd, buffer, size);
        if (bytesRead < 0)
        {
            return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1;
        }
        return int(bytesRead);
    }

private:
    int m_fd = -1;
};

#else

inline std::vector<HidDeviceInfo> hidEnumerateSteamControllers()
{
    return {};
}

class HidDevice
{
public:
    HidDevice() = default;
    HidDevice(const HidDevice&) = delete;
    HidDevice& operator=(const HidDevice&) = delete;

    bool open(const HidDeviceInfo& info) { return false; }
    bool isOpen() const { return false; }
    void close() {}
    int read(uint8_t* buffer, size_t size) { return -1; }
};

#endif

} // namespace detail

// ---------------------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------------------

// Events produced by SteamControllerSession::update().
struct SteamControllerEvent
{
    enum class Type
    {
        Connected,
        Disconnected,
        ButtonDown,
        ButtonUp,
    };

    Type type;
    int slot;
    // One of SteamControllerButtons, for ButtonDown/ButtonUp.
    uint32_t button = 0;
};

// Polls all controller slots of all attached puck dongles.
//
// Slots are opened lazily: update() rescans once a second so a dongle (or a controller
// waking up) can be plugged in while an example is already running, and drops slots
// whose device disappears.
class SteamControllerSession
{
public:
    // Polls all slots for new input. Call once per frame.
    void update()
    {
        m_events.clear();

        auto now = std::chrono::steady_clock::now();
        if (now - m_lastScanTime >= std::chrono::seconds(1))
        {
            scan();
            m_lastScanTime = now;
        }

        for (size_t i = 0; i < m_slots.size();)
        {
            Slot& slot = *m_slots[i];
            bool alive = true;
            uint32_t previousButtons = slot.state.buttons;

            // A linked controller streams far faster than the frame rate, so drain the
            // queue instead of consuming a single (potentially stale) report per frame.
            for (int n = 0; n < 64; ++n)
            {
                uint8_t buffer[128];
                int bytesRead = slot.device->read(buffer, sizeof(buffer));
                if (bytesRead < 0)
                {
                    alive = false;
                    break;
                }
                if (bytesRead == 0)
                {
                    break;
                }
                handleReport(slot, buffer, size_t(bytesRead), now);
            }

            if (!alive)
            {
                if (slot.state.connected)
                {
                    m_events.push_back({SteamControllerEvent::Type::Disconnected, slot.index, 0});
                }
                m_states[slot.index] = SteamControllerState();
                m_slots.erase(m_slots.begin() + i);
                continue;
            }

            // The dongle keeps its slot interface around when the controller powers off
            // or drops out of range, and doesn't always emit a disconnect edge for it.
            if (slot.state.connected && now - slot.lastInputTime >= std::chrono::seconds(2))
            {
                slot.state = SteamControllerState();
                previousButtons = 0;
                m_events.push_back({SteamControllerEvent::Type::Disconnected, slot.index, 0});
            }

            emitButtonEvents(slot.index, previousButtons, slot.state.buttons);
            m_states[slot.index] = slot.state;
            ++i;
        }
    }

    // Returns the state of the given slot. Slots without a controller report a default
    // (disconnected, all-zero) state, so shaders and examples can read them unconditionally.
    const SteamControllerState& getState(int slot) const
    {
        static const SteamControllerState kEmptyState;
        return (slot >= 0 && slot < kMaxSteamControllers) ? m_states[slot] : kEmptyState;
    }

    // Returns the lowest slot with a connected controller, or -1 if there is none.
    int getPrimarySlot() const
    {
        for (int slot = 0; slot < kMaxSteamControllers; ++slot)
        {
            if (m_states[slot].connected)
            {
                return slot;
            }
        }
        return -1;
    }

    // Events that occurred during the last update().
    const std::vector<SteamControllerEvent>& getEvents() const { return m_events; }

private:
    struct Slot
    {
        std::unique_ptr<detail::HidDevice> device;
        std::string path;
        int index = -1;
        SteamControllerState state;
        std::chrono::steady_clock::time_point lastInputTime;
    };

    void scan()
    {
        std::vector<detail::HidDeviceInfo> devices = detail::hidEnumerateSteamControllers();
        for (const detail::HidDeviceInfo& info : devices)
        {
            if (m_slots.size() >= size_t(kMaxSteamControllers))
            {
                break;
            }
            bool alreadyOpen = false;
            for (const auto& slot : m_slots)
            {
                alreadyOpen |= slot->path == info.path;
            }
            if (alreadyOpen)
            {
                continue;
            }
            auto device = std::make_unique<detail::HidDevice>();
            if (!device->open(info))
            {
                continue;
            }
            auto slot = std::make_unique<Slot>();
            slot->device = std::move(device);
            slot->path = info.path;
            slot->index = findFreeSlotIndex();
            slot->lastInputTime = std::chrono::steady_clock::now();
            m_slots.push_back(std::move(slot));
        }
    }

    int findFreeSlotIndex() const
    {
        for (int index = 0; index < kMaxSteamControllers; ++index)
        {
            bool used = false;
            for (const auto& slot : m_slots)
            {
                used |= slot->index == index;
            }
            if (!used)
            {
                return index;
            }
        }
        return kMaxSteamControllers - 1;
    }

    void handleReport(Slot& slot, const uint8_t* buffer, size_t size, std::chrono::steady_clock::time_point now)
    {
        switch (buffer[0])
        {
        case detail::kReportInputController:
        case detail::kReportInputControllerV2:
            if (detail::parseSteamControllerInputReport(buffer, size, slot.state))
            {
                slot.lastInputTime = now;
                if (!slot.state.connected)
                {
                    slot.state.connected = true;
                    m_events.push_back({SteamControllerEvent::Type::Connected, slot.index, 0});
                }
            }
            break;
        case detail::kReportConnectionEdge:
            // 0x02 = connected, anything else = disconnected.
            if (size >= 2 && buffer[1] != 0x02 && slot.state.connected)
            {
                float rssi = slot.state.rssi;
                slot.state = SteamControllerState();
                slot.state.rssi = rssi;
                m_events.push_back({SteamControllerEvent::Type::Disconnected, slot.index, 0});
            }
            break;
        case detail::kReportConnectionStatus:
            // Byte 8 of the 12-byte payload is the link RSSI in signed dBm.
            if (size >= 13)
            {
                slot.state.rssi = float(int8_t(buffer[9]));
            }
            break;
        default:
            break;
        }
    }

    void emitButtonEvents(int slot, uint32_t previousButtons, uint32_t buttons)
    {
        uint32_t changed = previousButtons ^ buttons;
        while (changed)
        {
            uint32_t button = changed & (~changed + 1); // lowest set bit
            changed &= ~button;
            m_events.push_back(
                {(buttons & button) ? SteamControllerEvent::Type::ButtonDown : SteamControllerEvent::Type::ButtonUp,
                 slot,
                 button}
            );
        }
    }

    std::vector<std::unique_ptr<Slot>> m_slots;
    SteamControllerState m_states[kMaxSteamControllers];
    std::vector<SteamControllerEvent> m_events;
    std::chrono::steady_clock::time_point m_lastScanTime = {};
};

} // namespace rhi
