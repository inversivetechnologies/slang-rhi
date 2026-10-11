-- The scene viewer: shows the scenes in assets/scenes/ (lib/scene/: entities, prefabs,
-- systems and a render graph built from them), one at a time.
--
--   Page Up / Page Down   previous / next scene
--   V                     show: everything / meshes / splats / SDFs / the depth buffers
--   Tab                   hide / show the insets (cameras with "inset")
--   O                     2D overlays (assets/overlays/, lib/scene/overlays.lua): none,
--                         then each in turn, over whichever scene is shown
--   other input           the scene's: its behaviors (the player, bursts), its orbit
--                         camera (drag, wheel), its sounds (M)
--
-- Saving a scene or prefab file reloads the script, and with it the scene. A scene that
-- doesn't load shows why in the window title, and the viewer goes on.

local scenes = rhi.include("lib/scene/scene.lua")
local overlayLayer = rhi.include("lib/scene/overlays.lua")

local SHOW_MODES = { "everything", "meshes", "splats", "SDFs", "depth buffers" }

-- `setTitle(details)` shows the title (default: "Scenes | ..."); `order`, if given, lists
-- scene file names to put first, in that order (the rest follow, sorted).
return function(setTitle, order)
    local mode = { name = "Scenes" }
    setTitle = setTitle or function(details)
        rhi.set_title("Scenes | " .. details)
    end

    local files = {}
    local index = 1
    local current, failure
    local showMode = 1
    local entered = false
    local titleTimer = 0
    local overlays

    local function updateTitle()
        local name = files[index] or "no scenes"
        local head = string.format("%s (%d/%d, PgUp/PgDn)", name, index, #files)
        if failure then
            setTitle(head .. " | failed: " .. failure)
        elseif current then
            local overlay = overlays and overlays:describe()
            setTitle(string.format("%s | %s | V: %s%s", head, current:describe(), SHOW_MODES[showMode],
                overlay and " | " .. overlay or ""))
        else
            setTitle(head)
        end
    end

    local function load(i)
        if current then
            if entered then current:leave() end
            current = nil
            collectgarbage()
        end
        index = (i - 1) % math.max(#files, 1) + 1
        failure = nil
        if #files == 0 then
            failure = "no scenes in assets/scenes"
            return
        end
        local ok, result = pcall(scenes.load, "scenes/" .. files[index], overlays)
        if ok then
            current = result
            current:setShowMode(showMode - 1)
            if entered then current:enter() end
        else
            failure = tostring(result)
            print("[scene] " .. failure)
            rhi.set_graph(nil)
        end
        updateTitle()
    end

    function mode.init()
        overlays = overlays or overlayLayer.load()
        local found = {}
        for _, f in ipairs(rhi.list_assets("scenes", ".json")) do found[f] = true end
        files = {}
        for _, f in ipairs(order or {}) do
            if found[f] then
                files[#files + 1] = f
                found[f] = nil
            end
        end
        for _, f in ipairs(rhi.list_assets("scenes", ".json")) do
            if found[f] then files[#files + 1] = f end
        end
        load(index)
    end

    -- Switching scenes: by `delta` (wrapping round), or to scene `i`.
    function mode.step(delta) load(index + delta) end
    function mode.show(i) if i >= 1 and i <= #files then load(i) end end
    function mode.count() return #files end

    function mode.on_enter()
        entered = true
        if current then current:enter() end
        updateTitle()
    end

    function mode.on_leave()
        entered = false
        if current then current:leave() end
    end

    function mode.update(_, dt)
        if overlays then overlays:update(dt) end
        if current then
            current:update(dt)
            if current.ctx.requestReload then
                load(index)
                return
            end
        end
        titleTimer = titleTimer + dt
        if titleTimer > 0.5 then
            titleTimer = 0
            updateTitle()
        end
    end

    function mode.on_resize(width, height)
        if current then current:layout(width, height) end
    end

    function mode.on_key(key, action, mods)
        if action == input.PRESS and (key == keys.PAGE_UP or key == keys.PAGE_DOWN) then
            load(index + (key == keys.PAGE_DOWN and 1 or -1))
            return
        end
        if not current then return end
        if action == input.PRESS and key == keys.V then
            showMode = showMode % #SHOW_MODES + 1
            current:setShowMode(showMode - 1)
            updateTitle()
        elseif action == input.PRESS and key == keys.TAB then
            current:toggleInsets()
        elseif action == input.PRESS and key == keys.O then
            overlays:cycle()
            updateTitle()
        elseif current:on_key(key, action, mods) then
            updateTitle() -- what the key changed, at once
        end
    end

    function mode.on_mouse_button(...)
        if overlays and overlays:on_mouse_button(...) then return end -- a click on the overlay
        if current then current:on_mouse_button(...) end
    end
    function mode.on_mouse_move(...) if current then current:on_mouse_move(...) end end
    function mode.on_scroll(...) if current then current:on_scroll(...) end end
    function mode.on_controller_button(...)
        return current and current:on_controller_button(...) or false
    end

    return mode
end
