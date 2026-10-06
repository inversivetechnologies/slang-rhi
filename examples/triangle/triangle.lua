-- Renders a vertex-colored triangle over a cycling grey, with a spherified cube spinning in
-- front of it.
--
-- A spherified cube is a cube whose faces are split into a grid of quads and whose vertices
-- are normalized onto a sphere. A compute shader (spherified-cube.slang) generates it into
-- a buffer, and the mesh shader (mesh.slang) reads that buffer back by SV_VertexID -- so
-- the mesh needs no vertex layout and no index buffer.
--
--   Up / Down               subdivision + / - 1
--   Page Up / Page Down     subdivision x2 / /2
--   + / - or mouse wheel    radius + / -

config = { title = "Triangle", features = { "rasterization" } }

-- -------------------------------------------------------------------------------------
-- Mesh parameters: change them with the keys above, or edit and save.
-- -------------------------------------------------------------------------------------

local subdivision = 8 -- quads along each edge of a cube face
local radius = 0.6

local MAX_SUBDIVISION = 128
local MIN_RADIUS, MAX_RADIUS = 0.05, 1.5

local VERTEX_SIZE = 32 -- sizeof(MeshVertex) in mesh-vertex.slang

-- 6 faces * subdivision^2 quads * 2 triangles * 3 vertices
local function vertexCount(n)
    return 6 * n * n * 6
end

-- -------------------------------------------------------------------------------------

local trianglePipeline, triangleVertices
local generatePipeline, meshPipeline, meshVertices
local time = 0
local grey = 0.5

-- What the mesh in `meshVertices` was generated from, to know when to generate it again.
local generated = {}

local function updateTitle()
    rhi.set_title(string.format("Triangle | sphere: subdivision %d, radius %.2f", subdivision, radius))
end

local function setSubdivision(n)
    subdivision = math.max(1, math.min(MAX_SUBDIVISION, math.floor(n)))
    updateTitle()
end

local function setRadius(r)
    radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, r))
    updateTitle()
end

function init()
    trianglePipeline = rhi.render_pipeline {
        shader = "triangle.slang",
        vertex = "vertexMain",
        fragment = "fragmentMain",
        layout = { { "POSITION", "rgb32f" }, { "COLOR", "rgb32f" } },
    }
    triangleVertices = rhi.vertex_buffer {
        -0.5, -0.5, 0.0,   1, 0, 0, -- red
         0.5, -0.5, 0.0,   0, 1, 0, -- green
         0.0,  0.5, 0.0,   0, 0, 1, -- blue
    }

    generatePipeline = rhi.compute_pipeline("spherified-cube.slang", "generateMain")
    -- No layout: the vertex shader fetches from the buffer itself. Depth-tested, since the
    -- far side of the sphere must not show through.
    meshPipeline = rhi.render_pipeline { shader = "mesh.slang", depth = true }
    -- Sized for the largest mesh, so changing the subdivision never reallocates it.
    meshVertices = rhi.buffer(vertexCount(MAX_SUBDIVISION) * VERTEX_SIZE)

    setSubdivision(subdivision)
end

function update(t, dt)
    time = t
    grey = grey + 1 / 60
    if grey > 1 then grey = 0 end
end

-- Generates the mesh when a parameter changed, or when the generator was rebuilt after
-- an edit to spherified-cube.slang.
local function generateMesh(frame)
    if not generatePipeline.built then
        return
    end
    if generated.subdivision == subdivision and generated.radius == radius
        and generated.version == generatePipeline.version then
        return
    end
    -- One thread per quad: subdivision x subdivision per face, 6 faces.
    frame:dispatch(generatePipeline, {
        subdivision = subdivision,
        radius = radius,
        vertices = meshVertices,
    }, subdivision, subdivision, 6)
    generated = { subdivision = subdivision, radius = radius, version = generatePipeline.version }
end

function draw(frame)
    generateMesh(frame)

    frame:draw(trianglePipeline, { vertices = triangleVertices, clear = { grey, grey, grey, 1 } })

    if generated.subdivision then
        frame:draw(meshPipeline, {
            count = vertexCount(generated.subdivision),
            params = {
                vertices = meshVertices,
                time = time,
                aspect = frame.width / frame.height,
            },
        })
    end
end

function on_key(key, action)
    if action == input.RELEASE then return end -- presses and auto-repeat
    if key == keys.UP then
        setSubdivision(subdivision + 1)
    elseif key == keys.DOWN then
        setSubdivision(subdivision - 1)
    elseif key == keys.PAGE_UP then
        setSubdivision(subdivision * 2)
    elseif key == keys.PAGE_DOWN then
        setSubdivision(subdivision / 2)
    elseif key == keys.EQUAL or key == keys.KP_ADD then
        setRadius(radius + 0.05)
    elseif key == keys.MINUS or key == keys.KP_SUBTRACT then
        setRadius(radius - 0.05)
    end
end

function on_scroll(x, y)
    setRadius(radius + 0.05 * y)
end
