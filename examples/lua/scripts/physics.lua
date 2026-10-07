-- Rigid body physics on Jolt: see lib/physics-mode.lua, which holds the scene so the
-- showcase can run it too (as its first mode).
--
-- The host steps the physics and draws the bodies every frame; Lua builds the scene in
-- init() and afterwards only reacts to input.

config = { title = "Physics", features = { "rasterization" } }

local physics = rhi.include("lib/physics-mode.lua")()

function init()
    physics.init()
    physics.on_enter()
end
function on_key(key, action, mods) physics.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) physics.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) physics.on_mouse_move(x, y) end
function on_scroll(x, y) physics.on_scroll(x, y) end
