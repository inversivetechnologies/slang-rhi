-- Hybrid radiance cascades GI (the renderer's, with "Global illumination: Radiance
-- cascades"): no screen-space temporal accumulation; every frame's cascades are its own.
--
--   phase 1  the G-buffer (normals, view depth) and a Hi-Z pyramid: shaders/gi/gbuffer.slang
--   phase 2  the global SDF: a distance volume with albedo about the camera, rebuilt every
--            frame from the bodies and the SDF composition (shaders/gi/global-sdf*.slang)
--   phase 3  world-space probes (DDGI) about the camera, tracing the global SDF: the far
--            field, the cascades' last (shaders/gi/ddgi*.slang)
--   phase 4  screen-space radiance cascades on the G-buffer's surfaces: Hi-Z marching per
--            interval, the global SDF where the screen can't say (shaders/gi/rc.slang)
--   phase 5  merged coarse to fine (the bilinear fix; depth- and normal-aware), the probes
--            beyond the last
--   phase 6  cascade 0 cosine-integrated into irradiance, with the ambient visibility from
--            the near cascades' transmittance; the effects' apply pass upsamples it
--
-- For the main view only (an inset gets no GI: its light is the direct light alone). The
-- debug views (shaders/gi/debug.slang) are drawn over the main view's final image, chosen
-- by the viewer's V (gi.setDebug).

local gi = {}

gi.HIZ_LEVELS = 5 -- half resolution down to a 32nd

-- The global SDF: voxels a side, their size (world units), the narrow band.
gi.GSDF_RESOLUTION = 96
gi.GSDF_VOXEL = 0.2
gi.GSDF_BAND = 0.8

-- The probes: how many each way, how far apart, what a frame's rays keep of the last
-- (world space: a probe's own history), and the rays a probe traces a frame.
gi.DDGI_COUNTS = { 16, 8, 16 }
gi.DDGI_SPACING = 1.0
gi.DDGI_HYSTERESIS = 0.95
gi.DDGI_RAYS = 96 -- ddgi-update.slang's kRays

-- The cascades: how many, cascade 0's directions a side, its interval (world units; 4 x
-- longer each cascade), and its probe spacing (pixels) by the effects' quality.
gi.CASCADES = 4
gi.DIRECTIONS0 = 4
gi.INTERVAL0 = 0.12
gi.SPACING0 = { Half = 8, Mixed = 4, Full = 4 }
gi.MERGE = true -- false: each cascade its own interval alone (to look at them)

-- The modes of shaders/gi/debug.slang, by name (the viewer's V lists them).
gi.DEBUG_MODES = { "normals", "Hi-Z", "global SDF", "DDGI", "cascade 0", "cascade 1", "cascade 2", "cascade 3", "albedo" }

local pipelines

local function makePipelines()
    if pipelines then return pipelines end
    pipelines = {
        gbuffer = rhi.compute_pipeline("gi/gbuffer.slang", "gbufferMain"),
        hizFirst = rhi.compute_pipeline("gi/gbuffer.slang", "hizFirstMain"),
        hizDown = rhi.compute_pipeline("gi/gbuffer.slang", "hizDownMain"),
        debug = rhi.render_pipeline { shader = "gi/debug.slang" },
        gsdfClear = rhi.compute_pipeline("gi/global-sdf-bake.slang", "clearMain"),
        gsdfBodies = rhi.compute_pipeline("gi/global-sdf-bake.slang", "bodiesMain"),
        gsdfComposition = rhi.compute_pipeline("gi/global-sdf-bake.slang", "compositionMain"),
        gsdfResolve = rhi.compute_pipeline("gi/global-sdf-bake.slang", "resolveMain"),
        ddgiTrace = rhi.compute_pipeline("gi/ddgi-update.slang", "traceMain"),
        ddgiIrradiance = rhi.compute_pipeline("gi/ddgi-update.slang", "irradianceMain"),
        ddgiDepth = rhi.compute_pipeline("gi/ddgi-update.slang", "depthMain"),
        ddgiStamp = rhi.compute_pipeline("gi/ddgi-update.slang", "stampMain"),
        cascade = rhi.compute_pipeline("gi/rc.slang", "cascadeMain"),
        probes = rhi.compute_pipeline("gi/rc.slang", "probesMain"),
        integrate = rhi.compute_pipeline("gi/rc.slang", "integrateMain"),
    }
    return pipelines
end

-- The GI's passes for `view` (the main view), after its depth composite: `t` its targets.
-- Returns { irradiance = texture (rgb: indirect light, a: ambient visibility) } for the
-- effects' apply pass.
function gi.addView(ctx, graph, view, t, fx)
    local p = makePipelines()
    local g = { view = view }
    ctx.gi = g
    local depths = { meshDepth = t.meshDepth, splatDepth = t.splatDepth, sdfDepth = t.sdfDepth,
                     depthNear = 0.1, depthFar = 100 }
    g.depths = depths

    -- Phase 1: the G-buffer and the Hi-Z pyramid.
    g.gbuffer = rhi.render_target("rgba16f")
    g.albedo = rhi.render_target("rgba16f")
    graph:dispatch {
        name = view.name .. ": GI G-buffer",
        pipeline = p.gbuffer,
        params = { view.block, depths, { gbuffer = g.gbuffer, albedoOut = g.albedo, meshAlbedo = t.meshAlbedo,
                   sdfAlbedo = t.sdfAlbedo, sdfColor = t.sdfColor, splatColor = t.splatColor,
                   splatDepthBlend = t.splatDepthBlend } },
        threads = g.gbuffer,
    }
    g.hiz = {}
    for level = 0, gi.HIZ_LEVELS - 1 do
        g.hiz[level] = rhi.render_target("r32f", 0.5 ^ (level + 1))
        graph:dispatch {
            name = view.name .. ": GI Hi-Z " .. level,
            pipeline = level == 0 and p.hizFirst or p.hizDown,
            params = level == 0 and { gbufferIn = g.gbuffer, hizOut = g.hiz[0] }
                or { hizIn = g.hiz[level - 1], hizOut = g.hiz[level] },
            threads = g.hiz[level],
        }
    end

    -- Phase 2: the global SDF.
    local R = gi.GSDF_RESOLUTION
    g.gsdf = {
        volume = rhi.texture { width = R, height = R, depth = R, format = "rgba16f" },
        voxels = rhi.buffer(R * R * R * 4), -- distance (16 bits) and albedo (5:6:5)
    }
    g.gsdfBlock = rhi.params {
        gsdfOrigin = { 0, 0, 0 }, gsdfVoxel = gi.GSDF_VOXEL, gsdfResolution = R, gsdfBand = gi.GSDF_BAND,
        gsdfVoxels = g.gsdf.voxels,
        gsdfVolume = g.gsdf.volume, gsdfSampler = rhi.sampler { filter = "linear", address = "clamp" },
        compositionCorner = { 0, 0, 0 }, compositionSize = { 0, 0, 0 },
    }
    g.gsdfClearNode = graph:dispatch { name = "GI global SDF: clear", pipeline = p.gsdfClear, params = { g.gsdfBlock },
                                       threads = { R * R * R, 1, 1 }, timed = true }
    -- The composition first (stored), then the bodies (where nearer).
    if ctx.sdf then
        local n = math.ceil(2 * (ctx.sdf.radius + gi.GSDF_BAND) / gi.GSDF_VOXEL) + 2
        g.compositionSize = n
        graph:dispatch { name = "GI global SDF: composition", pipeline = p.gsdfComposition,
                         params = { ctx.shadowBlock, g.gsdfBlock }, threads = { n, n, n } }
    end
    g.groups = {}
    for _, d in ipairs(ctx.mesh and ctx.mesh.draws or {}) do
        local block = rhi.params { bodies = d.group.buffer, bodyCount = 0,
                                   bodyIsSphere = d.mesh == ctx.mesh.meshes.sphere and 1 or 0 }
        g.groups[#g.groups + 1] = { group = d.group, block = block }
        local params = { ctx.shadowBlock, g.gsdfBlock, block }
        graph:dispatch { name = "GI global SDF: bodies", pipeline = p.gsdfBodies, params = params,
                         threads = { d.group.capacity, R, 1 } }
    end
    g.gsdfNode = graph:dispatch { name = "GI global SDF: resolve", pipeline = p.gsdfResolve,
                     params = { g.gsdfBlock, { gsdfVolumeOut = g.gsdf.volume } }, threads = { R, R, R }, timed = true }

    -- Phase 3: the probes, traced through the global SDF just built.
    local C = gi.DDGI_COUNTS
    local probes = C[1] * C[2] * C[3]
    local rows = math.ceil(probes / 64)
    local bg = ctx.settings.background or { 0.015, 0.018, 0.025 }
    g.ddgi = {
        irradiance = rhi.texture { width = 64 * 8, height = rows * 8, format = "rgba16f" },
        radiance = rhi.texture { width = 64 * 8, height = rows * 8, format = "rgba16f" },
        depth = rhi.texture { width = 64 * 16, height = rows * 16, format = "rgba16f" },
        rays = rhi.buffer(probes * gi.DDGI_RAYS * 16),
        stamps = rhi.buffer(probes * 4),
    }
    g.ddgiGrid = rhi.params {
        ddgiOrigin = { 0, 0, 0 }, ddgiSpacing = gi.DDGI_SPACING, ddgiCounts = C, ddgiBaseCell = { 0, 0, 0 },
        ddgiHysteresis = gi.DDGI_HYSTERESIS, ddgiSky = { bg[1] * 0.5, bg[2] * 0.5, bg[3] * 0.5 },
        ddgiRays = g.ddgi.rays, ddgiProbeStamps = g.ddgi.stamps,
    }
    g.ddgiSample = rhi.params {
        ddgiIrradiance = g.ddgi.irradiance, ddgiRadiance = g.ddgi.radiance, ddgiDepth = g.ddgi.depth,
        ddgiSampler = rhi.sampler { filter = "linear", address = "clamp" },
    }
    g.ddgiNode = graph:dispatch { name = "GI probes: trace", pipeline = p.ddgiTrace,
                     params = { ctx.light, ctx.shadowBlock, g.gsdfBlock, g.ddgiGrid, g.ddgiSample },
                     threads = { gi.DDGI_RAYS, probes, 1 }, timed = true }
    graph:dispatch { name = "GI probes: irradiance", pipeline = p.ddgiIrradiance,
                     params = { g.ddgiGrid, { irradianceOut = g.ddgi.irradiance, radianceOut = g.ddgi.radiance } },
                     threads = { 64, probes, 1 } }
    graph:dispatch { name = "GI probes: depth", pipeline = p.ddgiDepth,
                     params = { g.ddgiGrid, { depthOut = g.ddgi.depth } }, threads = { 256, probes, 1 } }
    graph:dispatch { name = "GI probes: stamps", pipeline = p.ddgiStamp, params = { g.ddgiGrid }, threads = { probes, 1, 1 } }

    -- Phases 4 and 5: the cascades, coarsest first, each merged with the one above.
    local spacing0 = gi.SPACING0[fx and fx.quality or "Half"] or 8
    local scale = gi.DIRECTIONS0 / spacing0 -- every cascade's atlas: probes x directions
    g.cascades, g.probes = {}, {}
    for i = 0, gi.CASCADES - 1 do
        g.cascades[i] = rhi.render_target("rgba16f", scale)
        g.probes[i] = rhi.render_target("rgba32f", 1 / (spacing0 * 2 ^ i)) -- a texel a probe
    end
    g.rcInputs = { gbuffer = g.gbuffer, hiz0 = g.hiz[0], hiz1 = g.hiz[1], hiz2 = g.hiz[2], hiz3 = g.hiz[3],
                   hiz4 = g.hiz[4], litImage = view.litImage,
                   probes0 = g.probes[0], probes1 = g.probes[1], probes2 = g.probes[2], probes3 = g.probes[3] }
    local function rcParams(i)
        return { rcCascade = i, rcCascadeCount = gi.CASCADES, rcSpacing0 = spacing0, rcDirections0 = gi.DIRECTIONS0,
                 rcInterval0 = gi.INTERVAL0, rcMerge = gi.MERGE and 1 or 0 }
    end
    -- Each cascade's probes: a mean normal per cell (rc.slang's probesMain).
    for i = 0, gi.CASCADES - 1 do
        local own = rcParams(i)
        own.probesOut = g.probes[i]
        own.gbuffer = g.gbuffer
        graph:dispatch { name = view.name .. ": GI probes " .. i, pipeline = p.probes,
                         params = { view.block, depths, own }, threads = g.probes[i] }
    end
    local shared = { view.block, ctx.light, ctx.shadowBlock, depths, g.gsdfBlock, g.ddgiGrid, g.ddgiSample, g.rcInputs }
    g.cascadeNodes = {}
    for i = gi.CASCADES - 1, 0, -1 do
        local params = { table.unpack(shared) }
        local own = rcParams(i)
        own.cascadeOut = g.cascades[i]
        own.cascadeAbove = g.cascades[i + 1] or g.cascades[0] -- the top reads none
        params[#params + 1] = own
        g.cascadeNodes[#g.cascadeNodes + 1] = graph:dispatch {
            name = view.name .. ": GI cascade " .. i, pipeline = p.cascade, params = params,
            threads = g.cascades[i], timed = true,
        }
    end

    -- Phase 6: cascade 0 integrated, at its probes (one a cell of spacing0 pixels) -- into
    -- the splats' cache's texture, if they have one (the renderer's view.splatGi).
    g.irradiance = view.splatGi or rhi.render_target("rgba16f", 1 / spacing0)
    local params = { table.unpack(shared) }
    local own = rcParams(0)
    own.cascade0, own.irradianceOut = g.cascades[0], g.irradiance
    params[#params + 1] = own
    g.integrateNode = graph:dispatch { name = view.name .. ": GI integrate", pipeline = p.integrate, params = params,
                                       threads = g.irradiance, timed = true }
    return { irradiance = g.irradiance, normals = g.gbuffer, albedo = g.albedo }
end

-- The debug view, over the main view's final image (after everything but the overlays).
function gi.addDebug(ctx, graph)
    local g = ctx.gi
    if not g then return end
    local srgb = rhi.window_srgb()
    g.debugBlock = rhi.params {
        giDebugMode = 0, giDebugLevel = 2,
        outputEncodeGamma = srgb and 0 or 1,
        gbuffer = g.gbuffer,
        hiz0 = g.hiz[0], hiz1 = g.hiz[1], hiz2 = g.hiz[2], hiz3 = g.hiz[3], hiz4 = g.hiz[4],
        cascade0 = g.cascades[0], cascade1 = g.cascades[1], cascade2 = g.cascades[2], cascade3 = g.cascades[3],
        albedo = g.albedo,
    }
    g.debugPass = graph:render_pass { name = "GI debug" }
    g.debugPass:draw { pipeline = pipelines.debug, count = 3,
                       params = { g.view.block, ctx.light, g.depths, g.gsdfBlock, g.ddgiGrid, g.ddgiSample, g.debugBlock } }
    g.debugPass.enabled = (ctx.giDebugMode or 0) > 0
    if g.debugPass.enabled then g.debugBlock.giDebugMode = ctx.giDebugMode end
end

-- Every frame (from the renderer's updateFrame): the global SDF follows the camera, and
-- takes the bodies there are now.
function gi.updateFrame(ctx)
    local g = ctx.gi
    if not g then return end
    local eye = g.view.cameraValue.eye
    local snap = 4 * gi.GSDF_VOXEL
    local half = 0.5 * gi.GSDF_RESOLUTION * gi.GSDF_VOXEL
    local origin = {}
    for k = 1, 3 do origin[k] = math.floor(eye[k] / snap + 0.5) * snap - half end
    g.gsdfBlock.gsdfOrigin = origin
    if ctx.sdf and g.compositionSize then
        local corner = {}
        for k = 1, 3 do
            local lo = ctx.sdf.origin[k] - ctx.sdf.radius - gi.GSDF_BAND
            corner[k] = math.max(0, math.floor((lo - origin[k]) / gi.GSDF_VOXEL))
        end
        g.gsdfBlock.compositionCorner = corner
        local n = g.compositionSize
        g.gsdfBlock.compositionSize = { n, n, n }
    end
    for _, entry in ipairs(g.groups) do entry.block.bodyCount = entry.group.count end

    -- The probes follow the camera a cell at a time, the camera in the grid's middle.
    local C, s = gi.DDGI_COUNTS, gi.DDGI_SPACING
    local cell, probeOrigin = {}, {}
    for k = 1, 3 do
        cell[k] = math.floor(eye[k] / s) - C[k] // 2
        probeOrigin[k] = cell[k] * s
    end
    g.ddgiGrid.ddgiBaseCell = cell
    g.ddgiGrid.ddgiOrigin = probeOrigin
end

-- The GI's GPU time (the probes, the cascades, the integration), for a title.
function gi.describe(ctx)
    local g = ctx.gi
    if not g or not g.integrateNode then return nil end
    local cascades = 0
    for _, node in ipairs(g.cascadeNodes) do cascades = cascades + (node.gpu_time or 0) end
    -- The global SDF's clear and resolve (its bake is between them, untimed), the probes'
    -- trace, the cascades with their integration.
    local sdf = (g.gsdfClearNode.gpu_time or 0) + (g.gsdfNode.gpu_time or 0)
    return string.format("GI: SDF %.2f, probes %.2f, cascades %.2f ms", sdf, g.ddgiNode.gpu_time or 0,
        cascades + (g.integrateNode.gpu_time or 0))
end

-- Debug view `mode` (an index of DEBUG_MODES; 0: none).
function gi.setDebug(ctx, mode)
    ctx.giDebugMode = mode
    local g = ctx.gi
    if not g or not g.debugPass then return end
    g.debugPass.enabled = mode > 0
    g.debugBlock.giDebugMode = mode
end

return gi
