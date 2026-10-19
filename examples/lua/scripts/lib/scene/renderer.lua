-- The scene system's frame: a render graph built from what the systems contribute, once
-- per scene load (and again when the scene file changes). Per frame, nothing here runs:
-- systems change parameter blocks, and the host runs the graph.
--
-- The graph, in order:
--
--   prepasses          systems' one-time work (the SDF cache's bake)
--   shadow faces 0..5  the light's cube shadow map: systems draw their casters into the
--                      six passes (the meshes)
--   shadow passes      systems' own shadow passes (the splats' translucent maps)
--   for every view (camera), into its own targets:
--     opaque           a pass with color and depth: systems draw into it (the meshes)
--     surfaces         systems' passes after it (the SDFs' raymarching, the splats)
--     depth composite  the view's surfaces merged per pixel by depth
--                      (post/depth-composite.slang): into the window for the main view,
--                      into a texture for an inset
--   overlays           systems' passes over the main view (the player's crosshair)
--   insets             each inset's texture, framed, in its corner of the window
--   layers             the viewer's, over everything: 2D overlays (lib/scene/overlays.lua),
--                      in their panels, all off but the one shown; the pause menu
--                      (lib/pause-menu.lua), while it is open
--
-- Every surface reads one light block and one shadow block, which systems add to
-- (`shadowFields`): the SDFs' composition, whether there are splat shadows. So meshes,
-- splats and SDFs light and shadow each other the same way in every scene.
--
-- A system contributes through these optional functions, called in the systems' order:
--   shadowFields(ctx) -> table   addPrepasses(ctx, graph)   addShadowCasters(ctx, passes)
--   addShadowPasses(ctx, graph)  addOpaque(ctx, view, pass)  addSurfaces(ctx, graph, view)
--   addOverlays(ctx, graph)      addMotion(ctx, view, pass)

local renderer = {}


local function placeholderFields()
    return {
        splatShadows = 0,
        sdfShadows = 0, sdfShadowSharpness = 8, sdfNodes = rhi.buffer(128), sdfNodeCount = 0, sdfResultSlot = 0,
        smoothScale = 1, sdfOrigin = { 0, 0, 0 }, sdfSpin = 0, sdfBoundsRadius = 0,
        sdfUseCache = 0, sdfShowCacheError = 0,
        sdfCacheDistance = rhi.texture { width = 1, height = 1, depth = 1, format = "r16f" },
        sdfCacheColor = rhi.texture { width = 1, height = 1, depth = 1, format = "rgba8" },
        sdfCacheExtent = 1, sdfCacheResolution = 1,
    }
end

local function call(systems, name, ...)
    for _, system in ipairs(systems) do
        if system[name] then system[name](...) end
    end
end

-- The color textures and depth buffers a view renders into: window-sized, or squares of
-- `inset` times the window's height.
local function createTargets(inset)
    local scale, shape = inset or 1, inset and "square" or nil
    return {
        meshColor = rhi.render_target("rgba16f", scale, shape),
        meshDepth = rhi.depth_target(scale, shape),
        splatColor = rhi.render_target("rgba16f", scale, shape),
        splatDepth = rhi.depth_target(scale, shape),
        sdfColor = rhi.render_target("rgba16f", scale, shape),
        sdfDepth = rhi.render_target("r32f", scale, shape),
    }
end

-- Builds the scene's graph. `ctx` has been loaded by the systems (ctx.views, ctx.light).
-- Shadow map texels per cube face (the atlases are 3 x 2 faces); the shadow quality
-- setting changes it, for the graphs built after.
renderer.shadowFaceSize = 512

-- Screen-space effects on every view (post/ssao.slang): ambient occlusion (by `aoMethod`,
-- "GTAO" or "SSAO") and indirect light, at a quality: "Half" (both at half resolution),
-- "Mixed" (AO at full, GI at half) or "Full". The settings change them, for the graphs
-- built after.
renderer.effects = { ao = true, aoMethod = "GTAO", gi = false, quality = "Half" }
renderer.EFFECT_PARAMS = {
    aoRadius = 1.0,   -- world units
    aoStrength = 1.6, -- SSAO's: 1 black where fully occluded
    gtaoPower = 1.5,  -- GTAO's: its visibility raised to this
    giRadius = 2.5, giStrength = 2.5,
}

-- The effects' chains for a quality: what each computes, and at what scale of the view.
local function effectChains(fx)
    if fx.quality == "Mixed" and fx.ao and fx.gi then
        return { { ao = true, gi = false, scale = 1 }, { ao = false, gi = true, scale = 0.5 } }
    end
    local full = fx.quality == "Full" or (fx.quality == "Mixed" and not fx.gi)
    return { { ao = fx.ao, gi = fx.gi, scale = full and 1 or 0.5 } }
end

local function chainLabel(chain)
    local ao = renderer.effects.aoMethod == "GTAO" and "GTAO" or "SSAO"
    return (chain.ao and chain.gi and ao .. " + SSGI" or chain.ao and ao or "SSGI") ..
        (chain.scale < 1 and " (half)" or "")
end

function renderer.build(ctx, systems)
    local FACE = renderer.shadowFaceSize
    local srgb = rhi.window_srgb()
    local background = ctx.settings.background or { 0.015, 0.018, 0.025 }

    ctx.shadow = {
        faceSize = FACE,
        atlas = rhi.texture { width = 3 * FACE, height = 2 * FACE, format = "r32f" },
        splatAtlas = rhi.texture { width = 3 * FACE, height = 2 * FACE, format = "rgba16f" },
        splatLayers = rhi.texture { width = 3 * FACE, height = 2 * FACE, format = "rgba16f" },
    }
    local fields = placeholderFields()
    fields.shadowMap = ctx.shadow.atlas
    fields.shadowFaceSize = FACE
    fields.splatShadowMap = ctx.shadow.splatAtlas
    fields.splatShadowLayers = ctx.shadow.splatLayers
    fields.sdfCacheSampler = rhi.sampler { filter = "linear", address = "clamp" }
    for _, system in ipairs(systems) do
        if system.shadowFields then
            for k, v in pairs(system.shadowFields(ctx) or {}) do fields[k] = v end
        end
    end
    ctx.shadowBlock = rhi.params(fields)

    local pipelines = {
        compositeWindow = rhi.render_pipeline { shader = "post/depth-composite.slang" },
        compositeTexture = rhi.render_pipeline { shader = "post/depth-composite.slang", format = "rgba16f" },
        frame = rhi.render_pipeline { shader = "post/composite.slang" },
    }
    local fx = renderer.effects
    local effectsOn = fx.ao or fx.gi
    if effectsOn then
        pipelines.effects = rhi.compute_pipeline("post/ssao.slang", "effectsMain")
        pipelines.effectsBlur = rhi.compute_pipeline("post/ssao.slang", "blurMain")
        pipelines.effectsTemporal = rhi.compute_pipeline("post/ssao.slang", "temporalMain")
        pipelines.effectsHistory = rhi.compute_pipeline("post/ssao.slang", "historyMain")
        pipelines.applyWindow = rhi.render_pipeline { shader = "post/ssao-apply.slang" }
        pipelines.applyTexture = rhi.render_pipeline { shader = "post/ssao-apply.slang", format = "rgba16f" }
        local p = renderer.EFFECT_PARAMS
        ctx.effectsBlock = rhi.params {
            depthNear = 0.1, depthFar = 100,
            aoRadius = p.aoRadius, aoStrength = p.aoStrength, giRadius = p.giRadius,
            aoMethod = fx.aoMethod == "GTAO" and 1 or 0, gtaoPower = p.gtaoPower,
            frameIndex = 0,
        }
        ctx.effectsNodes = {} -- the main view's, timed
        ctx.effectsLabels = {}
    end

    local graph = rhi.graph()
    call(systems, "addPrepasses", ctx, graph)

    -- The light's cube shadow map: the first face clears the whole atlas.
    local facePasses = {}
    for face = 0, 5 do
        facePasses[#facePasses + 1] = graph:render_pass {
            name = "shadow face " .. face,
            target = ctx.shadow.atlas,
            viewport = { (face % 3) * FACE, (face // 3) * FACE, FACE, FACE },
            clear = face == 0 and { 1e9, 0, 0, 1 } or nil,
        }
    end
    call(systems, "addShadowCasters", ctx, facePasses)
    call(systems, "addShadowPasses", ctx, graph)

    -- The views.
    ctx.composites = {}
    for _, view in ipairs(ctx.views) do
        view.targets = createTargets(view.inset)
        local opaque = graph:render_pass {
            name = view.name .. ": opaque",
            target = view.targets.meshColor,
            depth_target = view.targets.meshDepth,
            clear = { background[1], background[2], background[3], 1 },
        }
        call(systems, "addOpaque", ctx, view, opaque)
        if effectsOn then
            -- What moved since the frame before (the bodies; the SDFs' spin is worked out
            -- from their block), so that the effects' history follows it.
            local scale, shape = view.inset or 1, view.inset and "square" or nil
            view.targets.meshMotion = rhi.render_target("rgba16f", scale, shape)
            view.targets.motionDepth = rhi.depth_target(scale, shape)
            local motion = graph:render_pass {
                name = view.name .. ": motion",
                target = view.targets.meshMotion,
                depth_target = view.targets.motionDepth,
                clear = { 0, 0, 0, 0 },
            }
            call(systems, "addMotion", ctx, view, motion)
        end
        call(systems, "addSurfaces", ctx, graph, view)
        if not ctx.splats then
            -- Nothing draws the splats' depth, but the composite reads it: clear it, so it
            -- holds the far plane (and D3D12 never reads a depth buffer nothing wrote).
            graph:render_pass {
                name = view.name .. ": no splats",
                depth_target = view.targets.splatDepth,
                color = false,
                clear = { 0, 0, 0, 0 },
            }
        end
        if not ctx.sdf then
            -- Nor do the SDFs' targets get written: no hit, at the far plane (the effects
            -- read the depth whatever the color says).
            graph:render_pass { name = view.name .. ": no SDFs", target = view.targets.sdfColor, clear = { 0, 0, 0, 0 } }
            graph:render_pass { name = view.name .. ": no SDF depth", target = view.targets.sdfDepth, clear = { 1, 0, 0, 0 } }
        end

        local t = view.targets
        view.composite = rhi.params {
            meshColor = t.meshColor, meshDepth = t.meshDepth,
            splatColor = t.splatColor, splatDepth = t.splatDepth,
            sdfColor = t.sdfColor, sdfDepth = t.sdfDepth,
            depthNear = 0.1, depthFar = 100, -- the planes every pass writes depth with
            -- With the effects, linear into a texture of its own; they encode it after.
            encodeGamma = (view.inset or effectsOn) and 0 or (srgb and 0 or 1),
            showMode = ctx.showMode or 0,
        }
        ctx.composites[#ctx.composites + 1] = view.composite
        local scale, shape = view.inset or 1, view.inset and "square" or nil
        if view.inset then
            view.image = rhi.render_target("rgba16f", view.inset, "square")
        end
        if effectsOn then
            view.litImage = rhi.render_target("rgba16f", scale, shape)
        end
        local present = graph:render_pass { name = view.name .. ": depth composite", target = view.litImage or view.image }
        present:draw {
            pipeline = (view.inset or effectsOn) and pipelines.compositeTexture or pipelines.compositeWindow,
            count = 3,
            params = view.composite,
        }

        if effectsOn then
            -- Each chain: the effects, blurred, blended with the frames before (reprojected
            -- by the last frame's camera, view.temporal), and kept for the next frame.
            view.temporal = rhi.params { prevCamera = view.cameraValue, historyValid = 0 }
            view.historyFrames = 0
            local inputs = { meshDepth = t.meshDepth, splatDepth = t.splatDepth, sdfDepth = t.sdfDepth,
                             litColor = view.litImage, meshMotion = t.meshMotion }
            local results = {}
            for _, chain in ipairs(effectChains(fx)) do
                local function target(format) return rhi.render_target(format, scale * chain.scale, shape) end
                local raw, blurred, resolved = target("rgba16f"), target("rgba16f"), target("rgba16f")
                local history, historyDepth = target("rgba16f"), target("r32f")
                local base = { view.block, ctx.shadowBlock, ctx.effectsBlock, view.temporal, inputs,
                               { aoEnabled = chain.ao and 1 or 0, giEnabled = chain.gi and 1 or 0 } }
                local function pass(name, pipeline, textures, threads)
                    local params = { table.unpack(base) }
                    params[#params + 1] = textures
                    local node = graph:dispatch {
                        name = view.name .. ": " .. chainLabel(chain) .. " " .. name,
                        pipeline = pipeline, params = params, threads = threads, timed = not view.inset,
                    }
                    if not view.inset then ctx.effectsNodes[#ctx.effectsNodes + 1] = node end
                end
                pass("effects", pipelines.effects, { effects = raw }, raw)
                pass("blur", pipelines.effectsBlur, { effectsIn = raw, effectsOut = blurred }, blurred)
                pass("temporal", pipelines.effectsTemporal,
                    { current = blurred, history = history, historyDepth = historyDepth, resolved = resolved }, resolved)
                pass("history", pipelines.effectsHistory,
                    { resolvedIn = resolved, history = history, historyDepth = historyDepth }, history)
                if chain.ao then results.ao = resolved end
                if chain.gi then results.gi = resolved end
                if not view.inset then ctx.effectsLabels[#ctx.effectsLabels + 1] = chainLabel(chain) end
            end
            view.apply = rhi.params {
                meshDepth = t.meshDepth, splatDepth = t.splatDepth, sdfDepth = t.sdfDepth,
                depthNear = 0.1, depthFar = 100,
                litColor = view.litImage, meshMotion = t.meshMotion,
                aoEffects = results.ao or results.gi, giEffects = results.gi or results.ao,
                giStrength = fx.gi and renderer.EFFECT_PARAMS.giStrength or 0,
                outputEncodeGamma = view.inset and 0 or (srgb and 0 or 1),
                showMode = ctx.showMode or 0,
            }
            ctx.composites[#ctx.composites + 1] = view.apply
            local apply = graph:render_pass { name = view.name .. ": effects", target = view.image }
            apply:draw {
                pipeline = view.inset and pipelines.applyTexture or pipelines.applyWindow,
                count = 3,
                params = view.apply,
            }
        end
    end

    call(systems, "addOverlays", ctx, graph)

    -- The insets, framed, over the main view.
    for _, view in ipairs(ctx.views) do
        if view.inset then
            view.framePass = graph:render_pass { name = view.name .. ": inset", viewport = { 0, 0, 1, 1 } }
            view.framePass:draw {
                pipeline = pipelines.frame,
                count = 3,
                params = {
                    source = view.image,
                    borderColor = { 0.85, 0.85, 0.9, 1 },
                    borderWidth = 2,
                    encodeGamma = srgb and 0 or 1,
                    decodeGamma = 0,
                },
            }
        end
    end

    -- The viewer's layers over everything: 2D overlays, the pause menu.
    for _, layer in ipairs(ctx.layers or {}) do layer:addPasses(graph) end
    return graph
end

-- What the depth composites show: 0 everything, 1 the meshes, 2 the splats, 3 the SDFs,
-- 4 the depth buffers; with the effects on, 5 the ambient occlusion, 6 the indirect light,
-- 7 the meshes' motion vectors.
function renderer.setShowMode(ctx, mode)
    ctx.showMode = mode
    for _, block in ipairs(ctx.composites or {}) do block.showMode = mode end
end

-- Every frame (paused too): the effects' noise turns, and each view's temporal block gets
-- the last frame's camera.
function renderer.updateFrame(ctx)
    if not ctx.effectsBlock then return end
    ctx.effectsFrame = (ctx.effectsFrame or 0) + 1
    ctx.effectsBlock.frameIndex = ctx.effectsFrame
    for _, view in ipairs(ctx.views) do
        if view.temporal then
            local now = view.cameraValue
            view.temporal.prevCamera = view.lastCamera or now
            -- The history holds something once the history pass has run twice.
            view.temporal.historyValid = view.historyFrames >= 2 and 1 or 0
            view.historyFrames = view.historyFrames + 1
            view.lastCamera = now
        end
    end
end

-- After a resize the effects' textures hold nothing: start their history over.
function renderer.resetHistory(ctx)
    for _, view in ipairs(ctx.views or {}) do
        view.historyFrames = 0
        view.lastCamera = nil
    end
end

-- The effects' GPU time in the main view (all their passes), for a title; nil without them.
function renderer.describeEffects(ctx)
    if not ctx.effectsNodes or #ctx.effectsNodes == 0 then return nil end
    local total = 0
    for _, node in ipairs(ctx.effectsNodes) do total = total + (node.gpu_time or 0) end
    return string.format("%s %.2f ms", table.concat(ctx.effectsLabels, ", "), total)
end

return renderer
