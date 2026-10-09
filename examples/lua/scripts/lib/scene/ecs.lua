-- The scene system's entities and components: a small entity-component store.
--
-- An entity is a number with an optional name. A component is a plain Lua table of data,
-- stored per component type; an entity has at most one of each type. Systems
-- (lib/scene/systems/) hold the behavior: they find the entities that have the components
-- they handle, and turn them into GPU resources, graph passes and parameter blocks.
--
--   local world = ecs.world()
--   local id = world:create("floor")
--   world:set(id, "mesh", { shape = "box", size = { 20, 0.5, 20 } })
--   for id, mesh, transform in world:query("mesh", "transform") do ... end
--
-- Iteration is in creation order, so a scene loads and draws the same way every time.

local ecs = {}

local World = {}
World.__index = World

function ecs.world()
    return setmetatable({ nextId = 1, order = {}, names = {}, nameOf = {}, components = {} }, World)
end

function World:create(name)
    local id = self.nextId
    self.nextId = id + 1
    self.order[#self.order + 1] = id
    if name then
        if self.names[name] then
            error(string.format("two entities are named '%s'", name), 2)
        end
        self.names[name] = id
        self.nameOf[id] = name
    end
    return id
end

function World:name(id)
    return self.nameOf[id] or ("#" .. id)
end

function World:find(name)
    return self.names[name]
end

function World:set(id, type, data)
    local store = self.components[type]
    if not store then
        store = {}
        self.components[type] = store
    end
    store[id] = data
    return data
end

function World:get(id, type)
    local store = self.components[type]
    return store and store[id]
end

function World:remove(id, type)
    local store = self.components[type]
    if store then store[id] = nil end
end

function World:count()
    return #self.order
end

-- Iterates over the entities that have every one of the given component types:
-- for id, a, b, ... in world:query("a", "b", ...).
function World:query(...)
    local types = { ... }
    local stores = {}
    for i, type in ipairs(types) do
        stores[i] = self.components[type] or {}
    end
    local i = 0
    return function()
        while true do
            i = i + 1
            local id = self.order[i]
            if not id then return nil end
            local found = { id }
            local all = true
            for k, store in ipairs(stores) do
                local c = store[id]
                if c == nil then
                    all = false
                    break
                end
                found[k + 1] = c
            end
            if all then return table.unpack(found, 1, #types + 1) end
        end
    end
end

-- How many entities have a component type.
function World:countOf(type)
    local n = 0
    for _ in pairs(self.components[type] or {}) do n = n + 1 end
    return n
end

return ecs
