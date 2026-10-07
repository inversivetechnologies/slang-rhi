-- Unit meshes built in Lua, in the vertex format of shaders/mesh/mesh-vertex.slang (two
-- float4s per vertex: position and quad parity, normal and face), as plain triangle lists
-- that shaders fetch by SV_VertexID.
--
--   local meshes = rhi.include("lib/meshes.lua")
--   local cube = meshes.cube()       -- { buffer, count }: from -1 to 1
--   local ball = meshes.sphere(24)   -- radius 1, `rings` rings of quads

local meshes = {}

local function pushVertex(floats, position, normal, parity, face)
    for k = 1, 3 do floats[#floats + 1] = position[k] end
    floats[#floats + 1] = parity
    for k = 1, 3 do floats[#floats + 1] = normal[k] end
    floats[#floats + 1] = face
end

-- A cube from -1 to 1, one face after the other.
function meshes.cube()
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
            pushVertex(floats, p, face.n, 0, f - 1)
        end
    end
    return { buffer = rhi.buffer(floats), count = 36 }
end

-- A sphere of radius 1: `rings` rings from pole to pole, twice as many segments around.
-- Neighboring quads alternate parity, so a checker pattern shows how a ball rolls.
function meshes.sphere(rings)
    rings = rings or 16
    local segments = rings * 2
    local function point(ring, segment)
        local theta = math.pi * ring / rings
        local phi = 2 * math.pi * segment / segments
        local p = { math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi) }
        return p
    end
    local floats = {}
    for ring = 0, rings - 1 do
        for segment = 0, segments - 1 do
            local a = point(ring, segment)
            local b = point(ring + 1, segment)
            local c = point(ring + 1, segment + 1)
            local d = point(ring, segment + 1)
            local parity = (ring // 2 + segment // 2) % 2
            for _, p in ipairs { a, b, c, a, c, d } do
                pushVertex(floats, p, p, parity, 0)
            end
        end
    end
    return { buffer = rhi.buffer(floats), count = rings * segments * 6 }
end

return meshes
