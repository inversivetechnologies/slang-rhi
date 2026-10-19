require "showcase"
local base, n = update, 0
function update(t, dt) base(t, dt) n = n + 1 if n % 50 == 0 and n <= 300 then on_key(keys[tostring(n // 50 + 1)], input.PRESS, 0) end if n == 360 then print("showcase 360 ok") end end
