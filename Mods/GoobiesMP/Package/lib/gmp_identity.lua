-- GoobiesMP production: player identity (pure Lua).
-- Production identity = SteamID. Development identity = explicitly marked dev/test identity, usable only in dev mode.
-- A key is namespaced ("steam:<id>" / "dev:<name>") so a dev identity can never be mistaken for, or compared equal to, a SteamID.
-- Never derived from pawn/actor/process order, GetPlayerPawn(0) or a locally generated counter.
local Identity = {}

-- SteamID64 validation is STRUCTURAL (S1 static analysis + live standalone probe): a CSteamID packs
-- account id bits 0-31, instance bits 32-51, account type bits 52-55, universe bits 56-63.
-- A valid local individual user is universe 1 (public), type 1 (individual), instance 1 (desktop), account id ~= 0.
-- The decimal PREFIX is NOT part of the rule: accounts with id >= 2039734272 start with 7656120 and are valid.
-- Requires 64-bit integers (Lua 5.4, confirmed in the UE4SS runtime).
Identity.STEAMID64_LEN = 17
function Identity.IsValidSteamId64(s)
    if type(s) ~= "string" or #s ~= Identity.STEAMID64_LEN or s:match("^[1-9]%d+$") == nil then return false end
    local id = math.tointeger(tonumber(s))
    if id == nil or id <= 0 then return false end
    return ((id >> 56) & 0xFF) == 1 and ((id >> 52) & 0xF) == 1 and ((id >> 32) & 0xFFFFF) == 1 and (id & 0xFFFFFFFF) ~= 0
end

local function make(kind, value)
    return { kind = kind, value = value, key = kind .. ":" .. value, isDev = (kind == "dev") }
end

function Identity.Steam(idString)
    if not Identity.IsValidSteamId64(idString) then return nil, "bad_steamid" end
    return make("steam", idString)
end

function Identity.Dev(name)
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") or #name > 24 then return nil, "bad_dev_name" end
    return make("dev", name)
end

-- Log-safe form of a key: a real SteamID is shown as prefix + last 4 digits only (it is a persistent personal identifier);
-- dev keys are not secret and are shown as is. Never use the masked form for comparisons.
function Identity.Mask(key)
    if type(key) ~= "string" then return "?" end
    local kind, value = key:match("^(%a+):(.+)$")
    if kind == "steam" and #value >= 8 then return "steam:" .. value:sub(1, 4) .. "..." .. value:sub(-4) end
    if kind == "dev" then return key end
    return "?"
end

function Identity.Parse(key)
    if type(key) ~= "string" then return nil, "bad_identity" end
    local kind, value = key:match("^(%a+):(.+)$")
    if kind == "steam" then return Identity.Steam(value) end
    if kind == "dev" then return Identity.Dev(value) end
    return nil, "bad_identity"
end

-- Policy: which identities a session in a given mode accepts. No fallback of any kind.
local Policy = {}
Policy.__index = Policy
Identity.Policy = Policy
local Mode = require("gmp_mode_policy")   -- D47: friend accepts real Steam identities only, like production
function Policy.new(mode)
    assert(Mode.Valid(mode), "mode must be production, friend or dev")
    return setmetatable({ mode = mode }, Policy)
end
function Policy:Check(id)
    if type(id) ~= "table" or not id.key then return false, "bad_identity" end
    if id.isDev and not Mode.Allows(self.mode, "dev_identity") then return false, "dev_identity_in_production" end
    return true
end

-- Resolve the LOCAL identity. opts: { mode=, steamProvider=function()->idString|nil, devName=string|nil }.
-- Production: only a real SteamID; if unavailable the result is nil,"steamid_unavailable" (NO silent dev fallback).
-- Dev: an explicit devName is required, or a real SteamID from the provider.
function Identity.Resolve(opts)
    local mode = opts.mode
    if Mode.Valid(mode) and not Mode.Allows(mode, "dev_identity") then   -- production, friend
        if opts.devName ~= nil then return nil, "dev_identity_in_production" end
        local s = opts.steamProvider and opts.steamProvider() or nil
        if s == nil then return nil, "steamid_unavailable" end
        return Identity.Steam(s)
    elseif Mode.Allows(mode, "dev_identity") then
        if opts.devName ~= nil then return Identity.Dev(opts.devName) end
        local s = opts.steamProvider and opts.steamProvider() or nil
        if s ~= nil then return Identity.Steam(s) end
        return nil, "no_identity_source"
    end
    return nil, "bad_mode"
end

return Identity
