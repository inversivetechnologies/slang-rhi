-- The SDF modes' keys, for a scene with SDFs:
--
--   J / K   every blend radius /1.25 / x1.25 (the depth composite's)
-- and, if the composition is cached (the SDF cache mode's):
--   C       raymarch the DAG / the cache / show the cache's error (where the DAG hits)
--   [ / ]   cache resolution /2 / x2 (32 to 256 voxels a side), baked again
--   B       benchmark: the main view's raymarching GPU time with the DAG, then the cache
--   Space   stop / start orbit cameras that turn
--
--   "script": { "file": "sdf-controls.lua" }

local SOURCES = { [0] = "DAG", [1] = "cache", [2] = "cache error" }
local RESOLUTIONS = { 32, 64, 128, 160, 192, 256 }
local WARMUP, MEASURE = 40, 180

return function(ctx)
    local b = {}
    local s = ctx.sdf
    if not s then return b end
    local cached = s.cache > 0
    local smoothScale = 1
    local benchmark, results = nil, nil

    local function resolutionIndex()
        for i, n in ipairs(RESOLUTIONS) do
            if n >= s.cache then return i end
        end
        return #RESOLUTIONS
    end

    function b.update()
        if not benchmark then return end
        local m = benchmark
        m.frame = m.frame + 1
        if m.frame > WARMUP then m.total = m.total + (s.gpuTime() or 0) end
        if m.frame == WARMUP + MEASURE then
            m.times[m.step] = m.total / MEASURE
            if m.step == 0 then
                m.step, m.frame, m.total = 1, 0, 0
                s.setSource(1)
            else
                results = m.times
                benchmark = nil
                s.setSource(m.restore)
            end
        end
    end

    function b.on_key(key, action)
        if action == input.RELEASE then return false end
        if key == keys.J or key == keys.K then
            smoothScale = key == keys.K and math.min(8, smoothScale * 1.25) or math.max(0, smoothScale / 1.25)
            if smoothScale < 0.01 then smoothScale = 0 end
            s.setSmoothScale(smoothScale)
            return true
        end
        if action ~= input.PRESS or not cached then return false end
        if key == keys.C then
            s.setSource((s.source + 1) % 3)
        elseif key == keys.LEFT_BRACKET or key == keys.RIGHT_BRACKET then
            local i = math.max(1, math.min(#RESOLUTIONS, resolutionIndex() + (key == keys.RIGHT_BRACKET and 1 or -1)))
            s.setResolution(RESOLUTIONS[i])
            results = nil
        elseif key == keys.B then
            benchmark = { step = 0, frame = 0, total = 0, times = {}, restore = s.source }
            s.setSource(0)
        elseif key == keys.SPACE then
            ctx.cameraStill = not ctx.cameraStill
        else
            return false
        end
        return true
    end

    function b.describe()
        local parts = { string.format("blend x%.2f (J/K)", smoothScale) }
        if cached then
            local bake = s.bakeTime()
            parts[#parts + 1] = string.format("%s (C), baked in %s ([ ])", SOURCES[s.source],
                bake and string.format("%.2f ms", bake) or "-")
            if benchmark then
                parts[#parts + 1] = "benchmarking..."
            elseif results then
                parts[#parts + 1] = string.format("B: DAG %.2f ms, cache %.2f ms (x%.1f)", results[0], results[1],
                    results[0] / math.max(results[1], 1e-6))
            else
                parts[#parts + 1] = "B: benchmark"
            end
        end
        return table.concat(parts, ", ")
    end

    return b
end
