-- A loaded scene: its world (lib/scene/ecs.lua), its systems' state (the context, `ctx`)
-- and its render graph (lib/scene/renderer.lua).
--
--   local scenes = rhi.include("lib/scene/scene.lua")
--   local scene = scenes.load("scenes/composite.json", layers) -- layers: optional, drawn
--                       -- over everything (lib/scene/overlays.lua, lib/pause-menu.lua)
--   scene:enter()            -- hands the graph (and physics, sounds) to the host
--   scene:update(dt)         -- behaviors and cameras, every frame
--   scene:on_key(...)        -- input goes to the systems, the first to want it takes it
--   scene:leave()
--
-- The systems, in the order they load and contribute: the light, meshes and bodies, SDFs,
-- splats, behaviors (which see all of those, and may add bodies, groups and cameras),
-- cameras, sounds.

local loader = rhi.include("lib/scene/loader.lua")
local renderer = rhi.include("lib/scene/renderer.lua")

local SYSTEMS = {
    rhi.include("lib/scene/systems/light.lua"),
    rhi.include("lib/scene/systems/mesh.lua"),
    rhi.include("lib/scene/systems/sdf.lua"),
    rhi.include("lib/scene/systems/splat.lua"),
    rhi.include("lib/scene/systems/behavior.lua"),
    rhi.include("lib/scene/systems/camera.lua"),
    rhi.include("lib/scene/systems/sound.lua"),
}

local scenes = { systems = SYSTEMS, renderer = renderer }

local Scene = {}
Scene.__index = Scene

function scenes.load(path, layers)
    local world, settings, name = loader.load(path, SYSTEMS)
    local ctx = { world = world, settings = settings, name = name, path = path, cameraProviders = {},
                  layers = layers or {} }
    for _, system in ipairs(SYSTEMS) do
        if system.load then system.load(ctx) end
    end
    local scene = setmetatable({ ctx = ctx }, Scene)
    scene.graph = renderer.build(ctx, SYSTEMS)
    return scene
end

local function each(scene, name, ...)
    for _, system in ipairs(SYSTEMS) do
        if system[name] then system[name](scene.ctx, ...) end
    end
end

local function first(scene, name, ...)
    for _, system in ipairs(SYSTEMS) do
        if system[name] and system[name](scene.ctx, ...) then return true end
    end
    return false
end

function Scene:enter()
    rhi.set_graph(self.graph)
    each(self, "enter")
    self:layout(rhi.window_size())
end

function Scene:leave()
    each(self, "leave")
    rhi.set_graph(nil)
end

function Scene:layout(width, height)
    each(self, "layout", width, height)
    for _, layer in ipairs(self.ctx.layers) do layer:layout(width, height) end
end

function Scene:update(dt)
    each(self, "update", dt)
end

function Scene:on_key(...) return first(self, "on_key", ...) end
function Scene:on_mouse_button(...) return first(self, "on_mouse_button", ...) end
function Scene:on_mouse_move(...) return first(self, "on_mouse_move", ...) end
function Scene:on_scroll(...) return first(self, "on_scroll", ...) end
function Scene:on_controller_button(...) return first(self, "on_controller_button", ...) end

-- Turns the insets off and on.
function Scene:toggleInsets()
    for _, view in ipairs(self.ctx.views) do
        if view.inset and view.framePass then view.framePass.enabled = not view.framePass.enabled end
    end
end

-- Pausing (the pause menu): systems with a `setPaused` hook (sounds) stop and go on.
function Scene:setPaused(paused)
    each(self, "setPaused", paused)
end

function Scene:setShowMode(mode)
    renderer.setShowMode(self.ctx, mode)
end

-- A line about the scene, for a window title.
function Scene:describe()
    local parts = { string.format("%d entities", self.ctx.world:count()) }
    for _, system in ipairs(SYSTEMS) do
        local text = system.describe and system.describe(self.ctx)
        if text then parts[#parts + 1] = text end
    end
    return table.concat(parts, " | ")
end

return scenes
