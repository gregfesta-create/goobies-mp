-- Test 15 (single install): the launch identity of one test window. Every window runs the same install and exe; only
-- this differs. Pure: main.lua hands in getenv and the command line (Bridge.CommandLine).
--   slot:     env GMP_SLOT=N, else -GMPSlot=N on the command line. A whole number 1..Config.MAX_PLAYERS_LIMIT (D54: no
--             fixed count). Malformed -> refused ('invalid_slot'); the window then boots as if it had no slot.
--   dev name: -GMPDevName=<name> on the command line, else qa_player<N> (never the ini's DEV_NAME / DEV_PLAYER_SLOT).
-- With a slot main.lua logs to <modDir>/gmp_slot<N>.log and uses <modDir>/net/slot<N>; the ini's ROLE is not used.
local Config = require("gmp_config")
local Slot = {}
Slot.ENV, Slot.SWITCH, Slot.NAME_SWITCH = "GMP_SLOT", "-GMPSlot", "-GMPDevName"
Slot.NAME_MAX = 32

local function switch(line, name)
    -- the exact switch: at the start or after whitespace / a quote, then '=' and the value up to the next space
    local value = (" " .. (line or "")):match('[%s"]' .. name:gsub("%p", "%%%0") .. "=(%S*)")
    return value
end
local function wholeSlot(text)
    if type(text) ~= "string" or not text:match("^%d+$") then return nil end
    local n = math.tointeger(tonumber(text))
    if n and n >= 1 and n <= Config.MAX_PLAYERS_LIMIT then return n end
end

-- opts: getenv = function(name) -> string|nil, commandLine = string|nil
-- -> {slot, devName, source, devNameRefused?} | nil, 'none' | nil, 'invalid_slot', raw, source
function Slot.Resolve(opts)
    local env = opts.getenv and opts.getenv(Slot.ENV) or nil
    local raw, source
    if type(env) == "string" and env ~= "" then raw, source = env, "env"
    else raw = switch(opts.commandLine, Slot.SWITCH); source = "command line" end
    if raw == nil then return nil, "none" end
    local slot = wholeSlot(raw)
    if not slot then return nil, "invalid_slot", raw, source end
    local out = { slot = slot, source = source, devName = "qa_player" .. slot }
    local name = switch(opts.commandLine, Slot.NAME_SWITCH)
    if name and name ~= "" then
        if #name <= Slot.NAME_MAX and name:match("^[%w_]+$") then out.devName = name else out.devNameRefused = name end
    end
    return out
end
function Slot.Describe(s) return string.format("slot %d (%s)", s.slot, s.source == "env" and "env " .. Slot.ENV or "command line " .. Slot.SWITCH) end
function Slot.LogName(n) return "gmp_slot" .. n .. ".log" end
function Slot.NetDir(modDir, n) return modDir .. "/net/slot" .. n end

return Slot
