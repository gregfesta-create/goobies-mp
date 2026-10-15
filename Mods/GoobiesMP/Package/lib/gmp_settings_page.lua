-- GoobiesMP's page in Mod Menu (Coder D, user report 2026-10-14: "no configs showing up for Goobies Multiplayer").
-- Mod Menu shows a mod's settings gear only for a registered settings provider (ctx.registerSettings); this is that
-- provider. It shows the player-facing keys of Configs/GoobiesMP.ini with Mod Menu's own controls (so Menu Options styles
-- them like every Mod Menu control) and writes each change to that file at once; GoobiesMP reads the file when the game
-- starts, so a change applies on the next start. Dev, technical and network keys are never shown: they stay in the file.
-- The file is GoobiesMP's plain KEY=VALUE format (gmp_config.lua Config.Parse, gmp_app.lua parseExtras); every other line
-- is kept as it is. Pure Lua: file access is the framework context's readConfig/writeConfig.
local Config = require("gmp_config")
local P = {}

P.NOTE = "Changes apply the next time you start Goobies."
-- The order is the page order. default: the game's own default (gmp_config.lua Defaults, gmp_app.lua parseExtras).
P.FIELDS = {
    { key = "MAX_PLAYERS", kind = "number", label = "Default lobby size", min = 2, max = Config.MAX_PLAYERS_LIMIT, default = Config.Defaults().MAX_PLAYERS,
      tip = "How many players a lobby you create has room for. You can still change it in the lobby for one game." },
    { key = "ALLOW_AUTO_REJOIN", kind = "boolean", label = "Allow auto rejoin", default = Config.Defaults().ALLOW_AUTO_REJOIN, on = "true", off = "false",
      tip = "When you host: a player who dropped out can come back into the run by themselves. You can also change it in the lobby." },
    { key = "HOST_ONLY_PAUSE", kind = "boolean", label = "Only host can pause", default = false, on = "1", off = "0",
      tip = "When you host: only you can pause the shared game. You can also change it in the lobby." },
    { key = "RESERVATION_MINUTES", kind = "number", label = "Keep a dropped player's slot (minutes)", min = 10, max = 20, default = Config.Defaults().RESERVATION_MINUTES,
      tip = "When you host: how long a player who dropped out keeps their slot, class and colour for a rejoin." },
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function fieldOf(key) for _, f in ipairs(P.FIELDS) do if f.key == key then return f end end end

-- The value as the game would read it, or nil when the game would not accept it (then the default is shown).
local function decode(f, v)
    if f.kind == "boolean" then
        if v == "true" or v == "1" then return true elseif v == "false" or v == "0" then return false end
        return nil
    end
    local n = tonumber(v)
    if n and n == math.floor(n) and n >= f.min and n <= f.max then return math.floor(n) end
    return nil
end

-- text|nil -> { KEY = value } for every field (the last line of a key wins, as in the game's parsers)
function P.Read(text)
    local found = {}
    for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        local k, v = trim((line:gsub("#.*$", ""))):match("^([%w_]+)%s*=%s*(.-)$")
        if k and fieldOf(k) then found[k] = v end
    end
    local out = {}
    for _, f in ipairs(P.FIELDS) do
        local v = nil
        if found[f.key] ~= nil then v = decode(f, found[f.key]) end   -- (not `x and y or z`: a false setting must stay false)
        if v == nil then v = f.default end
        out[f.key] = v
    end
    return out
end

-- -> true, or nil and a reason
function P.Check(key, value)
    local f = fieldOf(key)
    if not f then return nil, "Not a setting on this page: " .. tostring(key) end
    if f.kind == "boolean" then
        if type(value) ~= "boolean" then return nil, "Expected on or off" end
    elseif type(value) ~= "number" or value ~= math.floor(value) or value < f.min or value > f.max then
        return nil, ("Expected a whole number from %d to %d"):format(f.min, f.max)
    end
    return true
end

-- Rewrite text with KEY=value: the first KEY line is replaced, later KEY lines are removed (the game would let the last
-- one win), a missing key is appended; every other line, comment and the file's line ending (CRLF or LF) are kept.
function P.Set(text, key, value)
    local f = assert(fieldOf(key), "unknown setting " .. tostring(key))
    local nl = (text or ""):find("\r\n", 1, true) and "\r\n" or "\n"
    local val = f.kind == "boolean" and (value and f.on or f.off) or tostring(math.floor(value))
    local lines = {}
    for line in ((text or ""):gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end
    local out, done = {}, false
    for _, line in ipairs(lines) do
        local k = trim((line:gsub("#.*$", ""))):match("^([%w_]+)%s*=")
        if k == key then
            if not done then out[#out + 1] = key .. "=" .. val; done = true end
        else
            out[#out + 1] = line
        end
    end
    if not done then out[#out + 1] = key .. "=" .. val end
    return table.concat(out, nl) .. nl
end

-- ctx: the Mod Menu framework context (readConfig, writeConfig, invalidate). -> a Mod Menu settings provider
function P.Provider(ctx)
    local changed = false
    local function save(key, value)
        local ok, why = P.Check(key, value)
        if not ok then return nil, why end
        local text, err = ctx.readConfig()
        if err and err ~= "missing" then return nil, err end              -- never overwrite a file that could not be read
        local written, problem = ctx.writeConfig(P.Set(text, key, value))
        if not written then return nil, problem or "Could not write Configs/GoobiesMP.ini" end
        changed = true
        if type(ctx.invalidate) == "function" then ctx.invalidate() end
        return true
    end
    local function current()
        local text, err = ctx.readConfig()
        if err and err ~= "missing" then text = nil end
        return P.Read(text)
    end
    return {
        build = function(ui, panel)
            local values = current()
            for _, f in ipairs(P.FIELDS) do
                local set = function(value) return save(f.key, value) end
                if f.kind == "boolean" then
                    ui.boolean(panel, f.label, values[f.key], set, nil, f.tip)
                else
                    ui.slider(panel, f.label, values[f.key], f.min, f.max, 1, set, f.tip, nil, f.default)
                end
            end
            ui.label(panel, P.NOTE)
        end,
        buildInfo = function(ui, panel)
            ui.label(panel, "Your own defaults for Goobies Multiplayer. " .. P.NOTE)
            ui.label(panel, "Network and developer settings stay in Configs\\GoobiesMP.ini.")
        end,
        restartRequired = function() return changed end,
    }
end

return P
