-- GoobiesMP production: session configuration (pure Lua, no game access). Lua 5.4 compatible.
-- Module names are prefixed gmp_ so they cannot collide with other UE4SS mods' `require` names.
local Config = {}
local Mode = require("gmp_mode_policy")   -- D47: dev | friend | production, one gate table

-- VERSIONS (three separate concepts; this is the ONLY place they are defined, everything else reads them from here):
--   MOD_VERSION      the GoobiesMP release string. Set ONCE for the lobby milestone; do not bump it per edit.
--   PROTOCOL_VERSION wire major version. Major 5 binds native authority acknowledgements to term and fresh proof nonce.
--                    Enemy snapshot payload remains V2, retaining per-instance damage. Major 9 (C0): SESSION_POLICY has no
--                    achievement flag (D16, always blocked), and the world-entry messages are reserved (gmp_messages.lua).
--   gameVer          the Goobies game build; "" while no clean source for it exists (a check runs only when BOTH sides know it).
Config.PROTOCOL_VERSION = 9
Config.MOD_VERSION = "1.0.0-test.3"
Config.MOD_NAME = "GoobiesMP"         -- the name a host advertises as the required mod
-- lobby limits (host validates everything; clients only request)
Config.LOBBY = { MAX_CHAT_BYTES = 200, CHAT_HISTORY = 50, CHAT_BURST = 5, CHAT_WINDOW = 3.0, MAX_ARTIFACTS = 8, MAX_TOKEN_BYTES = 32 }
-- D55 (supersedes D12's fixed four slots): MAX_PLAYERS is the DEFAULT lobby size (GoobiesMP.ini, the single source of
-- truth); the host may type another size per lobby (Host:SetLobbyMaxPlayers, 2..MAX_PLAYERS_LIMIT, never saved).
-- PLAYER_SLOTS is only that default's built-in value; it never caps anything (D54).
Config.PLAYER_SLOTS = 4
Config.MAX_PLAYERS_LIMIT = 64         -- handover/wire sanity cap for untrusted row counts, not a session size
Config.MAX_NAME_BYTES = 32

-- Ordered palette; PLAYER_COLOR_<slot> overrides the default colour of a slot. Colours are session/run state, not identity.
Config.DEFAULT_PALETTE = { "Red", "Blue", "Green", "Yellow", "Orange", "Purple", "Cyan", "Pink" }

function Config.Defaults()
    local pal = {}
    for i, c in ipairs(Config.DEFAULT_PALETTE) do pal[i] = c end
    return {
        MAX_PLAYERS = 4,                  -- D55: the default lobby size, 2..MAX_PLAYERS_LIMIT; NEVER the XP scaling value (use current_players)
        PLAYER_COLORS = {},               -- [slot] = colour name override
        PALETTE = pal,
        MODE = "production",              -- "production" (real SteamID only) | "friend" (D47 friend test build: Steam like production + playtest gameplay) | "dev" (explicit dev identities allowed)
        ALLOW_AUTO_REJOIN = true,         -- host setting; false => rejoin needs host approval (flow NOT built in M1)
        RESERVE_ON_DISCONNECT = true,     -- during a run, keep a disconnected player's slot/colour for rejoin
        HEARTBEAT_INTERVAL = 0.5,         -- seconds (6 beats per timeout window: tolerates 5 consecutive lost heartbeats)
        PEER_TIMEOUT = 3.0,               -- seconds of silence => disconnected (POC relay used 3 s)
        RESEND_INTERVAL = 0.5,            -- seconds between reliable resends
        MAX_RESENDS = 20,                 -- then the link is declared failed
        WINDOW = 64,                      -- duplicate/stale window and max reliable messages in flight
        CONNECT_TIMEOUT = 10,             -- client: seconds to wait for the transport to connect (relay accept) before giving up
        -- peer authentication (PHASE2 12.17/12.18)
        AUTH_MODE = "steam",              -- "steam" (production: real Steam tickets) | "dev" (MODE=dev only: forgeable dev tickets) | "off" (MODE=dev only: claims, legacy/offline tests)
        AUTH_TIMEOUT = 15,                -- seconds from connect to authenticated (and from authenticated to JOIN); then the peer is dropped
        AUTH_VERIFY_TIMEOUT = 10,         -- seconds to wait for the provider's validate result (Steam callback) after Verify
        AUTH_CHUNK_BYTES = 400,           -- client side: raw ticket bytes per AUTH_TICKET chunk (hex doubles it); max 600
        AUTH_MAX_TICKET_BYTES = 4096,     -- host side: larger tickets are refused
        AUTH_MAX_PENDING = 8,             -- host side: unauthenticated peers allowed at once (cheap flood bound, no per-identity lockout)
        AUTH_TAKEOVER = false,            -- false (default): a second connection of an identity that is already connected is refused (duplicate_identity). true: an AUTHENTICATED reconnect replaces the older link
        -- world entry (reserved by C0; enforced by W8/W10)
        RESERVATION_MINUTES = 15,         -- D20: a disconnected player's slot stays reserved 10-20 minutes; 0 = legacy "until EndRun", MODE=dev only
        PREP_TIMEOUT_SECONDS = 60,        -- D24: a run stuck in authority/island prep returns everyone to the lobby (15-300)
        GENERATING_TIMEOUT_SECONDS = 120, -- D24: a run stuck generating the island returns everyone to the lobby (30-600)
    }
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- key=value lines; '#' starts a comment. Unknown keys are ignored. Bad values keep the default and are reported.
function Config.Parse(text)
    local cfg, errs = Config.Defaults(), {}
    for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        line = trim((line:gsub("#.*$", "")))
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        if k then
            local n = tonumber(v)
            if k == "MAX_PLAYERS" then
                if n and n == math.floor(n) then cfg.MAX_PLAYERS = math.floor(n) else errs[#errs + 1] = "bad MAX_PLAYERS" end
            elseif k:match("^PLAYER_COLOR_%d+$") then
                cfg.PLAYER_COLORS[tonumber(k:match("%d+"))] = v
            elseif k == "MODE" then
                if Mode.Valid(v) then cfg.MODE = v else errs[#errs + 1] = "bad MODE" end
            elseif k == "ALLOW_AUTO_REJOIN" or k == "RESERVE_ON_DISCONNECT" then
                if v == "true" or v == "1" then cfg[k] = true elseif v == "false" or v == "0" then cfg[k] = false else errs[#errs + 1] = "bad " .. k end
            elseif k == "CONNECT_TIMEOUT" then
                if n and n > 0 then cfg[k] = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "AUTH_MODE" then
                if v == "steam" or v == "dev" or v == "off" then cfg.AUTH_MODE = v else errs[#errs + 1] = "bad AUTH_MODE" end
            elseif k == "AUTH_TAKEOVER" then
                if v == "true" or v == "1" then cfg[k] = true elseif v == "false" or v == "0" then cfg[k] = false else errs[#errs + 1] = "bad " .. k end
            elseif k == "AUTH_TIMEOUT" or k == "AUTH_VERIFY_TIMEOUT" then
                if n and n > 0 then cfg[k] = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "AUTH_CHUNK_BYTES" or k == "AUTH_MAX_TICKET_BYTES" or k == "AUTH_MAX_PENDING" then
                if n and n >= 1 and n == math.floor(n) then cfg[k] = math.floor(n) else errs[#errs + 1] = "bad " .. k end
            elseif k == "HEARTBEAT_INTERVAL" or k == "PEER_TIMEOUT" or k == "RESEND_INTERVAL" then
                if n and n > 0 then cfg[k] = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "RESERVATION_MINUTES" or k == "PREP_TIMEOUT_SECONDS" or k == "GENERATING_TIMEOUT_SECONDS" then
                if n and n == math.floor(n) then cfg[k] = math.floor(n) else errs[#errs + 1] = "bad " .. k end
            elseif k == "MAX_RESENDS" or k == "WINDOW" then
                if n and n >= 1 and n == math.floor(n) then cfg[k] = math.floor(n) else errs[#errs + 1] = "bad " .. k end
            end
        end
    end
    return cfg, errs
end

local function validColorName(c) return type(c) == "string" and c:match("^%a[%w_]*$") ~= nil and #c <= 16 end

-- Ordered colour list for a config: slot overrides first (slot order), then the palette remainder.
function Config.ColorList(cfg)
    local out, seen = {}, {}
    local function add(c)
        local k = c:lower()
        if not seen[k] then seen[k] = true; out[#out + 1] = c end
    end
    local slots = {}
    for s in pairs(cfg.PLAYER_COLORS) do slots[#slots + 1] = s end
    table.sort(slots)
    for _, s in ipairs(slots) do add(cfg.PLAYER_COLORS[s]) end
    for _, c in ipairs(cfg.PALETTE) do add(c) end
    -- D55/D54: any lobby size up to the limit gets a distinct colour for every slot (generated names after the palette).
    local n = 1
    while #out < Config.MAX_PLAYERS_LIMIT do n = n + 1; add('Color' .. n) end
    return out
end

-- Default colour of a slot: PLAYER_COLOR_<slot>, else the palette entry for that slot.
function Config.DefaultColorForSlot(cfg, slot)
    return cfg.PLAYER_COLORS[slot] or cfg.PALETTE[slot] or Config.ColorList(cfg)[slot]
end

-- Returns ok, errors[], warnings[]
function Config.Validate(cfg)
    local errs, warns = {}, {}
    local mp = cfg.MAX_PLAYERS
    if math.type(mp) ~= "integer" or mp < 2 or mp > Config.MAX_PLAYERS_LIMIT then
        errs[#errs + 1] = "MAX_PLAYERS must be a whole number from 2 to " .. Config.MAX_PLAYERS_LIMIT .. " (D55: the default lobby size), got " .. tostring(mp)
    else
        local list = Config.ColorList(cfg)
        for _, c in ipairs(list) do if not validColorName(c) then errs[#errs + 1] = "invalid colour name: " .. tostring(c) end end
        if #list < mp then errs[#errs + 1] = "not enough distinct colours (" .. #list .. ") for MAX_PLAYERS=" .. mp end
        for s in pairs(cfg.PLAYER_COLORS) do
            if type(s) ~= "number" or s < 1 or s > mp then warns[#warns + 1] = "PLAYER_COLOR_" .. tostring(s) .. " is outside 1..MAX_PLAYERS (ignored for default slot colours)" end
        end
    end
    if type(cfg.HEARTBEAT_INTERVAL) == "number" and type(cfg.PEER_TIMEOUT) == "number" and cfg.PEER_TIMEOUT < 4 * cfg.HEARTBEAT_INTERVAL then
        errs[#errs + 1] = "PEER_TIMEOUT must be at least 4 x HEARTBEAT_INTERVAL (a single lost heartbeat would otherwise drop a peer)"
    end
    if not Mode.Valid(cfg.MODE) then errs[#errs + 1] = "MODE must be production, friend or dev" end
    local am = cfg.AUTH_MODE
    if am ~= "steam" and am ~= "dev" and am ~= "off" then errs[#errs + 1] = "AUTH_MODE must be steam, dev or off"
    elseif am ~= "steam" and not Mode.Allows(cfg.MODE, "dev_identity") then errs[#errs + 1] = "AUTH_MODE=" .. am .. " is only allowed with MODE=dev (production requires AUTH_MODE=steam)" end
    local cb = cfg.AUTH_CHUNK_BYTES
    if type(cb) ~= "number" or cb < 64 or cb > 600 then errs[#errs + 1] = "AUTH_CHUNK_BYTES must be 64..600" end
    local mt = cfg.AUTH_MAX_TICKET_BYTES
    if type(mt) ~= "number" or mt < 64 or mt > 16384 then errs[#errs + 1] = "AUTH_MAX_TICKET_BYTES must be 64..16384" end
    for _, k in ipairs({ "AUTH_TIMEOUT", "AUTH_VERIFY_TIMEOUT", "AUTH_MAX_PENDING", "CONNECT_TIMEOUT" }) do
        if type(cfg[k]) ~= "number" or cfg[k] <= 0 then errs[#errs + 1] = k .. " must be positive" end
    end
    local function ranged(key, lo, hi)
        local v = cfg[key]
        if v == nil then return end
        if math.type(v) ~= "integer" or v < lo or v > hi then errs[#errs + 1] = key .. " must be an integer in " .. lo .. ".." .. hi end
    end
    if cfg.RESERVATION_MINUTES == 0 then
        if not Mode.Allows(cfg.MODE, "dev_identity") then errs[#errs + 1] = "RESERVATION_MINUTES=0 (reserve until EndRun) is only allowed with MODE=dev" end
    else ranged("RESERVATION_MINUTES", 10, 20) end
    ranged("PREP_TIMEOUT_SECONDS", 15, 300)
    ranged("GENERATING_TIMEOUT_SECONDS", 30, 600)
    if Mode.Allows(cfg.MODE, "dev_identity") and am == "dev" then warns[#warns + 1] = "DEV AUTH: forgeable development tickets; dev: identities only; never for production." end
    if Mode.Allows(cfg.MODE, "dev_identity") then warns[#warns + 1] = "DEV MODE: development identities are accepted; never ship with MODE=dev." end
    if Mode.Allows(cfg.MODE, "friend_check") then warns[#warns + 1] = "FRIEND TEST MODE: playtest gameplay and the D36 legacy achievement proxy are on; a test build, never a release." end
    return #errs == 0, errs, warns
end

-- Canonical colour spelling from a user string (case-insensitive), or nil.
function Config.CanonicalColor(cfg, name)
    if type(name) ~= "string" then return nil end
    local k = name:lower()
    for _, c in ipairs(Config.ColorList(cfg)) do if c:lower() == k then return c end end
    return nil
end

return Config
