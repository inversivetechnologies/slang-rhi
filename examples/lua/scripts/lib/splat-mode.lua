-- Gaussian splatting: renders a 3D Gaussian splat scene (a .ply file from assets/) with
-- compute shaders and one blended draw.
--
-- The frame is a render graph, built once in init() and run by the host every frame:
--
--   reset count      compute, one thread: no splats drawn yet
--   preprocess       compute, one thread per splat (shaders/splat/preprocess.slang):
--                    picks the level of detail, projects each Gaussian to a screen-space
--                    ellipse, evaluates its view-dependent color, and packs the drawn ones'
--                    depth keys at the front of the sort's buffers
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
-- over the file's); preprocess draws the coarsest ones that are still small on screen.
--
--   Mouse drag      orbit the camera        Mouse wheel     zoom
--   [ / ]           splat size              F               flip the scene upside down
--   , / .           LOD threshold (pixels) down / up; down to 0: the file's splats only
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
    local blocks = {}
    local count = 0      -- the file's splats
    local entries = 0    -- with the merged ones
    local lodInfo = ""
    -- A merged splat stands in for its children once its bounds' radius is this many
    -- pixels or less on screen.
    local lodPixels = 3
    -- The shadows' threshold, in shadow map texels, as a fraction of lodPixels: the shadow
    -- map's texels are coarse, and its softening blurs what is left.
    local SHADOW_LOD_FACTOR = 2 / 3
    local showLevels = false

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
        return string.format("%s, LOD %s (, .)%s", lodInfo,
            lodPixels > 0 and string.format("%.2g px", lodPixels) or "off", showLevels and ", levels shown (/)" or "")
    end

    local function updateTitle()
        setTitle(string.format("%s, %d splats, size x%.2f | %s", file, count, splatScale, lodText()))
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

        -- The sort works on a power of two, at least one block of 1024: enough for every
        -- entry, though only the drawn ones are sorted.
        local sortCount = 1024
        while sortCount < entries do sortCount = sortCount * 2 end

        resources = {
            ply = ply,
            center = center,
            radius = ply.radius,
            sortCount = sortCount,
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
            resetShadow = rhi.compute_pipeline("splat/shadow-select.slang", "resetShadowMain"),
            selectShadow = rhi.compute_pipeline("splat/shadow-select.slang", "selectShadowMain"),
            shadow = rhi.render_pipeline { shader = "splat/shadow.slang", format = "rgba16f", blend = "accumulate" },
            shadowLayers = rhi.render_pipeline { shader = "splat/shadow.slang", fragment = "layersFragmentMain", format = "rgba16f", blend = "additive" },
            lighting = rhi.compute_pipeline("splat/lighting.slang", "lightSplatsMain"),
            casters = rhi.buffer(entries * 48), -- three float4s per splat, merged ones included
            shadowList = rhi.buffer(entries * 4), -- the splats the shadow passes draw
            shadowCount = rhi.buffer(16),
            projected = rhi.buffer(entries * 48), -- sizeof(ProjectedSplat)
            sortKeys = rhi.buffer(sortCount * 4),
            sortValues = rhi.buffer(sortCount * 4),
            drawCount = rhi.buffer(16), -- [0]: the splats drawn this frame
            entries = entries,
            -- The tree, or placeholders if there is none.
            lodBounds = lod and lod.bounds or rhi.buffer(32),
            lodLevel = lod and lod.level or rhi.buffer(4),
        }
        blocks.lod = rhi.params {
            lodEnabled = lod and 1 or 0,
            lodPixels = lodPixels,
            -- The shadows pick their level of detail from the light, in shadow map texels.
            lodShadowTexels = lodPixels * SHADOW_LOD_FACTOR,
            lodShowLevels = 0,
        }
        blocks.view = rhi.params {
            camera = cameraParams(),
            flipYZ = flip and 1 or 0,
            splatScale = splatScale,
            model = IDENTITY_MODEL,
        }
        -- How the splats are lit, where a graph lights them (addPasses' `lighting`).
        blocks.lighting = rhi.params { relight = 1, shadowStrength = 0.75, shadowBias = 0.08 }
        return resources
    end

    -- Where the splats are (after the flip, before any placement): { center, radius }.
    function splat.bounds()
        local r = splat.createResources()
        return { center = r.center, radius = r.radius }
    end

    -- Adds preprocessing, sorting and drawing the splats to a graph. `options`:
    --   name          a prefix for the passes' names
    --   view          a parameter block applied after the splats' own (e.g. a `camera`
    --                 and a `model` placing the splats), a list of blocks applied in
    --                 order, or nil
    --   lighting      if given, a list of parameter blocks with a light and shadow maps
    --                 (the scene's lightBlock() and shadowBlock()): the splats are then lit
    --                 by that light, and shadowed by the meshes and by each other
    --   target        the rgba16f texture to draw the splats' color into
    --   clear         the color to clear it to first
    --   depthTarget   if given, the splats are also drawn into this depth target
    -- Returns the dispatches and passes it added, in order (e.g. to switch them off).
    function splat.addPasses(g, options)
        local r = splat.createResources()
        local name = options.name or "splats"
        local nodes = {}
        local function add(node)
            nodes[#nodes + 1] = node
            return node
        end
        -- The view: one block, or a list of them (a plain table with an array part).
        local views = options.view
        if views == nil then
            views = {}
        elseif type(views) ~= "table" or getmetatable(views) ~= nil or views[1] == nil then
            views = { views }
        end
        local view = { blocks.view }
        for _, block in ipairs(views) do view[#view + 1] = block end

        local preprocessParams = {
            {
                plyData = r.ply.buffer,
                ply = plyLayout(r.ply),
                splatCount = r.entries, -- the file's splats and the merged ones
                sortCount = r.sortCount,
                projected = r.projected,
                sortKeys = r.sortKeys,
                sortValues = r.sortValues,
                drawCount = r.drawCount,
                lodBounds = r.lodBounds,
                lodLevel = r.lodLevel,
            },
            blocks.lod,
        }
        for _, block in ipairs(view) do preprocessParams[#preprocessParams + 1] = block end
        add(g:dispatch { name = name .. ": reset count", pipeline = r.resetCount, params = { drawCount = r.drawCount }, threads = { 1, 1, 1 } })
        add(g:dispatch { name = name .. ": preprocess", pipeline = r.preprocess, params = preprocessParams, threads = { r.entries, 1, 1 } })

        -- Light and shadows on the splats, if asked for: changes the colors preprocess just
        -- wrote, before the sort reorders the keys (shaders/splat/lighting.slang).
        if options.lighting then
            local params = { preprocessParams[1], blocks.view }
            for _, block in ipairs(options.lighting) do params[#params + 1] = block end
            -- The view after those: it can switch the splat maps on.
            for _, block in ipairs(views) do params[#params + 1] = block end
            params[#params + 1] = blocks.lighting
            -- One thread per drawn splat at most (preprocess packed them at the front).
            add(g:dispatch { name = name .. ": lighting", pipeline = r.lighting, params = params, threads = { count, 1, 1 } })
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

        -- At most one splat per file's splat is drawn (the cut through the tree).
        local drawParams = { projected = r.projected, sortKeys = r.sortKeys, sortValues = r.sortValues, drawCount = r.drawCount }
        local colorPass = add(g:render_pass { name = name .. ": color", target = options.target, clear = options.clear })
        colorPass:draw { pipeline = r.render, count = count * 6, params = drawParams }

        if options.depthTarget then
            local depthPass = add(g:render_pass {
                name = name .. ": depth",
                depth_target = options.depthTarget,
                color = false,
                clear = { 0, 0, 0, 0 }, -- clears the depth buffer to the far plane
            })
            depthPass:draw { pipeline = r.renderDepth, count = count * 6, params = drawParams }
        end
        return nodes
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
    function splat.addShadowPasses(g, options)
        local r = splat.createResources()
        local params = {
            {
                plyData = r.ply.buffer,
                ply = plyLayout(r.ply),
                splatCount = r.entries, -- the file's splats and the merged ones
                shadowCastersOut = r.casters,
            },
            blocks.view,
            options.view,
        }
        -- The splats don't move, so what the shadow passes need of them (center, opacity,
        -- covariance) is gathered once, and again when their size or the shader changes.
        local name = options.name or "splats"
        casterNodes[#casterNodes + 1] = g:dispatch {
            name = name .. ": shadow casters",
            pipeline = r.shadowCasters,
            params = params,
            threads = { r.entries, 1, 1 },
            once = true,
        }

        -- Every frame, as the light moves: which splats to draw, a cut through the levels
        -- of detail as seen from the light (shaders/splat/shadow-select.slang).
        g:dispatch {
            name = name .. ": shadow reset",
            pipeline = r.resetShadow,
            params = { shadowCount = r.shadowCount },
            threads = { 1, 1, 1 },
        }
        g:dispatch {
            name = name .. ": shadow select",
            pipeline = r.selectShadow,
            params = {
                {
                    splatCount = r.entries,
                    lodBounds = r.lodBounds,
                    shadowList = r.shadowList,
                    shadowCount = r.shadowCount,
                    shadowFaceSize = options.faceSize,
                },
                blocks.lod,
                blocks.view,
                options.view,
                options.light,
            },
            threads = { r.entries, 1, 1 },
        }

        -- One pass per cube face, into its cell of the atlas. The first clears the whole
        -- atlas: no optical depth, and the nearest splat as far as rgba16f goes.
        local size = options.faceSize
        for face = 0, 5 do
            local pass = g:render_pass {
                name = string.format("%s: shadow face %d", name, face),
                target = options.atlas,
                viewport = { (face % 3) * size, (face // 3) * size, size, size },
                clear = face == 0 and { 0, 0, 0, 60000 } or nil,
            }
            pass:draw {
                pipeline = r.shadow,
                count = count * 3, -- a triangle per splat
                params = { { shadowCasters = r.casters, shadowList = r.shadowList, shadowCount = r.shadowCount, face = face }, options.light },
            }
        end

        -- The deep opacity layers: the same splats again, now that the nearest distances
        -- are known, sorted into layers by how far past the nearest they are.
        for face = 0, 5 do
            local pass = g:render_pass {
                name = string.format("%s: shadow layers face %d", name, face),
                target = options.layers,
                viewport = { (face % 3) * size, (face // 3) * size, size, size },
                clear = face == 0 and { 0, 0, 0, 0 } or nil,
            }
            pass:draw {
                pipeline = r.shadowLayers,
                count = count * 3,
                params = {
                    { shadowCasters = r.casters, shadowList = r.shadowList, shadowCount = r.shadowCount, face = face, splatShadowMap = options.atlas },
                    options.light,
                },
            }
        end
    end

    -- Where graphs light the splats: 1 lights them by the light as albedo, 0 keeps their
    -- captured colors and only shadows them (see shaders/splat/lighting.slang).
    function splat.setRelight(amount)
        splat.createResources()
        blocks.lighting.relight = amount
    end

    -- The splats' own graph: drawn on a dark background, composited onto the window.
    function splat.init()
        splat.createResources()
        local image = rhi.render_target("rgba16f")
        local composite = rhi.render_pipeline { shader = "post/composite.slang" }

        graph = rhi.graph()
        splat.addPasses(graph, { target = image, clear = { 0.02, 0.02, 0.025, 1 } })

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
        updateTitle()
    end

    function splat.on_leave()
        rhi.set_graph(nil)
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
            if key == keys.PERIOD then
                lodPixels = lodPixels == 0 and 0.5 or math.min(64, lodPixels * 1.5)
            else
                lodPixels = lodPixels <= 0.5 and 0 or lodPixels / 1.5
            end
            blocks.lod.lodPixels = lodPixels
            blocks.lod.lodShadowTexels = lodPixels * SHADOW_LOD_FACTOR
            updateTitle()
            return
        elseif key == keys.SLASH and action == input.PRESS then
            showLevels = not showLevels
            blocks.lod.lodShowLevels = showLevels and 1 or 0
            updateTitle()
            return
        elseif key == keys.F and action == input.PRESS then
            flip = not flip
            local t = camera.target
            camera.target = { t[1], -t[2], -t[3] }
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
