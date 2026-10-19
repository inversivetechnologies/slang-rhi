-- Flicker / trailing measurement: scenes/_flick.scene, 24 consecutive frames of the main
-- view's final image saved (rhi.save_texture), and the splats' coverage as a mask.
return function(cfg)
    local scenes = rhi.include("lib/scene/scene.lua")
    scenes.renderer.captureMain = true
    scenes.renderer.taa = cfg.taa == true
    scenes.renderer.effects = { ao = cfg.ao ~= "Off", aoMethod = cfg.ao or "GTAO", gi = cfg.gi ~= "Off",
                                giMethod = cfg.gi or "Cascades", quality = cfg.quality or "Half" }
    local sc
    local n = 0
    function init()
        sc = scenes.load(cfg.scene or "scenes/_flick.scene")
        if cfg.turn then sc.ctx.views[1].camera.turn = cfg.turn end
        if cfg.still then sc.ctx.cameraTurnWhileStill = cfg.turn end
        if cfg.setup then cfg.setup(sc) end
        sc:enter()
    end
    function update(t, dt)
        if n == 2 and cfg.size then rhi.set_display { width = cfg.size[1], height = cfg.size[2] } end
        -- The trail test: from frame 84, time stands still (the box stays where it is) while
        -- the frames go on, so what lags catches up; frame 84 against frame 130 is the lag.
        local frozen = (cfg.trail and n >= 84) or cfg.still
        sc:update(frozen and 0 or (cfg.fixedDt or (1 / 60)))
        -- Still, but turning: the camera alone moves on.
        if cfg.still and cfg.turn then
            local c = sc.ctx.views[1].camera
            c.yaw = c.yaw + cfg.turn / 60
            sc.ctx.views[1].cameraValue = nil
            local yaw, pitch = math.rad(c.yaw), math.rad(c.pitch)
            local cp = math.cos(pitch)
            local t = c.target
            local value = { eye = { t[1] + c.distance * cp * math.sin(yaw), t[2] + c.distance * math.sin(pitch),
                                    t[3] - c.distance * cp * math.cos(yaw) }, target = t, fovY = math.rad(c.fov) }
            sc.ctx.views[1].cameraValue = value
            sc.ctx.views[1].block.camera = value
        end
        if cfg.lightOrbit then
            local d, a = sc.ctx.lightData, n * cfg.lightOrbit
            sc.ctx.light.light = { center = { 3 * math.cos(a), 3.5, 3 * math.sin(a) - 1 }, orbitRadius = 0,
                color = d.color, intensity = d.intensity, range = d.range, speed = 0, phase = 0, bob = 0 }
        end
        if cfg.step then cfg.step(sc, n) end
        sc:frame()
        n = n + 1
        if n == 61 then
            rhi.save_texture(sc.ctx.views[1].targets.splatColor, string.format("%s/%s_mask.rhim", cfg.out, cfg.name))
        end
        if n > 60 and n <= 84 then
            rhi.save_texture(sc.ctx.views[1].taaResolved or sc.ctx.views[1].image, string.format("%s/%s_%02d.rhif", cfg.out, cfg.name, n - 60))
        end
        if cfg.trail then
            if n == 84 then rhi.save_texture(sc.ctx.views[1].taaResolved or sc.ctx.views[1].image, string.format("%s/%s_moving.rhif", cfg.out, cfg.name)) end
            if n == 130 then
                rhi.save_texture(sc.ctx.views[1].taaResolved or sc.ctx.views[1].image, string.format("%s/%s_settled.rhif", cfg.out, cfg.name))
                print("captured " .. cfg.name) rhi.quit()
            end
            return
        end
        if n == 85 then print("captured " .. cfg.name, sc:describe():match("cascades [^|]*") or "") rhi.quit() end
    end
    function on_resize(w, h) sc:layout(w, h) end
end
