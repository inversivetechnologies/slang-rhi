-- The lights: point lights at their entities' positions, optionally orbiting them.
--
--   "light": { "color": [1, 0.9, 0.75], "intensity": 9, "range": 14,
--              "orbitRadius": 0, "speed": 0 (radians per second), "phase": 0 (radians),
--              "bob": 0 (how far it bounces up and down) }
--
-- The scene's first light is its key light: everything is lit and shadowed by it
-- (scene/scene-common.slang's PointLight; its orbit is computed by the shaders from
-- `time`). Without one, a default key light hangs above the origin.
--
-- The others, up to 8, are point lights without shadows (scene-common.slang's
-- pointLights): the meshes, the SDFs and the splats all add them as they shade, which
-- costs a few multiply-adds a light per shaded point and nothing else. Their orbits are
-- worked out here, every frame, and written into the light block; an entity with a mesh
-- without a body (a visual one: "pattern": 4 makes it glow) is moved along with its light,
-- as its marker.

local MAX_POINT_LIGHTS = 8 -- scene-common.slang's kMaxPointLights

local system = {
    name = "light",
    components = {
        light = {
            color = { "vec3", { 1.0, 0.9, 0.75 } },
            intensity = { "number", 9 },
            range = { "number", 14 },
            orbitRadius = { "number", 0 },
            speed = { "number", 0 },
            phase = { "number", 0 },
            bob = { "number", 0 },
        },
    },
}

local function orbitPosition(l)
    local c = l.center
    return { c[1] + math.cos(l.angle) * l.orbitRadius, c[2] + l.bob * math.sin(l.angle * 1.7),
             c[3] + math.sin(l.angle) * l.orbitRadius }
end

-- The block's pointLights: every slot filled, the unused ones dark.
local function pointLightParams(lights)
    local list = {}
    for i = 1, MAX_POINT_LIGHTS do
        local l = lights[i]
        list[i] = l and { position = l.position, range = l.range, color = l.color, intensity = l.intensity }
            or { position = { 0, 0, 0 }, range = 0, color = { 0, 0, 0 }, intensity = 0 }
    end
    return list
end

function system.load(ctx)
    local data = {
        center = { 0, 3, 0 }, orbitRadius = 0, color = { 1, 0.95, 0.85 }, intensity = 12,
        range = 20, speed = 0, phase = 0, bob = 0,
    }
    local key = false
    ctx.pointLights = {}
    for id, light, transform in ctx.world:query("light", "transform") do
        local l = {
            id = id,
            center = transform.position,
            orbitRadius = light.orbitRadius,
            color = light.color,
            intensity = light.intensity,
            range = light.range,
            speed = light.speed,
            phase = light.phase,
            bob = light.bob,
        }
        if not key then
            key = true
            data = l
        elseif #ctx.pointLights < MAX_POINT_LIGHTS then
            l.angle = l.phase
            l.position = orbitPosition(l)
            ctx.pointLights[#ctx.pointLights + 1] = l
        else
            print(string.format("[scene] %s: at most %d point lights besides the key light; '%s' is ignored",
                ctx.name, MAX_POINT_LIGHTS, ctx.world:name(id)))
        end
    end
    ctx.lightData = data
    ctx.light = rhi.params {
        light = {
            center = data.center, orbitRadius = data.orbitRadius, color = data.color, intensity = data.intensity,
            range = data.range, speed = data.speed, phase = data.phase, bob = data.bob,
        },
        pointLights = pointLightParams(ctx.pointLights),
        pointLightCount = #ctx.pointLights,
    }
end

function system.update(ctx, dt)
    if #ctx.pointLights == 0 then return end
    local moved = false
    for _, l in ipairs(ctx.pointLights) do
        if l.speed ~= 0 or not l.placed then
            l.angle = l.angle + l.speed * dt
            l.position = orbitPosition(l)
            moved = true
            -- Its marker, if it has one.
            local body = ctx.mesh and ctx.mesh.bodies[l.id]
            if body and body.kind == "visual" then body.group:set_transform(body.index, l.position) end
            l.placed = true
        end
    end
    if moved then ctx.light.pointLights = pointLightParams(ctx.pointLights) end
end

function system.describe(ctx)
    if #ctx.pointLights == 0 then return nil end
    return string.format("%d point lights", #ctx.pointLights)
end

return system
