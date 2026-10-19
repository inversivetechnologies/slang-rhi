-- The pause menu: Escape (or the Steam Controller's Menu button) opens it over whatever
-- is shown, and pauses it. Resume, Settings, Quit; the settings are the resolution,
-- fullscreen, the most splats drawn, the shadows' quality, and the screen-space ambient
-- occlusion and indirect light (lib/settings.lua keeps them between runs).
--
--   local menu = rhi.include("lib/pause-menu.lua").new {
--       settings = values,                    -- from settings.load(); changed in place
--       onPause = function(paused) end,       -- opened (true) or closed (false)
--       onChange = function(name, value) end, -- a setting changed (and was saved)
--       only = { "resolution", ... },         -- optional: the settings shown (default all)
--   }
--   menu:addPasses(graph)       -- in every graph that shows it (a layer: see renderer.lua),
--   menu:draw(frame)            -- or from a script's draw(frame), after everything else
--   menu:update(dt)
--   menu:on_key(...), menu:on_mouse_button(...), menu:on_mouse_move(...),
--   menu:on_controller_button(...)   -- each true if the menu took the input
--
-- Keys: Up / Down choose, Left / Right change a setting, Enter / Space pick, Escape goes
-- back (closing the menu from its first page). The mouse points and clicks: a setting's
-- left half goes back a value, its right half forward. Controller: the D-pad, A picks,
-- B goes back.

local ui = rhi.include("lib/ui.lua")
local settings = rhi.include("lib/settings.lua")

local COLORS = {
    dim = { 0.0, 0.0, 0.0, 0.55 },
    panel = { 0.075, 0.085, 0.11, 0.95 },
    border = { 0.45, 0.55, 0.85, 0.45 },
    selected = { 0.22, 0.38, 0.85, 0.95 },
    hover = { 1, 1, 1, 0.07 },
    title = { 1, 1, 1, 1 },
    text = { 0.88, 0.9, 0.95, 1 },
    value = { 0.6, 0.78, 1.0, 1 },
    hint = { 0.6, 0.63, 0.7, 1 },
}

local Menu = {}
Menu.__index = Menu

local pauseMenu = {}

local function thousands(n)
    local s = tostring(math.floor(n))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function pauseMenu.new(options)
    local self = setmetatable({
        values = options.settings,
        onPause = options.onPause or function() end,
        onChange = options.onChange or function() end,
        open = false,
        page = "main",
        selected = 1,
        hovered = nil,
        canvas = ui.canvas(),
        dirty = true,
        passes = {},
        only = options.only,
    }, Menu)
    return self
end

-- Its pipeline and parameter block, made on first use (a script's top level, where it may
-- be made, runs before there is a device).
function Menu:resources()
    if not self.pipeline then
        self.pipeline = ui.pipeline()
        self.params = self.canvas:params()
        self.block = rhi.params(self.params)
    end
end

-- The rows of the page shown: { label, action } buttons, or settings with { label,
-- choices, index, format, apply }.
function Menu:rows()
    if self.page == "main" then
        return {
            { label = "Resume", action = function() self:close() end },
            { label = "Settings", action = function() self.page, self.selected = "settings", 1 end },
            { label = "Quit", action = function() rhi.quit() end },
        }
    end
    local v = self.values
    local display = rhi.display()

    local resolutions = settings.resolutions()
    local want = v.resolution or { display.width, display.height }
    local resolutionIndex = #resolutions
    for i, r in ipairs(resolutions) do
        if r[1] == want[1] and r[2] == want[2] then resolutionIndex = i end
    end
    local budgetIndex = 1
    for i, b in ipairs(settings.SPLAT_BUDGETS) do
        if b <= v.splatBudget then budgetIndex = i end
    end
    local shadowIndex = 1
    for i, q in ipairs(settings.SHADOW_QUALITIES) do
        if q == v.shadowQuality then shadowIndex = i end
    end

    local rows = {
        { key = "resolution", label = "Resolution", choices = resolutions, index = resolutionIndex,
          format = function(r) return r[1] .. " x " .. r[2] end,
          apply = function(r) v.resolution = { r[1], r[2] } return "resolution", v.resolution end },
        { key = "fullscreen", label = "Fullscreen", choices = { false, true }, index = v.fullscreen and 2 or 1,
          format = function(on) return on and "On" or "Off" end,
          apply = function(on) v.fullscreen = on return "fullscreen", on end },
        { key = "splatBudget", label = "Max splats", choices = settings.SPLAT_BUDGETS, index = budgetIndex,
          format = thousands,
          apply = function(b) v.splatBudget = b return "splatBudget", b end },
        { key = "shadowQuality", label = "Shadow quality", choices = settings.SHADOW_QUALITIES, index = shadowIndex,
          format = function(q) return q .. " (" .. settings.SHADOW_FACE_SIZES[q] .. ")" end,
          apply = function(q) v.shadowQuality = q return "shadowQuality", q end },
        { key = "ssao", label = "Ambient occlusion", choices = { false, true }, index = v.ssao and 2 or 1,
          format = function(on) return on and "On" or "Off" end,
          apply = function(on) v.ssao = on return "ssao", on end },
        { key = "ssgi", label = "Indirect light", choices = { false, true }, index = v.ssgi and 2 or 1,
          format = function(on) return on and "On" or "Off" end,
          apply = function(on) v.ssgi = on return "ssgi", on end },
        { label = "Back", action = function() self.page, self.selected = "main", 2 end },
    }
    if not self.only then return rows end
    local shown, wanted = {}, {}
    for _, key in ipairs(self.only) do wanted[key] = true end
    for _, row in ipairs(rows) do
        if not row.key or wanted[row.key] then shown[#shown + 1] = row end
    end
    return shown
end

function Menu:isOpen() return self.open end

function Menu:setOpen(open)
    if open == self.open then return end
    self.open = open
    self.page, self.selected, self.hovered = "main", 1, nil
    self.dirty = true
    rhi.set_paused(open)
    rhi.show_pointer(open)
    for _, pass in ipairs(self.passes) do pass.enabled = open end
    self.onPause(open)
end

function Menu:close() self:setOpen(false) end

-- Escape: back a page, or closed.
function Menu:back()
    if self.page ~= "main" then
        self.page, self.selected = "main", 2
        self.dirty = true
    else
        self:close()
    end
end

function Menu:move(delta)
    local n = #self:rows()
    self.selected = (self.selected - 1 + delta) % n + 1
    self.dirty = true
end

-- A setting by `delta` choices (wrapping round), or a button pressed.
function Menu:activate(delta)
    local row = self:rows()[self.selected]
    if not row then return end
    if row.action then
        if delta == 0 then row.action() end
    else
        local i = (row.index - 1 + (delta == 0 and 1 or delta)) % #row.choices + 1
        local name, value = row.apply(row.choices[i])
        settings.save(self.values)
        self.onChange(name, value)
    end
    self.dirty = true
end

function Menu:on_key(key, action)
    if action ~= input.PRESS and action ~= input.REPEAT then return self.open end
    if not self.open then
        if key == keys.ESCAPE and action == input.PRESS then
            self:setOpen(true)
            return true
        end
        return false
    end
    if key == keys.ESCAPE then
        if action == input.PRESS then self:back() end
    elseif key == keys.UP then
        self:move(-1)
    elseif key == keys.DOWN then
        self:move(1)
    elseif key == keys.LEFT then
        self:activate(-1)
    elseif key == keys.RIGHT then
        self:activate(1)
    elseif (key == keys.ENTER or key == keys.SPACE) and action == input.PRESS then
        self:activate(0)
    end
    return true -- everything else waits until the menu closes
end

function Menu:on_controller_button(_, button, pressed)
    if button == buttons.Menu then
        if pressed then
            if self.open then self:close() else self:setOpen(true) end
        end
        return true
    end
    if not self.open then return false end
    if pressed then
        if button == buttons.DPadUp then self:move(-1)
        elseif button == buttons.DPadDown then self:move(1)
        elseif button == buttons.DPadLeft then self:activate(-1)
        elseif button == buttons.DPadRight then self:activate(1)
        elseif button == buttons.A then self:activate(0)
        elseif button == buttons.B then self:back()
        end
    end
    return true
end

local function inside(r, x, y)
    return r and x >= r[1] and y >= r[2] and x < r[1] + r[3] and y < r[2] + r[4]
end

function Menu:on_mouse_move(x, y)
    if not self.open then return false end
    for i, r in ipairs(self.rowRects or {}) do
        if inside(r, x, y) then
            if self.selected ~= i or self.hovered ~= i then self.dirty = true end
            self.selected, self.hovered = i, i
            return true
        end
    end
    if self.hovered then self.dirty = true end
    self.hovered = nil
    return true
end

function Menu:on_mouse_button(button, action)
    if not self.open then return false end
    if button ~= input.MOUSE_LEFT or action ~= input.PRESS then return true end
    local x, y = input.mouse()
    for i, r in ipairs(self.rowRects or {}) do
        if inside(r, x, y) then
            self.selected = i
            local row = self:rows()[i]
            if row.action then
                self:activate(0)
            else
                self:activate(x < r[1] + r[3] / 2 and -1 or 1)
            end
            return true
        end
    end
    return true
end

-- Lays the page out for a window of `width` x `height`.
function Menu:build(width, height)
    local c = self.canvas
    c:clear()
    local s = math.max(0.6, math.min(1.4, height / 900))
    local rows = self:rows()
    local rowHeight = math.floor(52 * s)
    local panelWidth = math.floor((self.page == "main" and 420 or 640) * s)
    local titleHeight = math.floor(90 * s)
    local hintHeight = math.floor(56 * s)
    local panelHeight = titleHeight + #rows * rowHeight + hintHeight
    local px = math.floor((width - panelWidth) / 2)
    local py = math.floor((height - panelHeight) / 2)
    local textScale = 0.85 * s
    local lineHeight = ui.CELL_HEIGHT * textScale

    c:rect(0, 0, width, height, COLORS.dim)
    c:rect(px, py, panelWidth, panelHeight, COLORS.panel, { radius = 14 * s })
    c:rect(px, py, panelWidth, panelHeight, COLORS.border, { radius = 14 * s, border = 1.5 })
    c:text(px + panelWidth / 2, py + (titleHeight - ui.CELL_HEIGHT * 1.3 * s) / 2,
        self.page == "main" and "Paused" or "Settings", { scale = 1.3 * s, color = COLORS.title, align = "center" })

    self.rowRects = {}
    local margin = math.floor(24 * s)
    for i, row in ipairs(rows) do
        local ry = py + titleHeight + (i - 1) * rowHeight
        local rect = { px + margin, ry + 4 * s, panelWidth - 2 * margin, rowHeight - 8 * s }
        self.rowRects[i] = rect
        if i == self.selected then
            c:rect(rect[1], rect[2], rect[3], rect[4], COLORS.selected, { radius = 8 * s })
        elseif i == self.hovered then
            c:rect(rect[1], rect[2], rect[3], rect[4], COLORS.hover, { radius = 8 * s })
        end
        local ty = rect[2] + (rect[4] - lineHeight) / 2
        if row.action then
            c:text(rect[1] + rect[3] / 2, ty, row.label, { scale = textScale, color = COLORS.text, align = "center" })
        else
            local pad = math.floor(18 * s)
            c:text(rect[1] + pad, ty, row.label, { scale = textScale, color = COLORS.text })
            local value = "<  " .. row.format(row.choices[row.index]) .. "  >"
            c:text(rect[1] + rect[3] - pad, ty, value,
                { scale = textScale, color = i == self.selected and COLORS.title or COLORS.value, align = "right" })
        end
    end

    local hint = self.page == "main" and "Up/Down  Enter  Esc: resume"
        or "Up/Down  Left/Right: change  Esc: back"
    c:text(px + panelWidth / 2, py + panelHeight - hintHeight + (hintHeight - ui.CELL_HEIGHT * 0.6 * s) / 2 - 4 * s,
        hint, { scale = 0.6 * s, color = COLORS.hint, align = "center" })
end

-- The menu's pass, in a scene's graph: last, over everything; on while the menu is open.
function Menu:addPasses(graph)
    self:resources()
    local pass = graph:render_pass { name = "pause menu" }
    pass:draw { pipeline = self.pipeline, count = 3, params = self.block }
    pass.enabled = self.open
    self.passes = { pass } -- only the graph being built is shown
    self.dirty = true
end

function Menu:layout()
    self.dirty = true
end

function Menu:update()
    if not self.open or not self.dirty then return end
    self:resources()
    self.dirty = false
    self:build(rhi.window_size())
    self.params = self.canvas:params()
    self.block:set(self.params)
end

-- For a script that draws each frame itself (or over its graph, as draw runs after it).
function Menu:draw(frame)
    if not self.open then return end
    self:update()
    frame:draw(self.pipeline, { count = 3, params = self.params })
end

return pauseMenu
