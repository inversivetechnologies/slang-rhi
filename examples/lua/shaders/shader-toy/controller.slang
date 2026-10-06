// A "test card" for the Steam Controller 2 support in examples/base/steam-controller.h.
// Every field of `iController` is visualized somewhere on screen:
//
//   - sticks      : the two dots in the rings (left/right)
//   - triggers    : the two vertical bars at the edges (fill = analog, red = click)
//   - leftPad     : the left rounded pad (dot = position, glow = pressure, ring = touch)
//   - rightPad    : likewise on the right
//   - buttons     : the D-pad and A/B/X/Y clusters, plus the 30-bit strip at the bottom
//   - accel       : tilt and offset of the horizon line, and (w) the shimmer along it
//   - gyro        : the spinning rotor around the orientation triad
//   - quat        : the orientation triad in the middle
//   - rssi        : the signal blocks in the top left corner
//   - flags       : the connection lamp next to them (screen dims when disconnected)
//   - sequence    : the packet activity dot in the top right corner

#include "shader-toy.slang"

static const float TAU = 6.28318530718;

// ---------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------

float sdCircle(vec2 p, float r)
{
    return length(p) - r;
}

float sdBox(vec2 p, vec2 b)
{
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdRoundBox(vec2 p, vec2 b, float r)
{
    return sdBox(p, b - r) - r;
}

float sdSegment(vec2 p, vec2 a, vec2 b)
{
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

// Antialiasing width: one pixel in the [-1,1] vertical space used below.
float pixel()
{
    return 2.0 / iResolution.y;
}

float fillMask(float d)
{
    return 1.0 - smoothstep(0.0, pixel() * 1.5, d);
}

float strokeMask(float d, float width)
{
    return fillMask(abs(d) - width);
}

vec3 palette(float t)
{
    return 0.5 + 0.5 * cos(TAU * (t + vec3(0.0, 0.33, 0.67)));
}

vec3 over(vec3 background, vec3 color, float mask)
{
    return mix(background, color, saturate(mask));
}

// Rotates `v` by the (w,x,y,z) quaternion `q`, falling back to identity if the device
// didn't report an orientation (legacy firmware leaves the quaternion zeroed).
vec3 rotateByQuat(vec4 q, vec3 v)
{
    if (length(q) < 1e-4)
    {
        return v;
    }
    q = normalize(q);
    vec3 axis = q.yzw;
    float w = q.x;
    return 2.0 * dot(axis, v) * axis + (w * w - dot(axis, axis)) * v + 2.0 * w * cross(axis, v);
}

// ---------------------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------------------

// A stick: ring, deadzone cross, and the stick position as a dot. The ring lights up while
// the stick is touched capacitively, and the dot grows while the stick is clicked in.
vec3 drawStick(vec3 col, vec2 p, vec2 center, vec2 value, bool touched, bool clicked, vec3 tint)
{
    vec2 q = p - center;
    float radius = 0.22;

    col = over(col, tint * 0.15, fillMask(sdCircle(q, radius)));
    col = over(col, tint * (touched ? 1.0 : 0.45), strokeMask(sdCircle(q, radius), pixel()));
    col = over(col, tint * 0.35, strokeMask(sdSegment(q, vec2(-0.03, 0.0), vec2(0.03, 0.0)), pixel()));
    col = over(col, tint * 0.35, strokeMask(sdSegment(q, vec2(0.0, -0.03), vec2(0.0, 0.03)), pixel()));

    vec2 tip = value * (radius - 0.04);
    col = over(col, tint * 0.6, strokeMask(sdSegment(q, vec2(0.0, 0.0), tip), pixel() * 0.75));
    col = over(col, clicked ? vec3(1.0) : tint, fillMask(sdCircle(q - tip, clicked ? 0.05 : 0.035)));
    return col;
}

// A trackpad: rounded outline, a pressure glow, and the touch position as a cross hair.
vec3 drawPad(vec3 col, vec2 p, vec2 center, vec4 pad, bool clicked, vec3 tint)
{
    vec2 q = p - center;
    vec2 half_ = vec2(0.22, 0.22);
    float pressure = pad.z;
    bool touched = pad.w > 0.5;

    float d = sdRoundBox(q, half_, 0.06);
    col = over(col, tint * (0.12 + 0.5 * pressure), fillMask(d));
    col = over(col, tint * (clicked ? 1.0 : 0.45), strokeMask(d, pixel() * (clicked ? 2.0 : 1.0)));

    if (touched)
    {
        vec2 tip = pad.xy * (half_ - 0.03);
        col = over(col, tint * 0.5, strokeMask(sdSegment(q, vec2(-half_.x, tip.y), vec2(half_.x, tip.y)), pixel()));
        col = over(col, tint * 0.5, strokeMask(sdSegment(q, vec2(tip.x, -half_.y), vec2(tip.x, half_.y)), pixel()));
        // The dot's size follows how hard the pad is being pressed.
        col = over(col, vec3(1.0), fillMask(sdCircle(q - tip, 0.02 + 0.05 * pressure)));
    }
    return col;
}

// An analog trigger as a vertical bar, filled from the bottom. Turns red once the trigger
// bottoms out and reports its click.
vec3 drawTrigger(vec3 col, vec2 p, vec2 center, float value, bool clicked)
{
    vec2 q = p - center;
    vec2 half_ = vec2(0.055, 0.6);

    float outline = sdRoundBox(q, half_, 0.03);
    col = over(col, vec3(0.08, 0.09, 0.12), fillMask(outline));

    float level = -half_.y + 2.0 * half_.y * value;
    vec2 fillCenter = vec2(0.0, (level - half_.y) * 0.5);
    vec2 fillHalf = vec2(half_.x, max((level + half_.y) * 0.5, 0.0));
    vec3 color = clicked ? vec3(1.0, 0.25, 0.2) : vec3(0.35, 0.8, 1.0);
    col = over(col, color, fillMask(sdRoundBox(q - fillCenter, fillHalf, 0.03)));
    col = over(col, vec3(0.45), strokeMask(outline, pixel()));
    return col;
}

// A single button cell, lit while pressed.
vec3 drawButton(vec3 col, vec2 p, vec2 center, float radius, uint button, vec3 tint)
{
    float d = sdCircle(p - center, radius);
    bool pressed = iController.button(button);
    col = over(col, pressed ? tint : tint * 0.18, fillMask(d));
    col = over(col, tint * (pressed ? 1.0 : 0.45), strokeMask(d, pixel()));
    return col;
}

vec3 drawDPadKey(vec3 col, vec2 p, vec2 center, uint button)
{
    float d = sdRoundBox(p - center, vec2(0.05, 0.05), 0.015);
    bool pressed = iController.button(button);
    vec3 tint = vec3(0.6, 0.75, 1.0);
    col = over(col, pressed ? tint : tint * 0.18, fillMask(d));
    col = over(col, tint * (pressed ? 1.0 : 0.45), strokeMask(d, pixel()));
    return col;
}

// Orientation triad driven by the IMU quaternion, with a rotor whose spokes are deflected
// by the raw gyro rates.
vec3 drawOrientation(vec3 col, vec2 p, vec2 center)
{
    vec2 q = p - center;
    float scale = 0.3;

    // Rotor: three spokes, each spun by one gyro axis.
    for (int i = 0; i < 3; ++i)
    {
        float rate = iController.gyro[i];
        float angle = TAU * (float(i) / 3.0 + 0.5 * rate + 0.05 * iTime);
        vec2 dir = vec2(cos(angle), sin(angle));
        float d = sdSegment(q, dir * scale * 1.15, dir * scale * (1.3 + 0.35 * abs(rate)));
        col = over(col, palette(float(i) / 3.0) * (0.3 + 0.7 * abs(rate)), strokeMask(d, pixel() * 1.5));
    }

    // Triad: the three body axes, rotated by the reported orientation and projected
    // orthographically. Axes pointing away from the viewer are drawn dimmer.
    vec3 axes[3] = {vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0)};
    for (int i = 0; i < 3; ++i)
    {
        vec3 dir = rotateByQuat(iController.quat, axes[i]);
        vec3 color = axes[i] * 0.85 + 0.15;
        float depth = 0.5 + 0.5 * dir.z;
        float d = sdSegment(q, vec2(0.0, 0.0), dir.xy * scale);
        col = over(col, color * (0.35 + 0.65 * depth), strokeMask(d, pixel() * 1.5));
        col = over(col, color, fillMask(sdCircle(q - dir.xy * scale, 0.02 + 0.015 * depth)));
    }
    col = over(col, vec3(0.8), fillMask(sdCircle(q, 0.012)));
    return col;
}

// Link quality as five blocks, plus a lamp showing whether a controller is connected.
vec3 drawLink(vec3 col, vec2 p, vec2 center)
{
    vec2 q = p - center;

    // -90 dBm (barely there) .. -40 dBm (right next to the dongle).
    float quality = saturate((iController.rssi + 90.0) / 50.0);
    for (int i = 0; i < 5; ++i)
    {
        float height = 0.02 + 0.018 * float(i);
        vec2 blockCenter = vec2(float(i) * 0.05, height - 0.05);
        bool lit = iController.connected() && quality * 5.0 > float(i);
        vec3 tint = mix(vec3(1.0, 0.5, 0.2), vec3(0.3, 1.0, 0.5), quality);
        col = over(col, lit ? tint : vec3(0.15), fillMask(sdBox(q - blockCenter, vec2(0.016, height))));
    }

    bool connected = iController.connected();
    // Unlinked: pulse the lamp so it's obvious nothing is arriving.
    float pulse = 0.5 + 0.5 * sin(iTime * 4.0);
    vec3 lampColor = connected ? vec3(0.3, 1.0, 0.5) : vec3(1.0, 0.25, 0.2) * (0.35 + 0.65 * pulse);
    col = over(col, lampColor, fillMask(sdCircle(q - vec2(-0.09, 0.0), 0.025)));
    return col;
}

// ---------------------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------------------

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 p = (fragCoord * 2.0 - iResolution.xy) / iResolution.y;
    float px = pixel();

    // Background: a grid that drifts with the accelerometer, tinted by the gyro.
    vec2 drift = iController.accel.xy * 0.25;
    vec2 cell = frac((p + drift) * 4.0) - 0.5;
    float grid = min(abs(cell.x), abs(cell.y));
    float spin = length(iController.gyro.xyz);
    vec3 col = vec3(0.03, 0.035, 0.05) + palette(0.6 + 0.2 * spin) * 0.02;
    col += vec3(0.05, 0.06, 0.09) * (1.0 - smoothstep(0.0, px * 2.0, grid));
    col *= 1.0 - 0.35 * length(p * vec2(0.35, 0.6));

    // Horizon: tilted by the accelerometer's x/y, raised or lowered by its z. The shimmer
    // travelling along it is driven by the device's own IMU clock, so it stalls the moment
    // reports stop arriving.
    {
        float tilt = iController.accel.x * 0.6;
        float height = iController.accel.y * 0.35 + iController.accel.z * 0.1;
        vec2 dir = normalize(vec2(1.0, tilt));
        float d = abs(dot(p - vec2(0.0, height), vec2(-dir.y, dir.x)));
        float shimmer = 0.5 + 0.5 * sin(dot(p, dir) * 12.0 - iController.accel.w * 6.0);
        col = over(col, vec3(0.25, 0.55, 0.8) * (0.4 + 0.6 * shimmer), fillMask(d - px * 1.2));
    }

    // Sticks and trackpads.
    col = drawStick(
        col,
        p,
        vec2(-0.75, 0.2),
        iController.sticks.xy,
        iController.button(Btn_LeftStickTouch),
        iController.button(Btn_L3),
        vec3(0.5, 0.85, 1.0)
    );
    col = drawStick(
        col,
        p,
        vec2(0.75, 0.2),
        iController.sticks.zw,
        iController.button(Btn_RightStickTouch),
        iController.button(Btn_R3),
        vec3(1.0, 0.75, 0.45)
    );
    col = drawPad(col, p, vec2(-0.75, -0.42), iController.leftPad, iController.button(Btn_LeftPadClick), vec3(0.5, 0.85, 1.0));
    col = drawPad(
        col,
        p,
        vec2(0.75, -0.42),
        iController.rightPad,
        iController.button(Btn_RightPadClick),
        vec3(1.0, 0.75, 0.45)
    );

    // Triggers, one at each edge.
    col = drawTrigger(col, p, vec2(-1.62, -0.1), iController.triggers.x, iController.triggers.z > 0.5);
    col = drawTrigger(col, p, vec2(1.62, -0.1), iController.triggers.y, iController.triggers.w > 0.5);

    // D-pad, face buttons and the remaining named buttons.
    vec2 dpad = vec2(-1.25, 0.6);
    col = drawDPadKey(col, p, dpad + vec2(0.0, 0.11), Btn_DPadUp);
    col = drawDPadKey(col, p, dpad + vec2(0.0, -0.11), Btn_DPadDown);
    col = drawDPadKey(col, p, dpad + vec2(-0.11, 0.0), Btn_DPadLeft);
    col = drawDPadKey(col, p, dpad + vec2(0.11, 0.0), Btn_DPadRight);

    vec2 face = vec2(1.25, 0.6);
    col = drawButton(col, p, face + vec2(0.0, 0.11), 0.05, Btn_Y, vec3(1.0, 0.9, 0.35));
    col = drawButton(col, p, face + vec2(0.0, -0.11), 0.05, Btn_A, vec3(0.4, 1.0, 0.5));
    col = drawButton(col, p, face + vec2(-0.11, 0.0), 0.05, Btn_X, vec3(0.45, 0.7, 1.0));
    col = drawButton(col, p, face + vec2(0.11, 0.0), 0.05, Btn_B, vec3(1.0, 0.4, 0.4));

    col = drawButton(col, p, vec2(-1.25, 0.88), 0.045, Btn_LB, vec3(0.6, 0.8, 1.0));
    col = drawButton(col, p, vec2(1.25, 0.88), 0.045, Btn_RB, vec3(1.0, 0.8, 0.6));
    col = drawButton(col, p, vec2(-0.16, 0.72), 0.04, Btn_View, vec3(0.7));
    col = drawButton(col, p, vec2(0.16, 0.72), 0.04, Btn_Menu, vec3(0.7));
    col = drawButton(col, p, vec2(0.0, 0.78), 0.05, Btn_Steam, vec3(0.55, 0.75, 1.0));
    col = drawButton(col, p, vec2(0.0, 0.62), 0.035, Btn_QAM, vec3(0.55, 0.75, 1.0));

    // Grips and back paddles, along the outside of the trackpads.
    col = drawButton(col, p, vec2(-1.2, -0.3), 0.04, Btn_L4, vec3(0.5, 0.85, 1.0));
    col = drawButton(col, p, vec2(-1.2, -0.45), 0.04, Btn_L5, vec3(0.5, 0.85, 1.0));
    col = drawButton(col, p, vec2(-1.2, -0.6), 0.04, Btn_LeftGripTouch, vec3(0.35, 0.6, 0.8));
    col = drawButton(col, p, vec2(1.2, -0.3), 0.04, Btn_R4, vec3(1.0, 0.75, 0.45));
    col = drawButton(col, p, vec2(1.2, -0.45), 0.04, Btn_R5, vec3(1.0, 0.75, 0.45));
    col = drawButton(col, p, vec2(1.2, -0.6), 0.04, Btn_RightGripTouch, vec3(0.8, 0.6, 0.35));

    // Orientation and rotation rates.
    col = drawOrientation(col, p, vec2(0.0, -0.05));

    // Link status, top left.
    col = drawLink(col, p, vec2(-1.62, 0.88));

    // Packet activity, top right: the report sequence counter as a rotating sweep, so a
    // live but perfectly still controller is still visibly streaming.
    {
        vec2 q = p - vec2(1.62, 0.88);
        float angle = iController.sequence * TAU;
        col = over(col, vec3(0.2), strokeMask(sdCircle(q, 0.05), px));
        col = over(
            col,
            vec3(0.4, 1.0, 0.6),
            strokeMask(sdSegment(q, vec2(0.0, 0.0), vec2(cos(angle), sin(angle)) * 0.045), px * 1.5)
        );
    }

    // Raw button bitfield: one cell per defined bit, so buttons without a dedicated widget
    // (and any bit the protocol notes aren't confirmed) are still visible.
    for (uint i = 0u; i < 30u; ++i)
    {
        float cx = -1.45 + (float(i) + 0.5) * (2.9 / 30.0);
        float d = sdRoundBox(p - vec2(cx, -0.88), vec2(0.04, 0.03), 0.012);
        bool pressed = iController.button(1u << i);
        vec3 tint = palette(float(i) / 30.0);
        col = over(col, pressed ? tint : tint * 0.12, fillMask(d));
    }

    // Nothing connected: dim the whole card down to a standby state.
    if (!iController.connected())
    {
        float pulse = 0.35 + 0.1 * sin(iTime * 2.0);
        col = mix(vec3(dot(col, vec3(0.299, 0.587, 0.114))) * pulse, col, 0.25);
    }

    fragColor = vec4(col, 1.0);
}
