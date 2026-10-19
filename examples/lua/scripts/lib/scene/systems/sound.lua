-- Sounds (rhi.sound): played while the scene shows, paused while it doesn't. M mutes them.
--
--   "sound": { "file": "audio/timelapse.mpeg", "loop": true, "volume": 1, "autoplay": true }

local system = {
    name = "sound",
    components = {
        sound = {
            file = { "string", nil, true },
            loop = { "boolean", true },
            volume = { "number", 1 },
            autoplay = { "boolean", true },
        },
    },
}

function system.load(ctx)
    ctx.sounds = {}
    for _, sound in ctx.world:query("sound") do
        -- A missing file gives no sound (rhi.sound warns, and reloads once it is there).
        local handle = rhi.sound(sound.file, { loop = sound.loop, volume = sound.volume })
        if handle then ctx.sounds[#ctx.sounds + 1] = { handle = handle, spec = sound } end
    end
    ctx.muted = false
end

-- The pause menu: paused sounds go on where they were.
function system.setPaused(ctx, paused)
    for _, s in ipairs(ctx.sounds) do
        if paused then
            s.handle:pause()
        elseif s.spec.autoplay then
            s.handle:play()
        end
    end
end

function system.enter(ctx)
    for _, s in ipairs(ctx.sounds) do
        if s.spec.autoplay then s.handle:play() end
    end
end

function system.leave(ctx)
    for _, s in ipairs(ctx.sounds) do s.handle:pause() end
end

function system.on_key(ctx, key, action)
    if key ~= keys.M or action ~= input.PRESS or #ctx.sounds == 0 then return false end
    ctx.muted = not ctx.muted
    for _, s in ipairs(ctx.sounds) do s.handle.volume = ctx.muted and 0 or s.spec.volume end
    return true
end

function system.describe(ctx)
    if #ctx.sounds == 0 then return nil end
    return ctx.muted and "muted (M)" or "sound (M)"
end

return system
