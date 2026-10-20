-- The user's settings, kept between runs (and across script reloads) in
-- %LOCALAPPDATA%/slang-rhi-lua-settings.json ($HOME elsewhere). The pause menu
-- (lib/pause-menu.lua) changes them, on its Display, Graphics and Controls pages; the scene
-- viewer applies them.
--
-- Display:
--   resolution      { width, height }: the window's size, or with fullscreen the monitor's
--                   video mode; nil: as the script's config asks
--   fullscreen      true / false
--   graphicsDevice  { adapter = name }: the GPU to run on (rhi.devices: the engine runs on
--                   Vulkan only, for now); nil: the default one. The host reads it at
--                   startup; changing it restarts the script on it (rhi.restart).
--   graphicsDeviceTrial  the GPU switched to, until it has started: then it becomes
--                   graphicsDevice (load, once the script runs on it). A device that
--                   crashes the host on its way up (a driver's) is never kept: the next
--                   start is on the one before.
-- Graphics:
--   splatBudget     the most splats drawn a frame (the levels of detail fit them to it)
--   shadowQuality   "Low", "Medium", "High" or "Ultra": the shadow maps' size
--   ambientOcclusion  "Off", "SSAO" or "GTAO" (post/ssao.slang)
--   globalIllumination  "Off", "SSGI" (screen-space, post/ssao.slang) or "Cascades" (radiance
--                   cascades: lib/scene/gi.lua)
--   effectsQuality  "Half", "Mixed" (AO at full resolution, GI at half) or "Full"
--   antiAliasing    "Off", "FXAA" or "SMAA" (spatial, within the frame: post/fxaa.slang,
--                   post/smaa.slang) or "TAA" (temporal: the main view stabilized over
--                   frames, post/taa.slang)
-- Controls (every camera and the player read them: settings.mouseLook, settings.stickLook):
--   mouseSensitivity  times the mouse's turn of the camera (1: as it was made)
--   stickSensitivity  times the controller's (the right stick, the right pad)
--   invertY           true: moving up looks down, as in a flight sim

local json = rhi.include("lib/scene/json.lua")

local settings = {}

settings.SHADOW_QUALITIES = { "Low", "Medium", "High", "Ultra" }
settings.SHADOW_FACE_SIZES = { Low = 256, Medium = 512, High = 1024, Ultra = 2048 }
settings.SPLAT_BUDGETS = { 250000, 500000, 1000000, 1500000, 2000000, 3000000, 4000000, 6000000 }
settings.EFFECT_QUALITIES = { "Half", "Mixed", "Full" }
settings.AO_METHODS = { "Off", "SSAO", "GTAO" }
settings.GI_METHODS = { "Off", "SSGI", "Cascades" }
settings.AA_METHODS = { "Off", "FXAA", "SMAA", "TAA" }
settings.SENSITIVITIES = { 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3 }

local DEFAULTS = {
    fullscreen = false,
    splatBudget = 1500000,
    shadowQuality = "Medium",
    ambientOcclusion = "GTAO",
    globalIllumination = "Cascades",
    effectsQuality = "Half",
    antiAliasing = "TAA",
    mouseSensitivity = 1,
    stickSensitivity = 1,
    invertY = false,
}

-- The controls in effect, shared by every include of this file -- rhi.include runs it anew
-- each time, so no table of it is shared; this global is -- and kept by load and save.
local function shareControls(values)
    rhiControlSettings = { mouse = values.mouseSensitivity, stick = values.stickSensitivity, invertY = values.invertY }
end

local function path()
    local dir = os.getenv("LOCALAPPDATA") or os.getenv("HOME") or "."
    return dir .. "/slang-rhi-lua-settings.json"
end

-- Reads the file (a missing or broken one gives the defaults).
function settings.load()
    local values = {}
    for k, v in pairs(DEFAULTS) do values[k] = v end
    local saved
    local file = io.open(path(), "r")
    if file then
        local text = file:read("a")
        file:close()
        local ok, decoded = pcall(json.decode, text, path())
        if ok and type(decoded) == "table" then
            saved = decoded
            for k, v in pairs(saved) do
                if v ~= json.null then values[k] = v end
            end
        end
    end
    if type(values.splatBudget) ~= "number" then values.splatBudget = DEFAULTS.splatBudget end
    for _, key in ipairs { "mouseSensitivity", "stickSensitivity" } do
        if type(values[key]) ~= "number" or values[key] <= 0 then values[key] = DEFAULTS[key] end
    end
    values.invertY = values.invertY == true
    -- (Files from when the engine ran on several APIs also have the device's `api`: only
    -- the adapter is kept.)
    local device = values.graphicsDevice
    values.graphicsDevice = type(device) == "table" and type(device.adapter) == "string" and { adapter = device.adapter } or nil
    -- The GPU switched to, kept if this is it running (there is a device: not the host's
    -- look at the file before it makes one), forgotten either way.
    local trial = values.graphicsDeviceTrial
    if trial ~= nil and rhi.device and rhi.device() ~= "" then
        if type(trial) == "table" and trial.adapter == rhi.adapter() then
            values.graphicsDevice = { adapter = trial.adapter }
        end
        values.graphicsDeviceTrial = nil
        settings.save(values)
    end
    if not settings.SHADOW_FACE_SIZES[values.shadowQuality] then values.shadowQuality = DEFAULTS.shadowQuality end
    local known = false
    for _, q in ipairs(settings.EFFECT_QUALITIES) do known = known or q == values.effectsQuality end
    if not known then values.effectsQuality = DEFAULTS.effectsQuality end
    -- Files from before the AO methods have `ssao` on or off: off stays off.
    if values.ssao == false and not (saved and saved.ambientOcclusion) then values.ambientOcclusion = "Off" end
    values.ssao = nil
    -- And `ssgi` on or off: on is the default method (radiance cascades), off stays off.
    if saved and saved.globalIllumination == nil and saved.ssgi ~= nil then
        values.globalIllumination = saved.ssgi and DEFAULTS.globalIllumination or "Off"
    end
    values.ssgi = nil
    known = false
    for _, m in ipairs(settings.GI_METHODS) do known = known or m == values.globalIllumination end
    if not known then values.globalIllumination = DEFAULTS.globalIllumination end
    -- Files from before the AA methods have `temporalAA` on or off.
    if saved and saved.antiAliasing == nil and saved.temporalAA ~= nil then
        values.antiAliasing = saved.temporalAA and "TAA" or "Off"
    end
    values.temporalAA = nil
    known = false
    for _, m in ipairs(settings.AA_METHODS) do known = known or m == values.antiAliasing end
    if not known then values.antiAliasing = DEFAULTS.antiAliasing end
    known = false
    for _, m in ipairs(settings.AO_METHODS) do known = known or m == values.ambientOcclusion end
    if not known then values.ambientOcclusion = DEFAULTS.ambientOcclusion end
    shareControls(values)
    return values
end

local function encode(value)
    if type(value) == "table" then
        if #value > 0 then
            local parts = {}
            for i, v in ipairs(value) do parts[i] = encode(v) end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = string.format("  %q: %s", k, encode(value[k])) end
        return "{\n" .. table.concat(parts, ",\n") .. "\n}"
    elseif type(value) == "string" then
        return string.format("%q", value)
    else
        return tostring(value)
    end
end

function settings.save(values)
    local file = io.open(path(), "w")
    if not file then
        print("[settings] can't write " .. path())
        return
    end
    file:write(encode(values), "\n")
    file:close()
    shareControls(values)
end

-- The controls in effect (from the file, the first time).
function settings.controls()
    if not rhiControlSettings then settings.load() end
    return rhiControlSettings
end

-- A mouse drag's camera turn (dx, dy: as each camera scales it), by the controls.
function settings.mouseLook(dx, dy)
    local c = settings.controls()
    return dx * c.mouse, dy * c.mouse * (c.invertY and -1 or 1)
end

-- A stick's (or pad's), likewise.
function settings.stickLook(dx, dy)
    local c = settings.controls()
    return dx * c.stick, dy * c.stick * (c.invertY and -1 or 1)
end

-- The shadow maps' texels per cube face, as the saved shadow quality asks.
function settings.shadowFaceSize()
    return settings.SHADOW_FACE_SIZES[settings.load().shadowQuality]
end

-- The window as `values` ask for it (only what differs from now, so a reload changes
-- nothing).
function settings.applyDisplay(values)
    local now = rhi.display()
    local width = values.resolution and values.resolution[1] or now.width
    local height = values.resolution and values.resolution[2] or now.height
    if width ~= now.width or height ~= now.height or (values.fullscreen and true or false) ~= now.fullscreen then
        rhi.set_display { width = width, height = height, fullscreen = values.fullscreen and true or false }
    end
end

-- The sizes a resolution can be: the monitor's modes from 800 x 600 up, and the window's
-- own size if it isn't one of them.
function settings.resolutions()
    local display = rhi.display()
    local list = {}
    for _, m in ipairs(display.modes) do
        if m[1] >= 800 and m[2] >= 600 then list[#list + 1] = { m[1], m[2] } end
    end
    local found = false
    for _, m in ipairs(list) do
        if m[1] == display.width and m[2] == display.height then found = true end
    end
    if not found then
        list[#list + 1] = { display.width, display.height }
        table.sort(list, function(a, b) return a[1] * a[2] < b[1] * b[2] or (a[1] * a[2] == b[1] * b[2] and a[1] < b[1]) end)
    end
    return list
end

return settings
