-- GoobiesMP: peer-authentication PROVIDER CONTRACT and helpers (pure Lua, no game access, no Steam calls).
-- Design: PHASE2.md section 12.17 (tickets over the relay) and 12.18 (this Lua framework).
--
-- Vocabulary: an identity CLAIM is what a peer says; an AUTHENTICATED identity is a claim that a provider verified.
-- The session layer (gmp_host / gmp_client) never trusts a claim: the roster only receives keys the host's provider confirmed.
--
-- A provider moves opaque ticket bytes (as hex text) and reports verification results. It knows nothing about roster, slots or
-- transport. The real implementation (kind "steam") will be the native UE4SS layer (GetAuthSessionTicket / BeginAuthSession /
-- ValidateAuthTicketResponse_t); it is NOT written yet. kind "dev" is the test-only provider in gmp_auth_dev.lua.
--
-- Provider contract (all methods use identity KEYS: "steam:<id>" / "dev:<name>"; the provider maps them to what it needs):
--   p:Name()                         -> string
--   p:Kind()                         -> "steam" | "dev"
--   p:Status()                       -> true | nil,reason            can this provider work right now? (Steam running, logged on)
--   -- client side (asking for a ticket addressed to the host's key; a ticket is single use)
--   p:TicketBegin(hostKey)           -> handle | nil,reason
--   p:TicketState(handle)            -> "pending" | "ready",sizeBytes | "failed",reason
--   p:TicketChunk(handle, offset, n) -> hexString | nil             n bytes starting at byte offset
--   p:TicketCancel(handle)           -> nil
--   -- host side (validating a ticket that claims to belong to claimedKey)
--   p:Verify(claimedKey, ticketHex, hostKey) -> true | nil,reason   immediate quick check ONLY; NOT proof of identity
--   p:Poll()                         -> events[]                     { kind="validate", key=string, ok=bool, reason=string, owner=string|nil }
--   p:End(key)                       -> nil                          end the validation session for key
-- Identity is proven ONLY by a validate event with ok=true for the claimed key (Valve: BeginAuthSession's return value is not proof).
local Auth = {}

Auth.REQUIRED = { "Name", "Kind", "Status", "TicketBegin", "TicketState", "TicketChunk", "TicketCancel", "Verify", "Poll", "End" }
Auth.MAX_CHUNK_BYTES = 600        -- hard cap per AUTH_TICKET chunk (hex = 2x) so a packet stays below the codec's 1400 byte limit
Auth.MAX_CHUNKS = 32              -- a ticket never needs more; also below the reliable window
Auth.SCHEMES = { steam = true, dev = true }

-- Which provider kind a given AUTH_MODE accepts. AUTH_MODE=steam accepts ONLY a real Steam provider; "dev" only the dev provider.
Auth.KIND_FOR_MODE = { steam = "steam", dev = "dev" }

function Auth.CheckProvider(p, cfg)
    local missing = {}
    for _, m in ipairs(Auth.REQUIRED) do
        if type(p) ~= "table" or type(p[m]) ~= "function" then missing[#missing + 1] = m end
    end
    if #missing > 0 then return false, "bad_auth_provider: missing " .. table.concat(missing, ",") end
    local want = Auth.KIND_FOR_MODE[cfg.AUTH_MODE]
    if want == nil then return false, "auth_mode_has_no_provider" end
    if p:Kind() ~= want then return false, "auth_provider_kind_mismatch" end
    if want == "dev" and not require("gmp_mode_policy").Allows(cfg.MODE, "dev_identity") then return false, "dev_auth_in_production" end
    return true
end

------------------------------------------------------------------ hex
function Auth.ToHex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
function Auth.FromHex(h)
    if type(h) ~= "string" or #h % 2 ~= 0 or h:find("[^0-9a-fA-F]") then return nil end
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end
function Auth.IsHex(h) return type(h) == "string" and #h % 2 == 0 and not h:find("[^0-9a-fA-F]") end

------------------------------------------------------------------ result reasons
-- Provider reasons (named after Steam's EBeginAuthSessionResult / EAuthSessionResponse) -> short wire reasons.
local MAP = {
    ExpiredTicket = "ticket_expired", AuthTicketInvalidAlreadyUsed = "ticket_used", DuplicateRequest = "ticket_used",
    InvalidTicket = "ticket_invalid", InvalidVersion = "ticket_invalid", AuthTicketInvalid = "ticket_invalid",
    GameMismatch = "wrong_app", NoLicenseOrExpired = "not_licensed", AuthTicketNetworkIdentityFailure = "wrong_host",
    VACBanned = "banned_by_steam", PublisherIssuedBan = "banned_by_steam", UserNotConnectedToSteam = "steam_offline",
    LoggedInElseWhere = "logged_in_elsewhere", AuthTicketCanceled = "ticket_canceled", VACCheckTimedOut = "auth_timeout",
    steam_unavailable = "steam_unavailable", logged_off = "steam_offline",
}
function Auth.WireReason(r) return MAP[r] or "auth_failed" end

------------------------------------------------------------------ network exposure gate
-- PHASE2 12.17 / project rule: non-loopback Direct IP / relay traffic must not be enabled for production multiplayer until REAL
-- Steam authentication is active. Nothing in the mod opens a non-loopback socket yet; M4 must call this before it ever does.
-- Development modes (AUTH_MODE=dev/off) are loopback-only by definition, so they never pass.
function Auth.AllowNonLoopback(cfg, provider)
    if not require("gmp_mode_policy").Allows(cfg.MODE, "steam_session") then return false, "dev_mode_is_loopback_only" end   -- production, friend (D47)
    if cfg.AUTH_MODE ~= "steam" then return false, "real_steam_auth_required" end
    if type(provider) ~= "table" or not Auth.CheckProvider(provider, cfg) then return false, "real_steam_auth_required" end
    local ok, why = provider:Status()
    if not ok then return false, why or "steam_unavailable" end
    return true
end

return Auth
