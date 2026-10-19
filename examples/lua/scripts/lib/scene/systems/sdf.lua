-- SDF compositions: raymarched in every view (sdf/raymarch.slang), lit and shadowed like
-- the meshes, and casting soft shadows on everything. Every entity's composition, placed by
-- its transform, joins one composition for the scene (a union), compiled into one DAG
-- (lib/sdf.lua, sdf/sdf-dag.slang) -- and, with "cache", baked into 3D textures once and
-- sampled from them (sdf/sdf-cache.slang): see "Example: caching an SDF" in the README.
--
--   "sdf": { "shape": { ...a node... }, "cache": 0 (the DAG) or 32..256 (voxels a side),
--            "sharpness": 8 (of the soft shadows' edges),
--            "blend": 0 (how smoothly the entities' shapes join one another: the union of
--                        all of them is smooth over the largest entity's blend) }
--
-- The raymarching is timed on the GPU (its graph node's gpu_time). For behaviors,
-- ctx.sdf has setSource (0 the DAG, 1 the cache, 2 the cache's error, where the DAG hits),
-- setResolution (a new cache, baked again), setSmoothScale (every blend radius times this)
-- and gpuTime() (the main view's raymarching, in milliseconds).
--
-- A node is one primitive or one operation, with optional modifiers:
--
--   { "sphere": r }   { "box": [w, h, d] }   { "cube": s }   { "ellipsoid": [rx, ry, rz] }
--   { "capsule": { "radius": r, "a": [x, y, z], "b": [x, y, z] } }
--   { "cylinder": { "radius": r, "height": h } }   { "prism": { "sides": n, "height": h } }
--   { "union": [nodes] }   { "intersect": [nodes] }   { "subtract": [a, b] }
--     with "smooth": k for a smooth blend over about k
--   modifiers on any node: "position", "rotation" (degrees), "scale", "color"
--
-- (Sizes are whole, as for meshes: a box of size 1 reaches 0.5 to either side.)

local sdf = rhi.include("lib/sdf.lua")
local T = rhi.include("lib/scene/transform.lua")

local system = {
    name = "sdf",
    components = {
        sdf = {
            shape = { "object", nil, true },
            cache = { "number", 0 },
            sharpness = { "number", 8 },
            blend = { "number", 0 },
        },
    },
}

-- A rotation quaternion as lib/sdf.lua's 3x3 row-major matrix.
local function matrixOf(q)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    return {
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    }
end

-- A bounding sphere { center, radius } around spheres.
local function enclose(spheres)
    if #spheres == 0 then return { center = { 0, 0, 0 }, radius = 0 } end
    local lo, hi = { 1e30, 1e30, 1e30 }, { -1e30, -1e30, -1e30 }
    for _, s in ipairs(spheres) do
        for a = 1, 3 do
            lo[a] = math.min(lo[a], s.center[a] - s.radius)
            hi[a] = math.max(hi[a], s.center[a] + s.radius)
        end
    end
    local center = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
    local radius = 0
    for _, s in ipairs(spheres) do
        local d = math.sqrt((s.center[1] - center[1]) ^ 2 + (s.center[2] - center[2]) ^ 2 + (s.center[3] - center[3]) ^ 2)
        radius = math.max(radius, d + s.radius)
    end
    return { center = center, radius = radius }
end

local function length3(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end

-- A node to a lib/sdf.lua shape, with its bounding sphere (in the node's parent's frame).
local function build(node, where)
    if type(node) ~= "table" then error(where .. ": a node is an object", 0) end
    local shape, bounds
    local OPS = { union = true, intersect = true, subtract = true }
    local op
    for k in pairs(OPS) do
        if node[k] then op = k end
    end
    if op then
        local children = node[op]
        if type(children) ~= "table" or #children == 0 then error(where .. "." .. op .. ": a list of nodes", 0) end
        local shapes, spheres = {}, {}
        for i, child in ipairs(children) do
            shapes[i], spheres[i] = build(child, string.format("%s.%s[%d]", where, op, i))
        end
        local k = node.smooth or 0
        if op == "union" then
            shape = k > 0 and sdf.smoothUnion(k, table.unpack(shapes)) or sdf.union(table.unpack(shapes))
            bounds = enclose(spheres)
        elseif op == "intersect" then
            shape = k > 0 and sdf.smoothIntersect(k, table.unpack(shapes)) or sdf.intersect(table.unpack(shapes))
            bounds = spheres[1]
        else
            if #shapes ~= 2 then error(where .. ".subtract: two nodes, a minus b", 0) end
            shape = k > 0 and sdf.smoothSubtract(k, shapes[1], shapes[2]) or sdf.subtract(shapes[1], shapes[2])
            bounds = spheres[1]
        end
        bounds = { center = bounds.center, radius = bounds.radius + k }
    elseif node.sphere then
        shape = sdf.sphere(node.sphere)
        bounds = { center = { 0, 0, 0 }, radius = node.sphere }
    elseif node.box then
        local b = node.box
        shape = sdf.box(b[1] / 2, b[2] / 2, b[3] / 2)
        bounds = { center = { 0, 0, 0 }, radius = length3(b) / 2 }
    elseif node.cube then
        shape = sdf.cube(node.cube / 2)
        bounds = { center = { 0, 0, 0 }, radius = node.cube * 0.8661 }
    elseif node.ellipsoid then
        local e = node.ellipsoid
        shape = sdf.ellipsoid(e[1], e[2], e[3])
        bounds = { center = { 0, 0, 0 }, radius = math.max(e[1], e[2], e[3]) }
    elseif node.capsule then
        local c = node.capsule
        shape = sdf.capsule(c.radius, c.a, c.b)
        bounds = enclose { { center = c.a, radius = c.radius }, { center = c.b, radius = c.radius } }
    elseif node.cylinder then
        local c = node.cylinder
        shape = sdf.cylinder(c.radius, c.height)
        bounds = { center = { 0, 0, 0 }, radius = c.radius + c.height }
    elseif node.prism then
        local p = node.prism
        shape = sdf.prism(p.sides, p.height)
        bounds = { center = { 0, 0, 0 }, radius = 1 + p.height }
    else
        error(where .. ": no primitive or operation (sphere, box, cube, ellipsoid, capsule, cylinder, prism, union, intersect, subtract)", 0)
    end
    if node.color then
        shape = shape:color(node.color[1], node.color[2], node.color[3])
    end
    if node.position or node.rotation or node.scale then
        local t = T.fromSpec { position = node.position, rotation = node.rotation, scale = node.scale }
        shape = shape:place(matrixOf(t.rotation), t.position, t.scale)
        bounds = { center = T.apply(t, bounds.center), radius = bounds.radius * t.scale }
    end
    return shape, bounds
end

function system.load(ctx)
    local shapes, spheres = {}, {}
    local cache, sharpness, blend = 0, 8, 0
    for id, component, transform in ctx.world:query("sdf", "transform") do
        local shape, bounds = build(component.shape, ctx.world:name(id) .. ".sdf.shape")
        shapes[#shapes + 1] = shape:place(matrixOf(transform.rotation), transform.position, transform.scale)
        spheres[#spheres + 1] = { center = T.apply(transform, bounds.center), radius = bounds.radius * transform.scale }
        cache = math.max(cache, component.cache)
        sharpness = component.sharpness
        blend = math.max(blend, component.blend)
    end
    if #shapes == 0 then return end

    -- One composition, centered on its bounds: its space is the world's, moved there.
    local bounds = enclose(spheres)
    local radius = bounds.radius * 1.05 + 0.02 + blend
    local c = bounds.center
    local all = blend > 0 and sdf.smoothUnion(blend, table.unpack(shapes)) or sdf.union(table.unpack(shapes))
    local program = sdf.compile(all:translate(-c[1], -c[2], -c[3]))
    local s = {
        program = program,
        nodes = rhi.buffer(program.floats),
        origin = c,
        radius = radius,
        cache = cache,
        sharpness = sharpness,
        raymarch = rhi.compute_pipeline("sdf/raymarch.slang", "raymarchMain"),
        source = cache > 0 and 1 or 0,
        raymarchNodes = {},
    }
    if cache > 0 then
        s.distance = rhi.texture { width = cache, height = cache, depth = cache, format = "r16f" }
        s.color = rhi.texture { width = cache, height = cache, depth = cache, format = "rgba8" }
    end

    -- At run time (for behaviors).
    function s.setSource(source)
        if s.cache == 0 then return end
        s.source = source
        ctx.shadowBlock:set { sdfUseCache = source == 1 and 1 or 0, sdfShowCacheError = source == 2 and 1 or 0 }
    end

    function s.setResolution(n)
        if s.cache == 0 then return end
        s.cache = n
        s.distance = rhi.texture { width = n, height = n, depth = n, format = "r16f" }
        s.color = rhi.texture { width = n, height = n, depth = n, format = "rgba8" }
        ctx.shadowBlock:set { sdfCacheDistance = s.distance, sdfCacheColor = s.color, sdfCacheResolution = n }
        s.bakeBlock:set { sdfCacheDistanceOut = s.distance, sdfCacheColorOut = s.color, sdfCacheResolution = n }
        s.bakeNode.threads = { n, n, n }
        s.bakeNode:rerun()
    end

    function s.setSmoothScale(scale)
        ctx.shadowBlock.smoothScale = scale
        if s.bakeNode then s.bakeNode:rerun() end
    end

    function s.gpuTime()
        local node = s.raymarchNodes[1]
        return node and node.gpu_time
    end

    function s.bakeTime()
        return s.bakeNode and s.bakeNode.gpu_time
    end

    ctx.sdf = s
end

-- What every receiver of shadows (and the raymarching) reads of the composition.
function system.shadowFields(ctx)
    local s = ctx.sdf
    if not s then return nil end
    local fields = {
        sdfShadows = 1,
        sdfShadowSharpness = s.sharpness,
        sdfNodes = s.nodes,
        sdfNodeCount = s.program.nodeCount,
        sdfResultSlot = s.program.resultSlot,
        smoothScale = 1,
        sdfOrigin = s.origin,
        sdfSpin = 0,
        sdfBoundsRadius = s.radius,
    }
    if s.cache > 0 then
        fields.sdfUseCache = 1
        fields.sdfShowCacheError = 0
        fields.sdfCacheDistance = s.distance
        fields.sdfCacheColor = s.color
        fields.sdfCacheExtent = s.radius
        fields.sdfCacheResolution = s.cache
    end
    return fields
end

-- The bake, once (sdf/sdf-bake.slang), before anything samples the cache.
function system.addPrepasses(ctx, graph)
    local s = ctx.sdf
    if not s or s.cache == 0 then return end
    s.bakeBlock = rhi.params {
        sdfCacheDistanceOut = s.distance, sdfCacheColorOut = s.color, sdfCacheExtent = s.radius, sdfCacheResolution = s.cache,
    }
    s.bakeNode = graph:dispatch {
        name = "sdf bake",
        pipeline = rhi.compute_pipeline("sdf/sdf-bake.slang", "bakeMain"),
        params = { ctx.shadowBlock, s.bakeBlock },
        threads = { s.cache, s.cache, s.cache },
        once = true,
        timed = true,
    }
end

-- Raymarched into the view's SDF targets, stopping at its meshes' depth.
function system.addSurfaces(ctx, graph, view)
    local s = ctx.sdf
    if not s then return end
    local t = view.targets
    s.raymarchNodes[#s.raymarchNodes + 1] = graph:dispatch {
        name = view.name .. ": raymarch",
        pipeline = s.raymarch,
        params = { ctx.light, ctx.shadowBlock, view.block, { meshDepth = t.meshDepth, sdfColor = t.sdfColor, sdfDepth = t.sdfDepth, sdfAlbedo = t.sdfAlbedo } },
        threads = t.sdfColor,
        timed = true,
    }
end

function system.describe(ctx)
    local s = ctx.sdf
    if not s then return nil end
    local time = s.gpuTime()
    return string.format("SDF %d nodes%s%s", s.program.nodeCount, s.cache > 0 and string.format(", cache %d^3", s.cache) or "",
        time and string.format(", raymarched in %.2f ms", time) or "")
end

return system
