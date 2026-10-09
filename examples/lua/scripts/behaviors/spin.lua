-- Turns the entity's mesh about an axis, at a steady speed. For a mesh without a body
-- (a visual one, which Lua places); a body is the physics' to move.
--
--   "script": { "file": "spin.lua", "params": { "speed": 40 (degrees per second),
--               "axis": [0, 1, 0] } }

local T = rhi.include("lib/scene/transform.lua")

return function(ctx, id, params)
    local b = {}
    local body = ctx.mesh and ctx.mesh.bodies[id]
    local transform = ctx.world:get(id, "transform")
    if not body or body.kind ~= "visual" then
        print(string.format("[scene] %s: spin.lua turns meshes without a body only", ctx.world:name(id)))
        return b
    end
    local speed = math.rad(params.speed or 40)
    local axis = params.axis or { 0, 1, 0 }
    local length = math.sqrt(axis[1] ^ 2 + axis[2] ^ 2 + axis[3] ^ 2)
    local angle = 0

    function b.update(dt)
        angle = angle + speed * dt
        local s = math.sin(angle / 2) / length
        local turn = { axis[1] * s, axis[2] * s, axis[3] * s, math.cos(angle / 2) }
        body.group:set_transform(body.index, transform.position, T.qmul(turn, transform.rotation))
    end

    return b
end
