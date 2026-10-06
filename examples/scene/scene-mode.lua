-- A small lit scene: a spherified cube, a spinning cube and a checkered floor, lit by a
-- point light that orbits above them and casts realtime shadows. A second camera watches
-- from another angle; its view is composited into the lower right corner of the window.
--
-- The frame is a render graph: built here once, in init(), and run by the host every frame
-- without calling into Lua. Its passes, in order:
--
--   generate sphere   compute (spherified-cube.slang), only when its parameters change
--   shadow face 0..5  the scene from the light, one cube face per cell of the shadow atlas;
--                     each texel stores the distance to the nearest surface (shadow.slang)
--   main camera       the scene lit and shadowed, into the window (lit.slang)
--   second camera     the same objects from another camera, into a texture (lit.slang)
--   composite         that texture into the window's lower right corner (composite.slang)
--
-- Both camera passes read the shadow atlas, and the composite reads the second camera's
-- texture: the passes are composed through the textures they share.
--
-- Draws get their shader parameters from parameter blocks (rhi.params). A block is shared
-- by every draw that lists it, so changing one value -- the camera, when the mouse drags
-- it -- changes all of those draws on the next frame. Motion that never stops (the light's
-- orbit, the cube's spin) is computed by the shaders from `time` instead, so Lua does
-- nothing per frame at all: it only responds to input.
--
-- The sphere is generated on the GPU; the cube and the floor are built here in Lua. All
-- three use the same vertex format (mesh-vertex.slang) and are drawn without a vertex
-- layout: the shaders fetch vertices by SV_VertexID.
--
-- This file returns a constructor, so the scene can run on its own (scene.lua) or as a
-- mode of the showcase. `dir` is the path from the running script to this folder, since
-- shader paths are relative to the running script. `setTitle(details)`, if given, shows
-- the scene's parameters; by default they go in the window title after "Scene".
--
--   Mouse drag      orbit the camera        Mouse wheel           zoom
--   Up / Down       subdivision +/- 1       Page Up / Page Down   subdivision x2 / /2
--   + / -           sphere radius           Space                 pause the light
--   Tab             show / hide the second camera

return function(dir, setTitle)
    local scene = { name = "Scene" }
    setTitle = setTitle or function(details)
        rhi.set_title("Scene | " .. details)
    end

    -- ---------------------------------------------------------------------------------
    -- Parameters
    -- ---------------------------------------------------------------------------------

    local sphere = { subdivision = 24, radius = 0.8 }
    local MAX_SUBDIVISION = 128
    local MIN_RADIUS, MAX_RADIUS = 0.2, 1.4

    local FLOOR_Y = -1

    -- Mirrors the shaders' PointLight; the orbit is computed on the GPU from `time`.
    local light = {
        center = { 0, FLOOR_Y + 1.4, 0 },
        orbitRadius = 2.3,
        color = { 1.0, 0.85, 0.65 },
        intensity = 9,
        range = 14,
        speed = 0.5, -- radians per second
        phase = 0.8,
        bob = 0.4,
    }
    local LIGHT_SPEED = light.speed

    local camera = { yaw = 0.5, pitch = 0.42, distance = 7.5, target = { 0, -0.4, 0 }, fovY = math.rad(50) }

    -- The second camera: low, from the opposite side, looking across the floor.
    local secondCamera = { eye = { -4.2, 0.6, 3.6 }, target = { 0.2, -0.6, -0.2 }, fovY = math.rad(55) }

    -- Where the second camera's view goes, as fractions of the window, and how big its
    -- texture is relative to the window (the same, so it isn't stretched).
    local INSET = { 0.68, 0.66, 0.30, 0.30 }

    local SHADOW_FACE_SIZE = 512 -- texels per cube face; the atlas is 3 x 2 faces
    local VERTEX_SIZE = 32       -- sizeof(MeshVertex)

    -- ---------------------------------------------------------------------------------
    -- Meshes
    -- ---------------------------------------------------------------------------------

    local function sphereVertexCount(n)
        return 6 * n * n * 6 -- faces * quads * 2 triangles * 3 vertices
    end

    -- Appends one MeshVertex (8 floats) to `floats`.
    local function pushVertex(floats, position, normal, face)
        for k = 1, 3 do floats[#floats + 1] = position[k] end
        floats[#floats + 1] = 0
        for k = 1, 3 do floats[#floats + 1] = normal[k] end
        floats[#floats + 1] = face
    end

    -- A cube from -1 to 1. The face table matches spherified-cube.slang.
    local function cubeMesh()
        local faces = {
            { n = { 1, 0, 0 }, u = { 0, 0, -1 }, v = { 0, 1, 0 } },
            { n = { -1, 0, 0 }, u = { 0, 0, 1 }, v = { 0, 1, 0 } },
            { n = { 0, 1, 0 }, u = { 1, 0, 0 }, v = { 0, 0, -1 } },
            { n = { 0, -1, 0 }, u = { 1, 0, 0 }, v = { 0, 0, 1 } },
            { n = { 0, 0, 1 }, u = { 1, 0, 0 }, v = { 0, 1, 0 } },
            { n = { 0, 0, -1 }, u = { -1, 0, 0 }, v = { 0, 1, 0 } },
        }
        local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
        local floats = {}
        for f, face in ipairs(faces) do
            for _, c in ipairs { 1, 2, 3, 1, 3, 4 } do
                local a, b = corners[c][1], corners[c][2]
                local p = {}
                for k = 1, 3 do p[k] = face.n[k] + a * face.u[k] + b * face.v[k] end
                pushVertex(floats, p, face.n, f - 1)
            end
        end
        return { buffer = rhi.buffer(floats), count = 36 }
    end

    -- A square from -1 to 1 in x and z, facing up.
    local function floorMesh()
        local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
        local floats = {}
        for _, c in ipairs { 1, 2, 3, 1, 3, 4 } do
            pushVertex(floats, { corners[c][1], 0, corners[c][2] }, { 0, 1, 0 }, 2)
        end
        return { buffer = rhi.buffer(floats), count = 6 }
    end

    -- ---------------------------------------------------------------------------------
    -- Graph state, filled in by init()
    -- ---------------------------------------------------------------------------------

    local graph
    local blocks = {}       -- parameter blocks the input handlers update
    local generateNode      -- the sphere's generator dispatch
    local sphereDraws = {}  -- every draw of the sphere mesh, to update its vertex count
    local insetPasses = {}  -- the second camera's passes, for Tab

    local function sphereTransform()
        return { position = { -1.2, FLOOR_Y + sphere.radius, 0.3 }, yaw = 0, spin = 0.3, scale = { 1, 1, 1 }, followLight = 0 }
    end

    -- The light's marker is the sphere mesh scaled to a small ball wherever the radius is.
    local function markerTransform()
        local s = 0.08 / sphere.radius
        return { position = { 0, 0, 0 }, yaw = 0, spin = 0, scale = { s, s, s }, followLight = 1 }
    end

    local function mainCameraParams()
        local cp, sp = math.cos(camera.pitch), math.sin(camera.pitch)
        local t = camera.target
        return {
            eye = {
                t[1] + camera.distance * cp * math.sin(camera.yaw),
                t[2] + camera.distance * sp,
                t[3] - camera.distance * cp * math.cos(camera.yaw),
            },
            target = t,
            fovY = camera.fovY,
        }
    end

    local function updateTitle()
        setTitle(string.format(
            "sphere subdivision %d, radius %.2f%s",
            sphere.subdivision, sphere.radius, light.speed == 0 and " | light paused" or ""))
    end

    -- ---------------------------------------------------------------------------------
    -- Building the graph
    -- ---------------------------------------------------------------------------------

    function scene.init()
        local srgb = rhi.window_srgb()

        local generate = rhi.compute_pipeline(dir .. "spherified-cube.slang", "generateMain")
        local shadow = rhi.render_pipeline { shader = dir .. "shadow.slang", format = "r32f", depth = true }
        local litWindow = rhi.render_pipeline { shader = dir .. "lit.slang", depth = true }
        -- The same shader again, for the second camera's texture: a pipeline is built for
        -- one target format.
        local litTexture = rhi.render_pipeline { shader = dir .. "lit.slang", format = "rgba16f", depth = true }
        local composite = rhi.render_pipeline { shader = dir .. "composite.slang" }

        local sphereMesh = { buffer = rhi.buffer(sphereVertexCount(MAX_SUBDIVISION) * VERTEX_SIZE) }
        local cube = cubeMesh()
        local floor = floorMesh()

        local shadowAtlas = rhi.texture { width = 3 * SHADOW_FACE_SIZE, height = 2 * SHADOW_FACE_SIZE, format = "r32f" }
        -- Linear (rgba16f): the composite pass does the gamma encoding when it is needed.
        local secondView = rhi.render_target("rgba16f", INSET[3])

        -- Parameter blocks. Each object has one with its mesh, transform and material;
        -- the light, the shadow atlas and each camera have one shared by every draw.
        blocks.light = rhi.params { light = light }
        blocks.shadowMap = rhi.params { shadowMap = shadowAtlas, shadowFaceSize = SHADOW_FACE_SIZE }
        blocks.mainCamera = rhi.params { camera = mainCameraParams(), encodeGamma = srgb and 0 or 1 }
        blocks.secondCamera = rhi.params { camera = secondCamera, encodeGamma = 0 }
        blocks.generate = rhi.params {
            subdivision = sphere.subdivision,
            radius = sphere.radius,
            vertices = sphereMesh.buffer,
        }
        blocks.sphere = rhi.params {
            vertices = sphereMesh.buffer,
            transform = sphereTransform(),
            material = { albedo = { 0.9, 0.35, 0.28 }, pattern = 1, emissive = 0 },
        }
        blocks.marker = rhi.params {
            vertices = sphereMesh.buffer,
            transform = markerTransform(),
            material = { albedo = light.color, pattern = 0, emissive = 1 },
        }

        local objects = {
            {
                count = floor.count,
                castsShadow = true,
                params = rhi.params {
                    vertices = floor.buffer,
                    transform = { position = { 0, FLOOR_Y, 0 }, yaw = 0, spin = 0, scale = { 6, 1, 6 }, followLight = 0 },
                    material = { albedo = { 0.8, 0.8, 0.78 }, pattern = 2, emissive = 0 },
                },
            },
            { count = sphereVertexCount(sphere.subdivision), castsShadow = true, isSphere = true, params = blocks.sphere },
            {
                count = cube.count,
                castsShadow = true,
                params = rhi.params {
                    vertices = cube.buffer,
                    transform = { position = { 1.3, FLOOR_Y + 0.6, -0.4 }, yaw = 0, spin = 0.7, scale = { 0.6, 0.6, 0.6 }, followLight = 0 },
                    material = { albedo = { 0.3, 0.55, 0.9 }, pattern = 0, emissive = 0 },
                },
            },
            -- The light sits inside its marker, so the marker must not cast shadows.
            { count = sphereVertexCount(sphere.subdivision), castsShadow = false, isSphere = true, params = blocks.marker },
        }

        graph = rhi.graph()
        sphereDraws = {}

        local function addDraw(pass, object, pipeline, extraBlocks)
            local params = { object.params }
            for _, block in ipairs(extraBlocks) do params[#params + 1] = block end
            local draw = pass:draw { pipeline = pipeline, count = object.count, params = params }
            if object.isSphere then sphereDraws[#sphereDraws + 1] = draw end
        end

        generateNode = graph:dispatch {
            name = "generate sphere",
            pipeline = generate,
            params = blocks.generate,
            threads = { sphere.subdivision, sphere.subdivision, 6 }, -- one thread per quad, per face
            once = true,
        }

        for face = 0, 5 do
            local pass = graph:render_pass {
                name = "shadow face " .. face,
                target = shadowAtlas,
                viewport = { (face % 3) * SHADOW_FACE_SIZE, (face // 3) * SHADOW_FACE_SIZE, SHADOW_FACE_SIZE, SHADOW_FACE_SIZE },
                -- The first face clears the whole atlas to "nothing in the way".
                clear = face == 0 and { 1e9, 0, 0, 1 } or nil,
            }
            local faceBlock = rhi.params { face = face }
            for _, object in ipairs(objects) do
                if object.castsShadow then
                    addDraw(pass, object, shadow, { blocks.light, faceBlock })
                end
            end
        end

        local mainPass = graph:render_pass { name = "main camera", clear = { 0.015, 0.018, 0.025, 1 } }
        for _, object in ipairs(objects) do
            addDraw(mainPass, object, litWindow, { blocks.light, blocks.shadowMap, blocks.mainCamera })
        end

        local secondPass = graph:render_pass { name = "second camera", target = secondView, clear = { 0.03, 0.035, 0.05, 1 } }
        for _, object in ipairs(objects) do
            addDraw(secondPass, object, litTexture, { blocks.light, blocks.shadowMap, blocks.secondCamera })
        end

        local compositePass = graph:render_pass { name = "composite", viewport_fraction = INSET }
        compositePass:draw {
            pipeline = composite,
            count = 3,
            params = {
                source = secondView,
                borderColor = { 0.85, 0.85, 0.9, 1 },
                borderWidth = 2,
                encodeGamma = srgb and 0 or 1,
            },
        }
        insetPasses = { secondPass, compositePass }
    end

    -- Called whenever the scene is shown: hands the graph to the host.
    function scene.on_enter()
        rhi.set_graph(graph)
        updateTitle()
    end

    function scene.on_leave()
        rhi.set_graph(nil)
    end

    -- ---------------------------------------------------------------------------------
    -- Input: the only time Lua touches the graph after init()
    -- ---------------------------------------------------------------------------------

    local function setSubdivision(n)
        sphere.subdivision = math.max(1, math.min(MAX_SUBDIVISION, math.floor(n)))
        blocks.generate.subdivision = sphere.subdivision
        generateNode.threads = { sphere.subdivision, sphere.subdivision, 6 }
        generateNode:rerun()
        for _, draw in ipairs(sphereDraws) do
            draw.count = sphereVertexCount(sphere.subdivision)
        end
        updateTitle()
    end

    local function setRadius(r)
        sphere.radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, r))
        blocks.generate.radius = sphere.radius
        generateNode:rerun()
        blocks.sphere.transform = sphereTransform() -- keep it resting on the floor
        blocks.marker.transform = markerTransform()
        updateTitle()
    end

    -- Stops or restarts the orbit where the light is now. The shaders compute the angle as
    -- phase + speed * time, with the same clock as rhi.time().
    local function toggleLight()
        local now = rhi.time()
        local angle = light.phase + light.speed * now
        light.speed = light.speed == 0 and LIGHT_SPEED or 0
        light.phase = angle - light.speed * now
        blocks.light.light = light
        updateTitle()
    end

    function scene.on_key(key, action)
        if action == input.RELEASE then return end -- presses and auto-repeat
        if key == keys.UP then
            setSubdivision(sphere.subdivision + 1)
        elseif key == keys.DOWN then
            setSubdivision(sphere.subdivision - 1)
        elseif key == keys.PAGE_UP then
            setSubdivision(sphere.subdivision * 2)
        elseif key == keys.PAGE_DOWN then
            setSubdivision(sphere.subdivision / 2)
        elseif key == keys.EQUAL or key == keys.KP_ADD then
            setRadius(sphere.radius + 0.05)
        elseif key == keys.MINUS or key == keys.KP_SUBTRACT then
            setRadius(sphere.radius - 0.05)
        elseif key == keys.SPACE and action == input.PRESS then
            toggleLight()
        elseif key == keys.TAB and action == input.PRESS then
            for _, pass in ipairs(insetPasses) do pass.enabled = not pass.enabled end
        end
    end

    local drag -- last mouse position while the left button is held

    function scene.on_mouse_button(button, action)
        if button ~= input.MOUSE_LEFT then return end
        drag = action == input.PRESS and { input.mouse() } or nil
    end

    function scene.on_mouse_move(x, y)
        if not drag then return end
        camera.yaw = camera.yaw - (x - drag[1]) * 0.008
        camera.pitch = math.max(0.05, math.min(1.45, camera.pitch + (y - drag[2]) * 0.008))
        drag = { x, y }
        blocks.mainCamera.camera = mainCameraParams()
    end

    function scene.on_scroll(x, y)
        camera.distance = math.max(3, math.min(15, camera.distance - y * 0.5))
        blocks.mainCamera.camera = mainCameraParams()
    end

    return scene
end
