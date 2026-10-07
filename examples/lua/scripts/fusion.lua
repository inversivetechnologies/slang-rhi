-- The mesh scene and the Gaussian splats rendered separately, each with its own depth
-- buffer, and combined per pixel by depth: see lib/fusion-mode.lua.

config = { title = "Depth Composite", features = { "rasterization" } }

local scene = rhi.include("lib/scene-mode.lua")(function(details) rhi.set_title("Depth Composite | " .. details) end)
local splat = rhi.include("lib/splat-mode.lua")()
local fusion = rhi.include("lib/fusion-mode.lua")(scene, splat)

function init()
    fusion.init()
    fusion.on_enter()
end
function on_key(key, action, mods) fusion.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) fusion.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) fusion.on_mouse_move(x, y) end
function on_scroll(x, y) fusion.on_scroll(x, y) end
function on_resize(width, height) fusion.on_resize(width, height) end
