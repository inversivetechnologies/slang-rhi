require "scene"
local base, n = update, 0
function update(t, dt) if base then base(t, dt) end n = n + 1 if n == 60 then print("scene 60 ok") end end
