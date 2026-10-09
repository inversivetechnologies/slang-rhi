require "showcase"
local n, base = 0, update
function update(t, dt)
    base(t, dt)
    n = n + 1
    if n == 5 then on_key(keys["6"], input.PRESS) end
    if n == 40 then on_key(keys.V, input.PRESS); on_key(keys.RIGHT_BRACKET, input.PRESS) end
    if n == 70 then on_key(keys.V, input.PRESS); on_key(keys.EQUAL, input.PRESS) end
    if n == 100 then on_key(keys["5"], input.PRESS) end
    if n == 140 then on_key(keys["6"], input.PRESS) end
    if n == 180 then print("frame 180 ok", rhi.device()) end
end
