-- Rigid body physics on Jolt: see lib/physics-mode.lua, which holds the scene. (The
-- showcase shows it as a scene file: assets/scenes/physics.scene.)
--
-- The host steps the physics and draws the bodies every frame; Lua builds the scene in
-- init(), and every frame steers and poses the player character (lib/player.lua).

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
function update(time, dt) physics.update(time, dt) end
function on_controller_button(slot, button, pressed) physics.on_controller_button(slot, button, pressed) end

-- Escape: the pause menu (lib/pause.lua): resume, settings, quit.
rhi.include("lib/pause.lua").install {
    only = { "resolution", "fullscreen", "shadowQuality" },
}
