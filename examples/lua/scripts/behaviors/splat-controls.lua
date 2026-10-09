-- The splat modes' keys, for a scene with splats (every splat file in it):
--
--   , / .   splat budget /1.25 / x1.25         /    tint the splats by level of detail
--   [ / ]   splat size /1.1 / x1.1             L    lit / as captured / light visibility
--   C       clip: carve / keep inside / off (if the splats have a "clip")
--
--   "script": { "file": "splat-controls.lua" }

local LIGHTINGS = { "lit", "as captured", "light visibility" }
local CLIPS = { [0] = "off", [1] = "carve", [2] = "keep inside" }

return function(ctx)
    local b = {}
    local files = ctx.splats
    if not files then return b end
    local showLevels, lighting, scale = false, 1, 1
    local clipMode = 1

    local function each(f) for _, file in ipairs(files) do f(file) end end
    local hasClip = false
    each(function(file) hasClip = hasClip or file.clip ~= nil end)

    function b.on_key(key, action)
        if action == input.RELEASE then return false end
        if key == keys.COMMA or key == keys.PERIOD then
            local factor = key == keys.PERIOD and 1.25 or 1 / 1.25
            each(function(file) file.module.setBudget(file.module.budget() * factor) end)
        elseif key == keys.LEFT_BRACKET or key == keys.RIGHT_BRACKET then
            scale = key == keys.RIGHT_BRACKET and math.min(4, scale * 1.1) or math.max(0.05, scale / 1.1)
            each(function(file) file.module.setSplatScale(scale) end)
        elseif action ~= input.PRESS then
            return false
        elseif key == keys.SLASH then
            showLevels = not showLevels
            each(function(file) file.module.setShowLevels(showLevels) end)
        elseif key == keys.L then
            lighting = lighting % #LIGHTINGS + 1
            each(function(file)
                file.module.setRelight(lighting == 2 and 0 or 1)
                file.module.setShowVisibility(lighting == 3)
            end)
        elseif key == keys.C and hasClip then
            clipMode = (clipMode + 1) % 3
            each(function(file) if file.clip then file.clip.clipMode = clipMode end end)
        else
            return false
        end
        return true
    end

    function b.describe()
        local budget = files[1].module.budget()
        local text = string.format("splats: budget %.2fM (, .), %s (L)%s", budget / 1e6, LIGHTINGS[lighting],
            showLevels and ", levels (/)" or "")
        if hasClip then text = text .. ", clip " .. CLIPS[clipMode] .. " (C)" end
        return text
    end

    return b
end
