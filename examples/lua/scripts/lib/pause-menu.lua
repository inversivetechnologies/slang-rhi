-- The pause menu: Escape (or the Steam Controller's Menu button) opens it over whatever
-- is shown, and pauses it. Resume, Settings, Quit; the settings are on three pages
-- (lib/settings.lua keeps them between runs):
--
--   Display    the graphics device (the GPU: Enter restarts on it), the resolution,
--              fullscreen
--   Graphics   the most splats drawn, the shadows' quality, the ambient occlusion, the
--              global illumination, the effects' quality, the anti-aliasing
--   Controls   the mouse's and the controller's look sensitivity, invert Y
--
--   local menu = rhi.include("lib/pause-menu.lua").new {
--       settings = values,                    -- from settings.load(); changed in place
--       onPause = function(paused) end,       -- opened (true) or closed (false)
--       onChange = function(name, value) end, -- a setting changed (and was saved)
--       only = { "resolution", ... },         -- optional: the settings shown (default all;
--                                             -- the controls always), pages without any left out
--       controls = false,                     -- optional: no Controls page (no camera to turn)
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
        controls = options.controls ~= false,
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

-- The settings' pages, and which settings each has.
local PAGES = {
    { name = "display", title = "Display", keys = { "graphicsDevice", "resolution", "fullscreen" } },
    { name = "graphics", title = "Graphics",
      keys = { "splatBudget", "shadowQuality", "ambientOcclusion", "globalIllumination", "effectsQuality", "antiAliasing" } },
    { name = "controls", title = "Controls", keys = { "mouseSensitivity", "stickSensitivity", "invertY" } },
}
local CONTROLS = { mouseSensitivity = true, stickSensitivity = true, invertY = true }
-- Shown by every script, whatever its `only`: every script runs on a device.
local ALWAYS = { graphicsDevice = true }

local function indexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return 1
end

-- Every setting, by key: { label, choices, index, format, apply }.
function Menu:settingRows()
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
    local function sensitivityIndex(value)
        local best = 1
        for i, s in ipairs(settings.SENSITIVITIES) do
            if math.abs(s - value) < math.abs(settings.SENSITIVITIES[best] - value) then best = i end
        end
        return best
    end
    local function times(x) return string.format("%gx", x) end
    local function onOff(on) return on and "On" or "Off" end

    -- The GPUs (rhi.devices: listed once), and the one running.
    self.devices = self.devices or rhi.devices()
    local running = 1
    for i, d in ipairs(self.devices) do
        if d.adapter == rhi.adapter() then running = i end
    end
    self.runningDevice = running
    local function deviceName(d) return d.adapter end

    return {
        -- Picked with Left / Right, switched to with Enter: a restart on it.
        graphicsDevice = { label = "Graphics device", choices = self.devices,
          index = self.pendingDevice or running, confirm = true, format = deviceName,
          -- Tried first: kept (as graphicsDevice) once it has started (lib/settings.lua).
          apply = function(d)
              v.graphicsDeviceTrial = { adapter = d.adapter }
              return "graphicsDeviceTrial", v.graphicsDeviceTrial
          end },
        resolution = { label = "Resolution", choices = resolutions, index = resolutionIndex,
          format = function(r) return r[1] .. " x " .. r[2] end,
          apply = function(r) v.resolution = { r[1], r[2] } return "resolution", v.resolution end },
        fullscreen = { label = "Fullscreen", choices = { false, true }, index = v.fullscreen and 2 or 1,
          format = onOff,
          apply = function(on) v.fullscreen = on return "fullscreen", on end },
        splatBudget = { label = "Max splats", choices = settings.SPLAT_BUDGETS, index = budgetIndex,
          format = thousands,
          apply = function(b) v.splatBudget = b return "splatBudget", b end },
        shadowQuality = { label = "Shadow quality", choices = settings.SHADOW_QUALITIES,
          index = indexOf(settings.SHADOW_QUALITIES, v.shadowQuality),
          format = function(q) return q .. " (" .. settings.SHADOW_FACE_SIZES[q] .. ")" end,
          apply = function(q) v.shadowQuality = q return "shadowQuality", q end },
        ambientOcclusion = { label = "Ambient occlusion", choices = settings.AO_METHODS,
          index = indexOf(settings.AO_METHODS, v.ambientOcclusion),
          format = function(m) return m end,
          apply = function(m) v.ambientOcclusion = m return "ambientOcclusion", m end },
        globalIllumination = { label = "Global illumination", choices = settings.GI_METHODS,
          index = indexOf(settings.GI_METHODS, v.globalIllumination),
          format = function(m) return m == "Cascades" and "Radiance cascades" or m end,
          apply = function(m) v.globalIllumination = m return "globalIllumination", m end },
        effectsQuality = { label = "Effects quality", choices = settings.EFFECT_QUALITIES,
          index = indexOf(settings.EFFECT_QUALITIES, v.effectsQuality),
          format = function(q) return q == "Mixed" and "Mixed (AO full)" or q end,
          apply = function(q) v.effectsQuality = q return "effectsQuality", q end },
        antiAliasing = { label = "Anti-aliasing", choices = settings.AA_METHODS,
          index = indexOf(settings.AA_METHODS, v.antiAliasing),
          format = function(m)
              return m == "TAA" and "TAA (temporal)" or (m == "FXAA" or m == "SMAA") and m .. " (spatial)" or m
          end,
          apply = function(m) v.antiAliasing = m return "antiAliasing", m end },
        mouseSensitivity = { label = "Mouse sensitivity", choices = settings.SENSITIVITIES,
          index = sensitivityIndex(v.mouseSensitivity), format = times,
          apply = function(x) v.mouseSensitivity = x return "mouseSensitivity", x end },
        stickSensitivity = { label = "Controller look sensitivity", choices = settings.SENSITIVITIES,
          index = sensitivityIndex(v.stickSensitivity), format = times,
          apply = function(x) v.stickSensitivity = x return "stickSensitivity", x end },
        invertY = { label = "Invert Y", choices = { false, true }, index = v.invertY and 2 or 1,
          format = onOff,
          apply = function(on) v.invertY = on return "invertY", on end },
    }
end

-- Whether a setting is shown: all of them, or the script's `only` (and the controls,
-- which every script with a camera follows, unless it has none: `controls = false`).
function Menu:shows(key)
    if ALWAYS[key] then return true end
    if CONTROLS[key] then return self.controls end
    if not self.only then return true end
    for _, k in ipairs(self.only) do
        if k == key then return true end
    end
    return false
end

-- The settings pages with something to show.
function Menu:pages()
    local list = {}
    for _, page in ipairs(PAGES) do
        for _, key in ipairs(page.keys) do
            if self:shows(key) then
                list[#list + 1] = page
                break
            end
        end
    end
    return list
end

function Menu:go(page, selected)
    self.page, self.selected, self.hovered = page, selected or 1, nil
    self.dirty = true
end

-- The rows of the page shown: { label, action } buttons, or settings with { label,
-- choices, index, format, apply }.
function Menu:rows()
    if self.page == "main" then
        return {
            { label = "Resume", action = function() self:close() end },
            { label = "Settings", action = function() self:go("settings") end },
            { label = "Quit", action = function() rhi.quit() end },
        }
    end
    if self.page == "settings" then
        local rows = {}
        for i, page in ipairs(self:pages()) do
            rows[#rows + 1] = { label = page.title, action = function() self:go(page.name) end, opens = true }
        end
        rows[#rows + 1] = { label = "Back", action = function() self:back() end }
        return rows
    end
    local all = self:settingRows()
    local rows = {}
    for _, page in ipairs(PAGES) do
        if page.name == self.page then
            for _, key in ipairs(page.keys) do
                if self:shows(key) then
                    local row = all[key]
                    row.key = key
                    rows[#rows + 1] = row
                end
            end
        end
    end
    rows[#rows + 1] = { label = "Back", action = function() self:back() end }
    return rows
end

-- The page's title.
function Menu:title()
    if self.page == "main" then return "Paused" end
    for _, page in ipairs(PAGES) do
        if page.name == self.page then return page.title end
    end
    return "Settings"
end

function Menu:isOpen() return self.open end

function Menu:setOpen(open)
    if open == self.open then return end
    self.open = open
    self.page, self.selected, self.hovered = "main", 1, nil
    self.pendingDevice = nil
    self.dirty = true
    rhi.set_paused(open)
    rhi.show_pointer(open)
    for _, pass in ipairs(self.passes) do pass.enabled = open end
    self.onPause(open)
end

function Menu:close() self:setOpen(false) end

-- Escape: back a page (a settings page to the list of them, that to the first page), or
-- closed.
function Menu:back()
    if self.page == "main" then
        self:close()
    elseif self.page == "settings" then
        self:go("main", 2)
    else
        local back = 1
        for i, page in ipairs(self:pages()) do
            if page.name == self.page then back = i end
        end
        self:go("settings", back)
    end
end

function Menu:move(delta)
    local n = #self:rows()
    self.selected = (self.selected - 1 + delta) % n + 1
    self.dirty = true
end

-- A setting by `delta` choices (wrapping round), or a button pressed. A setting to confirm
-- (the graphics device) only changes its pending choice; Enter applies it.
function Menu:activate(delta)
    local row = self:rows()[self.selected]
    if not row then return end
    if row.action then
        if delta == 0 then row.action() end
    elseif row.confirm then
        if delta ~= 0 then
            self.pendingDevice = (row.index - 1 + delta) % #row.choices + 1
        elseif row.index ~= self.runningDevice then
            local name, value = row.apply(row.choices[row.index])
            settings.save(self.values)
            self.onChange(name, value)
            rhi.restart(value)
        end
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
    local panelWidth = math.floor(((self.page == "main" or self.page == "settings") and 420 or 700) * s)
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
        self:title(), { scale = 1.3 * s, color = COLORS.title, align = "center" })

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
            if row.opens then
                c:text(rect[1] + rect[3] - math.floor(18 * s), ty, ">",
                    { scale = textScale, color = i == self.selected and COLORS.title or COLORS.value, align = "right" })
            end
        else
            local pad = math.floor(18 * s)
            c:text(rect[1] + pad, ty, row.label, { scale = textScale, color = COLORS.text })
            -- The value, shortened (..) where it would run into the label.
            local shown = row.format(row.choices[row.index])
            local room = rect[3] - 2 * pad - ui.textWidth(row.label .. "  <    >", textScale)
            local fits = math.max(3, math.floor(room / ui.textWidth("x", textScale)))
            if #shown > fits then shown = shown:sub(1, fits - 2) .. ".." end
            local value = "<  " .. shown .. "  >"
            c:text(rect[1] + rect[3] - pad, ty, value,
                { scale = textScale, color = i == self.selected and COLORS.title or COLORS.value, align = "right" })
        end
    end

    local selectedRow = rows[self.selected]
    local hint = self.page == "main" and "Up/Down  Enter  Esc: resume"
        or self.page == "settings" and "Up/Down  Enter  Esc: back"
        or (selectedRow and selectedRow.confirm and selectedRow.index ~= self.runningDevice)
            and "Enter: restart on this GPU  Left/Right: change  Esc: back"
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
