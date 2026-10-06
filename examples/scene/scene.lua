-- A small lit scene with a point light, realtime shadows and a second camera composited
-- into the corner: see scene-mode.lua, which holds the scene so the showcase can run it too.
--
-- The scene is a render graph the host runs every frame, so there is no update() or draw()
-- here: Lua builds the graph in init() and afterwards only reacts to input.

config = { title = "Scene", features = { "rasterization" } }

local scene = rhi.include("scene-mode.lua")("")

function init()
    scene.init()
    scene.on_enter()
end
function on_key(key, action, mods) scene.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) scene.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) scene.on_mouse_move(x, y) end
function on_scroll(x, y) scene.on_scroll(x, y) end
