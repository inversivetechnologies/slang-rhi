-- Gaussian splatting with compute shaders: see lib/splat-mode.lua, which holds it so other
-- graphs can use it too. Shows assets/gsplats/skull.ply.
--
-- Like the scene, it is a render graph the host runs every frame: Lua builds it in init()
-- and afterwards only reacts to input.

config = { title = "Gaussian Splats", features = { "rasterization" } }

local splat = rhi.include("lib/splat-mode.lua")()

function init()
    splat.init()
    splat.on_enter()
end
function on_key(key, action, mods) splat.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) splat.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) splat.on_mouse_move(x, y) end
function on_scroll(x, y) splat.on_scroll(x, y) end

-- Escape: the pause menu (lib/pause.lua): resume, settings, quit.
rhi.include("lib/pause.lua").install {
    only = { "resolution", "fullscreen", "splatBudget" },
    onPause = function(paused) splat.setPaused(paused) end,
    -- More than the buffers were made for: made again, the script reloaded.
    apply = function(values) if splat.setBudget(values.splatBudget) then rhi.reload() end end,
}
