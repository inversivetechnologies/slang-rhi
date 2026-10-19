-- A 2D user interface layer: rounded rectangles and monospaced text, drawn over the
-- window by shaders/ui/ui.slang in one pass. Build a frame's contents, then hand them to
-- the pass's parameters:
--
--   local ui = rhi.include("lib/ui.lua")
--   local canvas = ui.canvas()
--   canvas:clear()
--   canvas:rect(x, y, w, h, { r, g, b, a }, { radius = 8, border = 2 })
--   canvas:text(x, y, "Resume", { scale = 1, color = { 1, 1, 1, 1 }, align = "center" })
--   block:set(canvas:params())            -- block = rhi.params(canvas:params())
--   pass:draw { pipeline = ui.pipeline(), count = 3, params = block }
--
-- Positions are window pixels, from the top left. Colors are display values. At most 32
-- rectangles, 32 texts and 1024 characters a frame (the shader's arrays); more is dropped.

local ui = {}

ui.CELL_WIDTH, ui.CELL_HEIGHT = 16, 32 -- the font's cell (shaders/ui/font.slang)
local MAX_RECTS, MAX_TEXTS, MAX_CHARS = 32, 32, 1024

-- The pass's pipeline: blended over what the window holds.
function ui.pipeline()
    return rhi.render_pipeline { shader = "ui/ui.slang", blend = "alpha" }
end

-- How wide `text` is at `scale`, in pixels.
function ui.textWidth(text, scale)
    return #text * ui.CELL_WIDTH * (scale or 1)
end

local Canvas = {}
Canvas.__index = Canvas

function ui.canvas()
    return setmetatable({ rects = {}, texts = {}, bytes = {} }, Canvas)
end

function Canvas:clear()
    self.rects, self.texts, self.bytes = {}, {}, {}
end

function Canvas:rect(x, y, w, h, color, style)
    if #self.rects >= MAX_RECTS then return end
    style = style or {}
    self.rects[#self.rects + 1] = {
        rect = { x, y, w, h },
        color = color,
        style = { style.radius or 0, style.border or 0, 0, 0 },
    }
end

-- `options`: scale (1: 16 x 32 pixels a character), color, align ("left", "center",
-- "right": `x` is where the text starts, its middle, or its end). `y` is the top of the
-- line; a line is 32 x scale pixels high.
function Canvas:text(x, y, text, options)
    options = options or {}
    if #self.texts >= MAX_TEXTS then return end
    local scale = options.scale or 1
    text = text:sub(1, MAX_CHARS - #self.bytes)
    local width = ui.textWidth(text, scale)
    if options.align == "center" then
        x = x - width / 2
    elseif options.align == "right" then
        x = x - width
    end
    self.texts[#self.texts + 1] = {
        place = { math.floor(x + 0.5), math.floor(y + 0.5), scale, 0 },
        color = options.color or { 1, 1, 1, 1 },
        start = #self.bytes,
        length = #text,
    }
    for i = 1, #text do self.bytes[#self.bytes + 1] = text:byte(i) end
end

-- The shader's parameters for what was drawn (every array full length, so that a block
-- made from one frame's takes another's).
function Canvas:params()
    local rects, texts, chars = {}, {}, {}
    for i = 1, MAX_RECTS do
        rects[i] = self.rects[i] or { rect = { 0, 0, 0, 0 }, color = { 0, 0, 0, 0 }, style = { 0, 0, 0, 0 } }
    end
    for i = 1, MAX_TEXTS do
        texts[i] = self.texts[i] or { place = { 0, 0, 1, 0 }, color = { 0, 0, 0, 0 }, start = 0, length = 0 }
    end
    -- 4 characters to a uint, 4 uints to a uint4.
    for group = 0, MAX_CHARS / 16 - 1 do
        local words = {}
        for w = 0, 3 do
            local word = 0
            for b = 0, 3 do
                local byte = self.bytes[group * 16 + w * 4 + b + 1] or 0
                word = word | (byte << (8 * b))
            end
            words[w + 1] = word
        end
        chars[group + 1] = words
    end
    return {
        rects = rects,
        rectCount = #self.rects,
        texts = texts,
        textCount = #self.texts,
        chars = chars,
        decodeGamma = rhi.window_srgb() and 1 or 0,
    }
end

return ui
