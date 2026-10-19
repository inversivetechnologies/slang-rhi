-- The user's settings, kept between runs (and across script reloads) in
-- %LOCALAPPDATA%/slang-rhi-lua-settings.json ($HOME elsewhere). The pause menu
-- (lib/pause-menu.lua) changes them; the scene viewer applies them.
--
--   resolution      { width, height }: the window's size, or with fullscreen the monitor's
--                   video mode; nil: as the script's config asks
--   fullscreen      true / false
--   splatBudget     the most splats drawn a frame (the levels of detail fit them to it)
--   shadowQuality   "Low", "Medium", "High" or "Ultra": the shadow maps' size
--   ssao, ssgi      screen-space ambient occlusion and indirect light (post/ssao.slang)

local json = rhi.include("lib/scene/json.lua")

local settings = {}

settings.SHADOW_QUALITIES = { "Low", "Medium", "High", "Ultra" }
settings.SHADOW_FACE_SIZES = { Low = 256, Medium = 512, High = 1024, Ultra = 2048 }
settings.SPLAT_BUDGETS = { 250000, 500000, 1000000, 1500000, 2000000 }

local DEFAULTS = {
    fullscreen = false,
    splatBudget = 1000000,
    shadowQuality = "Medium",
    ssao = true,
    ssgi = false,
}

local function path()
    local dir = os.getenv("LOCALAPPDATA") or os.getenv("HOME") or "."
    return dir .. "/slang-rhi-lua-settings.json"
end

-- Reads the file (a missing or broken one gives the defaults).
function settings.load()
    local values = {}
    for k, v in pairs(DEFAULTS) do values[k] = v end
    local file = io.open(path(), "r")
    if file then
        local text = file:read("a")
        file:close()
        local ok, saved = pcall(json.decode, text, path())
        if ok and type(saved) == "table" then
            for k, v in pairs(saved) do
                if v ~= json.null then values[k] = v end
            end
        end
    end
    if not settings.SHADOW_FACE_SIZES[values.shadowQuality] then values.shadowQuality = DEFAULTS.shadowQuality end
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
