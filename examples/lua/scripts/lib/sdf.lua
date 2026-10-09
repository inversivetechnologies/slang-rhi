-- Building compositions of SDF shapes in Lua, and compiling them into the node buffer that
-- shaders/sdf/sdf-dag.slang evaluates.
--
-- A shape is a Lua value built from primitives (the 3D ones of shaders/common/sdfs.slang),
-- transformed, colored, and combined with smooth booleans (shaders/sdf/smooth-ops.slang):
--
--   local sdf = rhi.include("lib/sdf.lua")
--   local body = sdf.smoothUnion(0.1,
--       sdf.sphere(0.3):color(1, 0.5, 0.2),
--       sdf.box(0.2, 0.2, 0.2):rotate("y", 0.6):translate(0, 0.2, 0))
--   local program = sdf.compile(body)   -- { floats, nodeCount, resultSlot, slotCount }
--   local nodes = rhi.buffer(program.floats)
--
-- Shapes are values: transforming or coloring one returns a new shape and leaves the
-- original as it was, so one shape can be used in several places. Where the same shape
-- (the same Lua value) is used more than once with the same placement, compile() emits it
-- once and lets every user read its result -- the composition becomes a DAG, not a tree.
--
-- compile() pushes every transform and color down to the primitives (each primitive node
-- gets the world-to-local transform of its whole path), orders the nodes so that each comes
-- after what it reads, and assigns result slots, reusing a slot once its last reader has
-- run. Transforms are rotations, translations and uniform scales.

local sdf = {}

-- Op codes and layout: these must match shaders/sdf/sdf-dag.slang.
local OP = {
    sphere = 0, cube = 1, box = 2, ellipsoid = 3, capsule = 4, plane = 5,
    cylinder = 6, prism = 7, tetrahedron = 8,
    union = 16, subtract = 17, intersect = 18,
}
local NODE_FLOATS = 8 * 4
local MAX_SLOTS = 16

local Shape = {}
Shape.__index = Shape

-- -------------------------------------------------------------------------------------
-- Primitives. Parameters go in the node's three parameter float4s, as sdf-dag.slang reads
-- them.
-- -------------------------------------------------------------------------------------

local function primitive(kind, p1, p2, p3)
    return setmetatable({
        kind = "primitive",
        op = OP[kind],
        params = { p1 or { 0, 0, 0, 0 }, p2 or { 0, 0, 0, 0 }, p3 or { 0, 0, 0, 0 } },
    }, Shape)
end

function sdf.sphere(radius) return primitive("sphere", { radius, 0, 0, 0 }) end
function sdf.cube(halfSize) return primitive("cube", { halfSize, 0, 0, 0 }) end
function sdf.box(x, y, z) return primitive("box", { x, y, z, 0 }) end
function sdf.ellipsoid(x, y, z) return primitive("ellipsoid", { x, y, z, 0 }) end
function sdf.capsule(radius, a, b)
    return primitive("capsule", { radius, 0, 0, 0 }, { a[1], a[2], a[3], 0 }, { b[1], b[2], b[3], 0 })
end
function sdf.plane(point, normal)
    return primitive("plane", { point[1], point[2], point[3], 0 }, { normal[1], normal[2], normal[3], 0 })
end
-- Along y, centered on the origin.
function sdf.cylinder(radius, height) return primitive("cylinder", { radius, height, 0, 0 }) end
-- A regular polygon of `sides` with circumradius 1, extruded along y.
function sdf.prism(sides, height) return primitive("prism", { sides, height, 0, 0 }) end
function sdf.tetrahedron(a, b, c, d)
    return primitive("tetrahedron", { a[1], a[2], a[3], d[1] }, { b[1], b[2], b[3], d[2] }, { c[1], c[2], c[3], d[3] })
end

-- -------------------------------------------------------------------------------------
-- Smooth booleans. `k` is the blend radius in world units; 0 is a hard boolean. Union and
-- intersection take any number of shapes.
-- -------------------------------------------------------------------------------------

local function operator(kind, k, a, b)
    return setmetatable({ kind = "operator", op = OP[kind], k = k, inputs = { a, b } }, Shape)
end

local function fold(kind, k, shapes)
    local result = shapes[1]
    for i = 2, #shapes do
        result = operator(kind, k, result, shapes[i])
    end
    return result
end

function sdf.smoothUnion(k, ...) return fold("union", k, { ... }) end
function sdf.smoothIntersect(k, ...) return fold("intersect", k, { ... }) end
function sdf.smoothSubtract(k, a, b) return operator("subtract", k, a, b) end
function sdf.union(...) return fold("union", 0, { ... }) end
function sdf.intersect(...) return fold("intersect", 0, { ... }) end
function sdf.subtract(a, b) return operator("subtract", 0, a, b) end

-- -------------------------------------------------------------------------------------
-- Transforms and colors: wrappers, applied by compile().
-- -------------------------------------------------------------------------------------

-- A placement: x' = scale * (rotation * x) + translation. Rotation is a 3x3 row-major table.
local IDENTITY = { rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, scale = 1, translation = { 0, 0, 0 } }

local function rotationAbout(axis, angle)
    local c, s = math.cos(angle), math.sin(angle)
    if axis == "x" then return { 1, 0, 0, 0, c, -s, 0, s, c } end
    if axis == "y" then return { c, 0, s, 0, 1, 0, -s, 0, c } end
    if axis == "z" then return { c, -s, 0, s, c, 0, 0, 0, 1 } end
    error("rotate: axis must be \"x\", \"y\" or \"z\"", 3)
end

local function wrap(shape, placement)
    return setmetatable({ kind = "transform", child = shape, placement = placement }, Shape)
end

function Shape:translate(x, y, z)
    return wrap(self, { rotation = IDENTITY.rotation, scale = 1, translation = { x, y, z } })
end
function Shape:rotate(axis, angle)
    return wrap(self, { rotation = rotationAbout(axis, angle), scale = 1, translation = { 0, 0, 0 } })
end
function Shape:scale(s)
    return wrap(self, { rotation = IDENTITY.rotation, scale = s, translation = { 0, 0, 0 } })
end
-- Any placement at once: `rotation` a 3x3 row-major table, then a uniform `scale`, then
-- `translation` (x' = scale * (rotation * x) + translation), as a scene entity's
-- transform places a composition.
function Shape:place(rotation, translation, scale)
    return wrap(self, { rotation = rotation, scale = scale or 1, translation = translation })
end
-- Colors every primitive below that has no color of its own nearer to it.
function Shape:color(r, g, b)
    return setmetatable({ kind = "color", child = self, rgb = { r, g, b } }, Shape)
end

local function multiply(a, b) -- 3x3 row-major
    local m = {}
    for row = 0, 2 do
        for col = 0, 2 do
            m[row * 3 + col + 1] = a[row * 3 + 1] * b[col + 1] + a[row * 3 + 2] * b[3 + col + 1] + a[row * 3 + 3] * b[6 + col + 1]
        end
    end
    return m
end

local function apply(r, v) -- 3x3 times vector
    return { r[1] * v[1] + r[2] * v[2] + r[3] * v[3], r[4] * v[1] + r[5] * v[2] + r[6] * v[3], r[7] * v[1] + r[8] * v[2] + r[9] * v[3] }
end

-- parent after child: world = parent(child(x))
local function compose(parent, child)
    local moved = apply(parent.rotation, child.translation)
    return {
        rotation = multiply(parent.rotation, child.rotation),
        scale = parent.scale * child.scale,
        translation = {
            parent.scale * moved[1] + parent.translation[1],
            parent.scale * moved[2] + parent.translation[2],
            parent.scale * moved[3] + parent.translation[3],
        },
    }
end

-- The world-to-local inverse as three rows of a 3x4 affine: x = R^T (x' - t) / s.
local function inverseRows(p)
    local r, s, t = p.rotation, p.scale, p.translation
    local rows = {}
    for i = 0, 2 do
        -- row i of R^T is column i of R
        local a, b, c = r[i + 1] / s, r[3 + i + 1] / s, r[6 + i + 1] / s
        rows[i + 1] = { a, b, c, -(a * t[1] + b * t[2] + c * t[3]) }
    end
    return rows
end

local function placementKey(p, rgb)
    local parts = {}
    for _, v in ipairs(p.rotation) do parts[#parts + 1] = string.format("%.6g", v) end
    for _, v in ipairs(p.translation) do parts[#parts + 1] = string.format("%.6g", v) end
    parts[#parts + 1] = string.format("%.6g", p.scale)
    for _, v in ipairs(rgb) do parts[#parts + 1] = string.format("%.4g", v) end
    return table.concat(parts, ",")
end

-- -------------------------------------------------------------------------------------
-- Compiling
-- -------------------------------------------------------------------------------------

-- Returns { floats, nodeCount, resultSlot, slotCount }.
function sdf.compile(shape)
    local nodes = {}  -- in evaluation order: { op, inputs = {index, index}, params, rows, rgb, scale, k }
    local emitted = {} -- [shape][placement key] = node index: the DAG's sharing

    local function emit(s, placement, rgb)
        if s.kind == "transform" then
            return emit(s.child, compose(placement, s.placement), rgb)
        elseif s.kind == "color" then
            return emit(s.child, placement, s.rgb)
        end
        local key = placementKey(placement, rgb)
        emitted[s] = emitted[s] or {}
        if emitted[s][key] then
            return emitted[s][key]
        end
        local node
        if s.kind == "primitive" then
            node = { op = s.op, params = s.params, rows = inverseRows(placement), rgb = rgb, scale = placement.scale }
        else
            local a = emit(s.inputs[1], placement, rgb)
            local b = emit(s.inputs[2], placement, rgb)
            -- A blend radius is in the shape's own units; scale it into the world's.
            node = { op = s.op, inputs = { a, b }, k = s.k * placement.scale }
        end
        nodes[#nodes + 1] = node
        emitted[s][key] = #nodes
        return #nodes
    end

    local root = emit(shape, IDENTITY, { 0.8, 0.8, 0.8 })

    -- Slots: a node's slot is free again once its last reader has run.
    local lastRead = {}
    for i, node in ipairs(nodes) do
        for _, input in ipairs(node.inputs or {}) do lastRead[input] = i end
    end
    local free, slotOf, slotCount = {}, {}, 0
    for i, node in ipairs(nodes) do
        -- Inputs are read before the output is written, so their slots can be reused for it.
        for _, input in ipairs(node.inputs or {}) do
            if lastRead[input] == i and slotOf[input] then
                free[#free + 1] = slotOf[input]
                lastRead[input] = nil
            end
        end
        if #free > 0 then
            table.sort(free, function(x, y) return x > y end)
            slotOf[i] = table.remove(free)
        else
            slotOf[i] = slotCount
            slotCount = slotCount + 1
        end
    end
    if slotCount > MAX_SLOTS then
        error(string.format("sdf.compile: the composition needs %d result slots; sdf-dag.slang has %d", slotCount, MAX_SLOTS), 2)
    end

    local floats = {}
    local function push(...)
        for _, v in ipairs({ ... }) do floats[#floats + 1] = v end
    end
    for i, node in ipairs(nodes) do
        if node.inputs then
            push(node.op, slotOf[node.inputs[1]], slotOf[node.inputs[2]], slotOf[i])
            push(node.k, 0, 0, 0)
            for _ = 1, 6 * 4 do floats[#floats + 1] = 0 end
        else
            push(node.op, 0, 0, slotOf[i])
            for _, p in ipairs(node.params) do push(p[1], p[2], p[3], p[4]) end
            for _, row in ipairs(node.rows) do push(row[1], row[2], row[3], row[4]) end
            push(node.rgb[1], node.rgb[2], node.rgb[3], node.scale)
        end
    end
    assert(#floats == #nodes * NODE_FLOATS)
    return { floats = floats, nodeCount = #nodes, resultSlot = slotOf[root], slotCount = slotCount }
end

return sdf
