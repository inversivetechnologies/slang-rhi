-- Caching an SDF composition: the DAG of lib/sdf.lua, evaluated node by node at every
-- step of every ray (shaders/sdf/sdf-dag.slang), against the same DAG baked once into 3D
-- textures and sampled with trilinear filtering (shaders/sdf/sdf-bake.slang,
-- shaders/sdf/sdf-cache.slang). One compute pass draws either (shaders/sdf/sdf-compare.slang),
-- with soft shadows and ambient occlusion that march the field too. The host times that
-- pass, and the bake, on the GPU with timestamps (the graph nodes' `timed`, `gpu_time`):
-- frame times stop at the display's refresh rate, and say nothing below it.
--
-- The composition is a sculpture of N shapes on a spiral, smoothly joined: its DAG has
-- about 2N nodes, and evaluating it costs about that much per sample. The cache costs one
-- texture fetch per sample, whatever N -- but holds no detail finer than its voxels, and
-- has to be baked again when the composition changes.
--
-- The graph, built once in init():
--
--   bake       compute, one thread per voxel, `once`: rerun when the composition or the
--              resolution changes
--   compare    compute, one thread per pixel: the sculpture, a floor and the sky
--   present    the image onto the window
--
--   V          the DAG / the cache / the cache's error (in voxels, where the DAG hits)
--   - / =      fewer / more shapes (4 to 128)
--   [ / ]      cache resolution /2 x2 (32 to 256 voxels a side)
--   B          benchmark: the compare pass's GPU time with the DAG and the cache in turn
--   Space      stop / start the camera turning
--   Mouse drag orbit the camera     Mouse wheel   zoom

local sdf = rhi.include("lib/sdf.lua")
local settings = rhi.include("lib/settings.lua") -- the controls (look sensitivity)

local COMPLEXITIES = { 4, 8, 16, 32, 64, 128 }
local RESOLUTIONS = { 32, 64, 128, 256 }
local SOURCES = { "DAG", "cache", "cache error" }
local EXTENT = 1.25 -- the cache's cube: this far to either side of the origin
local FLOOR = -0.95

-- A color around the color wheel.
local function hue(h)
    local function channel(n)
        local k = (n + h * 6) % 6
        return 0.25 + 0.65 * math.max(0, math.min(1, math.min(k, 4 - k)))
    end
    return channel(5), channel(3), channel(1)
end

-- The sculpture: a core and `n` shapes on a rising spiral around it, every one smoothly
-- joined to the rest. It fits within about 1 of the origin, inside the cache's cube.
local function buildComposition(n)
    local shapes = { sdf.sphere(0.3):color(0.92, 0.88, 0.8) }
    for i = 1, n do
        local f = (i - 1) / math.max(n - 1, 1)
        local angle = i * 2.39996 -- the golden angle: evenly spread, however many
        local radius = 0.25 + 0.5 * math.sqrt(f)
        local y = -0.75 + 1.45 * f
        local size = 0.16 - 0.08 * f
        local shape
        if i % 3 == 0 then
            shape = sdf.sphere(size)
        elseif i % 3 == 1 then
            shape = sdf.box(size, size * 0.6, size):rotate("y", angle):rotate("x", 0.5)
        else
            shape = sdf.capsule(size * 0.5, { 0, -size, 0 }, { 0, size, 0 }):rotate("z", angle)
        end
        local r, g, b = hue(f)
        shapes[#shapes + 1] = shape:color(r, g, b):translate(math.cos(angle) * radius, y, math.sin(angle) * radius)
    end
    return sdf.smoothUnion(0.06, table.unpack(shapes))
end

return function(setTitle)
    local mode = { name = "SDF Cache" }
    setTitle = setTitle or function(details)
        rhi.set_title("SDF Cache | " .. details)
    end

    local camera = { yaw = 0.6, pitch = 0.32, distance = 4.2, target = { 0, -0.1, 0 }, fovY = math.rad(45) }
    local turning = true
    local complexity = 4 -- index into COMPLEXITIES: 32 shapes
    local resolution = 3 -- index into RESOLUTIONS: 128 voxels a side
    local source = 1
    local nodeCount = 0

    local graph, bakeNode, compareNode
    local blocks = {}

    -- The benchmark's state and results.
    local benchmark, results = nil, nil
    local titleTimer = 0

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

    local function cacheBytes()
        local n = RESOLUTIONS[resolution]
        return n * n * n * (2 + 4) -- r16f distance and rgba8 color
    end

    local function updateTitle()
        local n = RESOLUTIONS[resolution]
        local function ms(node)
            local t = node and node.gpu_time
            return t and string.format("%.2f ms", t) or "-"
        end
        local text = string.format("%s (V) | %d shapes, %d nodes (- =) | cache %d^3, %.1f MB ([ ]), baked in %s | GPU %s",
            SOURCES[source], COMPLEXITIES[complexity], nodeCount, n, cacheBytes() / 1048576, ms(bakeNode),
            ms(compareNode))
        if benchmark then
            text = text .. " | benchmarking..."
        elseif results then
            text = text .. string.format(" | B: DAG %.2f ms, cache %.2f ms (x%.1f)", results[1], results[2],
                results[1] / results[2])
        else
            text = text .. " | B: benchmark"
        end
        setTitle(text)
    end

    -- ---------------------------------------------------------------------------------
    -- The composition and the cache
    -- ---------------------------------------------------------------------------------

    -- Compiles the sculpture of the current complexity into the DAG block.
    local function setComposition()
        local program = sdf.compile(buildComposition(COMPLEXITIES[complexity]))
        nodeCount = program.nodeCount
        blocks.dag:set {
            sdfNodes = rhi.buffer(program.floats),
            sdfNodeCount = program.nodeCount,
            sdfResultSlot = program.resultSlot,
        }
        results = nil
        if bakeNode then bakeNode:rerun() end
    end

    -- New textures at the current resolution, and a bake into them.
    local function setResolution()
        local n = RESOLUTIONS[resolution]
        local distance = rhi.texture { width = n, height = n, depth = n, format = "r16f" }
        local color = rhi.texture { width = n, height = n, depth = n, format = "rgba8" }
        blocks.cache:set {
            sdfCacheDistance = distance,
            sdfCacheDistanceOut = distance,
            sdfCacheColor = color,
            sdfCacheColorOut = color,
            sdfCacheResolution = n,
        }
        results = nil
        if bakeNode then
            bakeNode.threads = { n, n, n }
            bakeNode:rerun()
        end
    end

    function mode.init()
        blocks.dag = rhi.params { sdfNodes = rhi.buffer(32), sdfNodeCount = 0, sdfResultSlot = 0, smoothScale = 1 }
        blocks.cache = rhi.params {
            sdfCacheSampler = rhi.sampler { filter = "linear", address = "clamp" },
            sdfCacheExtent = EXTENT,
        }
        setComposition()
        setResolution()
        local sun = { 0.55, 0.75, -0.35 }
        local length = math.sqrt(sun[1] ^ 2 + sun[2] ^ 2 + sun[3] ^ 2)
        blocks.view = rhi.params {
            camera = cameraParams(),
            sdfSource = source - 1,
            sunDirection = { sun[1] / length, sun[2] / length, sun[3] / length },
            floorHeight = FLOOR,
        }

        local image = rhi.render_target("rgba16f")
        local n = RESOLUTIONS[resolution]
        graph = rhi.graph()
        bakeNode = graph:dispatch {
            name = "bake",
            pipeline = rhi.compute_pipeline("sdf/sdf-bake.slang", "bakeMain"),
            params = { blocks.dag, blocks.cache },
            threads = { n, n, n },
            once = true,
            timed = true,
        }
        compareNode = graph:dispatch {
            name = "compare",
            pipeline = rhi.compute_pipeline("sdf/sdf-compare.slang", "compareMain"),
            params = { { image = image }, blocks.dag, blocks.cache, blocks.view },
            threads = image, -- one thread per pixel
            timed = true,
        }
        local present = graph:render_pass { name = "present" }
        present:draw {
            pipeline = rhi.render_pipeline { shader = "post/composite.slang" },
            count = 3,
            params = {
                source = image,
                borderColor = { 0, 0, 0, 1 },
                borderWidth = 0,
                encodeGamma = rhi.window_srgb() and 0 or 1,
                decodeGamma = 0,
            },
        }
    end

    function mode.on_enter()
        rhi.set_graph(graph)
        updateTitle()
    end

    function mode.on_leave()
        rhi.set_graph(nil)
        benchmark = nil
    end

    local function setSource(index)
        source = index
        blocks.view.sdfSource = source - 1
    end

    -- The benchmark: each source in turn, a few frames to settle (the GPU time comes back a
    -- few frames late, smoothed), then many to average.
    local WARMUP, MEASURE = 40, 180

    function mode.update(_, dt)
        if turning then
            camera.yaw = camera.yaw + dt * 0.25
            blocks.view.camera = cameraParams()
        end
        if benchmark then
            local b = benchmark
            b.frame = b.frame + 1
            if b.frame > WARMUP then b.total = b.total + (compareNode.gpu_time or 0) end
            if b.frame == WARMUP + MEASURE then
                b.times[b.step] = b.total / MEASURE
                b.step = b.step + 1
                if b.step > 2 then
                    results = b.times
                    benchmark = nil
                    setSource(b.restore)
                else
                    b.frame, b.total = 0, 0
                    setSource(b.step)
                end
                updateTitle()
            end
        end
        titleTimer = titleTimer + dt
        if titleTimer > 0.25 then
            titleTimer = 0
            updateTitle()
        end
    end

    function mode.on_key(key, action)
        if action ~= input.PRESS then return end
        if key == keys.V then
            setSource(source % #SOURCES + 1)
        elseif key == keys.MINUS or key == keys.EQUAL then
            complexity = math.max(1, math.min(#COMPLEXITIES, complexity + (key == keys.EQUAL and 1 or -1)))
            setComposition()
        elseif key == keys.LEFT_BRACKET or key == keys.RIGHT_BRACKET then
            resolution = math.max(1, math.min(#RESOLUTIONS, resolution + (key == keys.RIGHT_BRACKET and 1 or -1)))
            setResolution()
        elseif key == keys.B then
            benchmark = { step = 1, frame = 0, total = 0, times = {}, restore = source }
            setSource(1)
        elseif key == keys.SPACE then
            turning = not turning
        else
            return
        end
        updateTitle()
    end

    local drag

    function mode.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return end
        drag = action == input.PRESS and { input.mouse() } or nil
    end

    function mode.on_mouse_move(x, y)
        if not drag then return end
        local dx, dy = settings.mouseLook(x - drag[1], y - drag[2]) -- the controls' sensitivity
        camera.yaw = camera.yaw - dx * 0.006
        camera.pitch = math.max(-0.2, math.min(1.4, camera.pitch + dy * 0.006))
        drag = { x, y }
        blocks.view.camera = cameraParams()
    end

    function mode.on_scroll(_, y)
        camera.distance = math.max(1.6, math.min(10, camera.distance * (y > 0 and 0.9 or 1.1)))
        blocks.view.camera = cameraParams()
    end

    return mode
end
