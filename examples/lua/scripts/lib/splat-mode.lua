-- Gaussian splatting: renders a 3D Gaussian splat scene (a .ply file from assets/) with
-- compute shaders and one blended draw.
--
-- The frame is a render graph, built once in init() and run by the host every frame:
--
--   preprocess       compute, one thread per splat (shaders/splat/preprocess.slang):
--                    projects each Gaussian to a screen-space ellipse, evaluates its
--                    view-dependent color, and writes a depth key for sorting
--   sort             compute, a bitonic sort of the keys (shaders/sort/bitonic.slang):
--                    one dispatch per long-range step, built here as a list of graph nodes
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
--   Mouse drag      orbit the camera        Mouse wheel     zoom
--   [ / ]           splat size              F               flip the scene upside down

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
    local count = 0

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

    local function updateTitle()
        setTitle(string.format("%s, %d splats, size x%.2f", file, count, splatScale))
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

        -- Frame the splats: look at their center from a distance that fits most of them.
        local center = flip and { ply.center[1], -ply.center[2], -ply.center[3] } or ply.center
        camera.target = center
        camera.distance = math.max(0.5, ply.radius * 3.0)

        -- The sort works on a power of two, at least one block of 1024.
        local sortCount = 1024
        while sortCount < count do sortCount = sortCount * 2 end

        resources = {
            ply = ply,
            center = center,
            radius = ply.radius,
            sortCount = sortCount,
            preprocess = rhi.compute_pipeline("splat/preprocess.slang", "preprocessMain"),
            sortStep = rhi.compute_pipeline("sort/bitonic.slang", "sortStepMain"),
            sortBlocks = rhi.compute_pipeline("sort/bitonic.slang", "sortBlocksMain"),
            render = rhi.render_pipeline { shader = "splat/render.slang", format = "rgba16f", blend = "premultiplied" },
            -- The same quads into a depth buffer only: no color target.
            renderDepth = rhi.render_pipeline { shader = "splat/render.slang", fragment = "depthFragmentMain", format = "none", depth = true },
            -- Shadows: the splats' Gaussians drawn into a translucent shadow map, see
            -- shaders/splat/shadow.slang.
            shadowCasters = rhi.compute_pipeline("splat/shadow-casters.slang", "shadowCastersMain"),
            shadow = rhi.render_pipeline { shader = "splat/shadow.slang", format = "rgba16f", blend = "accumulate" },
            shadowLayers = rhi.render_pipeline { shader = "splat/shadow.slang", fragment = "layersFragmentMain", format = "rgba16f", blend = "additive" },
            lighting = rhi.compute_pipeline("splat/lighting.slang", "lightSplatsMain"),
            casters = rhi.buffer(count * 48), -- three float4s per splat
            projected = rhi.buffer(count * 48), -- sizeof(ProjectedSplat)
            sortKeys = rhi.buffer(sortCount * 4),
            sortValues = rhi.buffer(sortCount * 4),
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
    --                 and a `model` placing the splats), or nil
    --   lighting      if given, a list of parameter blocks with a light and shadow maps
    --                 (the scene's lightBlock() and shadowBlock()): the splats are then lit
    --                 by that light, and shadowed by the meshes and by each other
    --   target        the rgba16f texture to draw the splats' color into
    --   clear         the color to clear it to first
    --   depthTarget   if given, the splats are also drawn into this depth target
    function splat.addPasses(g, options)
        local r = splat.createResources()
        local name = options.name or "splats"
        local view = { blocks.view, options.view }

        local preprocessParams = {
            {
                plyData = r.ply.buffer,
                ply = plyLayout(r.ply),
                splatCount = count,
                sortCount = r.sortCount,
                projected = r.projected,
                sortKeys = r.sortKeys,
                sortValues = r.sortValues,
            },
        }
        for _, block in ipairs(view) do preprocessParams[#preprocessParams + 1] = block end
        g:dispatch { name = name .. ": preprocess", pipeline = r.preprocess, params = preprocessParams, threads = { r.sortCount, 1, 1 } }

        -- Light and shadows on the splats, if asked for: changes the colors preprocess just
        -- wrote, before the sort reorders the keys (shaders/splat/lighting.slang).
        if options.lighting then
            local params = { preprocessParams[1], blocks.view }
            for _, block in ipairs(options.lighting) do params[#params + 1] = block end
            params[#params + 1] = options.view -- after those: it can switch the splat maps on
            params[#params + 1] = blocks.lighting
            g:dispatch { name = name .. ": lighting", pipeline = r.lighting, params = params, threads = { count, 1, 1 } }
        end

        -- The bitonic sort, as laid out in bitonic.slang: sort each block of 1024, then for
        -- every longer sequence length k, the long-range steps one dispatch each, and the
        -- short-range ones in a single block dispatch.
        local sortBuffers = rhi.params { sortKeys = r.sortKeys, sortValues = r.sortValues }
        local pairThreads = { r.sortCount // 2, 1, 1 } -- one thread per compared pair
        g:dispatch { name = name .. ": sort blocks", pipeline = r.sortBlocks, params = { sortBuffers, { sortStage = 0 } }, threads = pairThreads }
        local k = 2048
        while k <= r.sortCount do
            local j = k // 2
            while j >= 1024 do
                g:dispatch {
                    name = string.format("%s: sort k=%d j=%d", name, k, j),
                    pipeline = r.sortStep,
                    params = { sortBuffers, { sortK = k, sortJ = j } },
                    threads = pairThreads,
                }
                j = j // 2
            end
            g:dispatch {
                name = string.format("%s: sort k=%d blocks", name, k),
                pipeline = r.sortBlocks,
                params = { sortBuffers, { sortStage = k } },
                threads = pairThreads,
            }
            k = k * 2
        end

        local drawParams = { projected = r.projected, sortKeys = r.sortKeys, sortValues = r.sortValues }
        local colorPass = g:render_pass { name = name .. ": color", target = options.target, clear = options.clear }
        colorPass:draw { pipeline = r.render, count = count * 6, params = drawParams }

        if options.depthTarget then
            local depthPass = g:render_pass {
                name = name .. ": depth",
                depth_target = options.depthTarget,
                color = false,
                clear = { 0, 0, 0, 0 }, -- clears the depth buffer to the far plane
            }
            depthPass:draw { pipeline = r.renderDepth, count = count * 6, params = drawParams }
        end
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
                splatCount = count,
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
            threads = { count, 1, 1 },
            once = true,
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
                params = { { shadowCasters = r.casters, face = face }, options.light },
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
                params = { { shadowCasters = r.casters, face = face, splatShadowMap = options.atlas }, options.light },
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
