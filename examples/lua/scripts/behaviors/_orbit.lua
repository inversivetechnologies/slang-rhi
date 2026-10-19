return function(ctx, id, params)
    local b = {}
    local body = ctx.mesh and ctx.mesh.bodies[id]
    local center = ctx.world:get(id, "transform").position
    local angle = 0
    function b.update(dt)
        if not params.speed or params.speed == 0 then return end
        angle = angle + params.speed * dt
        local r = params.radius or 2
        body.group:set_transform(body.index, { center[1] + math.cos(angle) * r, center[2], center[3] + math.sin(angle) * r })
    end
    return b
end
