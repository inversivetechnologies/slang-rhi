-- The light: one point light, at the entity's position, optionally orbiting it. Everything
-- is lit and shadowed by it (scene/scene-common.slang's PointLight; the orbit is computed
-- by the shaders from `time`). A scene has one; more are ignored, with a warning. Without
-- one, a default light hangs above the origin.
--
--   "light": { "color": [1, 0.9, 0.75], "intensity": 9, "range": 14,
--              "orbitRadius": 0, "speed": 0 (radians per second), "phase": 0 (radians),
--              "bob": 0 (how far it bounces up and down) }

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

function system.load(ctx)
    local found = 0
    local data = {
        center = { 0, 3, 0 }, orbitRadius = 0, color = { 1, 0.95, 0.85 }, intensity = 12,
        range = 20, speed = 0, phase = 0, bob = 0,
    }
    for id, light, transform in ctx.world:query("light", "transform") do
        found = found + 1
        if found == 1 then
            data = {
                center = transform.position,
                orbitRadius = light.orbitRadius,
                color = light.color,
                intensity = light.intensity,
                range = light.range,
                speed = light.speed,
                phase = light.phase,
                bob = light.bob,
            }
        else
            print(string.format("[scene] %s: only one light is supported; '%s' is ignored", ctx.name, ctx.world:name(id)))
        end
    end
    ctx.lightData = data
    ctx.light = rhi.params { light = data }
end

return system
