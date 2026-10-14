-- Cross-PC 1.5 / D47: the friend-build config check (research/CROSS_PC_GAPS.md). Pure Lua.
-- A friend build runs MODE=friend (gmp_mode_policy.lua): a real Steam lobby with Steam auth, the playtest gameplay and
-- the D36 legacy achievement proxy, and no dev keys. The App logs the result at boot in MODE=friend.
local F = {}
-- Every key a friend build needs, with its value.
F.KEYS = {
    { 'MODE', 'friend' }, { 'AUTH_MODE', 'steam' }, { 'STEAM_LOBBY', '1' }, { 'LOBBY_UI', '1' },
    { 'DEV_LEGACY_ACHIEVEMENT_PROXY', '1' },
    -- the playtest gameplay set (tools/qa_four/prepare.py R1_FLAGS without the dev scaffolding) and presence
    { 'ISLAND_HANDOFF', '1' }, { 'AUTHORITY_PREP', '1' }, { 'RUN_SYNC_ENEMIES', '1' }, { 'CLIENT_ATTACKS', '1' },
    { 'HOST_CREDITED_STATS', '1' }, { 'HOST_ENEMY_CAPTURE', '1' }, { 'CLIENT_ENEMY_ROWS', '1' }, { 'SHARED_PAUSE', '1' },
    { 'PRESENCE', '1' },
    -- friend build (Coder D): the rest of the gameplay played in test 15 (its shared ini minus the dev keys)
    { 'SHARED_XP', '1' }, { 'ENEMY_FX', '1' }, { 'ENEMY_ATTACKS', '1' }, { 'PRESENCE_READ', '1' }, { 'PRESENCE_MARKERS', '1' },
    { 'PRESENCE_WORLD_SPACE', '1' }, { 'PRESENCE_SMOOTH', '1' }, { 'PRESENCE_ANIMATION', '1' }, { 'PRESENCE_APPEARANCE', '1' },
    { 'TICK_MS', '16' }, { 'PEER_TIMEOUT', '10' },
}
F.DEFAULTS = { MODE = 'production', AUTH_MODE = 'steam' }   -- gmp_config.lua defaults
-- Dev scaffolding: test transports, dev identities, boot drivers, probes and selftests. Any of these switched on is
-- reported (most are already ignored outside MODE=dev; the report keeps a friend config clean).
F.DEV_KEYS = { 'ROLE', 'DEV_NAME', 'DEV_PLAYER_SLOT', 'DEV_SOCKET_LOBBY', 'DEV_SOCKET_LOBBY_START', 'DEV_STEAM_SOCKETS_TEST',
    'STEAM_LOOPBACK_TEST', 'DEV_AUTOSTART', 'DEV_AUTOSTART_PLAYERS', 'SPLASH_SKIP_ONLY', 'STANDIN_SELFTEST', 'PRODUCTION_SLICE_TEST',
    'SELFTEST', 'LOBBY_SELFTEST', 'LOBBY_CHECK', 'LOBBY_UI_CHECK', 'STEAM_LOBBY_CHECK', 'M3_SCRIPT', 'S2_SCRIPT', 'AUTH_CHECK',
    'PRESENCE_CHECK', 'VISUAL_CHECK', 'ENEMY_CHECK', 'CHECKPOINT_PROBE', 'NATIVE_BINDING_PROBE', 'DEV_DISPATCH_PROBE',
    'DEV_DISPATCH_CONTROLLER_PROBE', 'DEV_PICKUP_COMPACTION_PROBE', 'NATIVE_XP_READ_CAPTURE', 'NATIVE_F6_EXPERIMENT',
    'NATIVE_F6_AUTOPAUSE', 'NATIVE_F6_CYCLE', 'NATIVE_SPAWN_CHECK', 'NATIVE_TIMER_CHECK', 'NATIVE_STATE_CHECK',
    'NATIVE_REBUILD_CHECK', 'NATIVE_REBUILD_AUTOPAUSE', 'PROGRESSION_RESTORE_CHECK', 'RUNTIME_FACTS', 'S1_PROBE' }

local function parse(text)
    local v = {}
    for line in (tostring(text or '') .. '\n'):gmatch('([^\r\n]*)[\r\n]') do
        local k, value = line:gsub('#.*$', ''):match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k then v[k:upper()] = value end
    end
    return v
end
local function on(value) value = tostring(value or ''):lower(); return value == '1' or value == 'true' end
local function off(value)
    value = tostring(value or ''):lower()
    return value == '' or value == '0' or value == 'false' or value == 'none' or value == 'off'
end

-- config text -> list of problems (empty when the config is a friend-build config).
function F.Check(text)
    local v, problems = parse(text), {}
    for _, kv in ipairs(F.KEYS) do
        local key, want = kv[1], kv[2]
        local got = v[key] or F.DEFAULTS[key]
        local ok = want == '1' and on(got) or got == want
        if not ok then problems[#problems + 1] = string.format('%s=%s is needed (now %s)', key, want, got or 'unset') end
    end
    for _, key in ipairs(F.DEV_KEYS) do
        local got = v[key]
        if got and not off(got) then problems[#problems + 1] = string.format('%s=%s is a dev key; remove it', key, got) end
    end
    return problems
end
return F
