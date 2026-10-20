-- A rigid body physics test scene, on Jolt Physics (examples/lua/physics.cpp).
--
-- A ball rolls down a ramp into a row of dominoes; the last domino topples into a box
-- pyramid. A tower of boxes stands beside them, to be knocked over with thrown balls, and
-- more boxes and balls can be dropped from the sky.
--
-- The host owns the physics: Lua only builds the world (rhi.physics_world) and its bodies,
-- in groups. The host steps the world every frame, at a fixed 60 Hz, and writes every
-- group's transforms into the group's GPU buffer. The render graph then draws each group in
-- one instanced draw (instances = the group, so it always draws as many bodies as the group
-- has), lit and shadowed as the scene's meshes are (scene/lit.slang, scene/shadow.slang:
-- bodyVertexMain). Neither the physics nor the drawing runs Lua per frame.
--
-- A player character (lib/player.lua) runs through it all, steered with a Steam
-- Controller (or the keyboard) the way Darksiders is, with the camera on it. Its input,
-- movement and pose are Lua, every frame; its body is a Jolt character the host moves.
--
--   Steam Controller  see lib/player.lua; also Menu reset, View drop a burst
--   WASD, Space, Shift, F, G, Q, E, C   the player (see lib/player.lua)
--   Mouse drag      turn the camera       Mouse wheel   camera distance
--   B               drop a burst of boxes and balls
--   R               reset the scene       P             pause
--   T               slow motion

local meshes = rhi.include("lib/meshes.lua")
local createPlayer = rhi.include("lib/player.lua")
local settings = rhi.include("lib/settings.lua") -- the controls (look sensitivity)

return function(setTitle)
    local mode = { name = "Physics" }
    setTitle = setTitle or function(details)
        rhi.set_title("Physics | " .. details)
    end

    local SHADOW_FACE_SIZE = rhi.include("lib/settings.lua").shadowFaceSize() -- the pause menu's shadow quality

    local world, groups, blocks, graph, player, crosshairPass
    local slowMotion = false
    local title = ""

    local function updateTitle()
        local text = string.format("%s | %d boxes, %d balls%s%s | B drop, R reset, P pause, T slow motion",
            player.describe(), groups.boxes.count, groups.balls.count,
            world.paused and " | paused" or "", slowMotion and " | slow motion" or "")
        if text ~= title then
            title = text
            setTitle(text)
        end
    end

    -- A rotation of `angle` radians about the y or z axis, as a quaternion x, y, z, w.
    local function about(axis, angle)
        local s, c = math.sin(angle / 2), math.cos(angle / 2)
        if axis == "y" then return { 0, s, 0, c } end
        return { 0, 0, s, c }
    end

    local PALETTE = {
        { 0.90, 0.35, 0.28 }, { 0.30, 0.55, 0.90 }, { 0.95, 0.75, 0.25 },
        { 0.35, 0.75, 0.45 }, { 0.70, 0.40, 0.85 }, { 0.90, 0.55, 0.20 },
    }

    -- ---------------------------------------------------------------------------------
    -- The scene's bodies
    -- ---------------------------------------------------------------------------------

    local function addStatics()
        local statics = groups.statics
        -- The floor: its top at y = 0, with the checker pattern.
        statics:add { shape = "box", motion = "static", half_extents = { 14, 0.25, 14 }, position = { 0, -0.25, 0 },
            color = { 0.8, 0.8, 0.78 }, pattern = 2, friction = 0.8 }
        -- A ramp, rising toward +x, that sends a ball into the dominoes.
        statics:add { shape = "box", motion = "static", half_extents = { 1.6, 0.08, 0.55 }, position = { 5.6, 0.62, 0 },
            rotation = about("z", math.rad(22)), color = { 0.55, 0.5, 0.45 }, friction = 0.4 }
        -- Its side rails.
        for _, z in ipairs { -0.6, 0.6 } do
            statics:add { shape = "box", motion = "static", half_extents = { 1.6, 0.12, 0.04 }, position = { 5.6, 0.72, z },
                rotation = about("z", math.rad(22)), color = { 0.45, 0.42, 0.38 } }
        end
    end

    local function addDynamics()
        local boxes, balls = groups.boxes, groups.balls

        -- The ball at the top of the ramp.
        balls:add { shape = "sphere", radius = 0.22, position = { 6.9, 1.4, 0 }, density = 2500,
            color = { 0.95, 0.95, 0.95 }, pattern = 1, friction = 0.3, restitution = 0.2 }

        -- Dominoes from the foot of the ramp toward -x; the last falls into the pyramid.
        for i = 0, 13 do
            boxes:add { shape = "box", half_extents = { 0.05, 0.42, 0.24 }, position = { 3.6 - i * 0.46, 0.42, 0 },
                color = PALETTE[i % #PALETTE + 1], density = 600, friction = 0.6 }
        end

        -- A pyramid of boxes where the dominoes end.
        local size = 0.2
        for level = 0, 6 do
            for i = 0, 6 - level do
                local x = -4.0 - (6 - level) * size + i * 2 * size
                boxes:add { shape = "box", half_extents = { size, size, size }, position = { x, size + level * 2 * size, 0 },
                    color = PALETTE[level % #PALETTE + 1], density = 300, friction = 0.6 }
            end
        end

        -- A tower to throw balls at: layers of three boards side by side, each layer turned
        -- a quarter turn from the one below.
        for level = 0, 11 do
            local turn = level % 2 == 0 and 0 or math.pi / 2
            for j = -1, 1 do
                -- Side by side across the boards' long axis (their local x), turned with them.
                local offset = { j * 0.32 * math.cos(turn), -j * 0.32 * math.sin(turn) }
                boxes:add { shape = "box", half_extents = { 0.15, 0.1, 0.48 }, rotation = about("y", turn),
                    position = { 0.5 + offset[1], 0.1 + level * 0.2, 3.2 + offset[2] },
                    color = level % 2 == 0 and { 0.82, 0.68, 0.48 } or { 0.72, 0.55, 0.38 }, density = 400, friction = 0.7 }
            end
        end
    end

    local function reset()
        groups.boxes:clear()
        groups.balls:clear()
        addDynamics()
        player.reset()
    end

    -- ---------------------------------------------------------------------------------
    -- Building the graph
    -- ---------------------------------------------------------------------------------

    function mode.init()
        world = rhi.physics_world { gravity = { 0, -9.81, 0 }, max_bodies = 4096 }
        groups = {
            statics = world:group { capacity = 16 },
            boxes = world:group { capacity = 1500 },
            balls = world:group { capacity = 800 },
        }
        addStatics()
        addDynamics()
        -- The player starts behind the dominoes, looking at the tower and the pyramid; its
        -- attacks hit the boxes and the balls, and it throws balls.
        player = createPlayer(world, {
            spawn = { 0, 0.05, -5 },
            targets = { groups.boxes, groups.balls },
            projectiles = groups.balls,
        })
        player.init()

        local cube = meshes.cube()
        local ball = meshes.sphere(16)
        local shadowAtlas = rhi.texture { width = 3 * SHADOW_FACE_SIZE, height = 2 * SHADOW_FACE_SIZE, format = "r32f" }
        local shadowPipeline = rhi.render_pipeline { shader = "scene/shadow.slang", vertex = "bodyVertexMain", format = "r32f", depth = true }
        local litPipeline = rhi.render_pipeline { shader = "scene/lit.slang", vertex = "bodyVertexMain", fragment = "bodyFragmentMain", depth = true }

        -- A light high above, circling slowly.
        blocks.light = rhi.params {
            light = {
                center = { 0, 6.5, 0 }, orbitRadius = 3.5, color = { 1.0, 0.92, 0.8 }, intensity = 55,
                range = 30, speed = 0.15, phase = 0.5, bob = 0.4,
            },
        }
        -- The shadow lookup (scene/shadow-lookup.slang) also has inputs for the splats' and
        -- the SDFs' shadows; there are none here, so they are switched off, and bound to
        -- placeholders.
        blocks.shadows = rhi.params {
            shadowMap = shadowAtlas,
            shadowFaceSize = SHADOW_FACE_SIZE,
            splatShadows = 0,
            splatShadowMap = rhi.texture { width = 1, height = 1, format = "rgba16f" },
            splatShadowLayers = rhi.texture { width = 1, height = 1, format = "rgba16f" },
            sdfShadows = 0, sdfShadowSharpness = 8, sdfNodes = rhi.buffer(128), sdfNodeCount = 0,
            sdfResultSlot = 0, smoothScale = 1, sdfOrigin = { 0, 0, 0 }, sdfSpin = 0, sdfBoundsRadius = 0,
            sdfUseCache = 0,
            sdfCacheDistance = rhi.texture { width = 1, height = 1, depth = 1, format = "r16f" },
            sdfCacheColor = rhi.texture { width = 1, height = 1, depth = 1, format = "rgba8" },
            sdfCacheSampler = rhi.sampler(),
            sdfCacheExtent = 1,
            sdfCacheResolution = 1,
        }
        blocks.camera = rhi.params { camera = player.camera(), encodeGamma = rhi.window_srgb() and 0 or 1 }
        blocks.crosshair = rhi.params {
            crosshairColor = { 1, 1, 1, 0.85 },
            crosshairHotColor = { 1, 0.45, 0.15, 1 },
            crosshairHot = 0,
            crosshairSpread = 0,
        }

        -- What to draw: each group with its mesh, one instance per body.
        local draws = {
            { group = groups.statics, mesh = cube },
            { group = groups.boxes, mesh = cube },
            { group = groups.balls, mesh = ball },
            { group = player.parts, mesh = cube },
            { group = player.round, mesh = ball },
        }

        graph = rhi.graph()
        for face = 0, 5 do
            local pass = graph:render_pass {
                name = "shadow face " .. face,
                target = shadowAtlas,
                viewport = { (face % 3) * SHADOW_FACE_SIZE, (face // 3) * SHADOW_FACE_SIZE, SHADOW_FACE_SIZE, SHADOW_FACE_SIZE },
                clear = face == 0 and { 1e9, 0, 0, 1 } or nil,
            }
            for _, d in ipairs(draws) do
                pass:draw {
                    pipeline = shadowPipeline, count = d.mesh.count, instances = d.group,
                    params = { { vertices = d.mesh.buffer, bodies = d.group.buffer, face = face }, blocks.light },
                }
            end
        end
        local main = graph:render_pass { name = "bodies", clear = { 0.015, 0.018, 0.025, 1 } }
        for _, d in ipairs(draws) do
            main:draw {
                pipeline = litPipeline, count = d.mesh.count, instances = d.group,
                params = { { vertices = d.mesh.buffer, bodies = d.group.buffer }, blocks.light, blocks.shadows, blocks.camera },
            }
        end

        -- The crosshair, over everything, in aim mode only.
        crosshairPass = graph:render_pass { name = "crosshair" }
        crosshairPass:draw {
            pipeline = rhi.render_pipeline { shader = "post/crosshair.slang", blend = "alpha" },
            count = 3,
            params = blocks.crosshair,
        }
        crosshairPass.enabled = false
    end

    -- Every frame: the player, and what follows it (the camera, the crosshair, the title).
    function mode.update(_, dt)
        if world.paused then dt = 0 end
        player.update(dt * world.time_scale)
        blocks.camera.camera = player.camera()
        local aiming = player.aiming()
        crosshairPass.enabled = aiming
        if aiming then
            local hot, spread = player.crosshair()
            blocks.crosshair.crosshairHot = hot
            blocks.crosshair.crosshairSpread = spread
        end
        updateTitle()
    end

    function mode.on_enter()
        player.clear_input()
        rhi.set_graph(graph)
        rhi.set_physics(world)
        updateTitle()
    end

    function mode.on_leave()
        rhi.set_graph(nil)
        rhi.set_physics(nil)
    end

    -- ---------------------------------------------------------------------------------
    -- Input: adds and removes bodies, and changes the world's settings
    -- ---------------------------------------------------------------------------------

    local function dropBurst()
        for _ = 1, 24 do
            local position = { (math.random() - 0.5) * 6, 6 + math.random() * 4, (math.random() - 0.5) * 6 }
            local color = PALETTE[math.random(#PALETTE)]
            if math.random() < 0.5 then
                local s = 0.12 + math.random() * 0.2
                groups.boxes:add { shape = "box", half_extents = { s, s * (0.6 + math.random()), s }, position = position,
                    rotation = about("y", math.random() * math.pi), color = color, density = 500,
                    angular_velocity = { math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2 } }
            else
                groups.balls:add { shape = "sphere", radius = 0.12 + math.random() * 0.18, position = position,
                    color = color, pattern = 1, density = 800, restitution = 0.4 }
            end
        end
    end

    function mode.on_key(key, action)
        if player.on_key(key, action) then return end
        if action ~= input.PRESS then return end
        if key == keys.B then
            dropBurst()
        elseif key == keys.R then
            reset()
        elseif key == keys.P then
            world.paused = not world.paused
        elseif key == keys.T then
            slowMotion = not slowMotion
            world.time_scale = slowMotion and 0.25 or 1
        else
            return
        end
        updateTitle()
    end

    local drag

    function mode.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return end
        drag = action == input.PRESS and { input.mouse() } or nil
    end

    function mode.on_mouse_move(x, y)
        if not drag then return end
        local dx, dy = settings.mouseLook(x - drag[1], y - drag[2]) -- the controls' sensitivity
        player.look(dx * 0.006, dy * 0.006)
        drag = { x, y }
    end

    function mode.on_scroll(_, y)
        player.zoom(y)
    end

    function mode.on_controller_button(slot, button, pressed)
        if player.on_controller_button(slot, button, pressed) then return true end
        if not pressed then return false end
        if button == buttons.Menu then
            reset()
        elseif button == buttons.View then
            dropBurst()
        else
            return false
        end
        return true
    end

    blocks = {}
    return mode
end
