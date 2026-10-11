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
--   2D overlays        the viewer's (lib/scene/overlays.lua), in their panels, all off but
--                      the one shown
--
-- Every surface reads one light block and one shadow block, which systems add to
-- (`shadowFields`): the SDFs' composition, whether there are splat shadows. So meshes,
-- splats and SDFs light and shadow each other the same way in every scene.
--
-- A system contributes through these optional functions, called in the systems' order:
--   shadowFields(ctx) -> table   addPrepasses(ctx, graph)   addShadowCasters(ctx, passes)
--   addShadowPasses(ctx, graph)  addOpaque(ctx, view, pass)  addSurfaces(ctx, graph, view)
--   addOverlays(ctx, graph)

local renderer = {}

local FACE = 512 -- shadow map texels per cube face; the atlases are 3 x 2 faces

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
function renderer.build(ctx, systems)
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

        local t = view.targets
        view.composite = rhi.params {
            meshColor = t.meshColor, meshDepth = t.meshDepth,
            splatColor = t.splatColor, splatDepth = t.splatDepth,
            sdfColor = t.sdfColor, sdfDepth = t.sdfDepth,
            depthNear = 0.1, depthFar = 100, -- the planes every pass writes depth with
            encodeGamma = view.inset and 0 or (srgb and 0 or 1),
            showMode = ctx.showMode or 0,
        }
        ctx.composites[#ctx.composites + 1] = view.composite
        if view.inset then
            view.image = rhi.render_target("rgba16f", view.inset, "square")
        end
        local present = graph:render_pass { name = view.name .. ": depth composite", target = view.image }
        present:draw {
            pipeline = view.inset and pipelines.compositeTexture or pipelines.compositeWindow,
            count = 3,
            params = view.composite,
        }
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

    if ctx.overlays then ctx.overlays:addPasses(graph) end
    return graph
end

-- What the depth composites show: 0 everything, 1 the meshes, 2 the splats, 3 the SDFs,
-- 4 the depth buffers.
function renderer.setShowMode(ctx, mode)
    ctx.showMode = mode
    for _, block in ipairs(ctx.composites or {}) do block.showMode = mode end
end

return renderer
