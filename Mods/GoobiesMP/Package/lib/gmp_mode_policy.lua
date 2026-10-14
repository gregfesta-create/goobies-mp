-- D47: what each MODE may do, in one table. Pure Lua, no requires.
--   dev         development: dev identities and tickets, network roles over the relay, dev sockets, probes, selftests,
--               the playtest gameplay and the D36 legacy achievement proxy.
--   friend      the friend test build (D47/D48): a real Steam lobby, invites and Steam auth like production, plus the
--               playtest gameplay and the D36 legacy proxy; every dev scaffold is off.
--   production  the release: Steam only, the release native paths, no playtest gameplay gates, no legacy proxy.
-- Every mode decision in the App, Config, Identity and Auth asks Allows(mode, gate); production is exactly as strict as
-- it was before friend existed (test_mode_policy.lua pins every gate for every mode).
local P = {}
P.MODES = { 'dev', 'friend', 'production' }
local VALID = { dev = true, friend = true, production = true }

local function set(...) local s = {}; for _, m in ipairs({ ... }) do s[m] = true end; return s end
P.GATES = {
    -- dev scaffolding: dev only
    dev_identity = set('dev'),          -- dev: identities, AUTH_MODE=dev|off, DEV_NAME, RESERVATION_MINUTES=0
    dev_roles = set('dev'),             -- ROLE over the relay, the dev socket lobby and its solo START
    dev_scaffolding = set('dev'),       -- DEV_AUTOSTART boot driver, SPLASH_SKIP_ONLY, STANDIN_SELFTEST
    dev_probes = set('dev'),            -- checkpoint/native/XP/spawn/timer/state/progression/dispatch probes, F6 experiments
    dev_handover = set('dev'),          -- the dev host handover (two players, relay checkpoint stream)
    -- playtest gameplay: dev and friend
    gameplay = set('dev', 'friend'),    -- island flow, host enemy capture, shared pause, CLIENT_DAMAGE, CLIENT_UPGRADE_DAMAGE,
                                        -- SHARED_XP, the Cheat Mod island request
    playtest_world = set('dev', 'friend'), -- the playtest world binding for lobby START (LobbyWorldBinding)
    legacy_proxy = set('dev', 'friend'),   -- D36: the legacy always-block steam_api64 proxy
    -- Steam sessions: production and friend
    steam_session = set('production', 'friend'), -- Steam lobby boot and activation, non-loopback auth, SteamID retry
    -- release only
    production_native = set('production'),       -- production native lifecycle/outcomes, graceful departure, world binding
    production_diagnostics = set('production'),  -- STEAM_LOOPBACK_TEST, S2_SCRIPT, AUTH_CHECK
    -- the friend build itself
    friend_check = set('friend'),                -- log the friend-build config check at boot (gmp_friend_profile.lua)
    unprotected_warning = set('friend'),         -- D57 (Coder B): no achievement protection: warn and allow the lobby
}

function P.Valid(mode) return VALID[mode] == true end
-- mode, gate -> bool. An unknown gate is a programming error; an unknown mode allows nothing.
function P.Allows(mode, gate)
    local g = P.GATES[gate]
    assert(g, 'unknown mode gate: ' .. tostring(gate))
    return g[mode] == true
end
return P
