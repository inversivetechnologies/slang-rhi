-- Runs "ShaderToy"-style shaders: a compute shader renders mainImage() (see
-- shader-toy.slang) into a texture that is blitted to the window.
--
-- Left/right arrows cycle through the shaders. Add one by dropping a .slang file in this
-- folder and listing it below -- saving this script picks it up without a restart.

config = { title = "ShaderToy" }

local shaders = { "circle.slang", "ocean.slang", "sdfs2d.slang", "controller.slang" }
local current = 1
local pipelines = {}

local target, controller
local time, timeDelta, frameRate = 0, 0, 0

-- iMouse: xy is where the left button was last held, z/w are "any button down" and
-- "pressed this frame".
local mouse = { x = 0, y = 0, down = false, clicked = false }

-- Shaders compile when first shown, then stay cached (and hot-reload) in the host.
local function pipeline()
    local name = shaders[current]
    pipelines[name] = pipelines[name] or rhi.compute_pipeline(name, "mainCompute")
    return pipelines[name]
end

function init()
    target = rhi.render_target("rgba32f")
    controller = input.controller()
    pipeline()
end

function update(t, dt)
    time, timeDelta = t, dt
    frameRate = 0.9 * frameRate + 0.1 * (dt > 0 and 1 / dt or 0)

    local left = input.mouse_down(input.MOUSE_LEFT)
    if left then mouse.x, mouse.y = input.mouse() end
    local down = left or input.mouse_down(input.MOUSE_RIGHT) or input.mouse_down(input.MOUSE_MIDDLE)
    mouse.clicked = down and not mouse.down
    mouse.down = down
end

function draw(frame)
    frame:dispatch(pipeline(), {
        iResolution = { frame.width, frame.height, 1 },
        iTime = time,
        iTimeDelta = timeDelta,
        iFrameRate = frameRate,
        iFrame = frame.index,
        iMouse = { mouse.x, mouse.y, mouse.down and 1 or 0, mouse.clicked and 1 or 0 },
        iController = controller,
        texture = target,
    })
    frame:blit(target)
end

function on_key(key, action)
    if action ~= input.PRESS then return end
    if key == keys.RIGHT then
        current = current % #shaders + 1
    elseif key == keys.LEFT then
        current = (current - 2) % #shaders + 1
    end
end
