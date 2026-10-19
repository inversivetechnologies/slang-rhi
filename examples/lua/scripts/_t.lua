require "showcase"
local base, t0, step = update, nil, 0
local last
local set = rhi.set_title
rhi.set_title = function(t) last = t set(t) end
function update(t, dt)
    base(t, dt)
    t0 = t0 or t
    local e = t - t0
    if step == 0 and e > 1 then step = 1 on_key(keys["3"], input.PRESS, 0) end
    -- everything .. light tiles = 9 entries, then GI: normals, GI: Hi-Z
    if step == 1 and e > 9 then step = 2 for _ = 1, 17 do on_key(keys.V, input.PRESS, 0) end print("MODE", last:match("V: [^|]*")) end

end
