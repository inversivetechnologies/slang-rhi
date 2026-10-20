-- The player character of lib/player.lua (Darksiders-style controls, Steam Controller or
-- keyboard), as a behavior: it starts at the entity's position, hits and throws at the
-- scene's dynamic bodies, and gives the "player" camera controller its camera. Its aim
-- mode's crosshair is drawn over the main view.
--
--   "script": { "file": "player.lua" }      with a camera entity's "controller": "player"

local createPlayer = rhi.include("lib/player.lua")
local settings = rhi.include("lib/settings.lua") -- the controls (look sensitivity)

return function(ctx, id)
    local b = {}
    if not ctx.mesh then
        print("[scene] player.lua needs the mesh system's physics world")
        return b
    end
    local m = ctx.mesh
    local player = createPlayer(m.world, {
        spawn = ctx.world:get(id, "transform").position,
        targets = { m.groups.box.dynamic, m.groups.sphere.dynamic },
        projectiles = m.groups.sphere.dynamic,
    })
    player.init()
    m.addGroup(player.parts, "box")
    m.addGroup(player.round, "sphere")
    ctx.cameraProviders.player = player.camera

    local crosshair, crosshairBlock

    function b.addOverlays(graph)
        crosshairBlock = rhi.params {
            crosshairColor = { 1, 1, 1, 0.85 }, crosshairHotColor = { 1, 0.45, 0.15, 1 },
            crosshairHot = 0, crosshairSpread = 0,
        }
        crosshair = graph:render_pass { name = "crosshair" }
        crosshair:draw {
            pipeline = rhi.render_pipeline { shader = "post/crosshair.slang", blend = "alpha" },
            count = 3,
            params = crosshairBlock,
        }
        crosshair.enabled = false
    end

    function b.update(dt)
        player.update(dt)
        if crosshair then
            local aiming = player.aiming()
            crosshair.enabled = aiming
            if aiming then
                local hot, spread = player.crosshair()
                crosshairBlock.crosshairHot = hot
                crosshairBlock.crosshairSpread = spread
            end
        end
    end

    function b.enter() player.clear_input() end
    function b.on_key(key, action) return player.on_key(key, action) end
    function b.on_controller_button(slot, button, pressed) return player.on_controller_button(slot, button, pressed) end

    local drag
    function b.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return false end
        drag = action == input.PRESS and { input.mouse() } or nil
        return true
    end
    function b.on_mouse_move(x, y)
        if not drag then return false end
        local dx, dy = settings.mouseLook(x - drag[1], y - drag[2]) -- the controls' sensitivity
        player.look(dx * 0.006, dy * 0.006)
        drag = { x, y }
        return true
    end
    function b.on_scroll(_, y)
        player.zoom(y)
        return true
    end

    function b.describe() return player.describe() end

    return b
end
