-- Every example in one script: the surface clear, the lit scene and the ShaderToy
-- shaders, one after another in the same window.
--
--   Left / Right arrows     previous / next mode
--   1 .. 6                  jump to a mode
--   Steam Controller LB/RB  previous / next mode
--   Left mouse button       moves iMouse in the ShaderToy modes, orbits the scene's camera
--
-- The scene has more controls of its own; see ../scene/scene-mode.lua.
--
-- Edit this script or any of the shaders while it runs; they reload when saved.

config = {
    title = "Showcase",
    device = "vulkan",              -- the graphics API; `--api d3d12` etc. overrides it
    features = { "rasterization" }, -- the surface and scene modes rasterize
}

-- -------------------------------------------------------------------------------------
-- State shared by the modes
-- -------------------------------------------------------------------------------------

-- The surface mode clears to a grey that ramps up and wraps around.
local grey = 0.5

local clock = { time = 0, dt = 0, frameRate = 0 }

-- ShaderToy's iMouse: xy is where the left button was last held, z/w are "any button
-- down" and "pressed this frame".
local mouse = { x = 0, y = 0, down = false, clicked = false }

-- The ShaderToy modes render into this texture (it follows the window size), then blit it
-- to the window.
local target

-- A live view of the primary Steam Controller, bound to the shaders' iController.
local controller

-- -------------------------------------------------------------------------------------
-- Modes
--
-- A mode is a table with a `name`, an optional `init()` -- run the first time the mode is
-- shown, so nothing is compiled before it is needed -- and `draw(frame)`. It can also
-- have `on_enter()` and `on_leave()`, called each time it is shown and hidden, and
-- `update` and input callbacks, which are forwarded to the current mode. A mode that sets
-- up a render graph (the scene) needs no `draw`: the host runs the graph.
-- -------------------------------------------------------------------------------------

-- Clears the window: the smallest thing a frame can do.
local function surfaceMode()
    return {
        name = "Surface",
        draw = function(frame)
            frame:clear(grey, grey, grey)
        end,
    }
end

local current = 1
local modes

local function modeTitle(index)
    return string.format("Showcase: %s (%d/%d)", modes[index].name, index, #modes)
end

-- The lit scene with point light shadows, shared with ../scene/scene.lua. rhi.include()
-- runs it from there (and reloads the showcase when it is saved); the scene's parameters
-- go in the title after the mode's.
local function sceneMode()
    local createScene = rhi.include("../scene/scene-mode.lua")
    return createScene("../scene/", function(details)
        rhi.set_title(modeTitle(current) .. " | " .. details)
    end)
end

-- A ShaderToy-style shader: a compute shader runs mainImage() (see
-- ../shader-toy/shader-toy.slang) for every pixel of `target`.
local function shaderToyMode(name, file)
    local mode = { name = "ShaderToy: " .. name }
    local pipeline

    function mode.init()
        pipeline = rhi.compute_pipeline("../shader-toy/" .. file, "mainCompute")
    end

    function mode.draw(frame)
        if not pipeline.built then
            -- It didn't compile (on this backend, or since the last edit didn't).
            frame:clear(0.4, 0, 0)
            return
        end
        frame:dispatch(pipeline, {
            iResolution = { frame.width, frame.height, 1 },
            iTime = clock.time,
            iTimeDelta = clock.dt,
            iFrameRate = clock.frameRate,
            iFrame = frame.index,
            iMouse = { mouse.x, mouse.y, mouse.down and 1 or 0, mouse.clicked and 1 or 0 },
            iController = controller,
            texture = target,
        }) -- one thread per pixel: x/y default to the frame size
        frame:blit(target)
    end

    return mode
end

modes = {
    surfaceMode(),
    sceneMode(),
    shaderToyMode("Circle", "circle.slang"),
    shaderToyMode("Ocean", "ocean.slang"),
    shaderToyMode("2D SDFs", "sdfs2d.slang"),
    shaderToyMode("Controller", "controller.slang"),
}

-- Shows mode `index`, wrapping around at either end.
local function switchTo(index)
    local previous = modes[current]
    if previous.ready and previous.on_leave then previous.on_leave() end
    current = (index - 1) % #modes + 1
    local mode = modes[current]
    if mode.init and not mode.ready then
        mode.init()
        mode.ready = true
    end
    rhi.set_title(modeTitle(current))
    if mode.on_enter then mode.on_enter() end
end

-- Passes a callback on to the current mode, if it has one.
local function forward(name, ...)
    local handler = modes[current][name]
    if handler then handler(...) end
end

-- -------------------------------------------------------------------------------------
-- Callbacks
-- -------------------------------------------------------------------------------------

function init()
    target = rhi.render_target("rgba32f")
    controller = input.controller()
    switchTo(current)
end

function update(time, dt)
    clock.time, clock.dt = time, dt
    clock.frameRate = 0.9 * clock.frameRate + 0.1 * (dt > 0 and 1 / dt or 0)

    grey = grey + 1 / 60
    if grey > 1 then grey = 0 end

    local left = input.mouse_down(input.MOUSE_LEFT)
    if left then mouse.x, mouse.y = input.mouse() end
    local down = left or input.mouse_down(input.MOUSE_RIGHT) or input.mouse_down(input.MOUSE_MIDDLE)
    mouse.clicked = down and not mouse.down
    mouse.down = down

    forward("update", time, dt)
end

function draw(frame)
    forward("draw", frame)
end

function on_key(key, action, mods)
    if action == input.PRESS and key == keys.RIGHT then
        switchTo(current + 1)
    elseif action == input.PRESS and key == keys.LEFT then
        switchTo(current - 1)
    else
        for i = 1, math.min(#modes, 9) do
            if action == input.PRESS and key == keys[tostring(i)] then
                switchTo(i)
                return
            end
        end
        forward("on_key", key, action, mods)
    end
end

function on_mouse_button(button, action, mods) forward("on_mouse_button", button, action, mods) end
function on_mouse_move(x, y) forward("on_mouse_move", x, y) end
function on_scroll(x, y) forward("on_scroll", x, y) end

function on_controller_button(slot, button, pressed)
    if not pressed then return end
    if button == buttons.RB then
        switchTo(current + 1)
    elseif button == buttons.LB then
        switchTo(current - 1)
    end
end
