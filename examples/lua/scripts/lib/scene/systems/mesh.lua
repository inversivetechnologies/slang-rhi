-- Meshes and rigid bodies: boxes and spheres, lit and shadowed by the light, and simulated
-- by Jolt if they have a body.
--
--   "mesh": { "shape": "box" | "sphere", "size": [x, y, z] (a box's, whole),
--             "radius": 0.5 (a sphere's), "color": [r, g, b],
--             "pattern": 0 (plain) | 1 (stripes) | 2 (checker, on the floor) |
--                        3 (checker, on every face) | 4 (emissive: its color, unlit) }
--   "body": { "motion": "static" | "dynamic" | "kinematic", "density": 1000 (kg/m^3),
--             "friction": 0.5, "restitution": 0, "velocity": [x, y, z],
--             "angularVelocity": [x, y, z] }
--
-- The entity's transform places it; its scale scales the size. Every mesh is a body of
-- the host's physics world (rhi.physics_world): one with a "body" moves by the physics,
-- one without is "visual" -- drawn like the others, placed by Lua (behaviors can move it).
-- Bodies of a shape and a kind of motion share a group, drawn by one instanced draw per
-- pass (scene/lit.slang, scene/shadow.slang: bodyVertexMain), as lib/physics-mode.lua's.
--
-- For behaviors, ctx.mesh has the physics world, the groups (ctx.mesh.groups[shape][kind],
-- kind "dynamic", "static" or "visual"), where each entity went (ctx.mesh.bodies[id] =
-- { group, index, shape, kind }), and addGroup(group, shape) for groups of their own.

local meshes = rhi.include("lib/meshes.lua")

local system = {
    name = "mesh",
    components = {
        mesh = {
            shape = { "string", "box" },
            size = { "vec3", { 1, 1, 1 } },
            radius = { "number", 0.5 },
            color = { "vec3", { 0.8, 0.8, 0.8 } },
            pattern = { "number", 0 },
        },
        body = {
            motion = { "string", "dynamic" },
            density = { "number", 1000 },
            friction = { "number", 0.5 },
            restitution = { "number", 0 },
            velocity = { "vec3", { 0, 0, 0 } },
            angularVelocity = { "vec3", { 0, 0, 0 } },
        },
    },
}

local SPAWN_CAPACITY = 600 -- room for bodies added later (throws, bursts), per dynamic group

function system.load(ctx)
    local count = 0
    for _ in ctx.world:query("mesh") do count = count + 1 end
    local hasBehaviors = ctx.world:countOf("script") > 0
    if count == 0 and not hasBehaviors then return end

    local settings = ctx.settings
    local physics = rhi.physics_world { gravity = settings.gravity or { 0, -9.81, 0 }, max_bodies = 8192 }
    local m = {
        world = physics,
        groups = { box = {}, sphere = {} },
        meshes = { box = meshes.cube(), sphere = meshes.sphere(16) },
        bodies = {},
        draws = {}, -- { group, mesh }
    }
    ctx.mesh = m
    ctx.physics = physics

    -- Count the bodies of each group first, for its capacity.
    local counts = { box = {}, sphere = {} }
    local function kindOf(body)
        if not body then return "visual" end
        return body.motion == "static" and "static" or "dynamic"
    end
    for id, mesh in ctx.world:query("mesh") do
        if mesh.shape ~= "box" and mesh.shape ~= "sphere" then
            error(string.format("%s.mesh.shape: \"box\" or \"sphere\", not \"%s\"", ctx.world:name(id), mesh.shape), 0)
        end
        local kind = kindOf(ctx.world:get(id, "body"))
        counts[mesh.shape][kind] = (counts[mesh.shape][kind] or 0) + 1
    end
    for _, shape in ipairs { "box", "sphere" } do
        for _, kind in ipairs { "dynamic", "static", "visual" } do
            local n = counts[shape][kind] or 0
            -- Dynamic groups always exist (behaviors spawn into them); others if used.
            if n > 0 or kind == "dynamic" then
                local group = physics:group { capacity = n + (kind == "dynamic" and SPAWN_CAPACITY or 0) }
                m.groups[shape][kind] = group
                m.draws[#m.draws + 1] = { group = group, mesh = m.meshes[shape] }
            end
        end
    end

    for id, mesh, transform in ctx.world:query("mesh", "transform") do
        local body = ctx.world:get(id, "body")
        local kind = kindOf(body)
        local s = transform.scale
        local desc = {
            shape = mesh.shape,
            half_extents = { mesh.size[1] * s / 2, mesh.size[2] * s / 2, mesh.size[3] * s / 2 },
            radius = mesh.radius * s,
            position = transform.position,
            rotation = transform.rotation,
            color = mesh.color,
            pattern = mesh.pattern,
        }
        if body then
            desc.motion = body.motion
            desc.density = body.density
            desc.friction = body.friction
            desc.restitution = body.restitution
            desc.velocity = body.velocity
            desc.angular_velocity = body.angularVelocity
        else
            desc.motion = "visual"
        end
        local group = m.groups[mesh.shape][kind]
        local index = group:add(desc)
        if index then
            m.bodies[id] = { group = group, index = index, shape = mesh.shape, kind = kind }
        end
    end

    function m.addGroup(group, shape)
        m.draws[#m.draws + 1] = { group = group, mesh = m.meshes[shape] }
    end

    m.pipelines = {
        shadow = rhi.render_pipeline { shader = "scene/shadow.slang", vertex = "bodyVertexMain", format = "r32f", depth = true },
        lit = rhi.render_pipeline {
            shader = "scene/lit.slang", vertex = "bodyVertexMain", fragment = "bodyFragmentMain", format = "rgba16f", depth = true,
        },
        motion = rhi.render_pipeline { shader = "scene/motion.slang", vertex = "bodyVertexMain", format = "rgba16f", depth = true },
    }
end

function system.addShadowCasters(ctx, facePasses)
    local m = ctx.mesh
    if not m then return end
    for face, pass in ipairs(facePasses) do
        for _, d in ipairs(m.draws) do
            pass:draw {
                pipeline = m.pipelines.shadow, count = d.mesh.count, instances = d.group,
                params = { { vertices = d.mesh.buffer, bodies = d.group.buffer, face = face - 1 }, ctx.light },
            }
        end
    end
end

function system.addOpaque(ctx, view, pass)
    local m = ctx.mesh
    if not m then return end
    for _, d in ipairs(m.draws) do
        pass:draw {
            pipeline = m.pipelines.lit, count = d.mesh.count, instances = d.group,
            params = { { vertices = d.mesh.buffer, bodies = d.group.buffer }, ctx.light, ctx.shadowBlock, view.block },
        }
    end
end

-- The bodies' motion since the frame before, for the screen-space effects' history
-- (scene/motion.slang; the renderer's motion pass, with SSAO or SSGI on).
function system.addMotion(ctx, view, pass)
    local m = ctx.mesh
    if not m then return end
    for _, d in ipairs(m.draws) do
        pass:draw {
            pipeline = m.pipelines.motion, count = d.mesh.count, instances = d.group,
            params = { { vertices = d.mesh.buffer, bodies = d.group.buffer }, view.block },
        }
    end
end

function system.enter(ctx)
    if ctx.physics then rhi.set_physics(ctx.physics) end
end

function system.leave(ctx)
    if ctx.physics then rhi.set_physics(nil) end
end

function system.describe(ctx)
    local m = ctx.mesh
    if not m then return nil end
    local n = 0
    for _, d in ipairs(m.draws) do n = n + d.group.count end
    return string.format("%d bodies", n)
end

return system
