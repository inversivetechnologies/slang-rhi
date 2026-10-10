-- ShaderToy shaders (shaders/shader-toy/: mainImage(), with ShaderToy's inputs) as part of
-- a scene: run over a texture of the window's size every frame, and drawn over the window,
-- after the views. (shader-toy.lua runs them on their own.)
--
--   "shadertoy": { "shader": "sdfs2d.slang" (in shaders/shader-toy/) }
--
-- Inputs, as shader-toy.lua gives them: iResolution, iTime, iTimeDelta, iFrameRate, iFrame,
-- iMouse (xy where the left button was last held, z held, w pressed this frame) and
-- iController (the primary Steam Controller, live). They change every frame, so this
-- system updates its parameter block from Lua every frame. A shader that doesn't compile
-- shows dark red until it does.

local system = {
    name = "shadertoy",
    components = {
        shadertoy = {
            shader = { "string", nil, true },
        },
    },
}

function system.load(ctx)
    local toys = {}
    for id, toy in ctx.world:query("shadertoy") do
        local image = rhi.render_target("rgba32f")
        toys[#toys + 1] = {
            name = ctx.world:name(id),
            shader = toy.shader,
            image = image,
            pipeline = rhi.compute_pipeline("shader-toy/" .. toy.shader, "mainCompute"),
            block = rhi.params {
                iResolution = { 1, 1, 1 }, iTime = 0, iTimeDelta = 0, iFrameRate = 0, iFrame = 0,
                iMouse = { 0, 0, 0, 0 }, iController = input.controller(), texture = image,
            },
        }
    end
    if #toys == 0 then return end
    if #toys > 1 then
        print(string.format("[scene] %s: one shadertoy is drawn; the others are ignored", ctx.name))
    end
    ctx.shadertoy = { toy = toys[1], time = 0, frame = 0, frameRate = 0, mouse = { 0, 0 }, down = false }
end

function system.addOverlays(ctx, graph)
    local s = ctx.shadertoy
    if not s then return end
    local toy = s.toy
    toy.node = graph:dispatch {
        name = "shadertoy " .. toy.shader,
        pipeline = toy.pipeline,
        params = toy.block,
        threads = toy.image, -- one thread per pixel
    }
    -- ShaderToy colors are display values: the window encodes them itself if it is sRGB.
    toy.present = graph:render_pass { name = "shadertoy present" }
    toy.present:draw {
        pipeline = rhi.render_pipeline { shader = "post/composite.slang" },
        count = 3,
        params = { source = toy.image, borderColor = { 0, 0, 0, 1 }, borderWidth = 0, encodeGamma = 0,
                   decodeGamma = rhi.window_srgb() and 1 or 0 },
    }
    toy.failed = graph:render_pass { name = "shadertoy failed", clear = { 0.4, 0, 0, 1 } }
    toy.failed.enabled = false
end

function system.update(ctx, dt)
    local s = ctx.shadertoy
    if not s then return end
    s.time = s.time + dt
    s.frame = s.frame + 1
    s.frameRate = 0.9 * s.frameRate + 0.1 * (dt > 0 and 1 / dt or 0)
    local left = input.mouse_down(input.MOUSE_LEFT)
    if left then s.mouse = { input.mouse() } end
    local clicked = left and not s.down
    s.down = left
    local width, height = rhi.window_size()
    local toy = s.toy
    toy.block:set {
        iResolution = { width, height, 1 },
        iTime = s.time,
        iTimeDelta = dt,
        iFrameRate = s.frameRate,
        iFrame = s.frame,
        iMouse = { s.mouse[1], s.mouse[2], left and 1 or 0, clicked and 1 or 0 },
    }
    -- Until it compiles: dark red.
    local built = toy.pipeline.built
    if toy.node then
        toy.node.enabled = built
        toy.present.enabled = built
        toy.failed.enabled = not built
    end
end

function system.describe(ctx)
    local s = ctx.shadertoy
    if not s then return nil end
    return "ShaderToy " .. s.toy.shader .. (s.toy.pipeline.built and "" or " (doesn't compile)")
end

return system
