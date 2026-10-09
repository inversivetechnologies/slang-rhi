-- A small JSON reader for scene and prefab files: standard JSON, plus // and /* */
-- comments and trailing commas (as JSONC allows), so that scene files can be annotated.
--
--   local json = rhi.include("lib/scene/json.lua")
--   local value = json.decode(text, "scenes/composite.json")   -- errors say file:line:column
--
-- Objects become Lua tables with string keys; arrays become sequences; null becomes
-- json.null (a unique value), so that a key set to null is still there.

local json = { null = setmetatable({}, { __tostring = function() return "null" end }) }

function json.decode(text, source)
    local pos = 1
    local len = #text

    local function fail(message)
        local line, column = 1, 1
        for i = 1, math.min(pos, len + 1) - 1 do
            if text:sub(i, i) == "\n" then
                line, column = line + 1, 1
            else
                column = column + 1
            end
        end
        error(string.format("%s:%d:%d: %s", source or "json", line, column, message), 0)
    end

    -- Whitespace and comments.
    local function skip()
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            elseif text:sub(pos, pos + 1) == "//" then
                local stop = text:find("\n", pos, true)
                pos = stop and stop + 1 or len + 1
            elseif text:sub(pos, pos + 1) == "/*" then
                local stop = text:find("*/", pos + 2, true)
                if not stop then fail("unterminated comment") end
                pos = stop + 2
            else
                return
            end
        end
    end

    local value -- forward

    local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

    local function decodeString()
        pos = pos + 1 -- the opening quote
        local parts = {}
        while true do
            local stop = text:find('["\\]', pos)
            if not stop then fail("unterminated string") end
            parts[#parts + 1] = text:sub(pos, stop - 1)
            pos = stop
            if text:sub(pos, pos) == '"' then
                pos = pos + 1
                return table.concat(parts)
            end
            local e = text:sub(pos + 1, pos + 1)
            if e == "u" then
                local hex = text:sub(pos + 2, pos + 5)
                if not hex:match("^%x%x%x%x$") then fail("bad \\u escape") end
                parts[#parts + 1] = utf8.char(tonumber(hex, 16))
                pos = pos + 6
            elseif ESCAPES[e] then
                parts[#parts + 1] = ESCAPES[e]
                pos = pos + 2
            else
                fail("bad escape \\" .. e)
            end
        end
    end

    local function decodeNumber()
        local s, e = text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not s then fail("bad number") end
        local n = tonumber(text:sub(s, e))
        if not n then fail("bad number") end
        pos = e + 1
        return n
    end

    local function decodeArray()
        pos = pos + 1
        local result = {}
        skip()
        if text:sub(pos, pos) == "]" then
            pos = pos + 1
            return result
        end
        while true do
            result[#result + 1] = value()
            skip()
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == "]" then return result end
            if c ~= "," then fail("expected ',' or ']'") end
            skip()
            if text:sub(pos, pos) == "]" then -- trailing comma
                pos = pos + 1
                return result
            end
        end
    end

    local function decodeObject()
        pos = pos + 1
        local result = {}
        skip()
        if text:sub(pos, pos) == "}" then
            pos = pos + 1
            return result
        end
        while true do
            skip()
            if text:sub(pos, pos) ~= '"' then fail("expected a key (a string)") end
            local key = decodeString()
            skip()
            if text:sub(pos, pos) ~= ":" then fail("expected ':' after \"" .. key .. "\"") end
            pos = pos + 1
            result[key] = value()
            skip()
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == "}" then return result end
            if c ~= "," then fail("expected ',' or '}'") end
            skip()
            if text:sub(pos, pos) == "}" then -- trailing comma
                pos = pos + 1
                return result
            end
        end
    end

    function value()
        skip()
        local c = text:sub(pos, pos)
        if c == "{" then return decodeObject() end
        if c == "[" then return decodeArray() end
        if c == '"' then return decodeString() end
        if c == "-" or c:match("%d") then return decodeNumber() end
        if text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
        if text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
        if text:sub(pos, pos + 3) == "null" then pos = pos + 4 return json.null end
        if c == "" then fail("unexpected end") end
        fail("unexpected '" .. c .. "'")
    end

    local result = value()
    skip()
    if pos <= len then fail("unexpected text after the value") end
    return result
end

return json
