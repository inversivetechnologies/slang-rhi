-- Behaviors: Lua that runs for an entity -- the scene system's code, where everything else
-- is data. A behavior is a file in scripts/behaviors/ returning a constructor:
--
--   return function(ctx, id, params)    -- the scene context, the entity, its "params"
--       local b = {}
--       function b.update(dt) ... end   -- every frame (optional)
--       function b.on_key(key, action, mods) return true end  -- true: handled (optional)
--       -- also on_mouse_button, on_mouse_move, on_scroll, on_controller_button,
--       -- addOverlays(graph) (passes over the main view), enter(), leave(), describe()
--       return b
--   end
--
--   "script": { "file": "spin.lua", "params": { ... } }
--
-- Constructors run after the meshes and bodies (ctx.mesh), the SDFs (ctx.sdf) and the
-- splats (ctx.splats) are loaded, and before the cameras and the graph, so a behavior can
-- add bodies, groups to draw (ctx.mesh.addGroup) and cameras (ctx.cameraProviders). It can
-- ask the viewer to load the scene again by setting ctx.requestReload.

local system = {
    name = "behavior",
    components = {
        script = {
            file = { "string", nil, true },
            params = { "object", {} },
        },
    },
}

function system.load(ctx)
    ctx.behaviors = {}
    for id, script in ctx.world:query("script") do
        -- A missing behavior is left out (the file is watched: it loads once it is there).
        local ok, constructor = pcall(rhi.include, "behaviors/" .. script.file)
        if ok then
            ctx.behaviors[#ctx.behaviors + 1] = constructor(ctx, id, script.params)
        elseif tostring(constructor):find("cannot open", 1, true) then
            print(string.format("[scene] %s: behavior %s is missing; left out until it is there",
                ctx.name, script.file))
        else
            error(constructor, 0)
        end
    end
end

local function each(ctx, name, ...)
    for _, b in ipairs(ctx.behaviors) do
        if b[name] then b[name](...) end
    end
end

-- The first behavior that handles an input event takes it.
local function first(ctx, name, ...)
    for _, b in ipairs(ctx.behaviors) do
        if b[name] and b[name](...) then return true end
    end
    return false
end

function system.update(ctx, dt) each(ctx, "update", dt) end
function system.enter(ctx) each(ctx, "enter") end
function system.leave(ctx) each(ctx, "leave") end
function system.addOverlays(ctx, graph) each(ctx, "addOverlays", graph) end
function system.on_key(ctx, ...) return first(ctx, "on_key", ...) end
function system.on_mouse_button(ctx, ...) return first(ctx, "on_mouse_button", ...) end
function system.on_mouse_move(ctx, ...) return first(ctx, "on_mouse_move", ...) end
function system.on_scroll(ctx, ...) return first(ctx, "on_scroll", ...) end
function system.on_controller_button(ctx, ...) return first(ctx, "on_controller_button", ...) end

function system.describe(ctx)
    local parts = {}
    for _, b in ipairs(ctx.behaviors) do
        local text = b.describe and b.describe()
        if text then parts[#parts + 1] = text end
    end
    return #parts > 0 and table.concat(parts, " | ") or nil
end

return system
