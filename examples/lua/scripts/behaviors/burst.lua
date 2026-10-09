-- Drops a burst of boxes and balls from above the entity's position when a key (or a
-- Steam Controller button) is pressed.
--
--   "script": { "file": "burst.lua", "params": { "key": "B", "button": "View",
--               "count": 24, "area": 6, "height": 6 } }

local PALETTE = {
    { 0.90, 0.35, 0.28 }, { 0.30, 0.55, 0.90 }, { 0.95, 0.75, 0.25 },
    { 0.35, 0.75, 0.45 }, { 0.70, 0.40, 0.85 }, { 0.90, 0.55, 0.20 },
}

return function(ctx, id, params)
    local b = {}
    if not ctx.mesh then return b end
    local key = keys[params.key or "B"]
    local button = buttons[params.button or "View"]
    local count = params.count or 24
    local area = params.area or 6
    local height = params.height or 6
    local center = ctx.world:get(id, "transform").position
    local boxes, balls = ctx.mesh.groups.box.dynamic, ctx.mesh.groups.sphere.dynamic

    local function drop()
        for _ = 1, count do
            local position = {
                center[1] + (math.random() - 0.5) * area,
                center[2] + height + math.random() * 4,
                center[3] + (math.random() - 0.5) * area,
            }
            local color = PALETTE[math.random(#PALETTE)]
            if math.random() < 0.5 then
                local s = 0.12 + math.random() * 0.2
                local angle = math.random() * math.pi
                boxes:add { shape = "box", half_extents = { s, s * (0.6 + math.random()), s }, position = position,
                    rotation = { 0, math.sin(angle / 2), 0, math.cos(angle / 2) }, color = color, density = 500,
                    angular_velocity = { math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2 } }
            else
                balls:add { shape = "sphere", radius = 0.12 + math.random() * 0.18, position = position,
                    color = color, pattern = 1, density = 800, restitution = 0.4 }
            end
        end
    end

    function b.on_key(k, action)
        if action ~= input.PRESS then return false end
        if k == key then
            drop()
            return true
        end
        return false
    end

    function b.on_controller_button(_, pressedButton, pressed)
        if pressed and pressedButton == button then
            drop()
            return true
        end
        return false
    end

    function b.describe()
        return string.format("%s: drop boxes", params.key or "B")
    end

    return b
end
