-- The scene viewer on its own: the scenes in assets/scenes/, built from entities,
-- prefabs (assets/prefabs/) and systems. See lib/scene-viewer-mode.lua and lib/scene/.

config = { title = "Scenes", features = { "rasterization" } }

local viewer = rhi.include("lib/scene-viewer-mode.lua")()

function init()
    viewer.init()
    viewer.on_enter()
end
function update(time, dt) viewer.update(time, dt) end
function on_key(key, action, mods) viewer.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) viewer.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) viewer.on_mouse_move(x, y) end
function on_scroll(x, y) viewer.on_scroll(x, y) end
function on_resize(width, height) viewer.on_resize(width, height) end
function on_controller_button(slot, button, pressed) viewer.on_controller_button(slot, button, pressed) end
