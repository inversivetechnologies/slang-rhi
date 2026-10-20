-- The pause menu (lib/pause-menu.lua) for a script of its own: one call at the end of the
-- script, after its callbacks are defined, wraps them. Escape (or the Steam Controller's
-- Menu button) then pauses the script and opens the menu over whatever it draws.
--
--   rhi.include("lib/pause.lua").install {
--       only = { "resolution", "fullscreen", "splatBudget" }, -- the settings it has
--       controls = false,                     -- no camera: no Controls page
--       onPause = function(paused) end,       -- e.g. pause its music
--       apply = function(values) end,         -- after init, and when a setting changes:
--   }                                         -- make the script follow `values`
--
-- While the menu is open, the script's update isn't called and its input goes to the
-- menu; the shaders' `time` and the physics stop (rhi.set_paused). The menu is drawn by a
-- `draw` wrapped round the script's (draw runs after the graph, so over it). The window's
-- resolution and fullscreen are handled here; a new shadow quality reloads the script
-- (rhi.reload), whose modes size their shadow maps by it (settings.shadowFaceSize).

local pauseMenu = rhi.include("lib/pause-menu.lua")
local settings = rhi.include("lib/settings.lua")

local pause = {}

function pause.install(options)
    options = options or {}
    local only = options.only or { "resolution", "fullscreen" }
    local apply = options.apply or function() end
    local onPause = options.onPause or function() end

    local values = settings.load()
    local pending = { display = true, apply = true } -- after the script's init: in update
    local menu = pauseMenu.new {
        settings = values,
        only = only,
        controls = options.controls,
        onPause = onPause,
        onChange = function(name)
            if name == "resolution" or name == "fullscreen" then
                pending.display = true
            elseif name == "shadowQuality" then
                rhi.reload()
            else
                pending.apply = true
            end
        end,
    }

    local script = {
        update = update, draw = draw, on_key = on_key, on_mouse_button = on_mouse_button,
        on_mouse_move = on_mouse_move, on_scroll = on_scroll, on_controller_button = on_controller_button,
    }

    function update(time, dt)
        if pending.display then
            pending.display = false
            settings.applyDisplay(values)
        end
        if pending.apply then
            pending.apply = false
            apply(values)
        end
        menu:update(dt)
        if not menu:isOpen() and script.update then script.update(time, dt) end
    end

    function draw(frame)
        if script.draw then script.draw(frame) end
        menu:draw(frame)
    end

    function on_key(key, action, mods)
        if menu:on_key(key, action, mods) then return end
        if script.on_key then script.on_key(key, action, mods) end
    end

    function on_mouse_button(button, action, mods)
        if menu:on_mouse_button(button, action, mods) then return end
        if script.on_mouse_button then script.on_mouse_button(button, action, mods) end
    end

    function on_mouse_move(x, y)
        if menu:on_mouse_move(x, y) then return end
        if script.on_mouse_move then script.on_mouse_move(x, y) end
    end

    function on_scroll(x, y)
        if menu:isOpen() then return end
        if script.on_scroll then script.on_scroll(x, y) end
    end

    function on_controller_button(slot, button, pressed)
        if menu:on_controller_button(slot, button, pressed) then return true end
        if script.on_controller_button then return script.on_controller_button(slot, button, pressed) end
        return false
    end

    return { menu = menu, settings = values }
end

return pause
