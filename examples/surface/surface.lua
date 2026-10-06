-- Clears the window to a grey that ramps up and wraps around, on every backend.

config = { title = "Surface", features = { "rasterization" } }

local grey = 0.5

function update(time, dt)
    grey = grey + 1 / 60
    if grey > 1 then grey = 0 end
end

function draw(frame)
    frame:clear(grey, grey, grey)
end
