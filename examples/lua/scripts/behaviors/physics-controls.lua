-- The physics mode's keys, for a scene with bodies: P pauses the simulation, T toggles slow
-- motion (a quarter of the speed), R resets the scene (the viewer loads it again).
--
--   "script": { "file": "physics-controls.lua" }

return function(ctx)
    local b = {}
    if not ctx.physics then return b end
    local slow = false

    function b.on_key(key, action)
        if action ~= input.PRESS then return false end
        if key == keys.P then
            ctx.physics.paused = not ctx.physics.paused
        elseif key == keys.T then
            slow = not slow
            ctx.physics.time_scale = slow and 0.25 or 1
        elseif key == keys.R then
            ctx.requestReload = true
        else
            return false
        end
        return true
    end

    function b.describe()
        local state = ctx.physics.paused and "paused" or (slow and "slow motion" or "running")
        return state .. " (P, T, R reset)"
    end

    return b
end
