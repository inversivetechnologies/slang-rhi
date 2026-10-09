-- Gaussian splatting: renders a 3D Gaussian splat scene (a .ply file from assets/) with
-- compute shaders and one blended draw.
--
-- The frame is a render graph, built once in init() and run by the host every frame:
--
--   reset count      compute, one thread: no splats drawn yet
--   lod clear, lod histogram, lod pick
--                    compute (shaders/splat/lod.slang): the cut through the levels of
--                    detail that fits the budget
--   preprocess       compute, one thread per splat and instance
--                    (shaders/splat/preprocess.slang): skips what isn't in the cut,
--                    projects each Gaussian to a screen-space ellipse, evaluates its
--                    view-dependent color, and packs the drawn ones at the front of the
--                    buffers
--   pad              compute: keys that sort last after them, up to the sort's size
--   sort             compute, a bitonic sort of the keys (shaders/sort/bitonic.slang):
--                    one dispatch per long-range step, built here as a list of graph nodes;
--                    each skips what is past the drawn splats
--   splats           one draw of 6 vertices per splat, back to front, blended with
--                    premultiplied alpha into a texture (shaders/splat/render.slang)
--   composite        that texture onto the window (shaders/post/composite.slang)
--
-- The splats are blended in the color space they were trained in (display space, as the
-- captured photos are), in an rgba16f texture. The composite then converts for the window.
--
-- This file returns a constructor, as lib/scene-mode.lua does: splat.lua runs it on its own,
-- the showcase as its sixth mode. `setTitle(details)`, if given, shows the splat count.
--
-- Levels of detail: rhi.load_ply builds them for splat files (merged splats, in a tree
-- over the file's). Every frame, the GPU picks the finest cut through the tree that fits a
-- budget of splats, over all instances, by how large each looks from the camera
-- (shaders/splat/lod.slang). So the frame costs about the same whatever the view and
-- however many instances: this mode draws a grid of them.
--
--   Mouse drag      orbit the camera        Mouse wheel     zoom
--   [ / ]           splat size              F               flip the scene upside down
--   , / .           splat budget /1.25 / x1.25
--   - / =           fewer / more instances (1 x 1 up to 5 x 5)
--   M               mute / unmute the music (assets/audio/timelapse.mpeg, looped, while
--                   this mode shows)
--   C               clip the splats by moving spheres and boxes: carve them out / keep
--                   only what is inside them / off (shaders/splat/clip.slang)
--   /               tint the splats by LOD level

return function(setTitle, file)
    local splat = { name = "Gaussian Splats" }
    setTitle = setTitle or function(details)
        rhi.set_title("Gaussian Splats | " .. details)
    end
    file = file or "skull.ply"

    local camera = { yaw = 0.0, pitch = 0.15, distance = 3, target = { 0, 0, 0 }, fovY = math.rad(50) }
    local splatScale = 1.0
    local flip = true -- 3DGS scenes are usually y-down

    local graph
    local music -- this mode's own graph plays it (rhi.sound)
    local MUSIC_FILE = "audio/timelapse.mpeg"
    local blocks = {}
    local count = 0   -- the file's splats
    local entries = 0 -- with the merged ones
    local lodInfo = ""

    -- The levels of detail are held to a budget: every frame, the GPU picks the finest cut
    -- through the tree that draws at most this many splats, over all instances, by their
    -- size as seen from the camera (shaders/splat/lod.slang). The shadows have their own
    -- budget, seen from the light.
    local CAPACITY = 1 << 21 -- the most splats the buffers hold; the sort's size
    local SHADOW_CAPACITY = 1 << 20 -- the most the shadow maps draw
    local MIN_BUDGET = 50000
    local CAMERA_FINEST = 0.5 -- pixels
    local SHADOW_FINEST = 1.0 -- shadow map texels
    local budget = 1000000
    local function shadowBudget() return math.min(SHADOW_CAPACITY, budget // 2) end
    -- Views drawn with a share of the budget (addPasses' budgetScale): { block, scale }.
    local scaledBudgets = {}
    local function updateBudgets()
        blocks.lod.lodBudget = budget
        blocks.shadowLod.lodBudget = shadowBudget()
        for _, b in ipairs(scaledBudgets) do b.block.lodBudget = math.max(1024, math.floor(budget * b.scale)) end
    end
    local showLevels = false

    -- Instances, in this mode's own graph: a grid of copies, each turned its own way.
    local MAX_GRID = 5
    local grid = 3

    -- Clipping, in this mode's own graph: a field of spheres and boxes moving through the
    -- grid, cutting the splats per pixel (shaders/splat/clip.slang).
    local CLIP_MODES = { [0] = "off", [1] = "carve", [2] = "keep inside" }
    local clipMode = 1

    local function cameraParams()
        local cp, sp = math.cos(camera.pitch), math.sin(camera.pitch)
        local t = camera.target
        return {
            eye = {
                t[1] + camera.distance * cp * math.sin(camera.yaw),
                t[2] + camera.distance * sp,
                t[3] - camera.distance * cp * math.cos(camera.yaw),
            },
            target = t,
            fovY = camera.fovY,
        }
    end

    local function lodText()
        if lodInfo == "" then return "no LOD" end
        return string.format("%s, budget %.2fM splats (, .)%s", lodInfo, budget / 1e6,
            showLevels and ", levels shown (/)" or "")
    end

    local function updateTitle()
        local sound = music and (music.volume > 0 and "music (M)" or "muted (M)") or "no music"
        setTitle(string.format("%s x%d (- =), %d splats each, size x%.2f | %s | clip: %s (C) | %s", file, grid * grid,
            count, splatScale, lodText(), CLIP_MODES[clipMode], sound))
    end

    -- Where the named properties are in each record. 3DGS files store rot_0..3, scale_0..2,
    -- f_dc_0..2 and f_rest_* consecutively, so the first of each is enough.
    local function plyLayout(ply)
        local p = ply.properties
        local function offset(name)
            local value = p[name]
            if not value then error(file .. " has no '" .. name .. "' property", 0) end
            return value
        end
        local restCount = 0
        while p["f_rest_" .. restCount] do restCount = restCount + 1 end
        return {
            stride = ply.stride,
            position = offset("x"),
            rotation = offset("rot_0"),
            scale = offset("scale_0"),
            opacity = offset("opacity"),
            dc = offset("f_dc_0"),
            rest = restCount > 0 and offset("f_rest_0") or 0,
            restCount = restCount,
        }
    end

    -- ---------------------------------------------------------------------------------
    -- Building graphs
    --
    -- Made of pieces other graphs can use too (the fusion example draws the splats into
    -- the mesh scene): createResources() loads the file and makes what every graph shares,
    -- addPasses() adds the per-frame passes to a graph.
    -- ---------------------------------------------------------------------------------

    local resources

    -- The identity placement: the splats where the file has them (after the flip).
    local IDENTITY_MODEL = { position = { 0, 0, 0 }, yaw = 0, scale = 1 }

    -- An instances block: `list` of { position, yaw, scale }, as ply.slang reads them.
    local function instanceParams(list)
        local floats = {}
        for _, m in ipairs(list) do
            local p = m.position
            for _, v in ipairs { p[1], p[2], p[3], m.yaw, m.scale, 0, 0, 0 } do floats[#floats + 1] = v end
        end
        return { instances = rhi.buffer(floats), instanceCount = #list }
    end

    -- The grid's instances: `n` x `n` copies, `spacing` apart, each turned its own way
    -- about its own center (the splats' center, which isn't the file's origin).
    local function gridInstances(n)
        local r = resources
        local c = r.center
        -- (`radius` is the splats' spread, not their bounds: horns reach about twice that.)
        local spacing = r.radius * 4.5
        local list = {}
        for gz = 0, n - 1 do
            for gx = 0, n - 1 do
                local yaw = (gx * 2 + gz * 3) * 0.9
                local cy, sy = math.cos(yaw), math.sin(yaw)
                -- position = where its center goes - its center turned by yaw.
                local turned = { cy * c[1] + sy * c[3], c[2], -sy * c[1] + cy * c[3] }
                local at = { (gx - (n - 1) / 2) * spacing, 0, (gz - (n - 1) / 2) * spacing }
                list[#list + 1] = {
                    position = { at[1] + c[1] - turned[1], c[2] - turned[2], at[3] + c[3] - turned[3] },
                    yaw = yaw,
                    scale = 1,
                }
            end
        end
        return list
    end

    function splat.createResources()
        if resources then return resources end
        local ply = rhi.load_ply(file)
        count = ply.count
        -- With levels of detail, the merged splats follow the file's in the buffer.
        local lod = ply.lod
        entries = lod and lod.count or count
        if lod then
            lodInfo = string.format("%d merged in %d levels", lod.nodes, lod.levels)
        end

        -- Frame the splats: look at their center from a distance that fits most of them.
        local center = flip and { ply.center[1], -ply.center[2], -ply.center[3] } or ply.center
        camera.target = center
        camera.distance = math.max(0.5, ply.radius * 3.0)

        resources = {
            ply = ply,
            center = center,
            radius = ply.radius,
            sortCount = CAPACITY,
            entries = entries,
            -- Levels of detail: the budget's histogram and pick (shaders/splat/lod.slang).
            lodClear = rhi.compute_pipeline("splat/lod.slang", "lodClearMain"),
            lodHistogram = rhi.compute_pipeline("splat/lod.slang", "lodHistogramCameraMain"),
            lodPick = rhi.compute_pipeline("splat/lod.slang", "lodPickMain"),
            preprocess = rhi.compute_pipeline("splat/preprocess.slang", "preprocessMain"),
            resetCount = rhi.compute_pipeline("splat/preprocess.slang", "resetCountMain"),
            pad = rhi.compute_pipeline("splat/preprocess.slang", "padMain"),
            sortStep = rhi.compute_pipeline("sort/bitonic.slang", "sortStepMain"),
            sortBlocks = rhi.compute_pipeline("sort/bitonic.slang", "sortBlocksMain"),
            render = rhi.render_pipeline { shader = "splat/render.slang", format = "rgba16f", blend = "premultiplied" },
            -- The same quads into a depth buffer only: no color target.
            renderDepth = rhi.render_pipeline { shader = "splat/render.slang", fragment = "depthFragmentMain", format = "none", depth = true },
            -- Shadows: the splats' Gaussians drawn into a translucent shadow map, see
            -- shaders/splat/shadow.slang.
            shadowCasters = rhi.compute_pipeline("splat/shadow-casters.slang", "shadowCastersMain"),
            lodHistogramLight = rhi.compute_pipeline("splat/shadow-select.slang", "lodHistogramLightMain"),
            resetShadow = rhi.compute_pipeline("splat/shadow-select.slang", "resetShadowMain"),
            selectShadow = rhi.compute_pipeline("splat/shadow-select.slang", "selectShadowMain"),
            shadow = rhi.render_pipeline { shader = "splat/shadow.slang", format = "rgba16f", blend = "accumulate" },
            shadowLayers = rhi.render_pipeline { shader = "splat/shadow.slang", fragment = "layersFragmentMain", format = "rgba16f", blend = "additive" },
            lighting = rhi.compute_pipeline("splat/lighting.slang", "lightSplatsMain"),
            casters = rhi.buffer(entries * 48), -- three float4s per splat, merged ones included
            shadowList = rhi.buffer(SHADOW_CAPACITY * 8), -- the splats (and instances) the shadow passes draw
            shadowCount = rhi.buffer(16),
            -- Per drawn splat: up to CAPACITY of them.
            projected = rhi.buffer(CAPACITY * 48), -- sizeof(ProjectedSplat)
            drawnSplats = rhi.buffer(CAPACITY * 8),
            sortKeys = rhi.buffer(CAPACITY * 4),
            sortValues = rhi.buffer(CAPACITY * 4),
            drawCount = rhi.buffer(16), -- [0]: the splats drawn this frame
        }
        -- The tree (or placeholders if there is none), and the budget's histogram and pick.
        blocks.lodData = rhi.params {
            lodEnabled = lod and 1 or 0,
            lodLeafCount = count,
            lodBounds = lod and lod.bounds or rhi.buffer(16),
            lodParents = lod and lod.parents or rhi.buffer(4),
            lodLevel = lod and lod.level or rhi.buffer(4),
            lodHistogram = rhi.buffer((160 + 1) * 4), -- kLodBins + 1 in lod.slang
            lodChoice = rhi.buffer(16),
        }
        -- The cuts go no finer than what the camera (half a pixel) or the shadow map (a
        -- texel) resolves: the radius of a merged splat's bounds, below which it does.
        blocks.lod = rhi.params { lodBudget = budget, lodFinest = CAMERA_FINEST, lodShowLevels = 0 }
        blocks.shadowLod = rhi.params { lodBudget = shadowBudget(), lodFinest = SHADOW_FINEST }
        -- One instance where the file puts it, for graphs that place the splats with a
        -- `model` (the fusion example); this mode's own graph has a grid.
        blocks.singleInstance = rhi.params(instanceParams { IDENTITY_MODEL })
        -- No clipping, for graphs that don't ask for it.
        blocks.noClip = rhi.params { clipMode = 0, clipShapeCount = 0, clipShapes = rhi.buffer(48) }
        blocks.view = rhi.params {
            camera = cameraParams(),
            flipYZ = flip and 1 or 0,
            splatScale = splatScale,
            model = IDENTITY_MODEL,
        }
        -- How the splats are lit, where a graph lights them (addPasses' `lighting`).
        -- Shadow bias: a little, plus half the splat's own extent (a merged splat stands for
        -- a cluster), plus a texel and a half (see shaders/splat/lighting.slang).
        blocks.lighting = rhi.params {
            relight = 1,
            showVisibility = 0,
            shadowStrength = 0.75,
            shadowBias = 0.02,
            shadowBiasExtent = 0.5,
            shadowBiasTexels = 1.5,
        }
        return resources
    end

    -- Where the splats are (after the flip, before any placement): { center, radius }.
    function splat.bounds()
        local r = splat.createResources()
        return { center = r.center, radius = r.radius }
    end

    -- For graphs that place the splats themselves (the scene system, lib/scene/):
    --
    -- An instances block for addPasses / addShadowPasses, from a list of placements
    -- { position = {x, y, z}, yaw = radians, scale = s } (applied to the file's splats
    -- after the flip, as ply.slang places them); and its instance count.
    function splat.instanceBlock(list)
        splat.createResources()
        local params = instanceParams(list)
        return rhi.params(params), params.instanceCount
    end

    -- A clip block for addPasses / addShadowPasses: `mode` 0 none, 1 carve the shapes out,
    -- 2 keep only what is inside them; `shapes` as shaders/splat/clip.slang lays them out
    -- (three float4s each: center and kind (0 sphere, 1 box), size and turning speed,
    -- movement and its speed).
    function splat.clipBlock(mode, shapes)
        local floats = {}
        for _, s in ipairs(shapes) do
            for _, v in ipairs(s) do floats[#floats + 1] = v end
        end
        if #floats == 0 then floats = { 0, 0, 0, 0 } end
        return rhi.params { clipMode = mode, clipShapes = rhi.buffer(floats), clipShapeCount = #shapes }
    end

    -- The splat budget (the most splats drawn per view), as , and . set it.
    function splat.setBudget(splats)
        splat.createResources()
        budget = math.max(MIN_BUDGET, math.min(CAPACITY, math.floor(splats)))
        updateBudgets()
    end

    -- A view option as a list of blocks: one block, a list of them (a plain table with an
    -- array part), or nil.
    local function viewList(views)
        if views == nil then return {} end
        if type(views) ~= "table" or getmetatable(views) ~= nil or views[1] == nil then return { views } end
        return views
    end

    -- The budget's three steps, for a view: clear the histogram, fill it (one thread per
    -- splat and instance), pick the cut. `params` are the blocks the histogram sees.
    local function addLodPick(g, name, histogramPipeline, params, instanceCount, budgetBlock, add)
        local r = resources
        add(g:dispatch { name = name .. ": lod clear", pipeline = r.lodClear, params = blocks.lodData, threads = { 161, 1, 1 } })
        local histogram = add(g:dispatch {
            name = name .. ": lod histogram",
            pipeline = histogramPipeline,
            params = params,
            threads = { r.entries, instanceCount, 1 },
        })
        add(g:dispatch { name = name .. ": lod pick", pipeline = r.lodPick, params = { blocks.lodData, budgetBlock }, threads = { 1, 1, 1 } })
        return histogram
    end

    -- Adds preprocessing, sorting and drawing the splats to a graph. `options`:
    --   name          a prefix for the passes' names
    --   view          a parameter block applied after the splats' own (e.g. a `camera`
    --                 and a `model` placing the splats), a list of blocks applied in
    --                 order, or nil
    --   instances     an instances block (instanceParams), or nil for one instance
    --   instanceCount how many instances it has (1 if nil)
    --   budgetScale   the share of the splat budget this view gets (1 if nil): a small
    --                 view needs fewer splats for the same detail
    --   clip          a clip block (clipMode, clipShapes, clipShapeCount: see
    --                 shaders/splat/clip.slang), or nil for none
    --   lighting      if given, a list of parameter blocks with a light and shadow maps
    --                 (the scene's lightBlock() and shadowBlock()): the splats are then lit
    --                 by that light, and shadowed by the meshes and by each other
    --   target        the rgba16f texture to draw the splats' color into
    --   clear         the color to clear it to first
    --   depthTarget   if given, the splats are also drawn into this depth target
    --   depthClear    false: keep what is in it (other splats drawn before), not clear it
    -- Returns the dispatches and passes it added, in order (e.g. to switch them off), and
    -- those whose thread counts follow the number of instances.
    function splat.addPasses(g, options)
        local r = splat.createResources()
        local name = options.name or "splats"
        local nodes, perInstance = {}, {}
        local function add(node)
            nodes[#nodes + 1] = node
            return node
        end
        local views = viewList(options.view)
        local instances = options.instances or blocks.singleInstance
        local clip = options.clip or blocks.noClip
        local instanceCount = options.instanceCount or 1

        -- What every per-splat step sees: the splats, the tree, the instances, the view.
        local splatParams = {
            {
                plyData = r.ply.buffer,
                ply = plyLayout(r.ply),
                splatCount = r.entries, -- the file's splats and the merged ones
                sortCount = r.sortCount,
                projected = r.projected,
                drawnSplats = r.drawnSplats,
                sortKeys = r.sortKeys,
                sortValues = r.sortValues,
                drawCount = r.drawCount,
            },
            blocks.lodData,
            blocks.lod,
            instances,
            blocks.view,
        }
        for _, block in ipairs(views) do splatParams[#splatParams + 1] = block end
        splatParams[#splatParams + 1] = clip

        add(g:dispatch { name = name .. ": reset count", pipeline = r.resetCount, params = { drawCount = r.drawCount }, threads = { 1, 1, 1 } })
        local budgetBlock = blocks.lod
        if options.budgetScale and options.budgetScale ~= 1 then
            budgetBlock = rhi.params { lodBudget = budget, lodFinest = CAMERA_FINEST }
            scaledBudgets[#scaledBudgets + 1] = { block = budgetBlock, scale = options.budgetScale }
            updateBudgets()
        end
        perInstance[#perInstance + 1] = addLodPick(g, name, r.lodHistogram, splatParams, instanceCount, budgetBlock, add)
        perInstance[#perInstance + 1] = add(g:dispatch {
            name = name .. ": preprocess",
            pipeline = r.preprocess,
            params = splatParams,
            threads = { r.entries, instanceCount, 1 },
        })

        -- Light and shadows on the splats, if asked for: changes the colors preprocess just
        -- wrote, before the sort reorders the keys (shaders/splat/lighting.slang).
        if options.lighting then
            local params = { splatParams[1], instances, blocks.view }
            for _, block in ipairs(options.lighting) do params[#params + 1] = block end
            -- The view after those: it can switch the splat maps on.
            for _, block in ipairs(views) do params[#params + 1] = block end
            params[#params + 1] = blocks.lighting
            -- One thread per drawn splat at most (preprocess packed them at the front).
            add(g:dispatch { name = name .. ": lighting", pipeline = r.lighting, params = params, threads = { r.sortCount, 1, 1 } })
        end

        add(g:dispatch {
            name = name .. ": pad",
            pipeline = r.pad,
            params = { sortKeys = r.sortKeys, sortValues = r.sortValues, drawCount = r.drawCount, sortCount = r.sortCount },
            threads = { r.sortCount, 1, 1 },
        })

        -- The bitonic sort, as laid out in bitonic.slang: sort each block of 1024, then for
        -- every longer sequence length k, the long-range steps one dispatch each, and the
        -- short-range ones in a single block dispatch.
        local sortBuffers = rhi.params { sortKeys = r.sortKeys, sortValues = r.sortValues, sortActive = r.drawCount }
        local pairThreads = { r.sortCount // 2, 1, 1 } -- one thread per compared pair
        add(g:dispatch { name = name .. ": sort blocks", pipeline = r.sortBlocks, params = { sortBuffers, { sortStage = 0 } }, threads = pairThreads })
        local k = 2048
        while k <= r.sortCount do
            local j = k // 2
            while j >= 1024 do
                add(g:dispatch {
                    name = string.format("%s: sort k=%d j=%d", name, k, j),
                    pipeline = r.sortStep,
                    params = { sortBuffers, { sortK = k, sortJ = j } },
                    threads = pairThreads,
                })
                j = j // 2
            end
            add(g:dispatch {
                name = string.format("%s: sort k=%d blocks", name, k),
                pipeline = r.sortBlocks,
                params = { sortBuffers, { sortStage = k } },
                threads = pairThreads,
            })
            k = k * 2
        end

        -- Six vertices per slot; the ones past this frame's count draw nothing.
        -- The draws also read the splats themselves, to clip per pixel those that need it.
        local drawParams = { splatParams[1], instances, blocks.view }
        for _, block in ipairs(views) do drawParams[#drawParams + 1] = block end
        drawParams[#drawParams + 1] = clip
        local colorPass = add(g:render_pass { name = name .. ": color", target = options.target, clear = options.clear })
        colorPass:draw { pipeline = r.render, count = r.sortCount * 6, params = drawParams }

        if options.depthTarget then
            local depthPass = add(g:render_pass {
                name = name .. ": depth",
                depth_target = options.depthTarget,
                color = false,
                -- Clears the depth buffer to the far plane, unless other splats are in it.
                clear = options.depthClear ~= false and { 0, 0, 0, 0 } or nil,
            })
            depthPass:draw { pipeline = r.renderDepth, count = r.sortCount * 6, params = drawParams }
        end
        return nodes, perInstance
    end

    -- Shadows, for graphs that draw the splats into a scene with a light (the fusion
    -- example). The splats dim the light like a translucent medium: each is drawn as its
    -- Gaussian, seen from the light, into a translucent shadow map that the lit pass reads
    -- (see shaders/splat/shadow.slang).
    local casterNodes = {} -- rerun when the splats change size

    -- Adds the passes that draw that map. `options`:
    --   name       a prefix for the passes' names
    --   view       a parameter block applied after the splats' own (the `model`)
    --   light      the light's parameter block (the scene's)
    --   atlas      the rgba16f texture to draw the map into, layers the one for its deep
    --              opacity layers, faceSize the size of their cube-face cells
    --   clip       a clip block, as for addPasses (nil: none)
    --   instances, instanceCount   as for addPasses (nil: one instance, the `model`'s)
    --   clearMaps  false: keep what other splats drew into the maps, not clear them
    function splat.addShadowPasses(g, options)
        local r = splat.createResources()
        local name = options.name or "splats"
        local views = viewList(options.view)
        local instances = options.instances or blocks.singleInstance
        local instanceCount = options.instanceCount or 1
        local clearMaps = options.clearMaps ~= false
        local clip = options.clip or blocks.noClip

        -- The splats don't change, so what the shadow passes need of them (center,
        -- opacity, covariance, in the file's frame) is gathered once, and again when their
        -- size or the shader changes.
        local casterParams = {
            {
                plyData = r.ply.buffer,
                ply = plyLayout(r.ply),
                splatCount = r.entries, -- the file's splats and the merged ones
                shadowCastersOut = r.casters,
            },
            blocks.view,
        }
        casterNodes[#casterNodes + 1] = g:dispatch {
            name = name .. ": shadow casters",
            pipeline = r.shadowCasters,
            params = casterParams,
            threads = { r.entries, 1, 1 },
            once = true,
        }

        -- Every frame, as the light moves: which splats to draw, the cut through the
        -- levels of detail that fits the shadows' budget, seen from the light
        -- (shaders/splat/shadow-select.slang).
        local selectParams = {
            {
                splatCount = r.entries,
                shadowList = r.shadowList,
                shadowCount = r.shadowCount,
                shadowCapacity = SHADOW_CAPACITY,
                shadowFaceSize = options.faceSize,
            },
            blocks.lodData,
            instances,
            blocks.view,
        }
        for _, block in ipairs(views) do selectParams[#selectParams + 1] = block end
        selectParams[#selectParams + 1] = options.light
        selectParams[#selectParams + 1] = clip
        local function ignore(node) return node end
        addLodPick(g, name .. ": shadow", r.lodHistogramLight, selectParams, instanceCount, blocks.shadowLod, ignore)
        g:dispatch { name = name .. ": shadow reset", pipeline = r.resetShadow, params = { shadowCount = r.shadowCount }, threads = { 1, 1, 1 } }
        g:dispatch { name = name .. ": shadow select", pipeline = r.selectShadow, params = selectParams, threads = { r.entries, instanceCount, 1 } }

        -- What the shadow passes' vertex shader needs: the picked splats, and how to place
        -- them (the instances and the `model`).
        local drawBlocks = { instances, blocks.view }
        for _, block in ipairs(views) do drawBlocks[#drawBlocks + 1] = block end
        drawBlocks[#drawBlocks + 1] = options.light
        drawBlocks[#drawBlocks + 1] = clip
        local function drawParams(own)
            local list = { own }
            for _, block in ipairs(drawBlocks) do list[#list + 1] = block end
            return list
        end

        -- One pass per cube face, into its cell of the atlas. The first clears the whole
        -- atlas: no optical depth, and the nearest splat as far as rgba16f goes.
        local size = options.faceSize
        local picked = { shadowCasters = r.casters, shadowList = r.shadowList, shadowCount = r.shadowCount, shadowCapacity = SHADOW_CAPACITY }
        for face = 0, 5 do
            local pass = g:render_pass {
                name = string.format("%s: shadow face %d", name, face),
                target = options.atlas,
                viewport = { (face % 3) * size, (face // 3) * size, size, size },
                clear = (face == 0 and clearMaps) and { 0, 0, 0, 60000 } or nil,
            }
            local own = { face = face }
            for key, value in pairs(picked) do own[key] = value end
            pass:draw {
                pipeline = r.shadow,
                count = SHADOW_CAPACITY * 3, -- a triangle per picked splat
                params = drawParams(own),
            }
        end

        -- The deep opacity layers: the same splats again, now that the nearest distances
        -- are known, sorted into layers by how far past the nearest they are.
        for face = 0, 5 do
            local pass = g:render_pass {
                name = string.format("%s: shadow layers face %d", name, face),
                target = options.layers,
                viewport = { (face % 3) * size, (face // 3) * size, size, size },
                clear = (face == 0 and clearMaps) and { 0, 0, 0, 0 } or nil,
            }
            local own = { face = face, splatShadowMap = options.atlas }
            for key, value in pairs(picked) do own[key] = value end
            pass:draw {
                pipeline = r.shadowLayers,
                count = SHADOW_CAPACITY * 3,
                params = drawParams(own),
            }
        end
    end

    -- Where graphs light the splats: 1 lights them by the light as albedo, 0 keeps their
    -- captured colors and only shadows them (see shaders/splat/lighting.slang).
    function splat.setRelight(amount)
        splat.createResources()
        blocks.lighting.relight = amount
    end

    -- Where graphs light the splats: true shows only the light reaching each splat.
    function splat.setShowVisibility(show)
        splat.createResources()
        blocks.lighting.showVisibility = show and 1 or 0
    end

    -- Tints the splats by their level of detail (as / does).
    function splat.setShowLevels(show)
        splat.createResources()
        blocks.lod.lodShowLevels = show and 1 or 0
    end

    -- Multiplies every splat's size (as [ and ] do); 1 is as trained.
    function splat.setSplatScale(scale)
        splat.createResources()
        splatScale = scale
        blocks.view.splatScale = scale
        for _, node in ipairs(casterNodes) do node:rerun() end
    end

    function splat.budget() return budget end

    -- The splats' own graph: drawn on a dark background, composited onto the window.
    local instanceNodes = {} -- this graph's dispatches over every instance

    -- The camera, far enough back and high enough up to see the whole grid.
    local function fitGrid()
        camera.distance = resources.radius * (3.0 + 3.2 * (grid - 1))
        camera.pitch = grid > 1 and 0.45 or 0.15
    end

    -- The clip field for the grid: spheres and boxes, sized by the splats and moving across
    -- the whole grid (as clip.slang lays shapes out: three float4s each).
    local function gridClipShapes(n)
        local r = resources
        local c, R = r.center, r.radius
        local spacing = R * 4.5
        local reach = math.max(spacing, (n - 1) / 2 * spacing + R) -- half the grid, and more
        local SPHERE, BOX = 0, 1
        local shapes = {
            -- type, offset from the center, size, turning speed, movement, movement speed
            { SPHERE, { 0, 0.3 * R, 0 }, { 1.7 * R, 0, 0 }, 0, { reach, 0, 0 }, 0.35 },
            { SPHERE, { 0, -0.2 * R, 0.5 * spacing }, { 1.3 * R, 0, 0 }, 0, { 0, 0, reach }, 0.5 },
            { SPHERE, { 0.5 * spacing, 0.8 * R, -0.5 * spacing }, { 1.0 * R, 0, 0 }, 0, { 0, 1.2 * R, 0 }, 0.9 },
            -- A tall pillar and a flat slab across the whole grid, turning as they go.
            { BOX, { -0.5 * spacing, 0, 0 }, { 0.8 * R, 3.5 * R, 0.8 * R }, 0.7, { 0, 0, reach }, 0.3 },
            { BOX, { 0, 0, 0 }, { reach + 2 * R, 0.35 * R, reach + 2 * R }, -0.25, { 0, 1.6 * R, 0 }, 0.6 },
        }
        local floats = {}
        for _, s in ipairs(shapes) do
            local at, size, move = s[2], s[3], s[5]
            for _, v in ipairs {
                c[1] + at[1], c[2] + at[2], c[3] + at[3], s[1],
                size[1], size[2], size[3], s[4],
                move[1], move[2], move[3], s[6],
            } do floats[#floats + 1] = v end
        end
        return { clipShapes = rhi.buffer(floats), clipShapeCount = #shapes, clipMode = clipMode }
    end

    -- The grid's instances block, for `grid` x `grid` copies; the camera backs off to see
    -- them all.
    local function setGrid(n)
        grid = n
        local r = resources
        local params = instanceParams(gridInstances(n))
        blocks.grid:set(params)
        blocks.clip:set(gridClipShapes(n))
        for _, node in ipairs(instanceNodes) do node.threads = { r.entries, params.instanceCount, 1 } end
        fitGrid()
        blocks.view.camera = cameraParams()
    end

    function splat.init()
        local r = splat.createResources()
        -- Looped, from the start; on_enter and on_leave play and pause it.
        music = rhi.sound(MUSIC_FILE, { loop = true })
        local image = rhi.render_target("rgba16f")
        local composite = rhi.render_pipeline { shader = "post/composite.slang" }
        local params = instanceParams(gridInstances(grid))
        blocks.grid = rhi.params(params)
        blocks.clip = rhi.params(gridClipShapes(grid))
        fitGrid()
        blocks.view.camera = cameraParams()

        graph = rhi.graph()
        local _, perInstance = splat.addPasses(graph, {
            target = image,
            clear = { 0.02, 0.02, 0.025, 1 },
            instances = blocks.grid,
            instanceCount = params.instanceCount,
            clip = blocks.clip,
        })
        instanceNodes = perInstance

        local present = graph:render_pass { name = "composite" }
        present:draw {
            pipeline = composite,
            count = 3,
            params = {
                source = image,
                borderColor = { 0, 0, 0, 1 },
                borderWidth = 0,
                encodeGamma = 0,
                decodeGamma = rhi.window_srgb() and 1 or 0,
            },
        }
    end

    function splat.on_enter()
        rhi.set_graph(graph)
        -- The music goes on where it was left.
        if music then music:play() end
        updateTitle()
    end

    function splat.on_leave()
        rhi.set_graph(nil)
        if music then music:pause() end
    end

    -- Input: changes parameter blocks only; the graph itself never changes.

    local function updateView()
        blocks.view:set {
            camera = cameraParams(),
            flipYZ = flip and 1 or 0,
            splatScale = splatScale,
        }
    end

    function splat.on_key(key, action)
        if action == input.RELEASE then return end
        if key == keys.RIGHT_BRACKET then
            splatScale = math.min(4, splatScale * 1.1)
        elseif key == keys.LEFT_BRACKET then
            splatScale = math.max(0.05, splatScale / 1.1)
        elseif key == keys.COMMA or key == keys.PERIOD then
            local factor = key == keys.PERIOD and 1.25 or 1 / 1.25
            budget = math.max(MIN_BUDGET, math.min(CAPACITY, math.floor(budget * factor + 0.5)))
            updateBudgets()
            updateTitle()
            return
        elseif (key == keys.MINUS or key == keys.EQUAL) and action == input.PRESS then
            if not blocks.grid then return end
            setGrid(math.max(1, math.min(MAX_GRID, grid + (key == keys.EQUAL and 1 or -1))))
            updateTitle()
            return
        elseif key == keys.SLASH and action == input.PRESS then
            showLevels = not showLevels
            blocks.lod.lodShowLevels = showLevels and 1 or 0
            updateTitle()
            return
        elseif key == keys.M and action == input.PRESS then
            if not music then return end
            music.volume = music.volume > 0 and 0 or 1
            updateTitle()
            return
        elseif key == keys.C and action == input.PRESS then
            if not blocks.clip then return end
            clipMode = (clipMode + 1) % 3
            blocks.clip.clipMode = clipMode
            updateTitle()
            return
        elseif key == keys.F and action == input.PRESS then
            flip = not flip
            local t = camera.target
            camera.target = { t[1], -t[2], -t[3] }
            resources.center = { resources.center[1], -resources.center[2], -resources.center[3] }
            if blocks.grid then setGrid(grid) end
        else
            return
        end
        updateView()
        updateTitle()
        for _, node in ipairs(casterNodes) do node:rerun() end
    end

    local drag

    function splat.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return end
        drag = action == input.PRESS and { input.mouse() } or nil
    end

    function splat.on_mouse_move(x, y)
        if not drag then return end
        camera.yaw = camera.yaw - (x - drag[1]) * 0.006
        camera.pitch = math.max(-1.5, math.min(1.5, camera.pitch + (y - drag[2]) * 0.006))
        drag = { x, y }
        updateView()
    end

    function splat.on_scroll(x, y)
        camera.distance = math.max(0.05, camera.distance * (y > 0 and 0.9 or 1.1))
        updateView()
    end

    return splat
end
