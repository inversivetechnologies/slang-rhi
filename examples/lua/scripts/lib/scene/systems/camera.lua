-- Cameras: each one a view the renderer draws (lib/scene/renderer.lua). One is the main
-- view, into the window; the others are insets: squares in a corner of the window, `inset`
-- times its height on a side.
--
--   "camera": { "fov": 50 (degrees, vertical),
--               "controller": "orbit" | "fixed" | "player",
--               "target": [x, y, z]   -- what it looks at; an orbit's center
--               "distance": 6, "yaw": 0, "pitch": 25 (degrees) -- for "orbit"
--               "turn": 0 (degrees per second: an orbit that turns by itself)
--               "inset": 0 (the main view) or a size, e.g. 0.3,
--               "corner": "bottom-right" | "bottom-left" | "top-right" | "top-left" }
--
-- "orbit" turns about `target` with the mouse (drag, wheel) when it is the main view;
-- "fixed" looks from the entity's position at `target`; "player" follows the player
-- behavior's camera (behaviors/player.lua). Without a main camera, an orbit camera looks
-- at the origin.

local settings = rhi.include("lib/settings.lua") -- the controls (look sensitivity)
local system = {
    name = "camera",
    components = {
        camera = {
            fov = { "number", 50 },
            controller = { "string", "orbit" },
            target = { "vec3", { 0, 0, 0 } },
            distance = { "number", 6 },
            yaw = { "number", 0 },
            pitch = { "number", 25 },
            turn = { "number", 0 },
            inset = { "number", 0 },
            corner = { "string", "bottom-right" },
        },
    },
}

local INSET_MARGIN = 0.03

local function orbitParams(c)
    local yaw, pitch = math.rad(c.yaw), math.rad(c.pitch)
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local t = c.target
    return {
        eye = { t[1] + c.distance * cp * math.sin(yaw), t[2] + c.distance * sp, t[3] - c.distance * cp * math.cos(yaw) },
        target = t,
        fovY = math.rad(c.fov),
    }
end

local function cameraParams(ctx, view)
    local c = view.camera
    if c.controller == "player" and ctx.cameraProviders.player then
        return ctx.cameraProviders.player()
    elseif c.controller == "fixed" then
        return { eye = view.position, target = c.target, fovY = math.rad(c.fov) }
    end
    return orbitParams(c)
end

-- A view's camera, into its block; `view.cameraValue` keeps it for Lua (the renderer's
-- temporal effects reproject by the last frame's).
local function setCamera(view, value)
    view.cameraValue = value
    view.block.camera = value
end

function system.load(ctx)
    local main, insets = nil, {}
    for id, camera, transform in ctx.world:query("camera", "transform") do
        local view = { name = ctx.world:name(id), camera = camera, position = transform.position }
        if camera.inset > 0 then
            view.inset = camera.inset
            view.budgetScale = camera.inset * camera.inset
            insets[#insets + 1] = view
        elseif not main then
            main = view
        else
            print(string.format("[scene] %s: a second main camera ('%s') is ignored", ctx.name, view.name))
        end
    end
    if not main then
        main = { name = "camera", camera = {
            fov = 50, controller = "orbit", target = { 0, 0, 0 }, distance = 8, yaw = 30, pitch = 25, turn = 0, inset = 0,
            corner = "bottom-right",
        } }
    end
    ctx.views = { main }
    for _, view in ipairs(insets) do ctx.views[#ctx.views + 1] = view end
    for _, view in ipairs(ctx.views) do
        view.budgetScale = view.budgetScale or 1
        -- What every pass of the view sees the world through; the mesh pass writes linear
        -- color, the composite encodes it.
        view.cameraValue = cameraParams(ctx, view)
        view.block = rhi.params { camera = view.cameraValue, encodeGamma = 0 }
    end
end

-- Insets: where each goes in a window of `width` x `height`, stacked from its corner.
function system.layout(ctx, width, height)
    if width <= 0 or height <= 0 then return end
    local stacked = {}
    for _, view in ipairs(ctx.views) do
        if view.inset then
            local corner = view.camera.corner
            local index = stacked[corner] or 0
            stacked[corner] = index + 1
            local side = math.max(1, math.floor(height * view.inset + 0.5))
            local margin = math.floor(height * INSET_MARGIN + 0.5)
            local x = corner:find("left") and margin or width - side - margin
            local offset = index * (side + margin)
            local y = corner:find("top") and margin + offset or height - side - margin - offset
            if view.framePass then view.framePass.viewport = { x, y, side, side } end
            -- Dispatches over the splats see the window's size unless told the square's.
            view.block.viewportSize = { side, side }
        end
    end
end

function system.update(ctx, dt)
    for _, view in ipairs(ctx.views) do
        local c = view.camera
        if c.controller == "player" then
            setCamera(view, cameraParams(ctx, view))
        elseif c.controller == "orbit" and c.turn ~= 0 and not ctx.cameraStill then
            c.yaw = c.yaw + c.turn * dt
            setCamera(view, cameraParams(ctx, view))
        end
    end
end

-- The main view's orbit, by mouse.
local drag

function system.on_mouse_button(ctx, button, action)
    if button ~= input.MOUSE_LEFT then return false end
    local main = ctx.views[1]
    if main.camera.controller ~= "orbit" then return false end
    drag = action == input.PRESS and { input.mouse() } or nil
    return true
end

function system.on_mouse_move(ctx, x, y)
    local main = ctx.views[1]
    if not drag or main.camera.controller ~= "orbit" then return false end
    local c = main.camera
    local dx, dy = settings.mouseLook(x - drag[1], y - drag[2]) -- the controls' sensitivity
    c.yaw = c.yaw - dx * 0.35
    c.pitch = math.max(-80, math.min(85, c.pitch + dy * 0.35))
    drag = { x, y }
    setCamera(main, cameraParams(ctx, main))
    return true
end

function system.on_scroll(ctx, _, y)
    local main = ctx.views[1]
    if main.camera.controller ~= "orbit" then return false end
    main.camera.distance = math.max(0.5, math.min(200, main.camera.distance * (y > 0 and 0.9 or 1.1)))
    setCamera(main, cameraParams(ctx, main))
    return true
end

return system
