-- An SDF composition raymarched two ways, to compare: its DAG evaluated at every step,
-- or baked once into 3D textures and sampled. See lib/sdf-cache-mode.lua.

config = { title = "SDF Cache" }

local cache = rhi.include("lib/sdf-cache-mode.lua")()

function init()
    cache.init()
    cache.on_enter()
end
function update(time, dt) cache.update(time, dt) end
function on_key(key, action, mods) cache.on_key(key, action, mods) end
function on_mouse_button(button, action, mods) cache.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) cache.on_mouse_move(x, y) end
function on_scroll(x, y) cache.on_scroll(x, y) end

-- Escape: the pause menu (lib/pause.lua): resume, settings, quit.
rhi.include("lib/pause.lua").install()
