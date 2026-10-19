-- The scene viewer: shows the scenes in assets/scenes/ (lib/scene/: entities, prefabs,
-- systems and a render graph built from them), one at a time.
--
--   Page Up / Page Down   previous / next scene
--   V                     show: everything / meshes / splats / SDFs / the depth buffers /
--                         the ambient occlusion / the indirect light / the bodies' motion
--                         vectors (when the effects are on) / the light tiles (how many
--                         point lights reach each, with point lights)
--   Tab                   hide / show the insets (cameras with "inset")
--   O                     2D overlays (assets/overlays/, lib/scene/overlays.lua): none,
--                         then each in turn, over whichever scene is shown
--   Escape                the pause menu (lib/pause-menu.lua): resume, settings, quit
--   other input           the scene's: its behaviors (the player, bursts), its orbit
--                         camera (drag, wheel), its sounds (M)
--
-- Saving a scene or prefab file reloads the script, and with it the scene. A scene that
-- doesn't load shows why in the window title, and the viewer goes on.

local scenes = rhi.include("lib/scene/scene.lua")
local overlayLayer = rhi.include("lib/scene/overlays.lua")
local pauseMenu = rhi.include("lib/pause-menu.lua")
local settings = rhi.include("lib/settings.lua")

local SHOW_MODES = { "everything", "meshes", "splats", "SDFs", "depth buffers", "ambient occlusion", "indirect light",
    "motion vectors", "light tiles" }

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
    local overlays, menu
    local values -- the settings (lib/settings.lua)
    local displayPending = false -- applied in update, not from inside an input callback

    -- What draws over every scene: the overlays, then the menu.
    local function layers()
        return { overlays, menu }
    end

    -- The settings that a loaded scene takes.
    local function applyToScene()
        if not current then return end
        for _, f in ipairs(current.ctx.splats or {}) do
            local own = current.ctx.settings.splatBudget
            f.module.setBudget(own and math.min(own, values.splatBudget) or values.splatBudget)
        end
    end

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
        local ok, result = pcall(scenes.load, "scenes/" .. files[index], layers())
        if ok then
            current = result
            current:setShowMode(showMode - 1)
            applyToScene()
            if entered then current:enter() end
            if menu:isOpen() then current:setPaused(true) end
        else
            failure = tostring(result)
            print("[scene] " .. failure)
            -- Still a frame, with the layers over it (the menu, the overlays).
            local graph = rhi.graph()
            graph:render_pass { name = "no scene", clear = { 0.05, 0.05, 0.07, 1 } }
            for _, layer in ipairs(layers()) do layer:addPasses(graph) end
            rhi.set_graph(graph)
        end
        updateTitle()
    end

    function mode.init()
        overlays = overlays or overlayLayer.load()
        values = values or settings.load()
        scenes.renderer.shadowFaceSize = settings.SHADOW_FACE_SIZES[values.shadowQuality]
        scenes.renderer.effects = { ao = values.ambientOcclusion ~= "Off", aoMethod = values.ambientOcclusion, gi = values.ssgi, quality = values.effectsQuality }
        scenes.renderer.taa = values.temporalAA ~= false
        menu = menu or pauseMenu.new {
            settings = values,
            onPause = function(paused)
                if current then current:setPaused(paused) end
            end,
            onChange = function(name)
                if name == "resolution" or name == "fullscreen" then
                    displayPending = true
                elseif name == "splatBudget" then
                    applyToScene()
                elseif name == "shadowQuality" then
                    scenes.renderer.shadowFaceSize = settings.SHADOW_FACE_SIZES[values.shadowQuality]
                    load(index) -- the shadow maps are part of the scene's graph
                elseif name == "temporalAA" then
                    scenes.renderer.taa = values.temporalAA
                    load(index) -- TAA's passes are part of the scene's graph
                elseif name == "ambientOcclusion" or name == "ssgi" or name == "effectsQuality" then
                    scenes.renderer.effects = { ao = values.ambientOcclusion ~= "Off", aoMethod = values.ambientOcclusion, gi = values.ssgi, quality = values.effectsQuality }
                    if values.ambientOcclusion == "Off" and not values.ssgi and showMode > 5 and showMode < 9 then
                        showMode = 1
                    end
                    load(index) -- so are the effects' passes
                end
            end,
        }
        displayPending = true
        local found = {}
        for _, f in ipairs(rhi.list_assets("scenes", ".scene")) do found[f] = true end
        files = {}
        for _, f in ipairs(order or {}) do
            if found[f] then
                files[#files + 1] = f
                found[f] = nil
            end
        end
        for _, f in ipairs(rhi.list_assets("scenes", ".scene")) do
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
        if displayPending then
            displayPending = false
            settings.applyDisplay(values)
        end
        if menu then menu:update(dt) end
        if overlays then overlays:update(dt) end
        if current and not menu:isOpen() then -- paused: the scene waits
            current:update(dt)
            if current.ctx.requestReload then
                load(index)
                return
            end
        end
        if current then current:frame() end -- after the cameras moved
        titleTimer = titleTimer + dt
        if titleTimer > 0.5 then
            titleTimer = 0
            updateTitle()
        end
    end

    function mode.on_resize(width, height)
        if current then current:layout(width, height) end
    end

    -- The pause menu's: Escape, and everything while it is open. True if it took the key
    -- (a script with keys of its own asks this first).
    function mode.menu_key(key, action, mods)
        return menu ~= nil and menu:on_key(key, action, mods)
    end

    function mode.on_key(key, action, mods)
        if mode.menu_key(key, action, mods) then return end
        if action == input.PRESS and (key == keys.PAGE_UP or key == keys.PAGE_DOWN) then
            load(index + (key == keys.PAGE_DOWN and 1 or -1))
            return
        end
        if not current then return end
        if action == input.PRESS and key == keys.V then
            -- The effects' only with them, the light tiles only with point lights.
            local available = { 1, 2, 3, 4, 5 }
            if values.ambientOcclusion ~= "Off" or values.ssgi then
                for i = 6, 8 do available[#available + 1] = i end
            end
            if current.ctx.pointLights and #current.ctx.pointLights > 0 then available[#available + 1] = 9 end
            local next = available[1]
            for k, i in ipairs(available) do
                if i == showMode then next = available[k % #available + 1] end
            end
            showMode = next
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
        if menu and menu:on_mouse_button(...) then return end
        if overlays and overlays:on_mouse_button(...) then return end -- a click on the overlay
        if current then current:on_mouse_button(...) end
    end
    function mode.on_mouse_move(...)
        if menu and menu:on_mouse_move(...) then return end
        if current then current:on_mouse_move(...) end
    end
    function mode.on_scroll(...)
        if menu and menu:isOpen() then return end
        if current then current:on_scroll(...) end
    end
    function mode.on_controller_button(...)
        if menu and menu:on_controller_button(...) then return true end
        return current and current:on_controller_button(...) or false
    end

    return mode
end
