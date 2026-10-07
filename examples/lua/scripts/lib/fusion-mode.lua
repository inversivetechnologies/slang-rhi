-- Depth compositing: the mesh scene (lib/scene-mode.lua), the Gaussian splats
-- (lib/splat-mode.lua) and a raymarched composition of SDF shapes (lib/sdf.lua) in one
-- picture. Each is rendered by its own passes into its own color texture and its own depth
-- buffer; a final pass combines them per pixel, by which is nearer the camera
-- (shaders/post/depth-composite.slang).
--
-- The render graph, built once in init():
--
--   scene: generate sphere, shadow faces 0..5      (as in the scene)
--   splats: shadow casters, shadow faces 0..5     the splats as seen from the light, in
--                        a translucent shadow map: how much they dim the light in each
--                        direction, and how far from it they start
--   mesh                 the lit scene -> meshColor, meshDepth
--   raymarch             the SDF composition, lit and shadowed like the meshes, its rays
--                        stopped by meshDepth -> sdfColor, sdfDepth (shaders/sdf/raymarch.slang)
--   splats: preprocess, lighting, sort             (as in the splat example), lit by the
--                        point light and shadowed in between (shaders/splat/lighting.slang)
--   splats: color        the blended splats -> splatColor (transparent background)
--   splats: depth        the same splats, depth only -> splatDepth: where a splat is at
--                        least 30% opaque, its depth; the nearest wins
--   depth composite      all three colors and depths -> the window
--
-- Both passes see the world through one camera block, and both write depth with the same
-- near and far planes, so the two depth buffers can be compared directly. The skull is
-- placed into the scene by a `model` transform in that block.
--
-- It uses the scene and splat instances it is given (sharing their meshes, the loaded
-- file and their parameter blocks), so the showcase loads the 454 MB file only once.
--
--   Mouse drag      orbit the camera          Mouse wheel   zoom
--   V               combined / mesh only / splats only / SDFs only / depth buffers
--   L               splats lit by the point light / as captured (only shadowed)
--   [ / ]           splat size                J / K         SDF blend radii /1.25 / x1.25
--   other keys      as in the scene

local sdf = rhi.include("lib/sdf.lua")

-- The SDF composition, in its own space (it sits on its pedestal, bottom at y = -0.62).
-- Built from the primitives and smooth booleans of lib/sdf.lua; compiled into the node
-- buffer that shaders/sdf/sdf-dag.slang evaluates.
local function buildComposition()
    -- A rounded body: a sphere melted into a box turned onto its corner.
    local body = sdf.smoothUnion(0.12,
        sdf.sphere(0.34):color(0.95, 0.55, 0.15),
        sdf.box(0.24, 0.24, 0.24):rotate("x", math.pi / 4):rotate("y", math.pi / 4):color(0.2, 0.55, 0.95))
    -- Three rods along the axes: one cylinder, placed three ways.
    local rod = sdf.cylinder(0.09, 1.4)
    local cross = sdf.union(rod, rod:rotate("x", math.pi / 2), rod:rotate("z", math.pi / 2)):color(0.9, 0.2, 0.35)
    -- The cross is used twice -- to drill the body, and for the rods' ends that stick out
    -- of it -- and compiled once: both read the same nodes' result.
    local drilled = sdf.smoothSubtract(0.03, body, cross)
    local ends = sdf.smoothSubtract(0.02, sdf.intersect(cross, sdf.sphere(0.62)), sdf.sphere(0.46))
    -- A stem down to a hexagonal pedestal, smoothly joined.
    local grey = { 0.75, 0.75, 0.7 }
    local stem = sdf.capsule(0.07, { 0, -0.55, 0 }, { 0, -0.3, 0 }):color(grey[1], grey[2], grey[3])
    local pedestal = sdf.prism(6, 0.3):scale(0.4):translate(0, -0.56, 0):color(grey[1], grey[2], grey[3])
    return sdf.union(sdf.smoothUnion(0.08, drilled, stem, pedestal), ends)
end

return function(scene, splat, setTitle)
    local fusion = { name = "Depth Composite" }
    setTitle = setTitle or function(details)
        rhi.set_title("Depth Composite | " .. details)
    end

    local FLOOR_Y = -1 -- the scene's floor
    local orbit = { yaw = 2.6, pitch = 0.32, distance = 6.5, target = { 0, -0.3, 0.5 }, fovY = math.rad(50) }

    local SHOW_MODES = { "combined", "mesh only", "splats only", "SDFs only", "depth buffers" }
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

    -- 1: the splats lit by the point light; 0: their captured colors, only shadowed.
    local relight = 1
    -- Multiplies every blend radius of the SDF composition.
    local smoothScale = 1
    local sdfInfo = ""

    local function updateTitle()
        setTitle(string.format("showing %s (V) | splats %s (L) | SDF %s, blend x%.2f (J/K)", SHOW_MODES[showMode],
            relight == 1 and "lit by the light" or "as captured", sdfInfo, smoothScale))
    end

    function fusion.init()
        scene.createResources()
        splat.createResources()

        -- Each side renders into its own color texture and depth buffer.
        local meshColor = rhi.render_target("rgba16f")
        local meshDepth = rhi.depth_target()
        local splatColor = rhi.render_target("rgba16f")
        local splatDepth = rhi.depth_target()
        local sdfColor = rhi.render_target("rgba16f")
        local sdfDepth = rhi.render_target("r32f")
        local composite = rhi.render_pipeline { shader = "post/depth-composite.slang" }
        local raymarch = rhi.compute_pipeline("sdf/raymarch.slang", "raymarchMain")

        -- The SDF composition, compiled into a node buffer once.
        local program = sdf.compile(buildComposition())
        sdfInfo = string.format("%d nodes, %d slots", program.nodeCount, program.slotCount)

        -- One block for every pass: the camera, the skull's placement in the scene, and the
        -- SDF composition -- which the raymarching draws, and every receiver of shadows
        -- marches toward the light for its soft shadows. The mesh is drawn in linear color;
        -- the composite does the gamma encoding when needed.
        blocks.view = rhi.params {
            camera = scene.orbitCamera(orbit),
            encodeGamma = 0,
            model = placement(),
            splatShadows = 1, -- receivers read the splats' shadow maps
            sdfShadows = 1,   -- ...and march the SDFs
            sdfShadowSharpness = 8,
            sdfNodes = rhi.buffer(program.floats),
            sdfNodeCount = program.nodeCount,
            sdfResultSlot = program.resultSlot,
            smoothScale = smoothScale,
            sdfOrigin = { 1.85, FLOOR_Y + 0.62, 1.25 },
            sdfSpin = 0.4,
            -- The composition fits in this sphere around its origin (with room for blend
            -- radii grown by K); rays that miss it skip marching.
            sdfBoundsRadius = 0.95,
        }
        blocks.sdf = blocks.view

        graph = rhi.graph()
        scene.addShadowPasses(graph)
        -- The splats cast shadows on the meshes: drawn as seen from the light into a
        -- translucent shadow map of their own, which the lit pass reads along with the
        -- scene's.
        local splatShadowAtlas, splatShadowLayers, faceSize = scene.splatShadowAtlas()
        splat.addShadowPasses(graph, {
            name = "splats",
            view = blocks.view,
            light = scene.lightBlock(),
            atlas = splatShadowAtlas,
            layers = splatShadowLayers,
            faceSize = faceSize,
        })
        scene.addCameraPass(graph, {
            name = "mesh",
            view = blocks.view,
            target = meshColor,
            depthTarget = meshDepth,
            clear = { 0.015, 0.018, 0.025, 1 },
        })
        -- The SDFs, raymarched up to the meshes' depth, lit and shadowed like them.
        graph:dispatch {
            name = "raymarch",
            pipeline = raymarch,
            params = {
                scene.lightBlock(),
                scene.shadowBlock(),
                blocks.view, -- after the shadow block: its splat and SDF shadow settings win
                { meshDepth = meshDepth, sdfColor = sdfColor, sdfDepth = sdfDepth },
            },
            threads = "window", -- one thread per pixel
        }
        splat.addPasses(graph, {
            name = "splats",
            view = blocks.view,
            target = splatColor,
            clear = { 0, 0, 0, 0 }, -- transparent: the mesh shows through where no splat is
            depthTarget = splatDepth,
            -- Lit by the scene's light, and shadowed by the meshes and by each other.
            lighting = { scene.lightBlock(), scene.shadowBlock() },
        })

        blocks.composite = rhi.params {
            meshColor = meshColor,
            meshDepth = meshDepth,
            splatColor = splatColor,
            splatDepth = splatDepth,
            sdfColor = sdfColor,
            sdfDepth = sdfDepth,
            depthNear = 0.1, -- the planes every pass writes depth with
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
        elseif (key == keys.J or key == keys.K) and action ~= input.RELEASE then
            smoothScale = key == keys.K and math.min(8, smoothScale * 1.25) or math.max(0, smoothScale / 1.25)
            if smoothScale < 0.01 then smoothScale = 0 end
            blocks.sdf.smoothScale = smoothScale
            updateTitle()
        elseif key == keys.L and action == input.PRESS then
            relight = 1 - relight
            splat.setRelight(relight)
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
