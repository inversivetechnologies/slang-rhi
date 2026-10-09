-- Loading scene files (assets/scenes/*.json) into a world of entities (lib/scene/ecs.lua),
-- with prefabs (assets/prefabs/*.json).
--
-- A scene file:
--
--   {
--     "name": "...",
--     "settings": { "background": [r, g, b], "splatBudget": 1000000, ... },
--     "prefabs": { "name": { ...an entity... } },   // optional, inline; else prefabs/name.json
--     "entities": [ { ...an entity... }, ... ]
--   }
--
-- An entity is an object whose keys are component types (see the systems'
-- `components`), plus these:
--
--   "id"         a name, unique in the scene (children's are prefixed: "parent/child")
--   "prefab"     a prefab's name: the entity starts as the prefab, and its own keys
--                override it (objects merge key by key, other values replace)
--   "transform"  { "position": [x, y, z], "rotation": [pitch, yaw, roll] (degrees),
--                  "scale": s } -- relative to the parent, for children
--   "children"   entities placed in this one's frame (a prefab's and the instance's both)
--   "repeat"     { "count": n or [nx, ny, nz], "step": [dx, dy, dz],
--                  "rotationStep": [pitch, yaw, roll],
--                  "vary": { "component": { "field": [value, value, ...] } } }
--                  -- copies, each moved by `step` per index along each axis, turned by
--                  `rotationStep` per copy, and given the values of `vary` in turn
--   "_..."       anything starting with an underscore is a comment, and ignored
--
-- A prefab file is an entity like any other, which may itself start from a prefab.

local json = rhi.include("lib/scene/json.lua")
local ecs = rhi.include("lib/scene/ecs.lua")
local T = rhi.include("lib/scene/transform.lua")

local loader = {}

local RESERVED = { id = true, prefab = true, transform = true, children = true, ["repeat"] = true }

local function isArray(t)
    return type(t) == "table" and (t[1] ~= nil or next(t) == nil)
end

local function copy(v)
    if type(v) ~= "table" or v == json.null then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

-- `over` on top of `base`: objects merge key by key; arrays and other values replace;
-- children add up.
local function merge(base, over)
    local result = copy(base)
    for k, v in pairs(over) do
        if k == "children" then
            local children = copy(result.children or {})
            for _, child in ipairs(v) do children[#children + 1] = copy(child) end
            result.children = children
        elseif type(v) == "table" and not isArray(v) and type(result[k]) == "table" and not isArray(result[k]) then
            result[k] = merge(result[k], v)
        else
            result[k] = copy(v)
        end
    end
    return result
end

-- Schema checking: a field's declared type against its value.
local VECTORS = { vec2 = 2, vec3 = 3, vec4 = 4 }

local function checkField(where, field, kind, value)
    if kind == "any" then return end
    if VECTORS[kind] then
        if not isArray(value) or #value ~= VECTORS[kind] then
            error(string.format("%s.%s: expected %d numbers", where, field, VECTORS[kind]), 0)
        end
        for _, x in ipairs(value) do
            if type(x) ~= "number" then error(string.format("%s.%s: expected numbers", where, field), 0) end
        end
    elseif kind == "array" then
        if not isArray(value) then error(string.format("%s.%s: expected an array", where, field), 0) end
    elseif kind == "object" then
        if type(value) ~= "table" or isArray(value) then error(string.format("%s.%s: expected an object", where, field), 0) end
    elseif type(value) ~= kind then
        error(string.format("%s.%s: expected a %s, got %s", where, field, kind, type(value)), 0)
    end
end

-- Fills the schema's defaults into a component, and checks what is there.
local function validate(where, schema, data)
    if type(data) ~= "table" or isArray(data) then
        error(where .. ": a component is an object", 0)
    end
    for field, value in pairs(data) do
        local spec = schema[field]
        if not spec then
            if field:sub(1, 1) ~= "_" then
                local known = {}
                for k in pairs(schema) do known[#known + 1] = k end
                table.sort(known)
                error(string.format("%s: unknown field '%s' (known: %s)", where, field, table.concat(known, ", ")), 0)
            end
        else
            checkField(where, field, spec[1], value)
        end
    end
    for field, spec in pairs(schema) do
        if data[field] == nil then
            if spec[3] then error(string.format("%s: '%s' is required", where, field), 0) end
            if spec[2] ~= nil then data[field] = copy(spec[2]) end
        end
    end
    return data
end

-- Loads a scene file into a new world. `systems` declare the component types (their
-- `components`: type -> { field -> { kind, default, required } }; kinds are "number",
-- "string", "boolean", "vec2", "vec3", "vec4", "array", "object" and "any"). Returns the world, the scene's
-- settings and its name.
function loader.load(path, systems)
    local schemas = {}
    for _, system in ipairs(systems) do
        for type, schema in pairs(system.components or {}) do schemas[type] = schema end
    end

    local scene = json.decode(rhi.read_asset(path), path)
    local inline = scene.prefabs or {}
    local prefabs = {}

    -- A prefab, resolved: its own prefab chain merged in.
    local function prefab(name, chain)
        if prefabs[name] then return prefabs[name] end
        chain = chain or {}
        if chain[name] then error("prefab '" .. name .. "' includes itself", 0) end
        chain[name] = true
        local spec = inline[name]
        if not spec then
            local file = "prefabs/" .. name .. ".json"
            spec = json.decode(rhi.read_asset(file), file)
        end
        if spec.prefab then
            spec = merge(prefab(spec.prefab, chain), spec)
            spec.prefab = nil
        end
        prefabs[name] = spec
        return spec
    end

    local world = ecs.world()
    local usedNames = {}

    local function uniqueName(name)
        if not name then return nil end
        if not usedNames[name] then
            usedNames[name] = 1
            return name
        end
        usedNames[name] = usedNames[name] + 1
        return name .. "#" .. usedNames[name]
    end

    local expand -- forward

    local function create(spec, parent, parentName, local_)
        local name = spec.id and (parentName and parentName .. "/" .. spec.id or spec.id) or nil
        local id = world:create(uniqueName(name))
        local where = name or ("an entity of " .. path)
        local transform = T.compose(parent, local_)
        world:set(id, "transform", transform)
        for type, data in pairs(spec) do
            if not RESERVED[type] and type:sub(1, 1) ~= "_" then
                local schema = schemas[type]
                if not schema then
                    local known = {}
                    for k in pairs(schemas) do known[#known + 1] = k end
                    table.sort(known)
                    error(string.format("%s: unknown component '%s' (known: %s)", where, type, table.concat(known, ", ")), 0)
                end
                world:set(id, type, validate(where .. "." .. type, schema, copy(data)))
            end
        end
        for _, child in ipairs(spec.children or {}) do
            expand(child, transform, name)
        end
        return id
    end

    function expand(spec, parent, parentName)
        if spec.prefab then
            local base = prefab(spec.prefab)
            spec = merge(base, spec)
            spec.prefab = nil
        end
        local own = spec.transform or {}
        local r = spec["repeat"]
        if not r then
            create(spec, parent, parentName, T.fromSpec(own))
            return
        end
        local count = r.count or 1
        if type(count) == "number" then count = { count, 1, 1 } end
        local step = r.step or { 0, 0, 0 }
        local turn = r.rotationStep or { 0, 0, 0 }
        local position = own.position or { 0, 0, 0 }
        local rotation = own.rotation or { 0, 0, 0 }
        local n = 0
        for z = 0, (count[3] or 1) - 1 do
            for y = 0, (count[2] or 1) - 1 do
                for x = 0, (count[1] or 1) - 1 do
                    local idx = { x, y, z }
                    local p, e = {}, {}
                    for a = 1, 3 do
                        p[a] = position[a] + step[a] * (count[a] and idx[a] or 0)
                        e[a] = rotation[a] + turn[a] * n
                    end
                    local copySpec = copy(spec)
                    copySpec["repeat"] = nil
                    for component, fields in pairs(r.vary or {}) do
                        copySpec[component] = copySpec[component] or {}
                        for field, values in pairs(fields) do
                            copySpec[component][field] = copy(values[n % #values + 1])
                        end
                    end
                    create(copySpec, parent, parentName, T.fromSpec { position = p, rotation = e, scale = own.scale })
                    n = n + 1
                end
            end
        end
    end

    for _, entity in ipairs(scene.entities or {}) do
        expand(entity, T.identity, nil)
    end
    return world, scene.settings or {}, scene.name or path
end

loader.merge = merge
loader.copy = copy
return loader
