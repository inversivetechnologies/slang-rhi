-- Every example in one script: the surface clear, the triangle and the ShaderToy shaders,
-- one after another in the same window.
--
--   Left / Right arrows     previous / next mode
--   1 .. 6                  jump to a mode
--   Steam Controller LB/RB  previous / next mode
--   Left mouse button       moves iMouse in the ShaderToy modes
--
-- Edit this script or any of the shaders while it runs; they reload when saved.

config = {
    title = "Showcase",
    device = "vulkan",              -- the graphics API; `--api d3d12` etc. overrides it
    features = { "rasterization" }, -- the triangle mode rasterizes
}

-- -------------------------------------------------------------------------------------
-- State shared by the modes
-- -------------------------------------------------------------------------------------

-- The surface and triangle modes clear to a grey that ramps up and wraps around.
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
-- shown, so nothing is compiled before it is needed -- and `draw(frame)`.
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

-- A vertex-colored triangle drawn with a render pipeline and a vertex buffer.
local function triangleMode()
    local mode = { name = "Triangle" }
    local pipeline, vertices

    function mode.init()
        pipeline = rhi.render_pipeline {
            shader = "../triangle/triangle.slang",
            vertex = "vertexMain",
            fragment = "fragmentMain",
            -- One interleaved stream: offsets and stride follow from the formats.
            layout = { { "POSITION", "rgb32f" }, { "COLOR", "rgb32f" } },
        }
        vertices = rhi.vertex_buffer {
            -0.5, -0.5, 0.0,   1, 0, 0, -- red
             0.5, -0.5, 0.0,   0, 1, 0, -- green
             0.0,  0.5, 0.0,   0, 0, 1, -- blue
        }
    end

    function mode.draw(frame)
        frame:draw(pipeline, { vertices = vertices, clear = { grey, grey, grey, 1 } })
    end

    return mode
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

local modes = {
    surfaceMode(),
    triangleMode(),
    shaderToyMode("Circle", "circle.slang"),
    shaderToyMode("Ocean", "ocean.slang"),
    shaderToyMode("2D SDFs", "sdfs2d.slang"),
    shaderToyMode("Controller", "controller.slang"),
}

local current = 1

-- Shows mode `index`, wrapping around at either end.
local function switchTo(index)
    current = (index - 1) % #modes + 1
    local mode = modes[current]
    if mode.init and not mode.ready then
        mode.init()
        mode.ready = true
    end
    rhi.set_title(string.format("Showcase: %s (%d/%d)", mode.name, current, #modes))
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
end

function draw(frame)
    modes[current].draw(frame)
end

function on_key(key, action)
    if action ~= input.PRESS then return end
    if key == keys.RIGHT then
        switchTo(current + 1)
    elseif key == keys.LEFT then
        switchTo(current - 1)
    else
        for i = 1, math.min(#modes, 9) do
            if key == keys[tostring(i)] then switchTo(i) end
        end
    end
end

function on_controller_button(slot, button, pressed)
    if not pressed then return end
    if button == buttons.RB then
        switchTo(current + 1)
    elseif button == buttons.LB then
        switchTo(current - 1)
    end
end
