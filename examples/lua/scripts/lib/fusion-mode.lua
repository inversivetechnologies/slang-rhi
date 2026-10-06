-- Depth compositing: the mesh scene (lib/scene-mode.lua) and the Gaussian splats
-- (lib/splat-mode.lua) in one picture. Each is rendered by its own passes into its own
-- color texture and its own depth buffer; a final pass combines them per pixel, by which
-- is nearer the camera (shaders/post/depth-composite.slang).
--
-- The render graph, built once in init():
--
--   scene: generate sphere, shadow faces 0..5      (as in the scene)
--   mesh                 the lit scene -> meshColor, meshDepth
--   splats: preprocess, sort                       (as in the splat example)
--   splats: color        the blended splats -> splatColor (transparent background)
--   splats: depth        the same splats, depth only -> splatDepth: where a splat is at
--                        least 30% opaque, its depth; the nearest wins
--   depth composite      meshColor + meshDepth + splatColor + splatDepth -> the window
--
-- Both passes see the world through one camera block, and both write depth with the same
-- near and far planes, so the two depth buffers can be compared directly. The skull is
-- placed into the scene by a `model` transform in that block.
--
-- It uses the scene and splat instances it is given (sharing their meshes, the loaded
-- file and their parameter blocks), so the showcase loads the 454 MB file only once.
--
--   Mouse drag      orbit the camera          Mouse wheel   zoom
--   V               combined / mesh only / splats only / depth buffers
--   [ / ]           splat size                other keys    as in the scene

return function(scene, splat, setTitle)
    local fusion = { name = "Depth Composite" }
    setTitle = setTitle or function(details)
        rhi.set_title("Depth Composite | " .. details)
    end

    local FLOOR_Y = -1 -- the scene's floor
    local orbit = { yaw = 2.6, pitch = 0.32, distance = 6.5, target = { 0, -0.3, 0.5 }, fovY = math.rad(50) }

    local SHOW_MODES = { "combined", "mesh only", "splats only", "depth buffers" }
    local showMode = 1

    local graph
    local blocks = {}

    -- Where the skull goes: between the sphere and the starting camera, facing it, its
    -- jaw sunk a little into the floor so that the depth test has something to cut.
    local function placement()
        local bounds = splat.bounds()
        local scale = 1.3 / bounds.radius
        local yaw = math.rad(-60)
        local at = { -0.2, FLOOR_Y + 0.6, 1.5 }
        -- model.position = at - rotateYaw(center * scale), as preprocess.slang applies it.
        local c = { bounds.center[1] * scale, bounds.center[2] * scale, bounds.center[3] * scale }
        local cy, sy = math.cos(yaw), math.sin(yaw)
        local rotated = { cy * c[1] + sy * c[3], c[2], -sy * c[1] + cy * c[3] }
        return {
            position = { at[1] - rotated[1], at[2] - rotated[2], at[3] - rotated[3] },
            yaw = yaw,
            scale = scale,
        }
    end

    local function updateTitle()
        setTitle("showing " .. SHOW_MODES[showMode] .. " (V)")
    end

    function fusion.init()
        scene.createResources()
        splat.createResources()

        -- Each side renders into its own color texture and depth buffer.
        local meshColor = rhi.render_target("rgba16f")
        local meshDepth = rhi.depth_target()
        local splatColor = rhi.render_target("rgba16f")
        local splatDepth = rhi.depth_target()
        local composite = rhi.render_pipeline { shader = "post/depth-composite.slang" }

        -- One camera for both sides, and the skull's placement in the scene. The mesh is
        -- drawn in linear color; the composite does the gamma encoding when needed.
        blocks.view = rhi.params {
            camera = scene.orbitCamera(orbit),
            encodeGamma = 0,
            model = placement(),
        }

        graph = rhi.graph()
        scene.addShadowPasses(graph)
        scene.addCameraPass(graph, {
            name = "mesh",
            view = blocks.view,
            target = meshColor,
            depthTarget = meshDepth,
            clear = { 0.015, 0.018, 0.025, 1 },
        })
        splat.addPasses(graph, {
            name = "splats",
            view = blocks.view,
            target = splatColor,
            clear = { 0, 0, 0, 0 }, -- transparent: the mesh shows through where no splat is
            depthTarget = splatDepth,
        })

        blocks.composite = rhi.params {
            meshColor = meshColor,
            meshDepth = meshDepth,
            splatColor = splatColor,
            splatDepth = splatDepth,
            depthNear = 0.1, -- the planes both sides write depth with
            depthFar = 100,
            encodeGamma = rhi.window_srgb() and 0 or 1,
            showMode = showMode - 1,
        }
        local present = graph:render_pass { name = "depth composite" }
        present:draw { pipeline = composite, count = 3, params = blocks.composite }
    end

    function fusion.on_enter()
        rhi.set_graph(graph)
        updateTitle()
    end

    function fusion.on_leave()
        rhi.set_graph(nil)
    end

    -- Input: parameter blocks only, as in the scene and the splats.

    function fusion.on_key(key, action, mods)
        if key == keys.V and action == input.PRESS then
            showMode = showMode % #SHOW_MODES + 1
            blocks.composite.showMode = showMode - 1
            updateTitle()
        elseif key == keys.LEFT_BRACKET or key == keys.RIGHT_BRACKET then
            splat.on_key(key, action, mods)
            updateTitle()
        elseif key ~= keys.F then -- flipping the splats would undo their placement
            scene.on_key(key, action, mods)
        end
    end

    local drag

    function fusion.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return end
        drag = action == input.PRESS and { input.mouse() } or nil
    end

    function fusion.on_mouse_move(x, y)
        if not drag then return end
        orbit.yaw = orbit.yaw - (x - drag[1]) * 0.008
        orbit.pitch = math.max(0.02, math.min(1.45, orbit.pitch + (y - drag[2]) * 0.008))
        drag = { x, y }
        blocks.view.camera = scene.orbitCamera(orbit)
    end

    function fusion.on_scroll(x, y)
        orbit.distance = math.max(1.5, math.min(15, orbit.distance - y * 0.5))
        blocks.view.camera = scene.orbitCamera(orbit)
    end

    return fusion
end
