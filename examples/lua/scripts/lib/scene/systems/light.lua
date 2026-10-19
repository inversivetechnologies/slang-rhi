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
-- The others, up to 1024, are point lights without shadows: the meshes, the SDFs and the
-- splats all add them as they shade -- each point only those whose range reaches its
-- screen tile (the renderer's light culling, scene/light-culling.slang). Their orbits are
-- worked out here, every frame, and written into the light block's buffer
-- (pointLightData: scene/light-tiles-layout.slang); an entity with a mesh without a body
-- (a visual one: "pattern": 4 makes it glow) is moved along with its light, as its marker.

local MAX_POINT_LIGHTS = 1024 -- light-tiles-layout.slang's kMaxPointLights

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

-- The lights' floats, as pointLightData holds them: position, range; color, intensity.
local function pointLightFloats(lights)
    local floats, n = {}, 0
    for _, l in ipairs(lights) do
        local p, c = l.position, l.color
        floats[n + 1], floats[n + 2], floats[n + 3], floats[n + 4] = p[1], p[2], p[3], l.range
        floats[n + 5], floats[n + 6], floats[n + 7], floats[n + 8] = c[1], c[2], c[3], l.intensity
        n = n + 8
    end
    return floats
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
    local floats = pointLightFloats(ctx.pointLights)
    ctx.pointLightBuffer = #floats > 0 and rhi.buffer(floats) or rhi.buffer(32)
    ctx.light = rhi.params {
        light = {
            center = data.center, orbitRadius = data.orbitRadius, color = data.color, intensity = data.intensity,
            range = data.range, speed = data.speed, phase = data.phase, bob = data.bob,
        },
        pointLightData = ctx.pointLightBuffer,
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
    if moved then ctx.pointLightBuffer:write(pointLightFloats(ctx.pointLights)) end
end


return system
