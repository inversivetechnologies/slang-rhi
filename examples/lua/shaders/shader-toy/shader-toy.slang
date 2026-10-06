typealias vec2 = float2;
typealias vec3 = float3;
typealias vec4 = float4;

typealias mat2 = float2x2;
typealias mat3 = float3x3;
typealias mat4 = float4x4;

#define mix lerp

uniform vec3      iResolution;           // viewport resolution (in pixels)
uniform float     iTime;                 // shader playback time (in seconds)
uniform float     iTimeDelta;            // render time (in seconds)
uniform float     iFrameRate;            // shader frame rate
uniform int       iFrame;                // shader playback frame
// uniform float     iChannelTime[4];       // channel playback time (in seconds)
// uniform vec3      iChannelResolution[4]; // channel resolution (in pixels)
uniform vec4      iMouse;                // mouse pixel coords. xy: current (if MLB down), zw: click
// uniform samplerXX iChannel0..3;          // input channel. XX = 2D/Cube
// uniform vec4      iDate;                 // (year, month, day, time in seconds)
// uniform float     iSampleRate;           // sound sample rate (i.e., 44100)

// Steam Controller 2 state of the primary (lowest connected) controller slot.
// Mirrors SteamControllerShaderData in examples/base/steam-controller.h; see that file
// for how the state is read off the device.
struct ControllerState
{
    uint   buttons;   // button bitfield, see the Btn_* constants below
    uint   flags;     // bit 0: a controller is connected
    float  sequence;  // [0,1), input report counter wrapped to a ramp
    float  rssi;      // RF link strength in dBm (typically -30..-90), 0 if unknown
    vec4   sticks;    // left stick xy, right stick xy, each in [-1,1]
    vec4   triggers;  // left/right analog trigger in [0,1], left/right trigger click as 0/1
    vec4   leftPad;   // trackpad x,y in [-1,1], pressure in [0,1], touched as 0/1
    vec4   rightPad;  // trackpad x,y in [-1,1], pressure in [0,1], touched as 0/1
    vec4   accel;     // accelerometer xyz in [-1,1], w: device IMU time in seconds
    vec4   gyro;      // gyroscope xyz in [-1,1], w: unused
    vec4   quat;      // orientation quaternion w,x,y,z (identity on legacy firmware)

    bool connected() { return (flags & 1u) != 0u; }
    bool button(uint b) { return (buttons & b) != 0u; }
};

uniform ControllerState iController;

static const uint Btn_A                 = 0x00000001u;
static const uint Btn_B                 = 0x00000002u;
static const uint Btn_X                 = 0x00000004u;
static const uint Btn_Y                 = 0x00000008u;
static const uint Btn_QAM               = 0x00000010u;
static const uint Btn_R3                = 0x00000020u;
static const uint Btn_View              = 0x00000040u;
static const uint Btn_R4                = 0x00000080u;
static const uint Btn_R5                = 0x00000100u;
static const uint Btn_RB                = 0x00000200u;
static const uint Btn_DPadDown          = 0x00000400u;
static const uint Btn_DPadRight         = 0x00000800u;
static const uint Btn_DPadLeft          = 0x00001000u;
static const uint Btn_DPadUp            = 0x00002000u;
static const uint Btn_Menu              = 0x00004000u;
static const uint Btn_L3                = 0x00008000u;
static const uint Btn_Steam             = 0x00010000u;
static const uint Btn_L4                = 0x00020000u;
static const uint Btn_L5                = 0x00040000u;
static const uint Btn_LB                = 0x00080000u;
static const uint Btn_RightStickTouch   = 0x00100000u;
static const uint Btn_RightPadTouch     = 0x00200000u;
static const uint Btn_RightPadClick     = 0x00400000u;
static const uint Btn_RightTriggerClick = 0x00800000u;
static const uint Btn_LeftStickTouch    = 0x01000000u;
static const uint Btn_LeftPadTouch      = 0x02000000u;
static const uint Btn_LeftPadClick      = 0x04000000u;
static const uint Btn_LeftTriggerClick  = 0x08000000u;
static const uint Btn_RightGripTouch    = 0x10000000u;
static const uint Btn_LeftGripTouch     = 0x20000000u;

void mainImage(out vec4 fragColor, in vec2 fragCoord);

[shader("compute")]
[numthreads(16, 16, 1)]
void mainCompute(uint3 tid: SV_DispatchThreadID, uniform RWTexture2D<float4> texture)
{
    if (any(tid.xy >= uint2(iResolution.xy)))
        return;

    float4 fragColor;
    mainImage(fragColor, tid.xy);
    texture[uint2(tid.x, uint(iResolution.y) - tid.y - 1)] = fragColor;
}
