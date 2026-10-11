-- 2D overlays: ShaderToy shaders (shaders/shader-toy/: mainImage(), with ShaderToy's inputs)
-- drawn in a framed panel over any scene, after its views and insets. Each is a file in
-- assets/overlays/:
--
--   { "name": "2D SDFs", "shader": "sdfs2d.slang" (in shaders/shader-toy/),
--     "size": 0.4 (of the window's width and height), "corner": "top-left" }
--
-- The viewer loads them once (their pipelines and images last across scenes), and every
-- scene's graph gets their passes (renderer.build), all off but the one shown.
--
--   local overlays = rhi.include("lib/scene/overlays.lua").load()
--   overlays:cycle()          -- none, each overlay in turn
--   overlays:update(dt)       -- ShaderToy's inputs, every frame
--
-- Inputs, as shader-toy.lua gives them: iResolution (the panel's), iTime, iTimeDelta,
-- iFrameRate, iFrame, iMouse (xy where the left button was last held over the panel, in
-- its pixels; z held, w pressed this frame) and iController (the primary Steam Controller,
-- live). Clicks on the panel go to it, not to the scene. A shader that doesn't compile
-- shows dark red until it does.

local json = rhi.include("lib/scene/json.lua")

local CORNERS = { ["top-left"] = true, ["top-right"] = true, ["bottom-left"] = true, ["bottom-right"] = true }
local MARGIN = 12 -- pixels from the window's edges

local Overlays = {}
Overlays.__index = Overlays

local overlays = {}

-- Reads assets/overlays/*.json; a file that doesn't load is reported and left out.
function overlays.load()
    local self = setmetatable({ list = {}, active = 0, time = 0, frame = 0, frameRate = 0, down = false }, Overlays)
    self.frame_pipeline = rhi.render_pipeline { shader = "post/composite.slang" }
    for _, file in ipairs(rhi.list_assets("overlays", ".json")) do
        local path = "overlays/" .. file
        local ok, spec = pcall(function() return json.decode(rhi.read_asset(path), path) end)
        if ok and type(spec.shader) ~= "string" then
            ok, spec = false, path .. ": \"shader\" is required"
        end
        if ok and spec.corner ~= nil and not CORNERS[spec.corner] then
            ok, spec = false, path .. ": unknown corner \"" .. tostring(spec.corner) .. "\""
        end
        if ok then
            local size = tonumber(spec.size) or 0.4
            local image = rhi.render_target("rgba32f", size)
            self.list[#self.list + 1] = {
                name = spec.name or file,
                shader = spec.shader,
                size = size,
                corner = spec.corner or "top-left",
                image = image,
                pipeline = rhi.compute_pipeline("shader-toy/" .. spec.shader, "mainCompute"),
                block = rhi.params {
                    iResolution = { 1, 1, 1 }, iTime = 0, iTimeDelta = 0, iFrameRate = 0, iFrame = 0,
                    iMouse = { 0, 0, 0, 0 }, iController = input.controller(), texture = image,
                },
                mouse = { 0, 0 },
            }
        else
            print("[overlay] " .. tostring(spec))
        end
    end
    return self
end

-- Adds every overlay's passes to a scene's graph, after everything else: run the shader,
-- then frame its image in its panel (or dark red, until it compiles).
function Overlays:addPasses(graph)
    local srgb = rhi.window_srgb()
    for _, o in ipairs(self.list) do
        o.node = graph:dispatch {
            name = "overlay " .. o.name,
            pipeline = o.pipeline,
            params = o.block,
            threads = o.image, -- one thread per pixel
        }
        -- ShaderToy colors are display values: the window encodes them itself if it is sRGB.
        o.present = graph:render_pass { name = "overlay " .. o.name .. ": panel", viewport = { 0, 0, 1, 1 } }
        o.present:draw {
            pipeline = self.frame_pipeline,
            count = 3,
            params = { source = o.image, borderColor = { 0.85, 0.85, 0.9, 1 }, borderWidth = 2,
                       encodeGamma = 0, decodeGamma = srgb and 1 or 0 },
        }
        o.failed = graph:render_pass { name = "overlay " .. o.name .. ": failed", viewport = { 0, 0, 1, 1 } }
        o.failed:draw {
            pipeline = self.frame_pipeline,
            count = 3,
            params = { source = o.image, borderColor = { 0.4, 0, 0, 1 }, borderWidth = 1e6,
                       encodeGamma = 0, decodeGamma = 0 },
        }
    end
    self:layout(rhi.window_size())
    self:refresh()
end

-- The panels' places in a window of `width` x `height`.
function Overlays:layout(width, height)
    self.width, self.height = width, height
    for _, o in ipairs(self.list) do
        local w, h = math.floor(o.size * width), math.floor(o.size * height)
        local x = o.corner:find("left") and MARGIN or width - w - MARGIN
        local y = o.corner:find("top") and MARGIN or height - h - MARGIN
        o.rect = { x, y, w, h }
        if o.present then
            o.present.viewport = o.rect
            o.failed.viewport = o.rect
        end
    end
end

-- Turns the passes on for the overlay shown (until it compiles: its dark red panel).
function Overlays:refresh()
    for i, o in ipairs(self.list) do
        if o.node then
            local shown, built = i == self.active, o.pipeline.built
            o.node.enabled = shown and built
            o.present.enabled = shown and built
            o.failed.enabled = shown and not built
        end
    end
end

-- None, then each overlay in turn.
function Overlays:cycle()
    self.active = (self.active + 1) % (#self.list + 1)
    self:refresh()
end

function Overlays:current()
    return self.list[self.active]
end

local function inside(rect, x, y)
    return rect and x >= rect[1] and y >= rect[2] and x < rect[1] + rect[3] and y < rect[2] + rect[4]
end

-- Clicks on the shown panel are the overlay's.
function Overlays:on_mouse_button(button, action)
    local o = self:current()
    return o ~= nil and inside(o.rect, input.mouse())
end

function Overlays:update(dt)
    self.time = self.time + dt
    self.frame = self.frame + 1
    self.frameRate = 0.9 * self.frameRate + 0.1 * (dt > 0 and 1 / dt or 0)
    local o = self:current()
    if not o or not o.rect then
        self.down = false
        return
    end
    local x, y = input.mouse()
    local left = input.mouse_down(input.MOUSE_LEFT) and (self.down or inside(o.rect, x, y))
    if left then o.mouse = { x - o.rect[1], y - o.rect[2] } end
    local clicked = left and not self.down
    self.down = left
    o.block:set {
        iResolution = { o.rect[3], o.rect[4], 1 },
        iTime = self.time,
        iTimeDelta = dt,
        iFrameRate = self.frameRate,
        iFrame = self.frame,
        iMouse = { o.mouse[1], o.mouse[2], left and 1 or 0, clicked and 1 or 0 },
    }
    self:refresh()
end

function Overlays:describe()
    local o = self:current()
    if not o then return #self.list > 0 and "O: overlay" or nil end
    return "O: overlay " .. o.name .. (o.pipeline.built and "" or " (doesn't compile)")
end

return overlays
