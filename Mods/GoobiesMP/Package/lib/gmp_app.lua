-- GoobiesMP: application glue between the production session core (gmp_*) and a bridge/env. Pure Lua: it receives the
-- bridge and env as arguments and never touches UE4SS globals itself, so it can be tested with a fake bridge.
-- M2a scope: boot a HOST-ONLY session (roster of 1) on a private in-memory hub (no network), optionally run the
-- in-process self-test. No gameplay, no sockets, no Steam networking.
local Config = require("gmp_config")
local Host = require("gmp_host")
local Hub = require("gmp_memory_transport")
-- Lean builds (friend zip): the dev, probe and self-test modules (gmp_dev_modules.lua) may be missing; they are loaded
-- on first use, behind their dev or diagnostic gates.
local Dev = require("gmp_dev_modules")
local SelfTest = Dev.Lazy("gmp_selftest")
local DevAuth = Dev.Lazy("gmp_auth_dev")
local Identity = require("gmp_identity")
local Client = require("gmp_client")
local RelayTransport = require("gmp_relay_transport")
local Role = require("gmp_role")
local M3 = Dev.Lazy("gmp_m3")
local S2 = Dev.Lazy("gmp_s2")
local AuthCheck = require("gmp_authcheck")
local LobbySelfTest = Dev.Lazy("gmp_lobby_selftest")
local Presence = require("gmp_presence")
local Mode = require("gmp_mode_policy")
-- D47: every mode decision is a gate of gmp_mode_policy.lua (dev | friend | production). A plain function, so test
-- fixtures that call App methods on bare tables keep working.
local function allows(self, gate) return type(self.cfg) == 'table' and Mode.Allows(self.cfg.MODE, gate) end

local App = {}
App.__index = App

-- App-only keys (the session Config ignores unknown keys):
--   DEV_NAME=<name>  SELFTEST=1|0  TICK_MS=<ms>
--   RUNTIME_FACTS=1|0   log tick rate / clock cross-check / game-thread execution after PROBE_DELAY seconds (read-only)
--   S1_PROBE=off|static|call|inspect   S1 SteamID investigation (see bridge.lua ProbeS1): static = existence + reflection only, no Steam call;
--                              call = additionally ONE call of the local-user getter(s). Default off. Runs once, PROBE_DELAY s after boot.
--   PROBE_DELAY=<seconds>  (default 10)
--   ROLE=none|host|client|auto   (M3, dev only) network role over the relay transport; auto = handed out by the dev launcher (gmp_role.lua)
--   M3_SCRIPT=1|0                (M3, dev only) run the scripted M3 scenario (gmp_m3.lua) and write its result files
--   AUTH_CHECK=1|0               (real-Steam-auth Stage 1) one-shot diagnostic of the Steam ticket/validation path on the local SteamID (gmp_authcheck.lua);
--                                 production host-only session, no network
--   STEAM_LOOPBACK_TEST=1|0      (Stage 2) allows ROLE=host|client with MODE=production + AUTH_MODE=steam over the LOOPBACK relay only (test gate; default off)
--   S2_SCRIPT=1|0                (Stage 2) run the same-account scenario driver (gmp_s2.lua) with the above
--   LOBBY_SELFTEST=1|0           (lobby milestone) run the private in-process lobby self-test (own hub + dev clients, any mode; no game access)
--   LOBBY_CHECK=1|0              (lobby milestone) run the lobby check on the REAL host-only session (view model, settings, chat, start); one instance
--   DEV_LEGACY_ACHIEVEMENT_PROXY=1|0  (G3', D36) dev runs rely on the legacy always-block steam_api64 proxy (QA verifies its sha
--                                 before launch); accepted only in MODE=dev, refused in production/release and with PRODUCTION_SLICE_TEST
-- Reserved world-entry keys (C0, PLAN_WORLD_ENTRY.md 3.2 item 7; parsed now, implemented by later units). Dev-only keys
-- are forced off outside MODE=dev.
local RESERVED_EXTRAS = {
    { key = "RUN_SYNC_ENEMIES", field = "runSyncEnemies" },
    { key = "CLIENT_ATTACKS", field = "clientAttacks" },
    { key = "AUTHORITY_PREP", field = "authorityPrep" },
    { key = "CLIENT_ENEMY_ROWS", field = "clientEnemyRows" },
    { key = "DEV_SOCKET_LOBBY_START", field = "devSocketLobbyStart" },
    { key = "PRODUCTION_SLICE_TEST", field = "productionSliceTest" },
    { key = "HOST_CREDITED_STATS", field = "hostCreditedStats" },
    { key = "STANDIN_SELFTEST", field = "standinSelftest", devOnly = true },
    { key = "SPLASH_SKIP_ONLY", field = "splashSkipOnly", devOnly = true },
}
App.RESERVED_EXTRAS = RESERVED_EXTRAS
-- Native process flags read by the native modules, not by this file (documented here so the set is pinned):
--   MM_GUARD_VERIFY=1        Mod Menu guard verification build: blocks even while inactive (every dev launch)
--   GMP_SLICE1_AUTHORITY=1   Goobies_MP slice-1 native authority candidate
App.NATIVE_FLAGS = { "MM_GUARD_VERIFY", "GMP_SLICE1_AUTHORITY" }
local function parseExtras(text)
    local x = { devName = "dev_local", devNameSet = false, selftest = false, tickMs = 50, runtimeFacts = false, s1Probe = "off", probeDelay = 10, role = "none", m3Script = false, authCheck = false, steamLoopbackTest = false, s2Script = false, lobbySelftest = false, lobbyCheck = false }
    for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        if k == "DEV_NAME" and v ~= "" then x.devName, x.devNameSet = v, true
        elseif k == "ROLE" and Role.VALID[v] then x.role = v
        elseif k == "DEV_STEAM_SOCKETS_TEST" then x.devSteamSocketsTest=(v=="1" or v=="true")
        elseif k == "DEV_SOCKET_LOBBY" then x.devSocketLobby=(v=="1" or v=="true")
        -- G3' (D36): parsed in every mode so a misplaced key is refused loudly (App:DevLegacyProxy), never ignored.
        elseif k == "DEV_LEGACY_ACHIEVEMENT_PROXY" then x.devLegacyAchievementProxy=(v=="1" or v=="true")
        -- Dev-only run sync flag for Coder B (client upgrade damage); forced off outside MODE=dev in App.new.
        elseif k == "CLIENT_UPGRADE_DAMAGE" then x.clientUpgradeDamage=(v=="1" or v=="true")
        -- Dev-only run sync flag for Coder B (host enemy contact damages clients); forced off outside MODE=dev in App.new.
        elseif k == "CLIENT_DAMAGE" then x.clientDamage=(v=="1" or v=="true")
        -- D32 shared lives (Coder C, user 2026-10-15: on in friend mode, so the host and every player die the same way:
        -- a ghost a teammate revives). LIVES: the pool, 1-99 (default 3, gmp_run_sync_lives.lua).
        elseif k == "SHARED_LIVES" then x.sharedLives=(v=="1" or v=="true")
        elseif k == "LIVES" then local n=math.tointeger(tonumber(v)); x.lives=(n and n>=1 and n<=99) and n or nil
        elseif k == "SHARED_XP" then x.sharedXp=(v=="1" or v=="true")   -- D45 hook (Coder C)
        elseif k == "ENEMY_FX" then x.enemyFx=(v=="1" or v=="true")   -- D45 hook (Coder C)
        elseif k == "ENEMY_ATTACKS" then x.enemyAttacks=(v=="1" or v=="true")   -- D45 hook (Coder C)
        elseif k == "DEV_PLAYER_SLOT" then x.devPlayerSlot=tonumber(v)
        -- D52 dev tooling: the slots that boot as hosts of their own local test lobby (default 1), e.g. DEV_HOST_SLOTS=1,3.
        elseif k == "DEV_HOST_SLOTS" then
            local set=nil
            for n in v:gmatch('%d+') do n=tonumber(n); if n>=1 and n<=4 then set=set or {};set[n]=true end end
            x.devHostSlots=set
        elseif k == "M3_SCRIPT" then x.m3Script = (v == "1" or v == "true")
        elseif k == "AUTH_CHECK" then x.authCheck = (v == "1" or v == "true")
        elseif k == "PRESENCE_CHECK" then x.presenceCheck = (v == "1" or v == "true")
        elseif k == "VISUAL_CHECK" then x.visualCheck = (v == "1" or v == "true")
        elseif k == "ENEMY_CHECK" then x.enemyCheck = (v == "1" or v == "true")
        elseif k == "HOST_ENEMY_CAPTURE" then x.hostEnemyCapture = (v == "1" or v == "true")
        elseif k == "CHECKPOINT_PROBE" then x.checkpointProbe = (v == "1" or v == "true")
        elseif k == "NATIVE_BINDING_PROBE" then x.nativeBindingProbe = (v == "1" or v == "true")
        elseif k == "DEV_DISPATCH_CONTROLLER_PROBE" then x.devDispatchControllerProbe = (v == "1" or v == "true")
        elseif k == "DEV_PICKUP_COMPACTION_PROBE" then x.devPickupCompactionProbe = (v == "1" or v == "true")
        elseif k == "DEV_DISPATCH_PROBE" then x.devDispatchProbe = (v == "1" or v == "true")
        elseif k == "NATIVE_XP_READ_CAPTURE" then x.nativeXpReadCapture = (v == "1" or v == "true")
        elseif k == "NATIVE_F6_EXPERIMENT" then x.nativeF6Experiment = (v == "1" or v == "true")
        elseif k == "NATIVE_F6_AUTOPAUSE" then x.nativeF6AutoPause = (v == "1" or v == "true")
        elseif k == "NATIVE_F6_CYCLE" then x.nativeF6Cycle = (v == "1" or v == "true")
        elseif k == "NATIVE_SPAWN_CHECK" then x.nativeSpawnCheck = (v == "1" or v == "true")
        elseif k == "NATIVE_TIMER_CHECK" then x.nativeTimerCheck = (v == "1" or v == "true")
        elseif k == "NATIVE_STATE_CHECK" then x.nativeStateCheck = (v == "1" or v == "true")
        elseif k == "NATIVE_REBUILD_CHECK" then x.nativeRebuildCheck = (v == "1" or v == "true")
        elseif k == "NATIVE_REBUILD_AUTOPAUSE" then x.nativeRebuildAutoPause = (v == "1" or v == "true")
        elseif k == "DEV_AUTOSTART" then x.devAutoStart = (v == "1" or v == "true")
        elseif k == "DEV_AUTOSTART_PLAYERS" then
            local count=tonumber(v);if count and count%1==0 and count>=1 and count<=32 then x.devAutoStartPlayers=count end
        elseif k == "NATIVE_REBUILD_AUTORESUME_SECONDS" then
            local seconds=tonumber(v)
            if seconds and seconds>=1 and seconds<=60 then x.nativeRebuildAutoResumeSeconds=seconds end
        elseif k == "PROGRESSION_RESTORE_CHECK" then x.progressionRestoreCheck = (v == "1" or v == "true")
        elseif k == "ISLAND_HANDOFF" then x.islandHandoff = (v == "1" or v == "true")
        elseif k == "SHARED_PAUSE" then x.sharedPause = (v == "1" or v == "true")
        elseif k == "HOST_ONLY_PAUSE" then x.hostOnlyPause = (v == "1" or v == "true")
        elseif k == "STEAM_LOBBY" then x.steamLobby = (v == "1" or v == "true")
        elseif k == "STEAM_LOBBY_CHECK" then x.steamLobbyCheck = (v == "1" or v == "true")
        elseif k == "STEAM_LOOPBACK_TEST" then x.steamLoopbackTest = (v == "1" or v == "true")
        elseif k == "S2_SCRIPT" then x.s2Script = (v == "1" or v == "true")
        elseif k == "LOBBY_SELFTEST" then x.lobbySelftest = (v == "1" or v == "true")
        elseif k == "LOBBY_CHECK" then x.lobbyCheck = (v == "1" or v == "true")
        elseif k == "SELFTEST" then x.selftest = (v == "1" or v == "true")
        elseif k == "TICK_MS" and tonumber(v) and tonumber(v) >= 10 then x.tickMs = math.floor(tonumber(v))
        elseif k == "RUNTIME_FACTS" then x.runtimeFacts = (v == "1" or v == "true")
        elseif k == "S1_PROBE" and (v == "off" or v == "static" or v == "call" or v == "inspect") then x.s1Probe = v
        elseif k == "PROBE_DELAY" and tonumber(v) and tonumber(v) >= 0 then x.probeDelay = tonumber(v) end
    end
    for _, row in ipairs(RESERVED_EXTRAS) do x[row.field] = false end
    for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        for _, row in ipairs(RESERVED_EXTRAS) do if k == row.key then x[row.field] = (v == "1" or v == "true") end end
    end
    x.presence, x.presenceErrors = Presence.ParseConfig(text)       -- M3.1: PRESENCE* keys (default: everything off)
    return x
end

App.ParseExtras = parseExtras

-- opts: env, bridge, configText, and for network roles (M3; resolved by main.lua through gmp_role BEFORE the env/log file exist):
--   role ("host"|"client"|nil), roleAuto (bool), netDir, fs ({write,append,read,size,readFrom}, default RelayTransport.RealFs), rng
function App.new(opts)
    local self = setmetatable({}, App)
    self.achievementProtection=opts.achievementProtection
    self.env, self.bridge = opts.env, opts.bridge
    self.cfg, self.cfgErrors = Config.Parse(opts.configText)
    self.extras = parseExtras(opts.configText)
    -- Test 15 stutters (Coder B): the opt-in Lua collector switch (gmp_lua_gc.lua; off without LUA_GC_* keys)
    do
        local GC = require('gmp_lua_gc')
        local settings, problem = GC.Parse(opts.configText)
        self.luaGc = GC.new(settings, { collect = opts.gcCollect, problem = problem, log = function(line) self:_log('%s', line) end })
        self.luaGc:Apply()
    end
    if not Mode.Allows(self.cfg.MODE, "dev_scaffolding") then for _, row in ipairs(RESERVED_EXTRAS) do if row.devOnly then self.extras[row.field] = false end end end
    self.extras.clientUpgradeDamage = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.clientUpgradeDamage == true
    self.extras.clientDamage = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.clientDamage == true
    self.extras.sharedLives = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.sharedLives == true   -- D32 (Coder C)
    self.extras.sharedXp = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.sharedXp == true   -- D45 hook (Coder C)
    self.extras.enemyFx = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.enemyFx == true   -- D45 hook (Coder C)
    self.extras.enemyAttacks = Mode.Allows(self.cfg.MODE, "gameplay") and self.extras.enemyAttacks == true   -- D45 hook (Coder C)
    -- Frozen seams (C0): world objects and the run sync can be injected by tests and later units.
    self.islandWorldFactory, self.nativeWorldFactory, self.runSyncFactory = opts.islandWorldFactory, opts.nativeWorldFactory, opts.runSyncFactory
    self.role, self.roleAuto, self.netDir = opts.role, opts.roleAuto, opts.netDir
    self:_dropMissingDiagnostics()
    if opts.devSlot then self:_applyDevSlot(opts.devSlot) end
    self.presenceWorld = opts.presenceWorld      -- tests only: a fake world for gmp_presence
    self.modSettings = opts.modSettings          -- { setting = {enabled,source,reason}, path, fs }: the persistent GoobiesMP.ini state (main.lua read it before anything else)
    -- D42: Mod Menu's registry text (Configs/ModList.ini, read by main.lua); nil when there is none (check skipped).
    self.modManifest = require('gmp_mod_manifest').FromModList(opts.modListText)
    -- Cross-PC 1.5: the friend-build config check (gmp_friend_profile.lua), logged at boot when STEAM_LOBBY=1.
    self.friendCheck = require('gmp_friend_profile').Check(opts.configText)
    self.logFriendCheckAtBoot = Mode.Allows(self.cfg.MODE, 'friend_check')
    self.fs, self.rng = opts.fs or RelayTransport.RealFs, opts.rng or math.random
    self.autoReconnect = (self.role == "client")
    self.state = "new"          -- new | config_error | no_identity | hosting | client
    self.ticks, self.probesDone = 0, false
    self.s1 = nil               -- S1 probe result (kept in memory only; NEVER used as the session identity by M2)
    self.reason = nil
    return self
end

function App:_log(...) self.env:Log(...) end
-- Steam persona names for the host's roster (Host:SetNameResolver): GMP_Name_Get(steamId) -> name, 'ready' |
-- nil, 'pending' | nil, reason (the native provider: GetPersonaName for the local user, GetFriendPersonaName after
-- RequestUserInformation for the others). Without the export every player keeps the "Player <slot>" fallback.
function App.SteamNameResolver(G)
    return function(key)
        local id = type(key) == 'string' and key:match('^steam:(%d+)$')
        if not id or type(G) ~= 'table' or type(G.GMP_Name_Get) ~= 'function' then return nil end
        local ok, name = pcall(G.GMP_Name_Get, id)
        return ok and type(name) == 'string' and name or nil
    end
end
-- Lean builds: a diagnostic whose module is not in this build is switched off with one log line (the config key
-- stays readable; gmp_dev_modules.lua lists the modules a build may leave out).
App.DIAGNOSTICS = {
    { field = 'selftest', key = 'SELFTEST', module = 'gmp_selftest' },
    { field = 'lobbySelftest', key = 'LOBBY_SELFTEST', module = 'gmp_lobby_selftest' },
    { field = 'lobbyCheck', key = 'LOBBY_CHECK', module = 'gmp_lobby_selftest' },
    { field = 'steamLobbyCheck', key = 'STEAM_LOBBY_CHECK', module = 'gmp_steam_lobby_check' },
    { field = 'm3Script', key = 'M3_SCRIPT', module = 'gmp_m3' },
    { field = 's2Script', key = 'S2_SCRIPT', module = 'gmp_s2' },
    { field = 'presenceCheck', key = 'PRESENCE_CHECK', module = 'gmp_presence_probe' },
    { field = 'nativeBindingProbe', key = 'NATIVE_BINDING_PROBE', module = 'gmp_native_binding_probe' },
    { field = 'nativeSpawnCheck', key = 'NATIVE_SPAWN_CHECK', module = 'gmp_native_spawn_probe' },
    { field = 'nativeTimerCheck', key = 'NATIVE_TIMER_CHECK', module = 'gmp_native_timer_probe' },
    { field = 'nativeXpReadCapture', key = 'NATIVE_XP_READ_CAPTURE', module = 'gmp_native_xp_capture' },
    { field = 'nativeStateCheck', key = 'NATIVE_STATE_CHECK', module = 'gmp_native_state_probe' },
    { field = 'nativeRebuildCheck', key = 'NATIVE_REBUILD_CHECK', module = 'gmp_native_rebuild_probe' },
    { field = 'progressionRestoreCheck', key = 'PROGRESSION_RESTORE_CHECK', module = 'gmp_progression_restore_probe' },
    { field = 'devDispatchProbe', key = 'DEV_DISPATCH_PROBE', module = 'gmp_dev_dispatch_probe' },
    { field = 'devDispatchControllerProbe', key = 'DEV_DISPATCH_CONTROLLER_PROBE', module = 'gmp_dev_controller_probe' },
    { field = 'devPickupCompactionProbe', key = 'DEV_PICKUP_COMPACTION_PROBE', module = 'gmp_dev_pickup_combined_probe' },
    { field = 'nativeF6Cycle', key = 'NATIVE_F6_CYCLE', module = 'gmp_dev_migration_cycle' },
}
function App:_dropMissingDiagnostics()
    for _, d in ipairs(App.DIAGNOSTICS) do
        if self.extras[d.field] then
            local module, why = Dev.Load(d.module)
            if not module then
                self.extras[d.field] = false
                if self.env then self:_log('%s=1 ignored: %s is not in this build (%s)', d.key, d.module, tostring(why)) end
            end
        end
    end
end
-- Test 15 (single install, gmp_dev_slot.lua): the launch slot replaces the ini's DEV_NAME / DEV_PLAYER_SLOT, and the ini's
-- ROLE is not used. Dev builds only get a role: DEV_HOST_SLOTS decides when given; otherwise the dev socket lobby lets
-- any window host or join (the role is only its boot gate); anything else has no network role.
function App:_applyDevSlot(devSlot)
    self.extras.devPlayerSlot, self.extras.devName, self.extras.devNameSet = devSlot.slot, devSlot.devName, true
    self.roleAuto, self.role = false, nil
    if not Mode.Allows(self.cfg.MODE, "dev_roles") then return end
    local hostSlots = self.extras.devHostSlots
    if hostSlots then self.role = hostSlots[devSlot.slot] and "host" or "client"
    elseif self.extras.devSocketLobby then self.role = "client" end
end
function App:_mode(gate) return allows(self, gate) end
-- The native gmp_world used by RunContext (gmp_run_context.lua); created once, through opts.nativeWorldFactory when given.
function App:NativeWorld()
    if not self.nativeWorld then
        local G = self.bridge and self.bridge.G
        self.nativeWorld = self.nativeWorldFactory and self.nativeWorldFactory(G) or require('gmp_world').new(G)
    end
    return self.nativeWorld
end
-- The run sync (gmp_run_sync.lua contract); created through opts.runSyncFactory when given. W3 ticks it
-- (App:_tickRunSync) and replaces a stopped one at the next run. Extra options for S:
--   flags            the run sync app flags {runSyncEnemies, clientAttacks, authorityPrep, clientEnemyRows,
--                    clientUpgradeDamage, clientDamage (dev only)}
--   standinSelftest  function() -> ok, reason: may island prep create the STANDIN_SELFTEST synthetic self-peer now?
function App:RunSync()
    if not self.runSync then
        local x = self.extras
        local options = { G = self.bridge and self.bridge.G, log = function(line) self:_log('%s', line) end,
            clock = function() return self.clockNow end,
            flags = { runSyncEnemies = x.runSyncEnemies == true, clientAttacks = x.clientAttacks == true,
                authorityPrep = x.authorityPrep == true, clientEnemyRows = x.clientEnemyRows == true,
                clientUpgradeDamage = x.clientUpgradeDamage == true, clientDamage = x.clientDamage == true,
                sharedXp = x.sharedXp == true, enemyFx = x.enemyFx == true, enemyAttacks = x.enemyAttacks == true,   -- sharedXp, enemyFx, enemyAttacks: D45 hook (Coder C)
                sharedLives = x.sharedLives == true },   -- D32 (Coder C): ghosts and revives for every player, the host included
            lives = x.lives or 3,
            standinSelftest = function() return self:StandinSelftestAllowed() end }
        -- CLIENT_DAMAGE: the host tests contact against each client's presence position (host.presence); say so once.
        if x.clientDamage == true and self.role ~= 'client' and not (x.presence and x.presence.enabled) and not self.clientDamagePresenceNoted then
            self.clientDamagePresenceNoted = true
            self:_log('CLIENT_DAMAGE needs PRESENCE=1 (host contact uses the client presence positions)')
        end
        self.runSync = (self.runSyncFactory or require('gmp_run_sync').new)(options)
        self.lastRunAttribution = nil   -- S8: a new sync starts a new attribution
    end
    return self.runSync
end
-- W3 (PLAN_WORLD_ENTRY.md 3.8): run sync wiring. Inert unless RUN_SYNC_ENEMIES, CLIENT_ATTACKS or AUTHORITY_PREP is
-- set. The sync ticks only while a shared run is playing (gmp_run_context.lua); between islands it is left alone.
-- It stops on run end, menu, leave, session or term change and hold, and the next run gets a new one.
local PREP_PHASE = { authority_prep = 'process', island_prep = 'island' }
function App:_runSyncWanted()
    local x = self.extras
    return type(x) == 'table' and (x.runSyncEnemies == true or x.clientAttacks == true or x.authorityPrep == true)
end
function App:_runSyncOnce(line)
    self.runSyncLogged = self.runSyncLogged or {}
    if self.runSyncLogged[line] then return end
    self.runSyncLogged[line] = true; self:_log('%s', line)
end
-- Release a held prep pause through S1's host:PauseForAuthorityPrep(key, false).
function App:_releaseAuthorityPrep(live, why)
    local held = live and live.prep
    if not held then return end
    live.prep = nil
    local host = live.session
    if type(host) == 'table' and type(host.PauseForAuthorityPrep) == 'function' then
        local ok, err = pcall(host.PauseForAuthorityPrep, host, held.key, false)
        if not ok then self:_runSyncOnce('RunSync prep release failed: ' .. tostring(err):sub(1, 300)) end
    end
    self:_log('RunSync prep phase=%s released%s', held.phase, why and (' (' .. why .. ')') or '')
end
function App:_stopRunSync(reason)
    local live = self.runSyncLive
    if not live then return end
    self:_releaseAuthorityPrep(live, 'stopped: ' .. reason)
    if self.runSync then
        -- S8: the run's attribution outlives the sync until the host pages the end-screen stats
        local ok, status = pcall(self.runSync.Status, self.runSync)
        if ok and type(status) == 'table' then self.lastRunAttribution = status.attribution end
        pcall(self.runSync.Stop, self.runSync, reason)
    end
    self:_log('RunSync stopped reason=%s', reason)
    self.runSync, self.runSyncLive = nil, nil
end
-- The prep pause is host-owned: run sync asks (PauseRequest), S1's host API holds it, and it is released once the
-- request is withdrawn (S1 withdraws it when no peer is waiting). User Esc and the shared-pause policy are untouched.
function App:_tickAuthorityPrep(live, ctx, sync)
    if not self.extras.authorityPrep or self.role ~= 'host' then return end
    local ok, request = pcall(sync.PauseRequest, sync)
    local phase = ok and type(request) == 'table' and request.paused == true and PREP_PHASE[request.reason] or nil
    if live.prep and (live.prep.phase ~= phase or live.prep.key ~= ctx.key) then self:_releaseAuthorityPrep(live) end
    if not phase or live.prep then return end
    local host = live.session
    if type(host.PauseForAuthorityPrep) ~= 'function' then
        self:_runSyncOnce('RunSync prep unavailable: host:PauseForAuthorityPrep missing (S1)'); return
    end
    local called, accepted, why = pcall(host.PauseForAuthorityPrep, host, ctx.key, phase)
    if called and accepted == true then
        live.prep = { key = ctx.key, phase = phase }; self:_log('RunSync prep phase=%s held', phase)
    else
        self:_runSyncOnce('RunSync prep refused: ' .. tostring(called and (why or accepted) or accepted):sub(1, 300))
    end
end
function App:_tickRunSync()
    if not self:_runSyncWanted() then return end
    local live = self.runSyncLive
    if self.handoverRuntimeHold or self.nativeRestoreHold then
        if live then self:_stopRunSync('hold') end
        return
    end
    local session = self.role == 'host' and self.host or self.role == 'client' and self.client or nil
    local ctx = (self.state == 'hosting' or self.state == 'client') and require('gmp_run_context').From(self) or nil
    local generation = session and type(session.sessionPolicy) == 'table' and session.sessionPolicy.runGeneration or nil
    if live then
        local reason
        if not session then reason = 'left'
        elseif session ~= live.session then reason = 'session_changed'
        elseif (session.authorityTerm or 1) ~= live.term then reason = 'term_changed'
        elseif ctx and ctx.epoch ~= live.epoch then reason = 'run_end'
        -- W10/W6: an abort or lobby return moves the policy to the next run generation while the world may still show
        elseif live.generation and generation and generation > live.generation then reason = 'run_end'
        elseif not ctx then
            local roster = self.role == 'host' and session.roster or session.mirror
            if roster and roster.phase == 'lobby' then reason = 'run_end'
            elseif not session.islands or session.islands.phase == 'idle' then reason = 'menu' end
        end
        if reason then
            if reason == 'run_end' and ctx then self.runSyncEnded = { session = session, epoch = ctx.epoch } end
            self:_stopRunSync(reason); live = nil
        end
    end
    if not ctx then return end
    -- An ended run's island stays visible until the menu exit; it never gets a new sync.
    local ended = self.runSyncEnded
    if ended and ended.session == session and ended.epoch == ctx.epoch then return end
    if not live then live = { session = session, term = ctx.term, epoch = ctx.epoch, generation = generation }; self.runSyncLive = live end
    local sync = self:RunSync()
    if live.key ~= ctx.key then live.key = ctx.key; self:_log('RunSync tick ctx=%s', ctx.key) end
    local ok, why = pcall(sync.Tick, sync, ctx, session, self.clockNow)
    if not ok then self:_runSyncOnce('RunSync tick failed: ' .. tostring(why):sub(1, 300)); self:_stopRunSync('error'); return end
    self:_tickAuthorityPrep(live, ctx, sync)
end
-- W3: STANDIN_SELFTEST (dev, solo) lets S7a/S1 island prep create the synthetic self-peer. It needs the protection
-- predicate (App:StandinSelftestGate) and a host alone in its session.
function App:StandinSelftestAllowed()
    local ok, why = self:StandinSelftestGate()
    if ok then
        local count = 0
        if self.role == 'host' and self.host and self.host.roster then
            for _, player in ipairs(self.host.roster:Snapshot()) do if player.conn == 'connected' then count = count + 1 end end
        end
        if count ~= 1 then ok, why = false, 'standin_selftest_requires_solo' end
    end
    if not ok and self.env then self:_runSyncOnce('STANDIN_SELFTEST refused: ' .. tostring(why)) end
    return ok, why
end
-- W10 (D24): leaving an aborted or ended run. The host's own abort (runAborted), a client's RUN_ABORT or LOBBY_RETURN
-- (W6) starts the game's own menu exit once per run generation (gmp_lobby_menu_exit.lua: the HUD End Run path, else
-- the death event then the death screen Quit), and the lobby shows why. The host reaching the menu needs no exit.
local RUN_EXIT_NOTICE = { prep_timeout = 'Run aborted: players did not finish preparing in time.',
    generating_timeout = 'Run aborted: the island did not finish loading in time.',
    host_abort = 'Run aborted by the host.', lobby_return = 'The host ended the run.',
    connection_lost = 'Lost connection to the host. Press Join to rejoin (your slot is held for 15 minutes).',
    -- D40: only this player left the run; the slot is held 15 minutes (D20).
    stuck_transition = 'You were left behind: your game did not finish the island change in time. The others play on; press Join to rejoin (your slot is held for 15 minutes).' }
-- W9 (client side): with HOST_CREDITED_STATS, the client end screen controller (gmp_deathscreen.lua) receives the
-- run's RUN_STATS through the client's onRunStats hook (called by gmp_client.lua's RUN_STATS handler, S CR) and
-- triggers and fills the game's own end screen. The run generation is the one the client last played.
function App:_tickEndScreen()
    if type(self.extras) ~= 'table' or not self.extras.hostCreditedStats or self.role ~= 'client' or not self.client then return end
    local client = self.client
    if require('gmp_run_context').From(self) and type(client.sessionPolicy) == 'table' then
        self.endScreenGeneration = client.sessionPolicy.runGeneration
    end
    if not self.endScreen or self.endScreenClient ~= client then
        self.endScreen = require('gmp_deathscreen').new{ G = self.bridge and self.bridge.G or {},
            world = function() return self.islandFlow and self.islandFlow.world end,
            slot = function() local me = client:Me(); return me and me.slot end,
            generation = function() return self.endScreenGeneration end, log = function(line) self:_log('%s', line) end }
        self.endScreen:Install(); self.endScreenClient = client
    end
    if client.onRunStatsOwner ~= self.endScreen then
        local screen = self.endScreen
        client.onRunStats = function(f) return screen:Receive(f) end; client.onRunStatsOwner = screen
    end
    self.endScreen:Tick()
end
-- S8: with HOST_CREDITED_STATS the host pages its end-screen stats from the run sync attribution (the C0 contract:
-- runSync:Status().attribution, filled by S7b). One line to swap if S7b exposes another call.
function App:_wireRunStats()
    if type(self.extras) ~= 'table' or not self.extras.hostCreditedStats or self.role ~= 'host' or not self.host then return end
    if self.host.runStatsOwner == self then return end
    self.host.runStatsOwner = self
    self.host.runStatsSource = function()
        local sync = self.runSync
        if sync then local ok, status = pcall(sync.Status, sync); if ok and type(status) == 'table' then return status.attribution end end
        return self.lastRunAttribution
    end
end
-- S6: with CLIENT_ATTACKS, a client in a run drains the native attack observation ring and sends each live one as an
-- ATTACK_INTENT to the host (gmp_client_attacks.lua). The host alone resolves damage (S5, RunSync:ApplyRemoteHit).
function App:_tickClientAttacks()
    if type(self.extras) ~= 'table' or not self.extras.clientAttacks or self.role ~= 'client' or not self.client then return end
    if self.handoverRuntimeHold or self.nativeRestoreHold then return end
    local ctx = require('gmp_run_context').From(self)
    if not ctx then return end
    local client = self.client
    if not self.clientAttacks or self.clientAttacksClient ~= client then
        self.clientAttacks = require('gmp_client_attacks').new{ G = self.bridge and self.bridge.G or {},
            send = function(fields) return client:_send('ATTACK_INTENT', fields) == true end,
            -- R1 attempt 5: movement/contact class passives (skipped DamageAOE) as ATTACK_AOE (gmp_client_attacks.lua)
            sendAoe = function(fields) return client:_send('ATTACK_AOE', fields) == true end,
            -- test 7: instant local hit numbers (cosmetic) and the intent -> result round trip in the 1/s line
            feedback = function(entry)
                local sync = self.runSync
                if sync and type(sync.Feedback) == 'function' then
                    local ok, shown = pcall(sync.Feedback, sync, entry)
                    return ok and shown == true
                end
                return false
            end,
            -- test 13: local damage numbers for area hits too (gmp_run_sync AoeFeedback; cosmetic, own hits only)
            aoeFeedback = function(item)
                local sync = self.runSync
                if sync and type(sync.AoeFeedback) == 'function' then
                    local ok, n = pcall(sync.AoeFeedback, sync, item)
                    return ok and n or 0
                end
                return 0
            end,
            -- Coder B: the chain blast of a client's own standard hit (gmp_run_sync ChainOf)
            chain = function(item) local sync = self.runSync; if sync and type(sync.ChainOf) == 'function' then local ok, a = pcall(sync.ChainOf, sync, item); return ok and a or nil end end,
            results = function() return client:TakeAttackResults() end,
            -- the app clock: os.time (the default) has 1 s resolution, so result_ms read 0
            clock = function() return self.clockNow end,
            -- D43: hits on boss/unique proxy rows, for the boss_hits counter
            classify = function(entry)
                local sync = self.runSync
                if sync and type(sync.ClassifyHit) == 'function' then return sync:ClassifyHit(entry) end
            end,
            log = function(line) self:_log('%s', line) end }
        self.clientAttacksClient = client
    end
    self.clientAttacks:Tick(ctx)
end
function App:HostAbortRun()
    if self.role ~= 'host' or not self.host then return false, 'host_only' end
    return self.host:AbortRun('host_abort')
end
function App:_runExitRequest(session)
    if self.role == 'host' then return session.runAborted end
    if self.connectionExit then return self.connectionExit end
    local abort, back = session.runAbort, session.lobbyReturn
    if back and (not abort or back > abort.runGeneration) then return { runGeneration = back, reason = 'lobby_return' } end
    return abort
end
function App:_tickRunExit()
    local session = self.role == 'host' and self.host or self.role == 'client' and self.client or nil
    if not session then return end
    local lobby = self.role == 'host' and session.roster and { state = session.roster.lobbyState }
        or (type(session.LobbyMirror) == 'function' and session:LobbyMirror())
    if lobby and lobby.state == 'handoff_pending' then self.lobbyNotice = nil end
    local request = self:_runExitRequest(session)
    -- W9: the host-credited end screen stays until the player presses Quit; only a lobby return waits for it.
    if request and request.reason == 'lobby_return' and request.runGeneration ~= self.runExitGeneration
        and self.endScreen and self.endScreen:Showing() then
        if self.runExitDeferred ~= request.runGeneration then
            self.runExitDeferred = request.runGeneration; self:_log('run exit deferred: end screen shown')
        end
        return
    end
    if request and request.runGeneration ~= self.runExitGeneration then
        self.runExitGeneration = request.runGeneration
        self.lobbyNotice = RUN_EXIT_NOTICE[request.reason] or 'The run ended.'
        -- D40: rejoining after being left behind is the player's choice (Join), never automatic.
        if request.reason == 'stuck_transition' then self.autoReconnect = false end
        self.runExit = require('gmp_lobby_menu_exit').new{ G = self.bridge and self.bridge.G or {},
            world = function() return self.islandFlow and self.islandFlow.world end, log = function(line) self:_log('%s', line) end }
        self.runExit:Request(request.reason, self.clockNow)
    end
    if self.runExit then self.runExit:Tick(self.clockNow or 0) end
end

function App:Boot()
    local env, cfg = self.env, self.cfg
    local info = env:Info()
    self:_log("GoobiesMP %s booting; lua=%s", Config.MOD_VERSION, tostring(info.lua))
    self:_log("package.path=%s", tostring(info.packagePath))
    self:_log("log file works=%s", tostring(info.logFileWorks))
    local caps = self.bridge:Capabilities()
    local names = {}
    for k, v in pairs(caps) do names[#names + 1] = k .. "=" .. tostring(v) end
    table.sort(names)
    self:_log("bridge capabilities: %s", table.concat(names, " "))

    for _, e in ipairs(self.cfgErrors) do self:_log("config error: %s", e) end
    local ok, errs, warns = Config.Validate(cfg)
    for _, e in ipairs(errs) do self:_log("config invalid: %s", e) end
    for _, w in ipairs(warns) do self:_log("config warning: %s", w) end
    if self.logFriendCheckAtBoot then self:_logFriendCheck() end
    local steamLoopback = Mode.Allows(cfg.MODE, "production_diagnostics") and cfg.AUTH_MODE == "steam" and self.extras.steamLoopbackTest
    if self.role and not (Mode.Allows(cfg.MODE, "dev_roles") and cfg.AUTH_MODE == "dev") and not steamLoopback then
        -- network roles use the TEST-ONLY dev provider, or (explicit test gate STEAM_LOOPBACK_TEST=1) the real Steam provider over the loopback relay.
        -- There is no other production network path (non-loopback stays closed: PHASE2 12.17/12.18).
        ok = false
        self:_log("config invalid: ROLE=%s requires MODE=dev and AUTH_MODE=dev (or MODE=production + AUTH_MODE=steam + STEAM_LOOPBACK_TEST=1); no production network path exists", tostring(self.role))
    end
    if not ok or #self.cfgErrors > 0 then self.state, self.reason = "config_error", "invalid_config"; self:_log("session NOT started: invalid config"); return self.state end
    -- G3': report the proxy decision at boot, before any lobby START can be reached.
    if self.extras.devLegacyAchievementProxy then self:DevLegacyProxy() end

    if self.extras.devSocketLobby then return self:_bootDevSocketLobby() end
    if self.role then return self:_startNetSession() end
    if self.extras.steamLobby then return self:_bootSteamLobby() end
    return self:_startSession()
end

function App:_logFriendCheck()
    local problems = self.friendCheck or {}
    if #problems == 0 then self:_log("friend build check: ok (Steam lobby, real Steam auth, lobby UI)") end
    for _, p in ipairs(problems) do self:_log("friend build check: %s", p) end
end
-- Explicit native Steam lobby backend. Production native gameplay authority
-- remains separately guarded; this binds real lobby/session transport only.
function App:_bootSteamLobby()
    if not allows(self,'steam_session') or self.cfg.AUTH_MODE~='steam' or self.role then
        self.state='config_error';self.reason='steam_lobby_requires_production_auth';return self.state
    end
    local id,why=self.bridge:LocalIdentity('production')
    if not id then self.state='no_identity';self.reason=why;return self.state end
    self.identity=id;self.clockNow=self.clockNow or 0;self.state='steam_lobby'
    if self.steamLobbyBackend then return self.state end
    local backend,reason=require('gmp_steam_lobby_backend').new{G=self.bridge.G,requireAuthority=true,
        log=function(line) self:_log('%s',line) end,
        authorize=function() return require('gmp_auth').AllowNonLoopback(self.cfg,self.bridge.authProvider) end,
        resolve=function(kind,result)
            if kind=='create' then return result end
            local authority,why=self:_steamAuthority();if not authority then return nil,why end
            local mapping,error=authority:JoinContext(result);if not mapping then return nil,error end
            result.mapping=mapping;return result
        end,
        confirm=function(session,role)
            if role=='host' then return true end
            return self.steamAuthority:Confirm(session,self.steamJoinMapping)
        end,
        activate=function(kind,result) return self:_activateSteamSession(kind,result) end,
        leave=function() return self:_leaveSteamLobby() end,
        close=function() return self:_closeSteamLobby() end,   -- t3 friend reports (Coder A): the host's Cancel
        clock=function() return self.clockNow or 0 end,
        -- D53: the Host dropdown marks each Steam lobby 'same mods' / 'different mods' against this hash.
        modHash=function() return self.modManifest and require('gmp_lobby_browser').ModHash(self.modManifest) or nil end,
        session=function() return self.role=='host' and self.host or self.client,self.role end,
        failed=function() self:_clearSteamSession() end}
    if not backend then self.reason=reason;return self.state end
    self.steamLobbyBackend=backend;self.reason=nil
    self.steamConnection=require('gmp_lobby_connection').new{maxPlayers=self.cfg.MAX_PLAYERS,
        session=function() return self.role=='host' and self.host or self.client,self.role end}
    self.steamConnection:Bind(backend)
    -- e048e22: the native Steam callback sinks register on the first GMP_Lob_*/GMP_Net_* call, so make one now; a lobby
    -- id it returns (the game was started from an invite, +connect_lobby) is joined on the next idle tick.
    local ok,first=pcall(backend.PendingJoin,backend)
    if ok and first then self.steamConnection.queuedJoin=first end
    return self.state
end
function App:SteamConnection() return self.steamConnection end
-- D52: a join the host refused (a run in progress without a held slot, or Allow auto rejoin off; a full lobby, a
-- version mismatch...) ends the attempt on the multiplayer screen with the reason, instead of "Connecting..." forever.
App.JOIN_REFUSED_TEXT = { run_in_progress = 'A game is in progress.', approval_required = 'A game is in progress.',
    rejoin_required = 'A game is in progress.',
    session_full = 'The lobby is full.', version_mismatch = "Your Goobies MP version differs from the host's.",
    game_version_mismatch = "Your game version differs from the host's." }
-- D52: a run in progress the player holds no slot in: it may wait for the next game (gmp_lobby_connection Wait).
App.WAIT_OFFER = { run_in_progress = true, approval_required = true, rejoin_required = true }
App.WAIT_OFFER_TEXT = 'A game is in progress. Wait for the next game?'
-- t3 friend reports (Coder A): the refusal names both versions, so the players know who has to update.
App.VERSION_REFUSED_TEXT = 'The host has Goobies MP %s; you have %s. Both players need the same version.'
function App.VersionRefusedText(hostVersion, mine)
    return string.format(App.VERSION_REFUSED_TEXT, tostring(hostVersion or '?'), tostring(mine or Config.MOD_VERSION))
end
-- t3 friend reports (Coder A): a first join that never reaches the host ends here (no reconnect loop), and a host
-- that closed its lobby (Cancel) sends everyone back to the multiplayer screen with this.
App.UNREACHABLE_TEXT = 'Could not reach the host. Check the lobby and press Join again.'
App.HOST_CLOSED_TEXT = 'The host closed the lobby.'
function App:_joinRefused(why)
    local offerWait = App.WAIT_OFFER[why] == true
    local text = offerWait and App.WAIT_OFFER_TEXT or App.JOIN_REFUSED_TEXT[why] or ('The host refused the join (' .. tostring(why) .. ').')
    if why == 'version_mismatch' then
        local c = self.client
        local info = c and c.hostInfo
        text = App.VersionRefusedText(info and info.modVer, c and c.localInfo and c.localInfo.modVer)
    end
    self:_log('join refused by the host: %s', tostring(why))
    return self:_endClientAttempt(text, offerWait)
end
-- t3 friend reports (Coder A): end the client's session attempt and show `text` on the multiplayer screen.
function App:_endClientAttempt(text, offerWait)
    local connection = self.steamConnection
    if self.devSocketLobbyBackend and self.role == 'client' then
        if self.transport then pcall(self.transport.Close, self.transport) end
        self.host, self.client, self.transport, self.role, self.autoReconnect = nil, nil, nil, nil, false
        self.islandFlow = nil; self.state = 'dev_socket_lobby'
    elseif self.steamLobbyBackend and self.role == 'client' then
        local transport = self.transport; self.client, self.transport = nil, nil
        if transport then pcall(transport.Close, transport) end
        self:_clearSteamSession()
        pcall(self.steamLobbyBackend.LeaveNative, self.steamLobbyBackend)
    else return end
    if connection and type(connection.Fail) == 'function' then connection:Fail(text, offerWait) end
end
-- D52 (test 13): the player quit the run to the main menu while the host plays on. The session is closed without a
-- freeing LEAVE: the host holds the slot (D20, a drop), so a later Join brings the player back (Allow auto rejoin on).
-- Nothing is remembered and nothing reconnects: the multiplayer screen offers Join again.
function App:_quitRunToMenu()
    local c=self.client;if not c then return end
    self:_log('client quit the run to the menu: session closed (the host holds the slot); join again from Multiplayer')
    if c.peerId and c.transport then pcall(c.transport.Close,c.transport,c.peerId) end
    pcall(c._setState,c,'disconnected','quit_to_menu')
    if self.rejoinCover then self.rejoinCover:Cancel() end
    if self.devSocketLobbyBackend then
        if self.transport then pcall(self.transport.Close,self.transport) end
        self.host,self.client,self.transport,self.role,self.autoReconnect=nil,nil,nil,nil,false
        self.islandFlow=nil;self.state='dev_socket_lobby'
    elseif self.steamLobbyBackend then
        local transport=self.transport;self.client,self.transport=nil,nil
        if transport then pcall(transport.Close,transport) end
        self:_clearSteamSession();self.steamResume=nil
        pcall(self.steamLobbyBackend.LeaveNative,self.steamLobbyBackend)
    end
end
-- 1.0.1: a client leaves its Steam lobby. A voluntary LEAVE frees the slot (D20); the Steam lobby itself is left
-- (GMP_Lob_Leave) only after the host acknowledged it, since leaving the lobby ends the messaging with the host.
function App:_leaveSteamLobby()
    if self.role=='host' then return false,'host_cannot_leave' end
    if self.role~='client' or not self.client then return false,'not_in_a_lobby' end
    local client,transport,backend=self.client,self.transport,self.steamLobbyBackend
    client:Leave('left')
    self.client,self.transport=nil,nil
    self.leavingClient={client=client,transport=transport,after=function() if backend then backend:LeaveNative() end end}
    self:_clearSteamSession()
    self:_log('left the Steam lobby (voluntary LEAVE; the Steam lobby is left after the host acknowledges it)')
    return true
end
-- t3 friend reports (Coder A): the host's Cancel closes its Steam lobby. Everyone in it is told (Host:CloseLobby, KICK
-- host_closed) and the host is back at the multiplayer screen at once; the old host keeps ticking for up to
-- CLOSE_LOBBY_FLUSH_SECONDS so the reliable KICKs go out, then its authentication and transport end and the Steam
-- lobby is left (leaving it first would end the messaging before the others are told).
App.CLOSE_LOBBY_FLUSH_SECONDS = 2
function App:_closeSteamLobby()
    if self.role~='host' or not self.host then return false,'not_hosting' end
    local host,transport,backend=self.host,self.transport,self.steamLobbyBackend
    local ok,why=host:CloseLobby()
    if not ok then return false,why end
    self.host,self.transport=nil,nil
    self:_clearSteamSession()
    self.closingHost={host=host,transport=transport,untilAt=(self.clockNow or 0)+App.CLOSE_LOBBY_FLUSH_SECONDS,
        after=function() if backend and type(backend.LeaveNative)=='function' then backend:LeaveNative() end end}
    self:_log('host closed the lobby (Cancel); the others are told, then the Steam lobby is left')
    return true
end
function App:_tickClosingHost()
    local l=self.closingHost;if not l then return end
    local h=l.host
    pcall(h.Poll,h);pcall(h.Tick,h)
    local open=false
    for _,p in pairs(h.peers or {}) do if p.closeAt then open=true end end
    if not open or (self.clockNow or 0)>=l.untilAt then
        pcall(h.RetireAuthentication,h)
        if l.transport and l.transport.Close then pcall(l.transport.Close,l.transport) end
        if l.after then pcall(l.after) end
        self.closingHost=nil
    end
end
-- A client that left the lobby keeps resending its LEAVE until the host acknowledges it, then its transport is closed.
function App:_tickLeavingClient()
    local l=self.leavingClient;if not l then return end
    local c=l.client
    pcall(c.Poll,c);pcall(c.Tick,c)
    if not c.leaving then
        if l.transport and l.transport.Close then pcall(l.transport.Close,l.transport) end
        if l.after then pcall(l.after) end
        self.leavingClient=nil
    end
end
-- D52/D54 dev tooling: DEV_HOST_SLOTS fixes which windows host (sorted list, set); without it (nil) every window can
-- host (D54: no fixed player numbers) and the lobbies that exist are announced by beacons (App:_tickDevLobbyBeacon).
function App:_devHostSlots()
    local set=self.extras.devHostSlots;if not set then return nil,nil end
    local list={};for n in pairs(set) do list[#list+1]=n end
    table.sort(list);return list,set
end
-- Static host windows: the configured role must match; any window can host otherwise.
function App:_devRoleOk(slot)
    local _,isHost=self:_devHostSlots()
    if isHost then return self.role==(isHost[slot] and 'host' or 'client') end
    return self.role=='host' or self.role=='client'
end
-- D54: a hosting window announces its local test lobby to the other windows once a second (a 'B' frame on the dev
-- transport, ignored by the session transport); a window lists the announced lobbies seen in the last few seconds.
-- Test 15: 5 s of silence before a lobby leaves the list (a window that hitches keeps its place); a host that closes its
-- lobby announces it (state=closed), so it leaves the lists at once.
App.DEV_LOBBY_BEACON_SECONDS, App.DEV_LOBBY_EXPIRE_SECONDS, App.DEV_SLOTS = 1, 5, 4
function App:_devBeaconSend(info)
    for target=1,App.DEV_SLOTS do
        if target~=self.extras.devPlayerSlot then pcall(self.fs.append,self.netDir..'/out.txt',target..'|1|B|00000000|'..info..'\n') end
    end
end
function App:_tickDevLobbyBeacon()
    if not self.devSocketLobbyBackend or self.extras.devHostSlots or self.role~='host' or not self.host or not self.netDir then return end
    local now=self.clockNow or 0
    if self.devBeaconAt and now-self.devBeaconAt<App.DEV_LOBBY_BEACON_SECONDS then return end
    self.devBeaconAt=now
    local r=self.host.roster
    local info=string.format('members=%d;max=%d;state=%s',r:CurrentPlayers(),r.maxPlayers,r.phase=='run' and 'run' or 'lobby')
    self:_devBeaconSend(info)
end
-- Test 15: the Refresh button: drop announcements older than a beacon and a half, then read what arrived.
function App:_devLobbyRefresh()
    local now=self.clockNow or 0
    for slot,l in pairs(self.devLobbies or {}) do
        if now-l.at>App.DEV_LOBBY_BEACON_SECONDS*1.5 then self.devLobbies[slot]=nil end
    end
    return self:_devLobbyList()
end
function App:_devLobbyList()
    if not self.netDir then return {} end
    local path=self.netDir..'/in.txt'
    if not self.devBeaconOffset then self.devBeaconOffset=self.fs.size(path) or 0 end
    local data=self.fs.readFrom(path,self.devBeaconOffset) or ''
    local last=data:match('.*()\n')
    self.devLobbies=self.devLobbies or {}
    local now=self.clockNow or 0
    if last then
        self.devBeaconOffset=self.devBeaconOffset+last
        for line in data:sub(1,last):gmatch('([^\n]+)\n') do
            local from,m,x,st=line:match('^(%d)|%d+|B|[^|]*|members=(%d+);max=(%d+);state=(%a+)$')
            if from and st=='closed' then self.devLobbies[tonumber(from)]=nil
            elseif from then self.devLobbies[tonumber(from)]={members=tonumber(m),max=tonumber(x),state=st,at=now} end
        end
    end
    local out={}
    for slot,l in pairs(self.devLobbies) do
        if now-l.at<=App.DEV_LOBBY_EXPIRE_SECONDS and slot~=self.extras.devPlayerSlot then
            out[#out+1]={id=tostring(slot),joinable=l.members<l.max,
                label=string.format('Local test lobby %d (%d/%d)%s',slot,l.members,l.max,l.state=='run' and ' - in progress' or '')}
        end
    end
    table.sort(out,function(a,b) return a.id<b.id end)
    return out
end
function App:_bootDevSocketLobby()
    local slot=self.extras.devPlayerSlot
    local hostSlots=self:_devHostSlots()
    if not allows(self,'dev_roles') or self.cfg.AUTH_MODE~='dev' or not self.extras.devSteamSocketsTest
        or self.roleAuto or type(slot)~='number' or slot%1~=0 or slot<1 or slot>App.DEV_SLOTS
        or self.extras.devName~=('qa_player'..slot) or not self:_devRoleOk(slot) then
        self.state,self.reason='config_error','dev_socket_lobby_profile_invalid';return self.state
    end
    local loaded,backend=pcall(require,'gmp_dev_socket_lobby_backend')
    if not loaded or type(backend)~='table' or type(backend.new)~='function' then
        self.state,self.reason='config_error','dev_socket_lobby_backend_unavailable';return self.state
    end
    self.devSocketInitialRole=self.role;self.role=nil;self.autoReconnect=false;self.clockNow=0;self.state='dev_socket_lobby'
    self.devSocketLobbyBackend=backend.new{slot=slot,hostSlots=hostSlots,lobbies=function() return self:_devLobbyList() end,
        refresh=function() return self:_devLobbyRefresh() end,
        clock=function()return self.clockNow or 0 end,
        session=function()return self.role=='host' and self.host or self.client,self.role end,
        activate=function(kind,_,lobbyId)
            -- Fixed four slots (D12): the backend's capacity argument never changes the session config.
            self.role=kind=='create' and 'host'or'client';self.autoReconnect=self.role=='client'
            -- the host of the chosen local test lobby (the qa_four transport talks to that slot)
            self.devSocketHostSlot=kind=='create' and slot or tonumber(lobbyId) or 1
            local state=self:_startNetSession()
            if state~='hosting' and state~='client'then self:_leaveDevSocketLobby();return false,self.reason or 'local_session_refused'end
            return true
        end,leave=function()return self:_leaveDevSocketLobby()end}
    self.steamConnection=require('gmp_lobby_connection').new{maxPlayers=self.cfg.MAX_PLAYERS,
        session=function()return self.role=='host' and self.host or self.client,self.role end}
    self.steamConnection:Bind(self.devSocketLobbyBackend);return self.state
end
function App:_leaveDevSocketLobby()
    local session=self.role=='host' and self.host or self.client
    -- Test 12: a client can always leave, also mid-handoff (a run in progress); the host keeps the lobby-only rule.
    if session and self.role=='host' and session.roster.phase~='lobby' then return false,'local_leave_requires_lobby'end
    -- Test 15: a closed dynamic lobby leaves the other windows' lists at once
    if session and self.role=='host' and not self.extras.devHostSlots and self.netDir then self:_devBeaconSend('members=0;max=0;state=closed') end
    if self.client then
        -- A voluntary LEAVE frees the slot (D20); the client keeps resending it until the host acknowledges it
        -- (Client.LEAVE_LINGER), so it is ticked on (App:_tickLeavingClient) before its transport is closed.
        self.client:Leave('local_lobby_leave')
        if self.client.leaving then self.leavingClient={client=self.client,transport=self.transport};self.transport=nil end
    end
    if self.transport then self.transport:Close()end
    self.host=nil;self.client=nil;self.transport=nil;self.role=nil;self.autoReconnect=false
    self.islandFlow=nil;self.state='dev_socket_lobby';return true
end
function App:_gracefulExistingEdges(commit)
    if type(commit)~='table' or type(commit.session)~='string' or type(commit.term)~='number'
        or commit.term%1~=0 or commit.term<2 then return nil end
    local session=self.role=='host' and self.host or self.client
    local transport=self.transport;local edges={};local role=self.role
    local clientAuthentication=role=='client' and session and session.auth
    local clientTicket=clientAuthentication and clientAuthentication.handle
    if not self:_trustedGracefulStage(commit)or not transport or not transport.bySteam then return nil end
    for steam,p in pairs(transport.bySteam)do
        local key='steam:'..steam;local peer=self.role=='host' and session.peers[p.key] or nil
        local authentication=peer and peer.auth
        local trusted=self.role=='host' and peer and peer.key==key and peer.authKey==key
            or self.role=='client' and session:State()=='joined' and session.authenticatedHostKey==key
        if trusted then
            edges[key]={nonce=p.nonce,live=function()
                if self.role~=role or self.transport~=transport or transport.bySteam[steam]~=p
                    or session.sid~=commit.session or (session.authorityTerm or 1)~=commit.term-1 then return false end
                if self.role=='host'then local player=session.roster:Get(key)
                    return session.peers[p.key]==peer and peer.key==key and peer.authKey==key
                        and peer.auth==authentication and authentication.state=='authenticated'
                        and player and player.conn=='connected' end
                return self.client==session and session:State()=='joined' and session.authenticatedHostKey==key
                    and session.auth==clientAuthentication and clientAuthentication
                    and clientAuthentication.handle==clientTicket and clientAuthentication.phase=='submitted'
            end}
        end
    end
    return edges
end
function App:_trustedGracefulStage(commit)
    if type(commit)~='table' or commit.kind~='graceful' or commit.forced~=false then return false end
    local session=self.role=='host' and self.host or self.client
    if not session or session.sid~=commit.session or (session.authorityTerm or 1)~=commit.term-1 then return false end
    if self.role=='host' then return self.identity.key==commit.formerHost and session.handoverCommit==commit
        and session:HandoverStageReady()==true end
    return session:State()=='joined' and session.authenticatedHostKey==commit.formerHost
        and session.handoverStage and session.handoverStage.ready==true and session.handoverStage.commit==commit
end
function App:_steamAuthority()
    if self.steamAuthority then return self.steamAuthority end
    local authority,why=require('gmp_steam_authority').new{G=self.bridge.G,identity=self.identity,clock=function()return self.clockNow end,
        verifyLoss=function(commit)return self.lossRecovery and self.lossRecovery:TrustedCommit(commit)==true end,
        verifyGracefulSelection=function(commit)return self:_trustedGracefulStage(commit)end,
        verifyLossSelection=function(commit)return self.lossRecovery and self.lossRecovery:SelectedCommit(commit)==true end,
        verifyCommit=function(commit)
            local runtime=self.handoverRuntime;local driver=runtime and runtime.driver
            local expected=driver and driver.pendingCommit
            return runtime and runtime.control.localApplied==true and expected
                and expected.session==commit.session and expected.term==commit.term and expected.hostKey==commit.hostKey
                and expected.formerHost==commit.formerHost and expected.sequence==commit.sequence
        end}
    if not authority then return nil,why end;self.steamAuthority=authority;return authority
end
-- Log a GMPPROTECT line once per distinct text (the predicate is evaluated every lobby tick).
function App:_protectLog(line)
    self.protectLogged=self.protectLogged or {}
    if self.protectLogged[line] or not self.env then return end
    self.protectLogged[line]=true;self:_log('GMPPROTECT %s',line)
end
-- G3' (D36 amends D13): dev runs may rely on the legacy always-block steam_api64 proxy that every dev copy carries
-- (sha 342c54a1, logs BLOCK AchievementMutation; QA verifies it in every staged slot before launch). Accepted only in
-- MODE=dev; refused in production or release config and together with the production switch. The verified guard
-- (REL-GUARD) is still required for release builds. Returns accepted, reason.
function App:DevLegacyProxy()
    local x,cfg=self.extras,self.cfg
    if type(x)~='table' or x.devLegacyAchievementProxy~=true then return false,'dev_legacy_proxy_not_configured' end
    local why
    if not allows(self,'legacy_proxy') then why='dev_legacy_proxy_requires_dev_mode'
    elseif x.productionSliceTest then why='dev_legacy_proxy_with_production_slice_test' end
    if why then self:_protectLog('dev_legacy_proxy refused: '..why);return false,why end
    self:_protectLog('dev_legacy_proxy accepted');return true
end
-- Protection is a scoped adapter receipt, never inferred from a menu setting or PE export.
-- Achievements are always blocked during multiplayer (D16): a receipt is valid only with an active, verified lease,
-- or (G3', MODE=dev only) with the accepted legacy proxy. This is the one protection predicate: the lobby runtime
-- (host START, client entry), App:ProtectionGate (solo DEV_SOCKET_LOBBY_START, STANDIN_SELFTEST), the native
-- lifecycle and loss recovery all read it.
-- D57 (Coder B, 2026-10-14): Mod Menu's own achievement guard (native ModMenuGuard: every stats-changing SteamCorePro
-- function denied for the whole process; MM_AchievementGuard in this Lua state) is protection too, in every mode. A
-- lobby starts with guard-ready OR the D16 lease / D36 legacy proxy (which keeps priority). Without either, friend
-- mode warns and allows (the user's stance, D57); dev and production stay refused. The guard is ready only when it
-- says so without contradiction (ready, reason 'ready', proven, not late).
-- Coder C (2026-10-14): the same words as Mod Menu's main-menu notice (Mod_Menu/Scripts/mm_guard.lua Guard.NOTICE).
App.ACHIEVEMENT_WARNING='Achievement protection not confirmed - achievements may unlock'
function App:_modMenuGuardReady()
    local G=self.bridge and self.bridge.G
    local okFn,fn=pcall(function() return G.MM_AchievementGuard end)   -- the package env reaches Mod Menu's globals by __index
    if not okFn then return false end
    if type(fn)~='function' then return false end
    local ok,ready,reason,_,_,late,_,proven=pcall(fn)
    return ok and ready==true and reason=='ready' and late==false and proven==true
end
function App:AchievementWarning() return self.achievementWarning end
function App:LobbyAchievementBinding(policy)
    local session=self.role=='host' and self.host or self.client
    local valid=session and require('gmp_messages').ValidatePolicy(policy)
    if not valid or (type(self.extras)=='table' and self.extras.devLegacyAchievementProxy) then return self:_lobbyAchievementBinding(policy) end
    local function receipt(source)
        return {available=true,session=session,term=session.authorityTerm or 1,active=true,verified=true,source=source,
            policy={revision=policy.revision,runGeneration=policy.runGeneration,locked=policy.locked}}
    end
    if self:_modMenuGuardReady() then self:_protectLog('mod_menu_guard accepted');return receipt('mod_menu_guard') end
    local binding=self:_lobbyAchievementBinding(policy)
    if binding.available or not allows(self,'unprotected_warning') then return binding end
    self.achievementWarning=App.ACHIEVEMENT_WARNING
    self:_protectLog('unprotected (friend mode): achievements may unlock while modded')
    return receipt('friend_unprotected')
end
function App:_lobbyAchievementBinding(policy)
    local session=self.role=='host' and self.host or self.client
    local term=session and (session.authorityTerm or 1)
    if not session or not require('gmp_messages').ValidatePolicy(policy) then return {available=false,reason='invalid_session_policy'} end
    if type(self.extras)=='table' and self.extras.devLegacyAchievementProxy then
        -- A configured key never falls back to the native lease: a misplaced dev key fails closed.
        local accepted,why=self:DevLegacyProxy()
        if not accepted then return {available=false,reason=why} end
        return {available=true,session=session,term=term,active=true,verified=true,source='dev_legacy_proxy',
            policy={revision=policy.revision,runGeneration=policy.runGeneration,locked=policy.locked}}
    end
    local adapter=self.achievementProtection
    if not adapter and self.bridge and self.bridge.G then
        self.achievementLeaseToken=self.achievementLeaseToken or ('GMPLease:'..string.format('%08x',math.random(0,0x7fffffff))..':session')
        adapter=require('gmp_achievement_protection').new(self.bridge.G,self.achievementLeaseToken)
        self.achievementProtection=adapter
    end
    if adapter and type(adapter.Acquire)=='function' and adapter.session==session then
        local accepted,why=adapter:Acquire(session,term,policy)
        if accepted~=true then return {available=false,reason=why or 'achievement_protection_unavailable'} end
    elseif adapter and type(adapter.Acquire)=='function' and not adapter.session then
        local accepted,why=adapter:Acquire(session,term,policy)
        if accepted~=true then return {available=false,reason=why or 'achievement_protection_unavailable'} end
    end
    if not adapter or type(adapter.Readback)~='function' then
        return {available=false,reason='achievement_protection_unavailable'}
    end
    local ok,receipt=pcall(adapter.Readback,adapter,session,term,policy)
    if not ok or type(receipt)~='table' then return {available=false,reason='achievement_protection_unavailable'} end
    local p=receipt.policy
    if receipt.session~=session or receipt.term~=term or receipt.verified~=true or type(p)~='table'
        or p.revision~=policy.revision or p.locked~=policy.locked or p.runGeneration~=policy.runGeneration
        or receipt.active~=true then
        return {available=false,reason='achievement_protection_unverified'}
    end
    return {available=true,session=session,term=term,active=true,verified=true,
        policy={revision=p.revision,runGeneration=p.runGeneration,locked=p.locked}}
end
-- The protection predicate applied to the current session and its own policy, for world-entry paths outside the
-- lobby runtime. purpose names the caller in the refusal log. Returns ok, reason.
function App:ProtectionGate(purpose)
    local session=self.role=='host' and self.host or self.role=='client' and self.client or nil
    local policy
    if session and type(session.LobbyAchievementPolicy)=='function' then
        local ok,value=pcall(session.LobbyAchievementPolicy,session);if ok then policy=value end
    end
    local ok,why=require('gmp_lobby_achievement_binding').Check(policy,self:LobbyAchievementBinding(policy),session)
    if not ok then self:_protectLog('refused purpose='..tostring(purpose)..' reason='..tostring(why)) end
    return ok,why
end
-- Solo dev START (DEV_SOCKET_LOBBY_START, wired by W3/W4) and the S7a synthetic self-peer (STANDIN_SELFTEST, wired
-- by W3) call these before acting; both features are MODE=dev only.
function App:DevSocketLobbyStartGate()
    if not allows(self,'dev_roles') or not self.extras.devSocketLobbyStart then return false,'dev_socket_lobby_start_disabled' end
    return self:ProtectionGate('dev_socket_lobby_start')
end
function App:StandinSelftestGate()
    if not allows(self,'dev_scaffolding') or not self.extras.standinSelftest then return false,'standin_selftest_disabled' end
    return self:ProtectionGate('standin_selftest')
end
-- Read-only production capability probes. Each reads live state only; none
-- acquires a lease, installs a controller or writes native state.
local ProductionCapabilities={}
-- W3: enemy authority is what the existing run sync reports (runSync:Capabilities()); it must claim production
-- scope. The probe never creates a run sync. The C0 stub reports none.
function ProductionCapabilities.enemy_authority(app)
    local sync=app.runSync
    if type(sync)~='table' or type(sync.Capabilities)~='function' then return false end
    local ok,caps=pcall(sync.Capabilities,sync)
    return ok and type(caps)=='table' and caps.enemy_authority==true and caps.enemy_authority_scope=='production'
end
-- Always needed: achievements are always blocked during multiplayer (D16).
-- Requires every native lease export and a ready report.
function ProductionCapabilities.achievement_lease(app,session)
    local G=app.bridge and app.bridge.G
    if not require('gmp_achievement_protection').HasExports(G) then return false end
    local ok,ready=pcall(G.MM_PortableProtectionReady)
    return ok and ready==true
end
-- Same island-flow state the dev binding requires; _tickIslands never creates
-- the flow outside MODE=dev, so it is absent in production today.
function ProductionCapabilities.island_flow(app)
    return type(app.extras)=='table' and app.extras.islandHandoff==true and type(app.islandFlow)=='table'
        and not app.islandFlow.failed
end
-- Committed native session mapping for this session/term, re-read from native
-- metadata (same contract as gmp_native_lifecycle.lua Check).
function ProductionCapabilities.native_world_binding(app,session)
    local authority=app.steamAuthority;local committed=authority and authority.committed
    if not session or not committed or not authority.context or type(authority.Read)~='function' then return false end
    if committed.session~=session.sid or committed.term~=(session.authorityTerm or 1) then return false end
    local ok,current=pcall(authority.Read,authority,authority.context)
    return ok and type(current)=='table' and current.session==committed.session and current.term==committed.term
        and current.hostKey==committed.hostKey
end
local PRODUCTION_CAPABILITIES={'enemy_authority','achievement_lease','island_flow','native_world_binding'}
function App:_productionWorldBinding(session)
    local missing={}
    for _,name in ipairs(PRODUCTION_CAPABILITIES) do
        if ProductionCapabilities[name](self,session)~=true then missing[#missing+1]=name end
    end
    if #missing>0 then return {available=false,reason='production_capabilities_missing',missing=missing} end
    -- No production world-entry contract exists yet, so even a complete set of
    -- capabilities never yields available=true outside MODE=dev.
    return {available=false,reason='production_world_entry_unimplemented',missing=missing}
end
function App:LobbyWorldBinding()
    local session=self.role=='host' and self.host or self.client
    if not allows(self,'playtest_world') then return self:_productionWorldBinding(session) end
    local flow=self.islandFlow
    if not session or not self.extras.islandHandoff or not flow or flow.failed then
        return {available=false,reason='native_world_binding_unavailable'}
    end
    return {available=true,session=session,role=self.role,term=session.authorityTerm or 1,flow=flow}
end
function App:_clearSteamSession()
    if self.client then
        local resume=self.client.resume
        if resume and resume.key==self.identity.key then self.steamResume={lobby=self.steamLobbyId,owner=self.steamAddress,
            key=resume.key,token=resume.token,slot=resume.slot,color=resume.color} end
        self.client:_cancelTicket();self.client:Leave('cancelled')
    end
    if self.host then self.host:RetireAuthentication() end
    if self.transport then self.transport:Close() end
    if self.gracefulControl then pcall(self.gracefulControl.ClearHandoverControl,self.gracefulControl);self.gracefulControl=nil end
    if self.steamAuthority then self.steamAuthority:Invalidate() end
    self.steamAuthority=nil;self.steamJoinMapping=nil;self.steamSessionCfg=nil
    self.client=nil;self.host=nil;self.transport=nil;self.role=nil;self.steamAddress=nil;self.steamLobbyId=nil;self.state='steam_lobby';self.autoReconnect=false    -- Coder B (friend test 1.0.0-test.3): the island flow is bound to this session (its session() closure); drop it
    -- with the session, as the dev socket lobby does, so the next host or rejoin makes a fresh one (EnableIslands)
    self.islandFlow=nil;self.islandHadWorld=false
end
-- Test 14: one process can play with several hosts in a row (left behind by host A, then host B). App state that
-- belongs to one session (the rejoin cover, the island-reload marker, the live HUD, run-exit generations, End Run) is
-- reset when a new session starts, so nothing keyed by epoch/island or run generation leaks into the next host.
function App:_resetSessionScoped()
    if self.rejoinCover then self.rejoinCover:Cancel() end
    self.lastPlayedIsland, self.lastClientState, self.clientInRun = nil, nil, nil
    self.liveHudClient, self.liveHudHost, self.liveHudLogAt = nil, nil, nil
    self.islandSignature = nil
    self.runExitGeneration, self.runExitDeferred = nil, nil
    self.endRunHandoverAt, self.endRunExit = nil, nil
    self.clientReached = nil   -- t3 friend reports (Coder A): per session
    -- objects bound to one session's island world or players: rebuilt for the next session
    self.pauseDriver, self.knownConn = nil, nil
end
function App:_activateSteamSession(kind,result)
    if not allows(self,'steam_session') or self.cfg.AUTH_MODE~='steam' or self.state~='steam_lobby' or self.role
        or not self.bridge.authProvider then return false,'steam_session_activation_refused' end
    local allowed,denial=require('gmp_auth').AllowNonLoopback(self.cfg,self.bridge.authProvider)
    if not allowed then return false,denial end
    local authority,authorityError=self:_steamAuthority();if not authority then return false,authorityError end
    -- D55: a lobby is created with a size of 2..MAX_PLAYERS_LIMIT (the default from GoobiesMP.ini); the host changes it
    -- per lobby (Host:SetLobbyMaxPlayers).
    local sessionCfg=self.cfg
    local mp=result.maxPlayers
    if kind=='create' and (math.type(mp)~='integer' or mp<2 or mp>Config.MAX_PLAYERS_LIMIT) then return false,'invalid_max_players' end
    self:_resetSessionScoped()
    local transport,why=require('gmp_steam_transport').new{G=self.bridge.G,clock=function() return self.clockNow end,rng=self.rng,
        log=function(line) self:_log('%s',line) end,   -- t3 friend reports (Coder A): a refused connect frame is logged
        verifySwitch=function(role,term,commit)
            local pending=authority.pending
            return pending and commit and pending.session==commit.session and pending.term==term and pending.hostKey==commit.hostKey
                and (self.identity.key==pending.hostKey)==(role=='host')
        end}
    if not transport then return false,why end
    local name=self.bridge:LocalName() or 'Player'
    local opts={cfg=sessionCfg,transport=transport,clock=function() return self.clockNow end,rng=self.rng,
        identity=self.identity,name=name,authProvider=self.bridge.authProvider,log=function(line) self:_log('%s',line) end}
    if kind=='create' then
        if result.owner~=self.identity.value then return false,'created_lobby_owner_mismatch' end
        local host,reason=Host.new(opts);if not host then return false,reason end
        local started,error=host:Start();if not started then return false,error end
        host:SetNameResolver(App.SteamNameResolver(self.bridge.G))
        local published,publishError=authority:Initialize(host,result)
        if published~=true then host:RetireAuthentication();transport:Close();return false,publishError end
        self.host=host;self.role='host';self.state='hosting'
        -- D55: the typed lobby size reaches the Steam lobby (GMP_Lob_Limit)
        host.lobbyLimit=function(n)
            local backend=self.steamLobbyBackend
            if not backend or type(backend.SetMemberLimit)~='function' then return nil,'unavailable' end
            return backend:SetMemberLimit(n)
        end
    elseif kind=='join' then
        local mapping=result.mapping
        if not mapping or mapping.phase~='C' or not Identity.IsValidSteamId64(mapping.address) then return false,'committed_host_mapping_required' end
        if mapping.hostKey==self.identity.key then return false,'cannot_join_own_session' end
        -- D52: the player chose "Wait for the next game"
        opts.wait=self.steamConnection~=nil and self.steamConnection.pending~=nil and self.steamConnection.pending.wait==true
        local client,reason=Client.new(opts);if not client then return false,reason end
        local saved=self.steamResume
        if saved and saved.lobby==result.lobbyId and saved.owner==mapping.address and saved.key==self.identity.key then
            client.resume={key=saved.key,token=saved.token,slot=saved.slot,color=saved.color}
        end
        local connected,error=client:Connect(mapping.address);if not connected then return false,error end
        client.expectedHandoverSession=mapping.session;client.expectedHandoverHost=mapping.hostKey;client.expectedAuthorityTerm=mapping.term
        self.steamJoinMapping=mapping
        self.client=client;self.role='client';self.state='client';self.steamAddress=mapping.address;self.autoReconnect=true
    else return false,'invalid_lobby_action' end
    self.transport=transport;self.steamLobbyId=result.lobbyId;self.steamSessionCfg=sessionCfg
    self.authProvider=self.bridge.authProvider;self.clockFn=function()return self.clockNow end
    -- Coder B (friend test 1.0.0-test.3): a Steam session starts presence like the relay and in-memory sessions do.
    -- Without it no PLAYER_STATE / WORLD_STATE was ever sent (lane 0), and the host enemy capture, which reads the
    -- presence world, never started (no ENEMY_LIFE / ENEMY_MOTION on lanes 2/3).
    self:_initPresence()
    return true
end
-- Cross-PC 1.3: Steam rich presence for friends (status, "Join game" through connect, the player group), through
-- the native GMP_Pres_Set(key, value) when it exists; only changed keys, at most once a second, our keys only.
App.RICH_PRESENCE_SECONDS = 1
function App:_richPresenceState()
    if not self.steamLobbyId then return nil end
    local phase, players
    if self.role == 'host' and self.host and self.host.roster then
        phase, players = self.host.roster.phase, self.host.roster:Count()
    elseif self.role == 'client' and self.client and type(self.client.Roster) == 'function' then
        local mirror = self.client:Roster(); if not mirror then return nil end
        phase, players = mirror.phase, #(mirror.players or {})
    else return nil end
    local slots = self.role == 'host' and self.host and self.host.roster.maxPlayers
        or (self.client and type(self.client.Roster) == 'function' and (self.client:Roster() or {}).maxPlayers)
        or (self.cfg and self.cfg.MAX_PLAYERS) or Config.Defaults().MAX_PLAYERS
    return { phase = phase == 'run' and 'run' or 'lobby', lobbyId = self.steamLobbyId, players = players, slots = slots }
end
function App:_tickRichPresence()
    local G = self.bridge and self.bridge.G
    if type(self.extras) ~= 'table' or not self.extras.steamLobby or type(G) ~= 'table' or type(G.GMP_Pres_Set) ~= 'function' then return end
    local now = self.clockNow or 0
    if self.richPresenceAt and now - self.richPresenceAt < App.RICH_PRESENCE_SECONDS then return end
    self.richPresenceAt = now
    self.richPresence = self.richPresence or {}
    for _, kv in ipairs(require('gmp_lobby_invite').RichPresence(self:_richPresenceState())) do
        local key, value = kv[1], kv[2]
        if (self.richPresence[key] or '') ~= value then
            local ok, done = pcall(G.GMP_Pres_Set, key, value)
            if ok and done ~= false then self.richPresence[key] = value
            elseif not self.richPresenceFailed then
                self.richPresenceFailed = true; self:_log('rich presence: GMP_Pres_Set failed (%s)', tostring(done))
            end
        end
    end
end
App.STEAM_JOIN_POLL_SECONDS = 0.25
-- D53: a hosting app publishes its lobby data for the Host dropdown (GMP_Lob_Data): gmp_state (lobby|run), gmp_mods
-- (the D42 manifest hash, '' without a local registry) and gmp_ver; at most once a second, sent on change.
function App:_tickSteamLobbyData()
    local backend = self.steamLobbyBackend
    if self.role ~= 'host' or not self.host or not self.steamLobbyId or type(backend) ~= 'table' or type(backend.PublishData) ~= 'function' then return end
    local now = self.clockNow or 0
    if self.lobbyDataAt and now - self.lobbyDataAt < 1 then return end
    self.lobbyDataAt = now
    pcall(backend.PublishData, backend, { gmp_state = self.host.roster and self.host.roster.phase == 'run' and 'run' or 'lobby',
        gmp_mods = self.modManifest and require('gmp_lobby_browser').ModHash(self.modManifest) or '', gmp_ver = Config.MOD_VERSION })
end
function App:_tickSteamLobby(dt)
    if not self.extras.steamLobby then return end
    if self.state=='steam_lobby' then
        self.clockNow=(self.clockNow or 0)+(dt or 0)
        if not self.steamLobbyBackend and self.clockNow>=(self.steamLobbyRetry or 0) then
            self.steamLobbyRetry=self.clockNow+1;self:_bootSteamLobby()
        end
    end
    if self.steamLobbyBackend then
        self.steamLobbyBackend:Snapshot()
        self:_tickSteamLobbyData()
    end
    -- Idle at the main menu (no session): poll for a Steam join request (Shift+Tab -> Join game), 4 times a second.
    if self.state=='steam_lobby' and not self.role and self.steamConnection and self.clockNow>=(self.steamJoinPollAt or 0) then
        self.steamJoinPollAt=self.clockNow+App.STEAM_JOIN_POLL_SECONDS
        pcall(self.steamConnection.Tick,self.steamConnection)
    end
    if self.extras.steamLobbyCheck then
        self.steamLobbyCheck=self.steamLobbyCheck or require('gmp_steam_lobby_check').new(self)
        self.steamLobbyCheck:Tick()
    end
end

-- Resolve the local identity and start the host-only session. Separate from Boot so that, in production, a not-yet-initialised Steam
-- (Steam may not be initialised yet when UE4SS starts the mod) can be retried from Tick instead of failing for the whole run.
function App:_startSession()
    local env, cfg = self.env, self.cfg
    local id, why = self.bridge:LocalIdentity(cfg.MODE, self.extras.devName)
    if not id then
        self.state, self.reason = "no_identity", why
        if self.noIdentityLogged then return self.state end        -- retries stay quiet; the first attempt already said why
        self.noIdentityLogged = true
        self:_log("session NOT started: no local identity (%s). MODE=%s. S1: in production the SteamID comes only from the native provider (GMP_SteamID64); use MODE=dev in gmp_config.txt for development.", tostring(why), cfg.MODE)
        return self.state
    end
    -- Display name only (never identity). No verified name source exists, so a real SteamID must NOT double as the name (it would reach logs and peers): use a short neutral label.
    local name = self.bridge:LocalName() or (id.isDev and id.value or ("Player" .. id.value:sub(-4)))
    self.identity = id
    self.hub = Hub.new({ seed = 1 })
    self.clockNow = 0
    -- Authentication provider (PHASE2 12.18): AUTH_MODE=dev -> the TEST-ONLY dev provider (MODE=dev only); AUTH_MODE=steam -> the native Steam
    -- ticket provider, which does not exist yet (bridge.authProvider is nil), so a production host refuses every remote peer (fail closed).
    local authProvider
    if cfg.AUTH_MODE == "dev" then authProvider = DevAuth.new({ cfg = cfg, localKey = id.key })
    elseif cfg.AUTH_MODE == "steam" then authProvider = self.bridge.authProvider end
    if self.extras.authCheck then
        -- The Stage 1 diagnostic is the ONLY consumer of the Steam verdicts: a session polling the same provider would steal them. This host-only
        -- session has no remote peers anyway, so it runs without a provider (it would refuse remote peers, fail closed).
        authProvider = nil
        self:_log("AUTH_CHECK: the in-memory host session runs without an auth provider so the diagnostic owns the Steam verdicts")
    end
    local host, herr = Host.new({ cfg = cfg, transport = self.hub:NewEndpoint("host"), clock = function() return self.clockNow end,
        rng = math.random, identity = id, name = name, log = function(m) env:Log("host: %s", m) end, authProvider = authProvider })
    if not host then self.state, self.reason = "no_identity", herr; self:_log("host refused: %s", tostring(herr)); return self.state end
    local started, serr = host:Start()
    if not started then self.state, self.reason = "config_error", serr; self:_log("host start failed: %s", tostring(serr)); return self.state end
    self.host = host
    self.state = "hosting"
    local me = host:GetPlayer(id.key)
    self:_log("hosting (host-only, in-memory): identity=%s%s name=%s slot=%d color=%s current_players=%d max_players=%d phase=%s",
        Identity.Mask(id.key), id.isDev and " [DEV IDENTITY]" or "", tostring(name), me.slot, me.color, host:CurrentPlayers(), cfg.MAX_PLAYERS, host.roster.phase)

    if self.extras.selftest then
        local res = SelfTest.run(function(...) env:Log(...) end)
        self.selftest = res
        self:_log("selftest result: %s (%d checks, %d failed)", res.ok and "PASS" or "FAIL", res.total, res.failed)
    end
    self:_runLobbyChecks()
    self:_initPresence()
    return self.state
end

-- M3.1 presence. Entirely inert unless PRESENCE=1 in gmp_config.txt AND its own settings validate. The game-facing module (gmp_world) is only
-- required here, after both checks, so with PRESENCE=0 nothing about presence is even loaded. opts.presenceWorld lets tests inject a fake world.
function App:_initPresence()
    local pc = type(self.extras) == 'table' and self.extras.presence or nil   -- Coder B: also from _activateSteamSession
    if self.presenceDriver or not pc or not pc.enabled then return end
    for _, e in ipairs(self.extras.presenceErrors or {}) do self:_log("presence config error: %s", e) end
    local ok, errs = Presence.Validate(pc)
    if not ok or #(self.extras.presenceErrors or {}) > 0 then
        for _, e in ipairs(errs) do self:_log("presence config invalid: %s", e) end
        self:_log("presence NOT started (invalid presence config)")
        return
    end
    local world = self.presenceWorld
    if not world and (pc.read or pc.markers) then
        local G = self.bridge and self.bridge.G
        if type(G) ~= "table" then self:_log("presence NOT started: no UE4SS globals available"); return end
        world = require("gmp_world").new(G, { clock = function() return self.clockNow end, log = function(line) self:_log("%s", line) end })
    end
    self.presenceDriver = Presence.Driver.new({ cfg = pc, world = world, getHost = function() return self.host end, getClient = function() return self.client end,
        log = function(...) self:_log(...) end })
    self:_log("presence ON: hz=%s read=%s markers=%s stale=%ss expire=%ss maxPacket=%d%s. %s",
        tostring(pc.hz), tostring(pc.read), tostring(pc.markers), tostring(pc.stale), tostring(pc.expire), pc.maxPacket, pc.selfEcho and " SELF_ECHO(dev)" or "",
        pc.worldSpace and "WORLD_SPACE(dev): remote coordinates; matching seeds and run stage required." or "Marker positions are APPROXIMATE (relative motion only) until a shared world exists.")
end

-- Lobby milestone runtime checks (one game instance). Results are logged and summarised in net\lobby_result.txt / lobby_done.txt (PASS|FAIL).
function App:_runLobbyChecks()
    if self.lobbyChecksDone or not (self.extras.lobbySelftest or self.extras.lobbyCheck) then return end
    self.lobbyChecksDone = true
    local env = self.env
    local log = function(...) env:Log(...) end
    local parts, pass = {}, true
    if self.extras.lobbySelftest then
        local r = LobbySelfTest.run(log)
        self.lobbySelftestResult = r
        pass = pass and r.ok
        parts[#parts + 1] = string.format("selftest=%s total=%d failed=%d", r.ok and "PASS" or "FAIL", r.total, r.failed)
        self:_log("LOBBY SELFTEST RESULT %s (%d checks, %d failed)", r.ok and "PASS" or "FAIL", r.total, r.failed)
    end
    if self.extras.lobbyCheck and self.host then
        local r = LobbySelfTest.runHostOnly(self, log)
        self.lobbyCheckResult = r
        pass = pass and r.ok
        parts[#parts + 1] = string.format("check=%s total=%d failed=%d", r.ok and "PASS" or "FAIL", r.total, r.failed)
        self:_log("LOBBY CHECK RESULT %s (%d checks, %d failed)", r.ok and "PASS" or "FAIL", r.total, r.failed)
    elseif self.extras.lobbyCheck then
        pass = false
        parts[#parts + 1] = "check=NOT_RUN(no host session)"
    end
    self:_log("LOBBY RESULT %s version=%s protocol=%s enabled_setting=%s", pass and "PASS" or "FAIL", Config.MOD_VERSION, tostring(Config.PROTOCOL_VERSION),
        self.modSettings and self.modSettings.setting and tostring(self.modSettings.setting.enabled) or "n/a")
    if self.netDir then
        self.fs.write(self.netDir .. "/lobby_result.txt", table.concat(parts, "\n") .. "\n")
        self.fs.write(self.netDir .. "/lobby_done.txt", pass and "PASS" or "FAIL")
    end
end

-- Advance the session by dt seconds of real time. Safe to call in any state.
function App:_testPhysicalPause()
    local ok,value=pcall(function()
        local world,library
        local nativeWorld=self.nativeStateWorld or (self.presenceDriver and self.presenceDriver.world)
        if nativeWorld then
            world=nativeWorld:_world();library=nativeWorld:_statics()
        elseif self.islandFlow and self.islandFlow.world then
            local pawn;world,pawn,library=self.islandFlow.world:LocalWorldPawn()
            if not pawn then return nil end
        end
        if not world or not library then return nil end
        return library:GetGlobalTimeDilation(world)
    end)
    if not ok or type(value)~='number' or value~=value or value<=0 or value>1.01 then return nil,'physical_pause_unavailable' end
    return value<=.001
end
function App:RequestIslandTest()
    if not allows(self,'gameplay') or not self.islandFlow or self.islandFlow.failed then return false,'test_disabled' end
    if self.handoverRuntimeHold or self.nativeRestoreHold then return false,'restoration_hold' end
    local session=self.role=='host' and self.host or self.client
    if not session or not session.sharedPause then return false,'shared_pause_unavailable' end
    if session.sharedPause.paused then return false,'unpause_before_F8' end
    local physical,why=self:_testPhysicalPause()
    if physical~=false then return false,why or 'unpause_before_F8' end
    local _,pawn=self.islandFlow.world:LocalWorldPawn()
    return pawn~=nil and self.islandFlow:Portal()==true
end
function App:RequestSharedPause(paused)
    if not allows(self,'gameplay') or not self.extras.sharedPause or not self.islandFlow
        or self.islandFlow.failed or type(paused)~='boolean' then return false,'pause_unavailable' end
    local _,pawn=self.islandFlow.world:LocalWorldPawn()
    if not pawn then return false,'not_playing' end
    local session=self.role=='host' and self.host or self.client
    if not session then return false,'no_session' end
    session:EnablePause()
    if self.role=='host' then return session:RequestPause(session.identity.key,paused) end
    if session.sharedPause.hostOnly then return false,'host_only' end
    return session:RequestPause(paused)
end
function App:SetPauseHostOnly(value)
    if not allows(self,'gameplay') or not self.extras.sharedPause or self.role~='host' or not self.host then
        return false,'policy_unavailable'
    end
    return self.host:SetPauseHostOnly(value)
end
function App:_tickSharedPause()
    if self.handoverRuntimeHold then return end
    if self.nativeRestoreHold then return end
    if not allows(self,'gameplay') or not self.extras.sharedPause or not self.islandFlow then return end
    if self.role~='host' and self.role~='client' then return end
    -- Test 14: a session switch in one process (leave, then host or join again) makes a new island flow and world;
    -- the old world's per-tick cache is frozen (no pawn), so a driver bound to it never applies the pause. Rebind.
    if self.pauseDriver and self.pauseDriver.options.world~=self.islandFlow.world then
        if type(self.pauseDriver.Dispose)=='function' then pcall(self.pauseDriver.Dispose,self.pauseDriver) end
        self.pauseDriver=nil;self:_log('Shared pause driver rebound to the new island world')
    end
    if not self.pauseDriver then
        self.pauseDriver=require('gmp_pause_driver').new({world=self.islandFlow.world,
            session=function() return self.role=='host' and self.host or self.client end,
            captureContext=function()
                local session=self.role=='host' and self.host or self.client
                local island=session and session.islands
                if not island or island.phase~='playing' or self.islandFlow.failed then return nil end
                return table.concat({self.role,tostring(session.sid),tostring(session.authorityTerm or 1),
                    tostring(island.epoch),tostring(island.island)},':')
            end,
            role=function() return self.role end,request=function(paused) return self:RequestSharedPause(paused) end,
            log=function(line) self:_log('%s',line) end})
    end
    local ok,why=pcall(self.pauseDriver.Tick,self.pauseDriver,self.clockNow)
    if not ok and self.pauseError~=tostring(why) then
        self.pauseError=tostring(why);self:_log('Shared pause integration failed: %s',self.pauseError)
    end
end
function App:_tickCheckpointProbe()
    if not allows(self,'dev_probes') or not self.extras.checkpointProbe then return end
    if self.checkpointProbeAt and self.clockNow<self.checkpointProbeAt then return end
    self.checkpointProbeAt=self.clockNow+5
    if not self.checkpointProbeWorld then
        if type(self.bridge.G)~='table' then return end
        self.checkpointProbeWorld=require('gmp_world').new(self.bridge.G)
    end
    local ok,snapshot=pcall(self.checkpointProbeWorld.ReadCheckpointProbe,self.checkpointProbeWorld)
    if not ok then
        if self.checkpointProbeError~=tostring(snapshot) then
            self.checkpointProbeError=tostring(snapshot);self:_log('CHECKPOINTPROBE failed: %s',self.checkpointProbeError)
        end
        return
    end
    if not snapshot then return end
    self.checkpointProbeError=nil;local fields={}
    for key,value in pairs(snapshot.scalars) do fields[#fields+1]=key..'='..tostring(value) end
    table.sort(fields)
    self:_log('CHECKPOINTPROBE role=%s complete=false dilation=%s seed=%s stage=%s fields=%s missing=%s',
        self.role,tostring(snapshot.dilation),tostring(snapshot.generation and snapshot.generation.seed),
        tostring(snapshot.generation and snapshot.generation.stage),table.concat(fields,','),table.concat(snapshot.unavailable,','))
end
function App:_tickNativeBindingProbe()
    if not allows(self,'dev_probes') or not self.extras.nativeBindingProbe or self.handoverRuntimeHold then return end
    if not self.nativeBindingProbe then
        if type(self.bridge.G)~='table' then return end
        self.nativeBindingProbe=require('gmp_native_binding_probe').new(require('gmp_world').new(self.bridge.G),
            function(line) self:_log('%s',line) end)
    end
    local ok,why=pcall(self.nativeBindingProbe.Tick,self.nativeBindingProbe,self.clockNow)
    if not ok then self.extras.nativeBindingProbe=false;self:_log('NATIVEBINDINGPROBE stopped: %s',tostring(why)) end
end
function App:_tickNativeXpReadCapture()
    local session=self.role=='host' and self.host or self.client
    local islands=session and session.islands;local pause=session and session.sharedPause
    if not allows(self,'dev_probes') or not self.extras.nativeXpReadCapture or self.handoverRuntimeHold
        or not islands or islands.phase~='playing' or not pause or not pause.paused then
        if self.nativeXpReadCapture then self.nativeXpReadCapture:CancelCapture();self.nativeXpReadCapture=nil end
        return
    end
    if (self.nativeXpReadReports or 0)>=4 then return end
    local world=self.nativeStateWorld
    if not world or require('gmp_native_timers').new(world):_paused()~=true then return end
    local function context()
        local current=self.role=='host' and self.host or self.client
        local state=current and current.islands;local shared=current and current.sharedPause
        if not state or state.phase~='playing' or not shared or not shared.paused then return nil end
        local manager=world:_enemyController();if not manager or not manager:IsValid() then return nil end
        return table.concat({current.sid or '',current.authorityTerm or 1,state.epoch,state.island,
            shared.revision,manager:GetFullName()},':')
    end
    local token=context();if not token then return end
    if not self.nativeXpReadCapture then
        if self.nativeXpReadContext==token then return end
        local manager=world:_enemyController();local mesh=manager.XPInstanceComponent
        if not mesh or not mesh:IsValid() or mesh:GetInstanceCount()==0 then return end
        self.nativeXpReadContext=token
        self.nativeXpReadCapture=require('gmp_native_xp_capture').new({manager=function() return world:_enemyController() end,
            context=context,paused=function() return require('gmp_native_timers').new(world):_paused()==true end})
        local started,why=self.nativeXpReadCapture:BeginCapture()
        if not started then
            self.nativeXpReadCapture=nil;self.nativeXpReadReports=(self.nativeXpReadReports or 0)+1
            self:_log('NATIVEXPREAD complete=false native_mutations=0 refused=%s',tostring(why):sub(1,600));return
        end
    end
    local state,why=self.nativeXpReadCapture:CaptureStep()
    if state==false then return end
    self.nativeXpReadCapture=nil;self.nativeXpReadReports=(self.nativeXpReadReports or 0)+1
    if not state then self:_log('NATIVEXPREAD complete=false native_mutations=0 refused=%s',tostring(why):sub(1,600));return end
    self.nativeXpReadSnapshot=state
    self:_log('NATIVEXPREAD complete=false native_mutations=0 count=%d xpp_sum=%d amounts_authoritative=false',#state.pickups,state.total)
end
function App:_tickNativeSpawnProbe()
    if not allows(self,'dev_probes') or not self.extras.nativeSpawnCheck or self.handoverRuntimeHold then return end
    local session=self.host or self.client
    if not session or not session.sharedPause or not session.sharedPause.paused or session.sharedPause.reason~='manual' then return end
    if not self.nativeSpawnProbe then
        if type(self.bridge.G)~='table' then return end
        self.nativeSpawnProbe=require('gmp_native_spawn_probe').new(require('gmp_world').new(self.bridge.G),{
            ready=function() return session.sharedPause.paused and session.sharedPause.reason=='manual' end,
            token=function()
                local islands=session.islands
                if not islands or islands.phase~='playing' then return nil end
                return tostring(islands.epoch)..':'..tostring(islands.island)
            end,
            log=function(line) self:_log('%s',line) end})
    end
    local ok,why=pcall(self.nativeSpawnProbe.Tick,self.nativeSpawnProbe)
    if not ok then self.extras.nativeSpawnCheck=false;self:_log('NATIVESPAWNCHECK stopped: %s',tostring(why)) end
end
function App:_tickNativeTimerProbe()
    if not allows(self,'dev_probes') or not self.extras.nativeTimerCheck or self.handoverRuntimeHold or self.nativeRestoreHold then return end
    local session=self.host or self.client
    if not session or not session.sharedPause then return end
    local function ready() return session.sharedPause.paused and session.sharedPause.reason=='manual' end
    if not self.nativeTimerProbe then
        if not ready() or type(self.bridge.G)~='table' then return end
        self.nativeTimerProbe=require('gmp_native_timer_probe').new(
            require('gmp_native_timers').new(require('gmp_world').new(self.bridge.G)),{
                ready=ready,token=function()
                    local islands=session.islands
                    if not islands or islands.phase~='playing' then return nil end
                    return tostring(islands.epoch)..':'..tostring(islands.island)
                end,log=function(line) self:_log('%s',line) end})
    end
    local ok,_,why,hold=pcall(self.nativeTimerProbe.Tick,self.nativeTimerProbe)
    if not ok then
        self.extras.nativeTimerCheck=false;hold=self.nativeTimerProbe.wrote==true
        self:_log('NATIVETIMERCHECK stopped: %s',tostring(_))
    end
    if hold then
        self.nativeRestoreHold=true
        if self.islandFlow then
            self.islandFlow.world:SetSharedPaused(true)
            self.islandFlow.world:SetPauseNotice('Timer restore check failed. Leave game open for diagnosis.')
        end
    end
end
function App:_nativeRebuildTimersReady()
    local timers=require('gmp_native_timers').new(self.nativeStateWorld)
    local state=timers:Capture()
    return state and timers:ValidateRestore(state)==true
end
function App:_nativeRebuildSceneReady()
    local world=self.nativeStateWorld:_world()
    local pawn=world and self.nativeStateWorld:_pawn(world)
    if not pawn or pawn:IsValid()~=true or pawn['PresentTime?']==true then return false end
    local hud=pawn.HUD
    if not hud or hud:IsValid()~=true then return false end
    local fade=hud.FadeValue
    return type(fade)=='number' and fade==fade and fade>=.999 and fade<=1.01
end
function App:_tickNativeStateProbe()
    if not allows(self,'dev_probes') or not (self.extras.nativeStateCheck or self.extras.nativeRebuildCheck) or self.handoverRuntimeHold or self.nativeRestoreHold then return end
    if self.extras.nativeRebuildCheck and (self.extras.hostEnemyCapture or self.extras.nativeStateCheck) then
        self.extras.nativeRebuildCheck=false
        self:_log('NATIVEREBUILDCHECK refused: concurrent_capture_or_state_probe');return
    end
    local session=self.host or self.client
    if not session or not session.sharedPause or type(self.bridge.G)~='table' then return end
    if self.nativeRebuildResumeAt and self.clockNow>=self.nativeRebuildResumeAt then
        self.nativeRebuildResumeAt=nil
        local islands=session.islands
        local token=islands and islands.phase=='playing' and tostring(islands.epoch)..':'..tostring(islands.island)
        if session.sharedPause.paused and session.sharedPause.reason=='manual'
            and session.sharedPause.revision==self.nativeRebuildResumeRevision
            and token==self.nativeStateProbe.token and self:RequestSharedPause(false)==true then
            self.islandFlow.world:SetSharedPaused(false)
            self:_log('NATIVEREBUILDCHECK automatic resume requested')
        end
    end
    if not self.nativeStateWorld then self.nativeStateWorld=require('gmp_world').new(self.bridge.G) end
    if self.extras.nativeRebuildAutoPause and not self.nativeRebuildPauseRequested
        and self.role=='host' and session.islands and session.islands.phase=='playing' then
        local ok,hasEnemies=pcall(function()
            local manager=self.nativeStateWorld:_enemyController()
            if not manager or #manager.InstanceStruct==0 or #manager.InstanceStruct>128 then return false end
            return self:_nativeRebuildSceneReady() and self:_nativeRebuildTimersReady()
        end)
        if ok and hasEnemies and self:RequestSharedPause(true)==true then
            self.nativeRebuildPauseRequested=true
            self.islandFlow.world:SetSharedPaused(true)
            self:_log('NATIVEREBUILDCHECK automatic first-enemy pause requested')
        end
    end
    local function ready()
        return session.sharedPause.paused and session.sharedPause.reason=='manual'
            and require('gmp_native_timers').new(self.nativeStateWorld):_paused()
    end
    if not self.nativeStateProbe then
        if not ready() then return end
        local module=self.extras.nativeRebuildCheck and 'gmp_native_rebuild_probe' or 'gmp_native_state_probe'
        self.nativeStateProbe=require(module).new(self.nativeStateWorld,{
            ready=ready,token=function()
                local islands=session.islands
                if not islands or islands.phase~='playing' then return nil end
                return tostring(islands.epoch)..':'..tostring(islands.island)
            end,log=function(line) self:_log('%s',line) end})
    end
    local ok,result,why,hold=pcall(self.nativeStateProbe.Tick,self.nativeStateProbe)
    if ok and result==false and hold~=true and self.nativeStateProbe.wrote~=true
        and self.nativeRebuildPauseRequested then
        -- Only release a pause owned by this diagnostic; the revision/context
        -- guard above preserves any later manual pause or island change.
        self.nativeRebuildResumeAt=self.clockNow
        self.nativeRebuildResumeRevision=session.sharedPause.revision
        self:_log('NATIVESTATECHECK finished without writes; automatic pause release scheduled')
    end
    if ok and result==true and self.extras.nativeRebuildAutoResumeSeconds then
        self.nativeRebuildResumeAt=self.clockNow+self.extras.nativeRebuildAutoResumeSeconds
        self.nativeRebuildResumeRevision=session.sharedPause.revision
    end
    if not ok then
        self.extras.nativeStateCheck=false;self.extras.nativeRebuildCheck=false;hold=self.nativeStateProbe.wrote==true
        self:_log('NATIVESTATECHECK stopped: %s',tostring(result))
    end
    if hold then
        self.nativeRestoreHold=true
        if self.islandFlow then
            self.islandFlow.world:SetSharedPaused(true)
            self.islandFlow.world:SetPauseNotice('State restore check failed. Leave game open for diagnosis.')
        end
    end
end
function App:_tickProgressionRestoreCheck()
    if self.handoverRuntimeHold then return end
    if not allows(self,'dev_probes') or not self.extras.progressionRestoreCheck or self.progressionRestoreChecked then return end
    if type(self.bridge.G)~='table' then return end
    local session=self.host or self.client
    if not session or (session.sharedPause and session.sharedPause.paused) or not self.islandFlow then return end
    local world=self.islandFlow.world
    if world:IsEscapeMenuOpen() then return end
    local nativeWorld=require('gmp_world').new(self.bridge.G)
    local native=require('gmp_native_progression').new(nativeWorld)
    local ready,blocked=native:ValidateProbe()
    if not ready then
        if self.progressionProbeBlocked~=blocked then
            self.progressionProbeBlocked=blocked;self:_log('PROGRESSIONRESTORECHECK waiting: %s',tostring(blocked))
        end
        return
    end
    self.progressionProbeBlocked=nil
    self.progressionRestoreChecked=true
    local success,ok,why,hold=pcall(require('gmp_progression_restore_probe').Run,world,native)
    self.nativeRestoreHold=not success or hold==true
    self:_log('PROGRESSIONRESTORECHECK result=%s reason=%s hold=%s',
        success and ok and 'PASS' or 'FAIL',tostring(success and why or ok),tostring(self.nativeRestoreHold))
    if self.nativeRestoreHold then world:SetPauseNotice('Restore check failed. Leave game open for diagnosis.') end
end
function App:_tickIslands()
    if self.handoverRuntimeHold then return end
    if not self.extras.islandHandoff then return end
    if not allows(self,'gameplay') or (self.role~='host' and self.role~='client') then
        if not self.islandGateLogged then self.islandGateLogged=true;self:_log('ISLAND handoff refused outside explicit dev network role') end
        return
    end
    local session=self.role=='host' and self.host or self.client
    if not session then return end
    local function enable()
        session:EnableIslands()
        session:EnableTravelGate()
        if self.extras.sharedPause then
            session:EnablePause()
            if self.role=='host' then session:SetPauseHostOnly(self.extras.hostOnlyPause==true) end
        end
    end
    -- t3 friend reports (Coder A): "Island handoff stopped: ... attempt to index a nil value (field 'islands')". A Steam
    -- Join after a refusal or after End Run makes a new session object while the flow still held the first one. The new
    -- session gets its own islands, travel gate and pause, and the flow follows it; the game's hooks (the world) stay.
    if self.islandFlow and not session.islands then
        enable()
        local old=self.islandFlow
        self.islandFlow=require('gmp_island_flow').new({role=self.role,world=old.world,session=function() return session end,
            now=function() return self.clockNow end,log=function(line) self:_log('%s',line) end})
        self.islandSignature=nil
        self:_log('ISLAND handoff follows the new %s session',tostring(self.role))
    end
    if not self.islandFlow then
        enable()
        local Flow=require('gmp_island_flow');local World=require('gmp_island_world')
        local world
        world=(self.islandWorldFactory or World.new)(self.bridge.G,{
            active=function() return self.islandFlow and not self.islandFlow.failed end,
            role=function() return self.role end,
            manifest=function() return self.islandFlow:Manifest() end,
            failed=function(why) self.islandFlow:Fail(why) end,
            prepared=function() end,
            trace=function(line) self:_log('ISLANDTRAVEL role=%s %s',self.role,line) end,
            generated=function(generator)
                -- Coder C (host death, 2026-10-15): a host world generated outside a run (its end-screen Retry after the
                -- run ended for everyone) never starts an island run that waits for players: it leaves to the lobby,
                -- where Start begins the next run for everyone (D51).
                if self.role=='host' and self.host and self.host.roster and self.host.roster.phase~='run' then
                    self:_log('HOST RETRY outside a run: leaving to the lobby (Start begins the next run for everyone)')
                    return self:_endRunToMenu()
                end
                self.islandFlow:Generated(generator)
                local activeSession=self.role=='host' and self.host or self.client
                local state=activeSession.islands
                self:_log('ISLAND generated role=%s phase=%s epoch=%d island=%d seed=%s',self.role,state.phase,state.epoch,state.island,
                    tostring(state.pending and state.pending.seed))
            end,
            portal=function() return self.islandFlow:Portal() end})
        self.islandFlow=Flow.new({role=self.role,world=world,session=function() return session end,now=function() return self.clockNow end,log=function(line) self:_log('%s',line) end})
        self:NativeWorld()
        self:_log('ISLAND handoff enabled (dev); client first entry requires host manifest before Play')
    end
    local flow=self.islandFlow
    local world=flow.world:LocalWorldPawn()
    if world then self.islandHadWorld=true
    elseif self.islandHadWorld then
        flow:Menu();self.islandHadWorld=false;self:_log('ISLAND run ended; handoff reset for next run')
        -- D52: a client that quit its run to the menu while the host plays on leaves the session (the host holds the slot).
        local mirror=self.role=='client' and self.client and type(self.client.Roster)=='function' and self.client:Roster() or nil
        if type(mirror)=='table' and mirror.phase=='run' and self.client:State()=='joined' then
            -- D51: from the end screen the world closes for a Retry (it comes back) or for the menu: hold the session
            if self.endScreenAt then
                self.endScreenGoneAt=self.clockNow or 0
                self:_log('END SCREEN: the world closed; holding the session for a Rejoin')
                return
            end
            return self:_quitRunToMenu()
        end
        -- W6: the host reaching the menu returns the run to the lobby (reservations kept, LOBBY_RETURN to clients).
        if self.role=='host' and self.host and self.host.roster.phase=='run' then
            local returned,generation=self.host:ReturnToLobby()
            if returned then self:_log('LOBBY_RETURN sent runGeneration=%d',generation) end
        end
    end
    if flow.failed then return end
    local ok,why=pcall(function()
        flow.world:Install()
        flow.world:FlushGenerated()
        local sharedPaused=session.sharedPause and session.sharedPause.paused and session.sharedPause.revision>0
        if not sharedPaused then flow:Tick() end
        local _,pawn=flow.world:LocalWorldPawn()
        local portalRequestsAllowed=not sharedPaused and session.islands.phase=='playing'
            and (self.role=='host' or session:State()=='joined')
        flow.world:PollPortals(pawn,portalRequestsAllowed)
        local state=session.islands
        local signature=table.concat({state.phase,state.epoch,state.island,state.pending and state.pending.seed or '-'},':')
        if signature~=self.islandSignature then self.islandSignature=signature;self:_log('ISLAND state %s',signature) end
    end)
    if not ok then flow:Fail(why) end
end

-- Development capture sends host records into a detached client cache only.
-- Client simulation/rendering is deliberately not replaced by this stage.
function App:_newEnemyCapture()
    local world=self.presenceDriver and self.presenceDriver.world
    if not world or not self.bridge or type(self.bridge.G)~='table' then return nil,'missing_native_enemy_world' end
    return require('gmp_enemy_capture').new(self.bridge.G,{
        active=function() return self.role=='host' and self.host and self.host.islands.phase=='playing' end,
        -- Coder B (test 15 rejoin stall): the spawn hooks do nothing until the island is visible
        visible=function() local w=self.islandFlow and self.islandFlow.world;return not w or type(w.DiagnosticVisible)~='function' or w:DiagnosticVisible()==true end,
        token=function() return self.host and (self.host.islands.epoch..':'..self.host.islands.island) end,
        begin=function() self.host:BeginEnemyIsland() end,
        registry=function() return self.host and self.host.enemies end,
        manager=function() return world:_enemyController() end,
        log=function(line) self:_log('%s',line) end})
end
function App:_tickEnemies()
    if self.handoverRuntimeHold then return end
    if not self.extras.hostEnemyCapture or not allows(self,'gameplay') or not self.extras.islandHandoff then return end
    local session=self.role=='host' and self.host or self.role=='client' and self.client
    if not session or not session.islands then return end
    session:EnableEnemies()
    if self.role=='host' then
        if not self.enemyCapture and self.presenceDriver then
            self.enemyCapture=self:_newEnemyCapture()
        end
        if self.enemyCapture then self.enemyCapture:Tick(self.clockNow) end
        if not self.enemyCapture or self.enemyCapture.failed then return end
        session:BroadcastEnemies()
    end
    if not self.nextEnemyReport or self.clockNow>=self.nextEnemyReport then
        self.nextEnemyReport=self.clockNow+5
        local snapshot=self.role=='host' and session.enemies:Snapshot() or session:EnemySnapshot()
        local count,alive,dead=0,0,0
        for _,row in ipairs(snapshot and snapshot.enemies or {}) do
            count=count+1;if row.dead then dead=dead+1 else alive=alive+1 end
        end
        self:_log('HOSTENEMIES role=%s epoch=%s revision=%s count=%d alive=%d dead=%d callbacks=%d rejected=%d',
            self.role,tostring(snapshot and snapshot.epoch),tostring(snapshot and snapshot.revision),count,alive,dead,
            self.enemyCapture and self.enemyCapture.spawnCallbacks or 0,session.stats.enemy_rejected or 0)
    end
end

function App:_devAutoStartReady()
    if self.role=='host' then
        local expected=self.extras.devAutoStartPlayers or 1
        local count=0
        for _,player in ipairs(self.host.roster:Snapshot()) do if player.conn=='connected' then count=count+1 end end
        return count>=expected
    elseif self.role=='client' then
        if not self.client or self.client.state~='joined' then return false end
        if self.extras.islandHandoff then
            local islands=self.client.islands
            return islands~=nil and islands.pending~=nil and islands.phase=='generating'
        end
    end
    return true
end
function App:_devCycleObserve()
    local session=self.role=='host' and self.host or self.client
    if not session or not self.islandFlow then return {alive=0} end
    session.devCycleEnabled=true
    local islands=session.islands;local pause=session.sharedPause
    local term=(self.role=='host' and session.authorityTerm or session.authorityTerm) or 1
    local world=self.islandFlow.world
    local visible=islands and islands.phase=='playing' and world:DiagnosticVisible()==true
    local physicalValue,physicalReason=self:_testPhysicalPause()
    local physical=visible and physicalValue==true
    local readiness=self.handoverGame and self.handoverGame:Readiness()
    local scopeFailure=physical and readiness and not readiness.ready and readiness.reason
    local ready=false;local frame=self.role=='host' and session.checkpointFrame
    if frame and session:CheckpointReady() and pause and pause.paused and physical then
        local context=table.concat({session.sid or '',term,islands.epoch,islands.island,pause.revision},':')
        ready=frame.term==term and self.nativePublishedContext==context
            and frame.state.manifest.epoch==islands.epoch and frame.state.manifest.island==islands.island
        if ready and self.clockNow>=(self.devCycleReadySendAt or 0) then
            self.devCycleReadySendAt=self.clockNow+1
            local packet={term=term,epoch=islands.epoch,island=islands.island,revision=pause.revision,
                sequence=frame.sequence,digest=frame.digest}
            -- A committed replacement island has no generation-required set.
            -- Scheduler readiness belongs to authenticated session membership.
            for _,peer in pairs(session.peers or {}) do
                local player=peer.key and session:GetPlayer(peer.key)
                if player and player.conn=='connected' then session:_send(peer,'DEV_CYCLE_READY',packet) end
            end
        end
    elseif self.role=='client' then
        local f=session.devCycleReady;local stream=session.checkpointStream
        ready=f and pause and pause.paused and physical and session.state=='joined' and stream
            and f.term==term and f.epoch==islands.epoch and f.island==islands.island and f.revision==pause.revision
            and f.sequence==stream.sequence and f.digest==stream.hash and session.checkpointSession==session.sid or false
    end
    local backend=self.nativeHandoverCandidate and self.nativeHandoverCandidate.domains.enemies.backend
    local alive,motion=0,self.devCycleMotion
    if backend and visible and self.clockNow>=(self.devCycleSampleAt or 0) then
        self.devCycleSampleAt=self.clockNow+.2
        local manager=backend:_manager();local rows=backend.capture:_rows(manager)
        local registry=self.role=='host' and session.enemies
            or backend.capture.observer and backend.capture.observer.registry
        if registry and type(registry.IdForSlot)=='function' then
            for _,row in ipairs(rows) do row.id=registry:IdForSlot(row.index) end
        end
        for _,row in ipairs(rows) do if row.hp>0 then alive=alive+1 end end
        if not self.devEnemyMotion then self.devEnemyMotion=require('gmp_dev_enemy_motion').new() end
        local context=tostring(manager:GetAddress())..':'..islands.epoch..':'..islands.island
        motion=self.devEnemyMotion:Sample(context,rows,pause and pause.paused==false)
        self.devCycleMotion=motion;self.devCycleAlive=alive
    else alive=self.devCycleAlive or 0 end
    -- The host cannot advertise a smaller intermediate checkpoint while the
    -- paused large-horde acquisition is still changing the native records.
    if ready then
        local state=frame and frame.state or session.checkpointStream and session.checkpointStream.state
        local count=0;for _,row in ipairs(state and state.enemies.enemies or {}) do if not row.dead then count=count+1 end end
        if count<120 then ready=false end
    end
    local control=self.handoverRuntime and self.handoverRuntime.control
    local failure=session.devCycleAbort or (control and control.failed and (control.failed..':'..tostring(control.failureReason)))
        or (self.islandFlow.failed and ('island_flow:'..tostring(self.islandFlow.failed)))
    local connected=self.role=='client' and session.state=='joined'
    if self.role=='host' then
        local count=0;for _,p in ipairs(session.roster:Snapshot()) do if p.conn=='connected' then count=count+1 end end
        connected=count>=(self.extras and self.extras.devSteamSocketsTest and 4 or 2)
    end
    local nativeReason=not backend and 'native_backend_pending'
        or self.handoverGame~=self.nativeHandoverCandidate and 'native_factory_arm_pending'
        or not physical and (physicalReason or 'physical_pause_not_ready')
        or not (readiness and readiness.ready) and 'native_domain_readiness_pending' or nil
    local hostSlot
    local roster=self.role=='host' and session.roster:Snapshot() or session.mirror and session.mirror.players
    if type(roster)=='table' then for _,row in ipairs(roster)do if row.role=='host' and row.conn=='connected'then hostSlot=row.slot end end end
    return {role=self.role,term=term,hostSlot=hostSlot,epoch=islands and islands.epoch or 0,island=islands and islands.island or 0,visible=visible,paused=pause and pause.paused,
        physicalPaused=physicalValue,revision=pause and pause.revision,sequence=(frame or session.devCycleReady or {}).sequence,
        digest=(frame or session.devCycleReady or {}).digest,connected=connected,nativeReason=nativeReason,
        nativeReady=backend~=nil and self.handoverGame==self.nativeHandoverCandidate and physical==true
            and readiness and readiness.ready==true or false,
        ready=ready,alive=alive,motion=motion,migrating=self.handoverRuntime~=nil,failure=failure,scopeFailure=scopeFailure}
end
function App:_devCycleReplacementBarrier()
    local session=self.role=='host' and self.host or self.client
    local f=self.role=='host' and session.checkpointFrame or session.devCycleReady
    if not f or not session.sharedPause or not session.sharedPause.paused then return false end
    local i=session.islands;local term=session.authorityTerm or 1
    local packet={term=term,epoch=i.epoch,island=i.island,revision=session.sharedPause.revision,
        sequence=f.sequence,digest=f.digest}
    if self.role=='client' then
        local token=table.concat({term,i.epoch,i.island,packet.revision,packet.sequence,packet.digest},':')
        local now=self.clockNow or 0
        if self.devReplacementAckToken==token and now<(self.devReplacementAckAt or 0) then return true end
        local sent=session:_send('DEV_CYCLE_REPLACEMENT_ACK',packet)==true
        if sent then self.devReplacementAckToken=token;self.devReplacementAckAt=now+.25 end
        return sent
    end
    local token=table.concat({term,i.epoch,i.island,packet.revision,packet.sequence,packet.digest},':')
    local count=0
    for _,row in ipairs(session.roster:Snapshot()) do
        if row.conn=='connected' and row.key~=session.identity.key then
            count=count+1
            if not session.devCycleReplacementAcks or session.devCycleReplacementAcks[row.key]~=token then return false end
        end
    end
    return count>0
end
function App:_devCycleStartBarrier(cycle,targetSlot,expected)
    if self:_testPhysicalPause()~=true then return false end
    local session=self.role=='host' and self.host or self.client
    if not session or not session.sharedPause or not session.sharedPause.paused then return false end
    local f=self.role=='host' and session.checkpointFrame or session.devCycleReady
    if not f then return false end
    if expected then
        local current={term=session.authorityTerm or 1,epoch=session.islands.epoch,island=session.islands.island,
            revision=session.sharedPause.revision,sequence=f.sequence,digest=f.digest}
        for _,name in ipairs{'term','epoch','island','revision','sequence','digest'}do if current[name]~=expected[name]then return false end end
    end
    if self.role=='client' and (session.state~='joined' or session.checkpointSession~=session.sid
        or not session.authenticatedHostKey)then return false end
    -- Calling this after the scheduler pins its old context is the prepared
    -- receipt; ordinary checkpoint assembly alone never authorizes a claim.
    if self:_devCycleReplacementBarrier()~=true then return false end
    if self.role=='client' then
        local start=session.devCycleStart
        if not start or start.cycle~=cycle or start.targetSlot~=targetSlot then return false end
        for _,name in ipairs{'term','epoch','island','revision','sequence','digest'}do if start[name]~=f[name]then return false end end
        return true
    end
    local islands=session.islands
    local packet={term=session.authorityTerm or 1,epoch=islands.epoch,island=islands.island,revision=session.sharedPause.revision,
        sequence=f.sequence,digest=f.digest,cycle=cycle,targetSlot=targetSlot}
    local peers=0
    for _,peer in pairs(session.peers or {})do
        local player=peer.key and session:GetPlayer(peer.key)
        if player and player.conn=='connected'then peers=peers+1;session:_send(peer,'DEV_CYCLE_START',packet)end
    end
    return peers==3
end
function App:_devCycleHold(reason)
    local control=self.handoverRuntime and self.handoverRuntime.control
    if control and control.phase~='finished' then
        control:Abort('development_test_stopped:'..reason);self.handoverRuntimeHold=true
    end
    local session=self.role=='host' and self.host or self.client;local world=self.islandFlow and self.islandFlow.world
    local ok,accepted,why=pcall(function() if not world then return false,'missing_world' end;return world:SetSharedPaused(true) end)
    local holdError=not ok and tostring(accepted) or accepted~=true and tostring(why or 'pause_rejected') or nil
    if not self.devCycleHoldReported or self.devCycleHoldError~=holdError then
        self.devCycleHoldReported=true;self.devCycleHoldError=holdError
        self:_log('DEVCYCLE physical hold: %s',holdError and ('failed:'..holdError):sub(1,300) or 'verified')
    end
    if world then pcall(world.SetPauseNotice,world,'Automatic test stopped. '..(holdError and 'Pause could not be applied.' or 'Game held paused.')) end
    if not session then return end
    session.devCycleAbort=reason
    if self.devCycleAbortSent==session then return end
    self.devCycleAbortSent=session
    local islands=session.islands;if not islands then return end
    local f={term=(self.role=='host' and session.authorityTerm or session.authorityTerm) or 1,
        epoch=islands.epoch,island=islands.island,reason=reason}
    if self.role=='host' then
        session:RequestPause(self.identity.key,true);session:_broadcastIsland('DEV_CYCLE_ABORT',f)
    elseif session.state=='joined' then session:_send('DEV_CYCLE_ABORT',f) end
end
function App:_devCycleAcquire()
    local game=self.nativeHandoverCandidate;local backend=game and game.domains.enemies.backend
    if not backend or not backend:Paused() then return false,'missing_paused_backend' end
    local ok,why=backend:Preflight();if not ok then return false,why end
    local rows=backend.capture:_rows(backend:_manager());local count,template=0,nil
    for _,row in ipairs(rows) do if row.hp>0 then count=count+1;template=template or row end end
    if count>=120 then return true end
    if not template then return false,'no_ordinary_enemy_template' end
    backend:SuspendSimulation() -- stable paused acquisition and checkpoint capture
    if backend:BindSpawnOnly()~=true then return false,'spawn_binding_refused' end
    local request={enemyType=template.enemyType,hp=1000000000,damage=template.damage,
        x=template.x+100*(count%4+1),y=template.y+100*(math.floor(count/4)%4+1),z=0}
    backend:Spawn(request) -- one verified ordinary native spawn per game tick
    if self.handoverGame then self.handoverGame:CancelCapture() end
    self.nativePublishedContext=nil;self.nativePublicationContext=nil
    self.devCycleSampleAt=0
    return true
end
function App:_tickDevMigrationCycle()
    if not allows(self,'dev_probes') or not self.extras.nativeF6Experiment or not self.extras.nativeF6Cycle then return end
    if not self.devMigrationCycle then
        self.devMigrationCycle=require('gmp_dev_migration_cycle').new({
            playerSlot=self.extras.devSteamSocketsTest and self.extras.devPlayerSlot or nil,
            maxCycles=self.extras.devSteamSocketsTest and 4 or 10,maxSeconds=600,
            observe=function() return self:_devCycleObserve() end,
            log=function(line) self:_log('%s',line) end,hold=function(reason) self:_devCycleHold(reason) end,
            acquire=function() return self:_devCycleAcquire() end,handover=function() return self:RequestHandoverTest(true) end,
            barrier=function() return self:_devCycleReplacementBarrier() end,
            startBarrier=self.extras.devSteamSocketsTest and function(cycle,target,expected)return self:_devCycleStartBarrier(cycle,target,expected)end or nil,
            resume=function() return self:RequestSharedPause(false) end,travel=function() return self:RequestIslandTest() end})
    end
    local ok,why=pcall(self.devMigrationCycle.Tick,self.devMigrationCycle,self.clockNow)
    if not ok then self.devMigrationCycle:Stop('test_executor:'..tostring(why)) end
end
function App:_tickDevDispatchProbe()
    if not allows(self,'dev_probes') or not self.extras.devDispatchProbe then return end
    if not self.devDispatchProbe then
        local world=require('gmp_world').new(self.bridge.G)
        local function path(object)
            if not object or object:IsValid()~=true then return nil end
            -- UE4SS Lua exposes GetFullName, not GetPathName. Strip only the
            -- verified class prefix; native code resolves/rechecks this path.
            return object:GetFullName():match('^[^ ]+ (.+)$')
        end
        local controller
        if self.extras.devDispatchControllerProbe then
            local combatAuthority={
                Role=function()return self.role end,
                LocalPeer=function()
                    local session=self.role=='host' and self.host or self.client
                    return session and session.identity and session.identity.key
                end,
                Context=function()
                    local session=self.role=='host' and self.host or self.client
                    local islands=session and session.islands
                    return islands and table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island},':')
                end}
            controller=require('gmp_dev_controller_probe').new(world,{combatAuthority=combatAuthority,
                log=function(line)self:_log('%s',line)end})
        end
        local pickup
        if self.extras.devPickupCompactionProbe then
            pickup=require('gmp_dev_pickup_combined_probe').new(world,function(expectedContext,expectedGeneration)
                local session=self.role=='host' and self.host or self.client
                local islands=session and session.islands;local flow=self.islandFlow and self.islandFlow.world
                local context=islands and table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island},':')
                return self.role=='host' and context==expectedContext and islands.epoch==expectedGeneration
                    and islands.phase=='playing' and flow and flow:DiagnosticVisible()==true
                    and self:_testPhysicalPause()==true and session.sharedPause and session.sharedPause.paused==true
            end,function(line)self:_log('%s',line)end)
        end
        self.devDispatchProbe=require('gmp_dev_dispatch_probe').new({G=self.bridge.G,controller=controller,pickup=pickup,
            observe=function()
                local session=self.role=='host' and self.host or self.client
                local islands=session and session.islands
                local flow=self.islandFlow and self.islandFlow.world
                local visible=islands and islands.phase=='playing' and flow and flow:DiagnosticVisible()==true
                local w=visible and world:_world();local manager=visible and world:_enemyController()
                local generation=islands and islands.epoch
                local observedPawn,observedHud,observedFade,observedPresent
                pcall(function()
                    local _,pawn=flow:LocalWorldPawn();observedPawn=path(pawn)
                    observedPresent=pawn and pawn['PresentTime?']
                    local hud=pawn and pawn.HUD;observedHud=path(hud);observedFade=hud and hud.FadeValue
                end)
                return {visible=visible==true,physicalPaused=self:_testPhysicalPause(),generation=generation,
                    sharedPaused=session and session.sharedPause and session.sharedPause.paused,
                    sharedRevision=session and session.sharedPause and session.sharedPause.revision,
                    observedPawn=observedPawn,observedHud=observedHud,observedFade=observedFade,observedPresent=observedPresent,
                    context=islands and table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island},':'),
                    worldPath=path(w),controllerPath=path(manager)}
            end,
            pause=function(value)return self:RequestSharedPause(value)end,
            hold=function(reason)
                self.nativeRestoreHold=true;self.nativeRestoreStatus='SDK dispatch check failed: '..reason
                self:RequestSharedPause(true)
            end,
            log=function(line)self:_log('%s',line)end})
    end
    local ok,why=pcall(self.devDispatchProbe.Tick,self.devDispatchProbe,self.clockNow)
    if not ok then self.devDispatchProbe:Stop('executor:'..tostring(why)) end
end
-- W3: with SPLASH_SKIP_ONLY=1 the boot dev driver is a splash-only instance. It runs from boot in every app state
-- (the lobby is reached later through the menu) on its own clock, dismisses the company splash and never presses
-- Play. The lobby's MP-entry driver (gmp_lobby_runtime.lua) is a separate instance without the option.
function App:_tickBootDriver(dt)
    if not allows(self,'dev_scaffolding') or type(self.extras)~='table' or not self.extras.devAutoStart
        or not self.extras.splashSkipOnly then return end
    if not self.devAutoStart then
        self.devAutoStart=require('gmp_dev_autostart').new(self.bridge.G,function(line) self:_log('%s',line) end,{splashOnly=true})
    end
    self.bootClock=(self.bootClock or 0)+(dt or 0)
    self.devAutoStart:Tick(self.bootClock)
end
-- Test 12 audit: one shared world/pawn lookup per tick for every LocalWorldPawn caller (gmp_island_world NextFrame).
function App:_tickWorldFrame()
    local world=self.islandFlow and self.islandFlow.world
    if type(world)=='table' and type(world.NextFrame)=='function' then pcall(world.NextFrame,world) end
end
function App:_tickLuaGc() if self.luaGc then self.luaGc:Tick(self.role) end end   -- Coder B: clients only, see gmp_lua_gc.lua
function App:Tick(dt)
    self:_tickLuaGc()
    self:_tickWorldFrame()
    self:_tickBootDriver(dt)
    if self.state=='dev_socket_lobby'then self.clockNow=(self.clockNow or 0)+(dt or 0)end
    self:_tickLeavingClient()
    self:_tickClosingHost()   -- t3 friend reports (Coder A): a closed lobby tells its players first
    self:_tickDevLobbyBeacon()
    if self.devSocketLobbyBackend then self.devSocketLobbyBackend:Snapshot()end
    self:_tickSteamLobby(dt)
    self:_tickRichPresence()
    self:_tickProductionNativeLifecycle()
    self:_tickPeerNativeCapture()
    self:_tickNativeF6Arm()
    self:_tickNativeCheckpointPublication()
    if self.state~='hosting' and self.state~='client'then self:_tickNativeOutcomes()end
    self.ticks = self.ticks + 1
    self:_retryIdentity()
    if self.state == "hosting" or self.state == "client" then
        self.clockNow = self.clockNow + (dt or 0)
        if self.lossRecovery then require("gmp_loss_app").Tick(self);return end
        if allows(self,'dev_scaffolding') and self.extras.devAutoStart and not self.extras.splashSkipOnly then
            if not self.devAutoStart then self.devAutoStart=require('gmp_dev_autostart').new(self.bridge.G,function(line) self:_log('%s',line) end) end
            self.devAutoStart:Tick(self.clockNow,self:_devAutoStartReady())
        end
        if self.role == nil then self.hub:Advance(dt or 0) end
        if self.handoverRuntimeHold and self.handoverRuntime and self.handoverRuntime.control.failed then
            -- Keep the authenticated physical control lane observable, but do
            -- not reconnect or expire the old session after a failed transaction.
            if self.transport and self.transport.Poll then self.transport:Poll() end
        elseif self.state == "hosting" then self.host:Poll(); self.host:Tick(); self:_wireRunStats(); self.host:TickReservations(); if self.islandFlow then self.host:TickStuckPhases() end else self:_tickClient() end
        self:_tickHandover()
        if self.handoverF5 then self.handoverF5:Tick(self.clockNow) end   -- D56/F5 (Coder C)
        self:_enforceHandoverFailureHold()
        self:_tickSharedPause()
        self:_tickNormalDeparture()
        self:_tickCheckpointProbe()
        self:_tickNativeBindingProbe()
        self:_tickNativeXpReadCapture()
        self:_tickNativeSpawnProbe()
        self:_tickNativeTimerProbe()
        self:_tickNativeStateProbe()
        self:_tickProgressionRestoreCheck()
        if not self.nativeRestoreHold then self:_tickIslands() end
        self:_tickEnemies()
        self:_tickNativeOutcomes()
        self:_tickDevMigrationCycle()
        self:_tickDevDispatchProbe()
        self:_tickPresence()
        self:_tickLanes()
        self:_tickCheats()
        self:_tickLiveHud()
        self:_tickModCheck()
        self:_tickPlayerNotices()
        self:_tickRejoinCover()
        if self.role then
            if self.m3 then self.m3:Tick() end
            if self.s2 then self.s2:Tick() end
            self:_logPresence()
        end
    end
    self:_tickRunSync()
    self:_tickClientAttacks()
    self:_tickEndScreen()
    self:_tickRunExit()
    self:_tickHostDeath()
    self:_tickEndRun()
    self:_tickRejoinEndScreen()
    if self.extras.authCheck and self.state == "hosting" and not self.role then self:_tickAuthCheck(dt) end
    if not self.probesDone and self.env:Clock() >= self.extras.probeDelay and (self.extras.runtimeFacts or self.extras.s1Probe ~= "off") then
        self.probesDone = true
        self:RunProbes()
    end
end
function App:_tickNativeOutcomes()
    if not allows(self,'production_native') then return end
    local healthy=self.state=='hosting' or self.state=='client'
    local session=healthy and (self.host or self.client);local role=self.host and 'host' or 'client'
    local term=session and (session.authorityTerm or 1)
    local binding=self.nativeOutcomeBinding
    if binding and (binding.cleanupPending or binding.session~=session or binding.term~=term or binding.role~=role)then
        local closed,accepted=pcall(binding.adapter.close,'outcome_context_changed')
        if not closed or accepted~=true then
            self.nativeOutcomeUnavailable='native_outcome_cleanup_failed';pcall(binding.adapter.hold,self.nativeOutcomeUnavailable);return
        end
        binding.session.outcomeAdapter=nil;binding.session.outcomeStream=nil;binding.session.outcomeFrame=nil
        self.nativeOutcomeBinding=nil;binding=nil
    end
    if not session then return end
    if not binding then
        local loaded,factory=pcall(require,'gmp_native_outcome_factory')
        if not loaded or type(factory.Bind)~='function'then self.nativeOutcomeUnavailable='native_outcome_factory_unavailable';return end
        local ok,adapter,why=pcall(factory.Bind,self,session,role)
        if not ok or not adapter then self.nativeOutcomeUnavailable=why or 'native_outcome_binding_unavailable';return end
        local called,enabled,reason=pcall(session.EnableOutcomes,session,adapter)
        if not called then enabled=false;reason='native_outcome_enable_exception'end
        if not enabled then
            local cleaned,closed=pcall(adapter.close,reason)
            self.nativeOutcomeUnavailable=cleaned and closed==true and reason or 'native_outcome_cleanup_failed'
            if not cleaned or closed~=true then self.nativeOutcomeBinding={session=session,term=term,role=role,adapter=adapter,cleanupPending=true};pcall(adapter.hold,self.nativeOutcomeUnavailable)end
            return
        end
        binding={session=session,term=term,role=role,adapter=adapter};self.nativeOutcomeBinding=binding;self.nativeOutcomeUnavailable=nil
    end
    if binding.failed or role~='host'then return end
    if session.outcomeFrame then
        local retired,why,terminal=session:RetireOutcomeNetworkFrame()
        if terminal then binding.failed=why;pcall(binding.adapter.hold,why)end
        return
    end
    if type(binding.adapter.PeekOutcome)~='function'then return end
    local ok,batch,why=pcall(binding.adapter.PeekOutcome)
    if not ok then binding.failed='native_outcome_capture_exception';pcall(binding.adapter.hold,binding.failed);return end
    if batch then
        local published,reason=session:PublishOutcome(batch)
        if not published then binding.failed=reason or 'native_outcome_publication_failed';pcall(binding.adapter.hold,binding.failed)end
    elseif why and why~='empty'then binding.failed=why;pcall(binding.adapter.hold,why)end
end
function App:_tickProductionNativeLifecycle()
    if not allows(self,'production_native') then return end
    if not self.nativeStateWorld and self.bridge and type(self.bridge.G)=='table' then
        self.nativeStateWorld=require('gmp_world').new(self.bridge.G)
    end
    local report,why=require('gmp_native_lifecycle').Read(self,false)
    if not report then
        if self.nativePlayerSlices then self.nativePlayerSlices:CancelCapture() end
        if self.nativeHandoverCandidate then self.nativeHandoverCandidate:CancelCapture() end
        self.nativePlayerCaptureContext=nil;self.localNativeStateContext=nil
        self.nativePublishedContext=nil;self.nativePublicationContext=nil
        self.productionNativeContext=nil
        self.productionNativeObjects=nil
        if self.productionPresenceOwned and self.presenceDriver then
            self.presenceDriver=nil;self.productionPresenceOwned=nil
        end
        if self.productionNativeReason~=why then
            self.productionNativeReason=why;self:_log('NATIVERUNTIME read-only activation waiting: %s',tostring(why))
        end
        return
    end
    local objects=self.productionNativeObjects
    if self.productionNativeContext~=report.context or not objects or objects.session~=report.session
        or objects.lobbyId~=report.lobbyId or objects.generation~=report.generation
        or objects.world~=report.nativeWorld or objects.pawn~=report.pawn or objects.controller~=report.controller then
        if self.nativePlayerSlices then self.nativePlayerSlices:CancelCapture() end
        self.nativePlayerSlices=nil;self.nativePlayerCaptureContext=nil;self.localNativeStateContext=nil
        self.nativePublishedContext=nil;self.nativePublicationContext=nil
        self.productionNativeContext=report.context
        self.productionNativeObjects={session=report.session,lobbyId=report.lobbyId,generation=report.generation,
            world=report.nativeWorld,pawn=report.pawn,controller=report.controller}
    end
    self.productionNativeReason=nil
    -- Verified local pawn reads only. Marker/authority operations keep their
    -- separate coverage gate; PRESENCE/NATIVE_BINDING_PROBE are diagnostics.
    if not self.presenceDriver then
        local cfg=Presence.Defaults();cfg.enabled=true
        self.presenceDriver=Presence.Driver.new({cfg=cfg,world=report.world,
            getHost=function()return self.host end,getClient=function()return self.client end,
            log=function(...)self:_log(...)end})
        self.productionPresenceOwned=true
    end
end
function App:_nativeRuntimeCaptureAllowed()
    if allows(self,'dev_probes') then return self.extras.nativeBindingProbe==true end
    if not allows(self,'production_native') then return false end
    return require('gmp_native_lifecycle').Read(self,true)~=nil
end
function App:_tickNativeF6Arm()
    self:_tickNativeF6AutoPause()
    if not allows(self,'dev_probes') or not self.extras.nativeF6Experiment or self.handoverGame
        or self.handoverRuntimeHold or not self.nativeHandoverCandidate then return end
    local game=self.nativeHandoverCandidate
    local readiness=game:Readiness()
    if not readiness.ready then
        local reason=readiness.reason or 'native_state_incomplete'
        if self.nativeF6ScopeReason~=reason then self.nativeF6ScopeReason=reason;self:_log('NATIVEF6 scope waiting: %s',reason) end
        return
    end
    if self.role=='host' and not self:NativePlayerCheckpoint() then return end
    local ok,why=self:ArmHandover(game)
    if ok then self:_log('NATIVEF6 armed role=%s scope=retained_ordinary production=false',self.role)
    elseif self.nativeF6ArmReason~=why then self.nativeF6ArmReason=why;self:_log('NATIVEF6 waiting: %s',tostring(why)) end
end
function App:_tickNativeF6AutoPause()
    if not allows(self,'dev_probes') or not self.extras.nativeF6Experiment or not self.extras.nativeF6AutoPause
        or self.handoverRuntimeHold or not self.islandFlow then return end
    local session=self.role=='host' and self.host or self.client
    local islands=session and session.islands
    local world=self.islandFlow.world
    if not islands or islands.phase~='playing' or type(world.DiagnosticVisible)~='function'
        or world:DiagnosticVisible()~=true then return end
    local token=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island},':')
    if self.role=='client' then
        if self.nativeVisibleSent~=token and session.state=='joined' then
            if session:_send('NATIVE_WORLD_READY',{term=session.authorityTerm or 1,epoch=islands.epoch,island=islands.island}) then
                self.nativeVisibleSent=token
            end
        end
        return
    end
    if self.nativeAutoPaused==token then return end
    local connected=0
    for _,player in ipairs(session.roster:Snapshot()) do
        if player.conn=='connected' then
            connected=connected+1
            if player.key~=self.identity.key and (not session.nativeVisiblePeers or session.nativeVisiblePeers[player.key]~=token) then return end
        end
    end
    if connected<2 then return end
    local accepted=session:RequestPause(self.identity.key,true)
    if accepted then self.nativeAutoPaused=token;self:_log('NATIVEF6 automatic pause after all islands visible') end
end
-- D56/F5 (Coder C): from any window (the host's too), any player count, pausing by itself (gmp_handover_f5.lua).
-- The native handover experiment stays required: it is what restores the world on the new host.
function App:RequestHandoverTest(forced)
    if forced~=true or not allows(self,'dev_probes') then return false,'test_disabled' end
    if not self.extras.nativeF6Experiment then return false,'native_handover_experiment_off' end
    if not self.handoverF5 then
        local F5, why = Dev.Load('gmp_handover_f5')
        if not F5 then return false, 'handover_test_not_in_build:' .. tostring(why) end
        self.handoverF5 = F5.new(self)
    end
    return self.handoverF5:Press(self.clockNow)
end
function App:_tickNativeCheckpointPublication()
    local game=self.handoverGame
    if not allows(self,'dev_handover') and not self:_nativeRuntimeCaptureAllowed() then
        if game then game:CancelCapture() end
        self.nativePublishedContext=nil;self.nativePublicationContext=nil;return
    end
    if self.role~='host' or not game or game~=self.nativeHandoverCandidate then return end
    local session=self.host;local islands=session and session.islands;local pause=session and session.sharedPause
    if self.handoverRuntimeHold or not islands or islands.phase~='playing' or not pause or not pause.paused then
        game:CancelCapture();self.nativePublishedContext=nil;self.nativePublicationContext=nil;return
    end
    local context=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island,pause.revision},':')
    if self.nativePublishedContext==context then return end
    if self.nativePublicationRetryAt and self.clockNow<self.nativePublicationRetryAt then return end
    local readiness=game:Readiness()
    if not readiness.ready then
        local reason=tostring(readiness.reason or 'native_state_incomplete')
        if self.nativePublicationReadinessReason~=reason then
            self.nativePublicationReadinessReason=reason
            self:_log('NATIVECHECKPOINT waiting for supported state: %s',reason)
        end
        return
    end
    self.nativePublicationReadinessReason=nil
    if self.nativePublicationContext~=context then
        -- A new pause revision first needs all bounded personal captures.
        -- An already armed executor must not race that recapture on later pauses.
        if not self:NativePlayerCheckpoint() then return end
        game:CancelCapture()
        if game:SetPaused(true)~=true then return end
        local accepted,why=game:BeginCapture(islands.current,context)
        if not accepted then self:_log('NATIVECHECKPOINT refused: %s',tostring(why));return end
        self.nativePublicationContext=context
    end
    local accepted,state=game:CaptureStep(context)
    if accepted==nil then return end
    if not accepted then
        self.nativePublicationContext=nil
        self.nativePublicationRetryAt=self.clockNow+1
        self:_log('NATIVECHECKPOINT capture refused: %s detail=%s',tostring(state),tostring(game.failureDetail));return
    end
    local published,why=session:PublishCheckpoint(state)
    if published then
        self.nativePublishedContext=context
        self:_log('NATIVECHECKPOINT published current paused state')
    else self:_log('NATIVECHECKPOINT publication refused: %s',tostring(why)) end
    self.nativePublicationContext=nil
end
function App:_tickPeerNativeCapture()
    if not self:_nativeRuntimeCaptureAllowed() or self.handoverRuntimeHold then
        if self.nativePlayerSlices then self.nativePlayerSlices:CancelCapture() end
        self.nativePlayerCaptureContext=nil;return
    end
    local session=self.role=='host' and self.host or self.client
    local islands=session and session.islands;local pause=session and session.sharedPause
    if not islands or islands.phase~='playing' or not pause or not pause.paused then
        if self.nativePlayerSlices then self.nativePlayerSlices:CancelCapture() end
        self.nativePlayerCaptureContext=nil;return
    end
    local world=self.nativeStateWorld or (self.presenceDriver and self.presenceDriver.world)
    if not world or require('gmp_native_timers').new(world):_paused()~=true then return end
    if not self.nativePlayerSlices then
        local rows={}
        for _,name in ipairs({'player','inventory','loadout','abilities','progression','rewards'}) do
            rows[#rows+1]={name=name,adapter=require('gmp_native_'..name).new(world)}
        end
        self.nativePlayerSlices=require('gmp_native_slice_group').new(rows)
    end
    local context=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island,pause.revision},':')
    if self.nativePlayerCaptureContext==context then
        if self.role=='host' and self.nativeCheckpointPreviewContext~=context
            and (not self.nativeCheckpointPreviewAt or self.clockNow>=self.nativeCheckpointPreviewAt) then
            self.nativeCheckpointPreviewAt=self.clockNow+.5
            local players,why=self:NativePlayerCheckpoint()
            if players then
                self.nativeCheckpointPreviewContext=context
                self:_log('NATIVEPLAYERCHECKPOINT assembled players=%d complete=false',#players)
            elseif self.nativeCheckpointPreviewReason~=why then
                self.nativeCheckpointPreviewReason=why
                self:_log('NATIVEPLAYERCHECKPOINT waiting: %s',tostring(why))
            end
        end
        return
    end
    local ok,state=self.nativePlayerSlices:CaptureStep(context)
    if ok==nil then return end
    if not ok then
        self.nativePlayerCaptureContext=context
        self:_log('PEERNATIVESTATE capture refused: %s',tostring(state));return
    end
    if self.role=='client' then
        local accepted,why=session:QueueNativeState(state)
        if not accepted then
            if why~='transfer_busy' then self.nativePlayerCaptureContext=context end
            self:_log('PEERNATIVESTATE transfer refused: %s',tostring(why));return
        end
    end
    self.localNativeState=state;self.localNativeStateContext=context;self.nativePlayerCaptureContext=context
    self:_log('PEERNATIVESTATE captured player=%s slices=6 role=%s',self.identity.key,self.role)
    if self.islandFlow and not self.handoverGame then
        local game,why=self:BuildNativeHandoverGame()
        local readiness=game and game:Readiness()
        self:_log('NATIVESTATEFACTORY role=%s constructed=%s ready=%s scope=%s production=false reason=%s',
            self.role,tostring(game~=nil),tostring(readiness and readiness.ready or false),
            tostring(readiness and readiness.scope),tostring(why))
    end
end
function App:NativePlayerCheckpoint()
    local session=self.host;local islands=session and session.islands;local pause=session and session.sharedPause
    if (not allows(self,'dev_handover') and not self:_nativeRuntimeCaptureAllowed()) or self.role~='host' or not islands or islands.phase~='playing'
        or not pause or not pause.paused or not self.nativePlayerSlices then return nil,'native_players_not_ready' end
    local context=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island,pause.revision},':')
    if self.localNativeStateContext~=context or not self.localNativeState then return nil,'local_capture_pending' end
    local adapter=require('gmp_native_players').new(self.nativePlayerSlices,{key=self.identity.key,
        roster=function() return session:Players() end,
        peerState=function(key) return session:PeerNativeState(key) end})
    return adapter:CaptureCached(self.localNativeState)
end
function App:BuildNativeHandoverGame()
    if not allows(self,'dev_handover') or not self.identity or not self.islandFlow then return nil,'native_handover_not_available' end
    local world=self.nativeStateWorld or (self.presenceDriver and self.presenceDriver.world)
    if not world or not self.bridge or type(self.bridge.G)~='table' then return nil,'missing_native_world' end
    local function context()
        local session=self.role=='host' and self.host or self.client
        local islands=session and session.islands
        if not islands or islands.phase~='playing' then return nil end
        return tostring(islands.epoch)..':'..tostring(islands.island)
    end
    if not context() then return nil,'island_not_playing' end
    -- Reconstruction adopts into private storage first. Live session authority
    -- is bound by _activateHandover only after the transport role commits.
    local registry=require('gmp_enemies').new()
    local capture=require('gmp_enemy_capture').new(self.bridge.G,{token=context,
        registry=function() return registry end})
    local backend=require('gmp_native_enemy_backend').new(world,capture,{token=context,
        import=function(imported) registry=imported;return true end,
        sourceCapture=function() return self.role=='host' and self.enemyCapture or nil end})
    local function players()
        if self.role=='host' then return self:NativePlayerCheckpoint() end
        return self.nativeCheckpointPlayers,nil
    end
    local game,domains=require('gmp_native_state_factory').new({world=world,pauseWorld=self.islandFlow.world,
        enemyBackend=backend,context=context,key=self.identity.key,players=players,
        experimentalOrdinary=self.extras and self.extras.nativeF6Experiment==true})
    self.nativeHandoverCandidate=game;self.nativeHandoverDomains=domains
    return game
end


-- ===================================================================================================================
-- M3 network roles: the SAME Host/Client session classes as the offline suite, over the relay-backed transport, with the dev provider.
-- Only reachable with MODE=dev + AUTH_MODE=dev + a role (checked in Boot). No gameplay, no game reads.
-- Dev keys are printed in full (they are test names); real SteamIDs are ALWAYS masked (first 4 + last 4), also in roster signatures.
local function peerLabel(p) return string.format("%d:%s:%s:%s", p.slot, tostring(p.key):match("^dev:") and p.key or Identity.Mask(p.key), p.color, p.conn) end

function App:_newRelay()
    if self.extras.devSteamSocketsTest then
        local slot=self.extras.devPlayerSlot
        if not allows(self,'dev_roles') or self.cfg.AUTH_MODE~='dev' or self.roleAuto
            or type(slot)~='number' or slot%1~=0 or slot<1 or slot>4
            or self.extras.devName~=('qa_player'..slot)
            or not self:_devRoleOk(slot) then return nil,'dev_socket_profile_invalid' end
        local loaded,module=pcall(require,'gmp_dev_steam_socket_transport')
        if not loaded or type(module)~='table' or type(module.new)~='function' then return nil,'dev_socket_transport_unavailable' end
        local ok,transport=pcall(module.new,{slot=slot,hostSlot=self.devSocketHostSlot or 1,role=self.role,dir=self.netDir,fs=self.fs,
            clock=function()return self.clockNow end,rng=self.rng,verifySwitch=function(role,term,commit)
                local runtime=self.handoverRuntime;local driver=runtime and runtime.driver
                return driver and driver.options.verifyCommit(commit)==true and term==commit.term
                    and self.identity and role==(commit.hostKey==self.identity.key and 'host' or 'client') or false
            end})
        if not ok or not transport or transport.HandoverControlAttribution~=true then return nil,'dev_socket_transport_invalid' end
        return transport
    end
    return RelayTransport.new({ role = self.role, dir = self.netDir, clock = function() return self.clockNow end, rng = self.rng, fs = self.fs,
        log = function(...) self.env:Log("relay: " .. tostring((...)), select(2, ...)) end })
end

function App:_startNetSession()
    local env, cfg = self.env, self.cfg
    local devName = self.roleAuto and ("m3_" .. self.role) or self.extras.devName     -- auto roles: the name is part of the role hand-off, not of the config
    local id, why = self.bridge:LocalIdentity(cfg.MODE, devName)
    if not id then
        self.state, self.reason = "no_identity", why
        if not self.noIdentityLogged then self.noIdentityLogged = true; self:_log("session NOT started: no local identity (%s)", tostring(why)) end     -- retries stay quiet
        return self.state
    end
    -- Test 14: the app clock is never reset by a new session (it was set to 0 here, so every timer of the previous
    -- session, e.g. the presence driver's next send at t=224, held the new session silent until it caught up).
    self.identity, self.clockNow = id, self.clockNow or 0
    self:_resetSessionScoped()
    self.clockFn = function() return self.clockNow end
    local transport,transportError=self:_newRelay()
    if not transport then self.state,self.reason='config_error',transportError;self:_log('network transport refused: %s',tostring(transportError));return self.state end
    self.transport=transport
    if cfg.AUTH_MODE == "steam" then
        self.authProvider = self.bridge.authProvider                  -- real Steam provider (nil => host refuses remote peers, client cannot authenticate: fail closed)
        if not self.authProvider then self:_log("no native Steam auth provider available: remote peers cannot be authenticated") end
    else
        self.authProvider = DevAuth.new({ cfg = cfg, localKey = id.key })
    end
    local name = id.isDev and id.value or ("Player" .. id.value:sub(-4))       -- display label only; never the SteamID itself (logs, peers)
    local tag = id.isDev and " [DEV IDENTITY]" or ""
    if self.role == "host" then
        local host, herr = Host.new({ cfg = cfg, transport = self.transport, clock = self.clockFn, rng = self.rng, identity = id, name = name,
            log = function(m) env:Log("host: %s", m) end, authProvider = self.authProvider })
        if not host then self.state, self.reason = "no_identity", herr; self:_log("host refused: %s", tostring(herr)); return self.state end
        local started, serr = host:Start()
        if not started then self.state, self.reason = "config_error", serr; self:_log("host start failed: %s", tostring(serr)); return self.state end
        self.host, self.state = host, "hosting"
        local me = host:GetPlayer(id.key)
        self:_log("hosting over relay: identity=%s%s name=%s slot=%d color=%s transport=%s", Identity.Mask(id.key), tag, name, me.slot, me.color, self.transport:Name())
    else
        self:_makeClient()
        self.state = "client"
        local ok, err = self.client:Connect("relay")
        self:_log("client over relay: identity=%s%s transport=%s connect=%s", Identity.Mask(id.key), tag, self.transport:Name(), tostring(ok or err))
    end
    if self.extras.m3Script then
        self.m3 = M3.new({ role = self.role, app = self, log = function(...) env:Log(...) end, fs = self.fs, netDir = self.netDir })
        self:_log("M3 scenario driver armed (%d steps)", #self.m3.steps)
    end
    if self.extras.s2Script and Mode.Allows(cfg.MODE, "production_diagnostics") and cfg.AUTH_MODE == "steam" then
        self.s2 = S2.new({ role = self.role, app = self, log = function(...) env:Log(...) end, fs = self.fs, netDir = self.netDir })
        self:_log("S2 same-account scenario driver armed (%d steps)", #self.s2.steps)
    end
    self:_initPresence()
    return self.state
end

function App:_makeClient()
    local env = self.env
    local c, err = Client.new({ cfg = self.cfg, transport = self.transport, clock = self.clockFn, rng = self.rng, identity = self.identity,
        name = self.identity.value, authProvider = self.authProvider, log = function(m) env:Log("client: %s", m) end,
        -- D52: the player chose "Wait for the next game" (the connection's join operation carries it)
        wait = self.steamConnection ~= nil and self.steamConnection.pending ~= nil and self.steamConnection.pending.wait == true })
    assert(c, err)
    if self.client then c.resume = self.client.resume; c.wantWait = c.wantWait or self.client.wantWait end          -- keep what the host told us (token/slot/colour) across a fresh Client object
    self.client = c
    return c
end
-- Dormant until the trusted handover executor invokes activation. Never call
-- _startNetSession: auto-role naming would incorrectly change player identity.
function App:_activateHandover(role,state,commit)
    local formerHost,formerClient=self.host,self.client
    local formerSession=formerHost or formerClient
    if allows(self,'production_native') and self.gracefulControl then
        local context=self.steamAuthority and self.steamAuthority.context
        if not context or not self.authProvider or type(self.authProvider.UseRetention)~='function' then return false,'native_retention_missing' end
        local retained,why=self.authProvider:UseRetention{generation=context.generation,session=commit.session,term=commit.term,nonce=commit.nonce}
        if retained~=true then return false,why end
    end
    local ok,session=require('gmp_session_activation').Activate({cfg=self.steamSessionCfg or self.cfg,transport=self.transport,
        clock=self.clockFn,rng=self.rng,identity=self.identity,name=self.identity.value,
        authProvider=self.authProvider,address=self.steamAuthority and commit.hostKey:match('^steam:(%d+)$') or nil,pauseHostOnly=formerSession and formerSession.sharedPause
            and formerSession.sharedPause.hostOnly,
        log=function(line) self:_log('%s',line) end},role,state,commit)
    if not ok then return false,session end
    if formerHost and type(formerHost.RetireAuthentication)=='function' then formerHost:RetireAuthentication() end
    if formerClient and type(formerClient._cancelTicket)=='function' then formerClient:_cancelTicket() end
    -- Keep native gameplay held even if a later authority binding fails.
    self.handoverRuntimeHold=true
    self.role=role;self.host=role=='host' and session or nil;self.client=role=='client' and session or nil
    self.autoReconnect=role=='client'
    -- a new Steam host keeps naming players by their persona names
    if role=='host' and self.steamAuthority and type(session.SetNameResolver)=='function' then
        session:SetNameResolver(App.SteamNameResolver(self.bridge and self.bridge.G),true)
    end
    if self.steamAuthority and role=='client' then self.steamAddress=commit.hostKey:match('^steam:(%d+)$') end
    self.state=role=='host' and 'hosting' or 'client';self.reconnectAt=nil
    -- The world and its guarded native hooks survive migration; presentation
    -- widgets and pending dumps belong to the replaced driver.
    if self.pauseDriver and type(self.pauseDriver.Dispose)=='function' then
        local disposed,problem=pcall(self.pauseDriver.Dispose,self.pauseDriver)
        if not disposed then self:_log('Pause driver cleanup unavailable: %s',tostring(problem):sub(1,300)) end
    end
    self.pauseDriver=nil;self.islandSignature=nil
    if self.islandFlow then
        self.islandFlow.options.role=role
        self.islandFlow.options.session=function() return self.role=='host' and self.host or self.client end
        self.islandFlow.started={};self.islandFlow.released={};self.islandFlow.readySent=nil
    end
    -- Existing capture hooks are retained, but must resolve the new session.
    if self.enemyCapture then
        local o=self.enemyCapture.options
        if o then
            o.active=function() return self.role=='host' and self.host and self.host.islands.phase=='playing' end
            o.token=function() return self.host.islands.epoch..':'..self.host.islands.island end
            o.begin=function() self.host:BeginEnemyIsland() end
            o.registry=function() return self.host.enemies end
        end
    end
    if role=='host' then
        if not self.enemyCapture then
            local capture,why=self:_newEnemyCapture()
            if not capture then return false,'enemy_registry_activation:'..tostring(why) end
            self.enemyCapture=capture
        end
        local rebound,why
        if self.handoverGame and type(self.handoverGame.BindEnemyAuthority)=='function' then
            rebound,why=self.handoverGame:BindEnemyAuthority(self.enemyCapture,session.enemies,
                function(registry) session.enemies=registry;return true end)
        else rebound,why=self.enemyCapture:RetargetRegistry(session.enemies) end
        if rebound~=true then return false,'enemy_registry_activation:'..tostring(why) end
        self.extras=self.extras or {};self.extras.hostEnemyCapture=true
    end
    return true
end
-- Production arms normal departure only; forced F6 remains development-only.
-- Concrete native domain adapters must independently report complete readiness.
function App:ArmProductionDeparture(game)
    if not allows(self,'production_native') or self.cfg.AUTH_MODE~='steam' or not game
        or type(game.Readiness)~='function' or type(game.Prepare)~='function'then return false,'native_state_incomplete'end
    local read,coverage=pcall(game.Readiness,game)
    if not read or type(coverage)~='table' or coverage.ready~=true then return false,'native_state_incomplete'end
    local report,reason=require('gmp_native_lifecycle').Read(self,true)
    if not report then return false,reason end
    local session=report.session
    local function paused()return self:_testPhysicalPause()==true and session.sharedPause and session.sharedPause.paused==true end
    local function ready()
        local live=require('gmp_native_lifecycle').Read(self,true)
        local ok,current=pcall(game.Readiness,game)
        return live and live.session==session and ok and type(current)=='table' and current.ready==true
    end
    local options={productionNative=true,paused=paused,ready=ready,allowGracefulRuntime=true,prepare=function(state)
        if not ready()then return false,'native_state_incomplete'end
        return game:Prepare(state)
    end}
    local accepted,why=session:EnableDeparture(options)
    if accepted~=true then return false,why end
    self.handoverGame=game;return true
end
function App:ArmHandover(game)
    if allows(self,'production_native') then return self:ArmProductionDeparture(game)end
    if not allows(self,'dev_handover') or not game or type(game.Readiness)~='function'
        or not game:Readiness().ready then return false,'native_state_incomplete' end
    local session=self.role=='host' and self.host or self.client;if not session then return false,'missing_session' end
    local ok,why
    if self.role=='host' then
        ok,why=session:EnableForcedHandover({ready=function()
            if not game:Readiness().ready then return false end
            if game~=self.nativeHandoverCandidate then return true end
            local islands=session.islands;local pause=session.sharedPause
            if not islands or islands.phase~='playing' or not pause or not pause.paused then return false end
            local context=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island,pause.revision},':')
            return self.nativePublishedContext==context
        end})
    else ok,why=session:EnableForcedHandover({prepare=function(state)
        local players=require('gmp_native_slice_group').Detach(state.players)
        if not players then return false,'invalid_native_players' end
        local accepted,reason=game:Prepare(state)
        if accepted then self.nativeCheckpointPlayers=players end
        return accepted,reason
    end}) end
    if not ok then return false,why end
    self.handoverGame=game
    local function paused() return self:_testPhysicalPause()==true end
    local prepare=function(state)
        local players=require('gmp_native_slice_group').Detach(state.players)
        if not players then return false,'invalid_native_players' end
        local accepted,reason=game:Prepare(state)
        if accepted then self.nativeCheckpointPlayers=players end
        return accepted,reason
    end
    if self.role=='host' then
        session:EnableDeparture{paused=paused,ready=function() return game:Readiness().ready end,
            prepare=prepare,allowGracefulRuntime=true}
    else session:EnableDeparture{paused=paused} end
    return true
end
function App:BeginHostLossRecovery()
 return require('gmp_loss_app').Begin(self)
end
function App:ClaimHostLoss(request)
 if not self.lossRecovery then return false,'loss_offer_unavailable' end
 return self.lossRecovery:Claim(request)
end
function App:HostLossSnapshot()
 local loss=self.lossRecovery
 if not loss then return nil end
 return {authenticated=not loss.failed,active=loss.phase=='offered',paused=self:_testPhysicalPause()==true,
  sid=loss.o.sid,term=loss.o.term,revision=1,me=self.identity.key,eligible=loss.d.eligible[self.identity.key]==true,
  winner=loss.winner,coordinator=loss.coordinator,phase=loss.phase,failure=loss.failed}
end
function App:RequestNormalDeparture()
    if self.role~='host' or not self.host or not self.handoverGame or self.handoverRuntimeHold then
        return false,'normal_departure_unavailable'
    end
    local members=0
    for _,player in ipairs(self.host.roster:Snapshot()) do if player.conn=='connected' then members=members+1 end end
    if allows(self,'dev_handover') then
        if members<2 then return false,'normal_native_participant_count_unsupported'end   -- D54/D59: any count
    elseif allows(self,'production_native') and self.cfg.AUTH_MODE=='steam' then
        if members<2 or members>self.cfg.MAX_PLAYERS then return false,'normal_native_participant_count_unsupported'end
        local report,reason=require('gmp_native_lifecycle').Read(self,true)
        if not report then return false,reason end
    else return false,'normal_native_participant_count_unsupported'end
    local ready=self.handoverGame:Readiness()
    if not ready.ready then return false,ready.reason or 'native_state_incomplete' end
    local paused
    if allows(self,'production_native') then paused=self.host:RequestPause(self.identity.key,true)else paused=self:RequestSharedPause(true)end
    if not paused then return false,'departure_pause_unavailable' end
    self.normalDeparturePending=true;return true
end
function App:_tickNormalDeparture()
    if not self.normalDeparturePending or self.handoverRuntimeHold or self.role~='host' or not self.host then return end
    if not self.host:CheckpointReady() then return end
    if self.handoverGame==self.nativeHandoverCandidate then
        local session=self.host;local islands=session.islands;local pause=session.sharedPause
        if not islands or not pause then return end
        local token=table.concat({session.sid or '',session.authorityTerm or 1,islands.epoch,islands.island,pause.revision},':')
        if self.nativePublishedContext~=token then return end
    end
    local ok,why=self.host:BeginDeparture()
    if ok then self.normalDeparturePending=nil;self.normalDepartureOwner=self.identity.key
    elseif self.normalDepartureError~=why then self.normalDepartureError=why;self:_log('Normal departure waiting: %s',tostring(why)) end
end
-- D52 (test 13): Esc > End run always works. The host hands over first only when a handover can start (dev: two
-- players and a capture executor; production: the native lifecycle) and falls back to ending the run for everyone
-- (its own menu exit returns the run to the lobby) when it cannot, or when the handover has not started
-- END_RUN_HANDOVER_SECONDS later. A client leaves the run to the menu (the host holds its slot). The world is unpaused
-- first (a paused world can hold the game's own exit). Logs "END RUN ...".
-- D59: the players have DepartureCoordinator.ANSWER_SECONDS (15 s) to answer "Become the new host?"; this covers
-- the pause and checkpoint before the question as well.
App.END_RUN_HANDOVER_SECONDS = 30
-- D51 (revised 2026-10-14): a client's End Run in a multiplayer run opens the game's own end screen, as the game's
-- End Run confirm does (WBP_HUD 2337: hide the Esc menu, Pause(true), Death(true)), and keeps the session: the end
-- screen's Retry (labelled Rejoin, gmp_end_screen.lua) reloads the game world and the client re-enters the host's
-- current run with its slot; Quit closes the session at the menu holding the slot (D52). Single player and the host are
-- untouched. END_SCREEN_REJOIN_SECONDS: how long a closed world may take to come back (Retry) before the session is
-- let go as at the menu.
App.END_SCREEN_REJOIN_SECONDS = 20
function App:_endScreenActive()
    return self.role == 'client' and type(self.client) == 'table' and type(self.client.State) == 'function'
        and self.client:State() == 'joined' or false
end
function App:_endRunToEndScreen()
    local world = self.islandFlow and self.islandFlow.world
    local okPawn, _, pawn = pcall(function() return world:LocalWorldPawn() end)
    if not okPawn or not pawn then return false, 'no_pawn' end
    local Exit = require('gmp_lobby_menu_exit')
    if not Exit.Callable(pawn.Death) then return false, 'no_death_event' end
    local hud = pawn.HUD
    pcall(function()
        if hud and hud:IsValid() then
            if hud.pause_menu then hud.pause_menu:SetVisibility(2) end
            if hud.pausemenu_overlay then hud.pausemenu_overlay:SetVisibility(2) end
        end
    end)
    if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
    if Exit.Callable(pawn.Pause) then pcall(pawn.Pause, pawn, true, false, true, true) end
    local ok, why = pcall(pawn.Death, pawn, true)
    if not ok then return false, 'death_failed:' .. tostring(why):sub(1, 120) end
    self.endScreenAt, self.endScreenGoneAt = self.clockNow or 0, nil
    self:_log('END RUN: client on the end screen (session kept; Retry rejoins, Quit leaves holding the slot)')
    return true
end
function App:_mainMenuVisible()
    return require('gmp_end_screen').MainMenuVisible(self.bridge and self.bridge.G)
end
function App:_tickRejoinEndScreen()
    -- Coder C (host death): a host on the game's own death screen in a run keeps playing as a ghost-less spectator;
    -- its Retry is disabled so it can never restart the run under the others.
    if self.role == 'host' and self.hostGameDeath and type(self.host) == 'table' and type(self.host.roster) == 'table'
        and self.host.roster.phase == 'run' and self.bridge and self.bridge.G then
        self.hostDeathScreen = self.hostDeathScreen or require('gmp_end_screen').new({ G = self.bridge.G, mode = 'host',
            active = function() return self.hostGameDeath == true end, log = function(line) self:_log('%s', line) end })
        self.hostDeathScreen:Tick(self.clockNow or 0)
    end
    if self:_endScreenActive() and self.bridge and self.bridge.G then
        self.rejoinLabel = self.rejoinLabel or require('gmp_end_screen').new({ G = self.bridge.G,
            active = function() return self:_endScreenActive() end, log = function(line) self:_log('%s', line) end })
        local shown = self.rejoinLabel:Tick(self.clockNow or 0)
        -- Coder C (client death, 2026-10-15): the game's own end screen after the client died holds the session too,
        -- so its Retry (Rejoin) takes the client back into the run (like End Run, D51); the run goes on for the others.
        if shown and not self.endScreenAt then
            self.endScreenAt, self.endScreenGoneAt = self.clockNow or 0, nil
            self:_log('END SCREEN: the client died; holding the session for a Rejoin')
        end
    end
    if not self.endScreenAt then return end
    if not self:_endScreenActive() then self.endScreenAt, self.endScreenGoneAt = nil, nil; return end
    if self.endScreenGoneAt then
        if self.islandHadWorld then
            self.endScreenAt, self.endScreenGoneAt = nil, nil
            self:_log('END SCREEN: Rejoin: back in the host run')
        elseif self:_mainMenuVisible() or (self.clockNow or 0) - self.endScreenGoneAt >= App.END_SCREEN_REJOIN_SECONDS then
            self.endScreenAt, self.endScreenGoneAt = nil, nil
            self:_log('END SCREEN: at the menu; leaving the run holding the slot')
            self:_quitRunToMenu()
        end
    end
end
-- Host death (Coder C; user 2026-10-15: "I did not want the host to die"; the takeover "is meant so that if the host
-- is kicked, or crashes, the client can take over"). A host dying in game is like any player dying: with the shared
-- lives (D32, SHARED_LIVES) it is a ghost a teammate revives, and with no lives left it stays a ghost. Never a host
-- handover (D59 is only the host's own End Run; a crash or kick is the host-loss takeover) and never the end of the
-- run, unless EVERY player is down (the shared lives ended): then the run returns to the lobby and everyone gets the
-- end screen together. A death outside the shared lives (the game's own death screen) is logged once and the run goes
-- on; hostGameDeath keeps the host's end-screen Retry from restarting the run under the others (gmp_end_screen).
function App:_tickHostDeath()
    if self.role ~= 'host' or type(self.host) ~= 'table' or type(self.host.roster) ~= 'table' or self.host.roster.phase ~= 'run' then return end
    local sync = self.runSync
    local okStatus, status = false, nil
    if type(sync) == 'table' and type(sync.Status) == 'function' then okStatus, status = pcall(sync.Status, sync) end
    local lives = okStatus and type(status) == 'table' and type(status.lives) == 'table' and status.lives or nil
    if lives and lives.ended == true then
        self:_log('EVERYONE DOWN: the shared lives ended; everyone gets the end screen together')
        local returned, generation = self.host:ReturnToLobby()
        if returned then self:_log('EVERYONE DOWN: LOBBY_RETURN runGeneration=%d', generation) end
        return
    end
    local world = self.islandFlow and self.islandFlow.world
    if type(world) ~= 'table' or type(world.LocalWorldPawn) ~= 'function' then return end
    local ok, dead = pcall(function() local _, pawn = world:LocalWorldPawn(); return pawn ~= nil and pawn.PlayerIsDead == true end)
    if not ok or not dead or self.hostGameDeath then return end
    self.hostGameDeath = true
    self:_log('HOST DIED (the game death screen, outside the shared lives): the run goes on; no handover, no end')
end
-- No freeze (coordinator, test.3 "end run freezes game"): a handover held after a failure is let go after
-- HANDOVER_FAILED_RELEASE_SECONDS, and one that never finishes after HANDOVER_MAX_SECONDS: the hold and the shared
-- pause are released and the run ends here (the host returns it to the lobby: everyone's end screen; then the menu exit).
App.HANDOVER_FAILED_RELEASE_SECONDS = 20
App.HANDOVER_MAX_SECONDS = 90
function App:_releaseHeldHandover(why)
    self:_log('HANDOVER released (%s): unpaused; the run ends here (end screen or menu)', tostring(why))
    local session = self.role == 'host' and self.host or self.client
    self.handoverRuntime, self.handoverRuntimeHold, self.handoverReleaseApplied, self.handoverGame = nil, nil, nil, nil
    self.handoverStartedAt, self.handoverFailedAt = nil, nil
    if type(session) == 'table' then session.handoverHold = nil end
    local world = self.islandFlow and self.islandFlow.world
    if type(world) == 'table' then
        if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
        if type(world.SetPauseNotice) == 'function' then pcall(world.SetPauseNotice, world, nil) end
    end
    if self.role == 'host' and type(session) == 'table' then
        if type(session.sharedPause) == 'table' and type(session.sharedPause.ReleaseHandover) == 'function' then
            pcall(session.sharedPause.ReleaseHandover, session.sharedPause, self.identity and self.identity.key)
        end
        if type(session.PublishPause) == 'function' then pcall(session.PublishPause, session) end
        if type(session.roster) == 'table' and session.roster.phase == 'run' and type(session.ReturnToLobby) == 'function' then
            pcall(session.ReturnToLobby, session)
        end
    end
    local ok, exiting = pcall(self._endRunToMenu, self)
    if not ok then self:_log('HANDOVER released: menu exit unavailable (%s); the end screen Quit leaves', tostring(exiting):sub(1, 160)) end
    return ok and exiting
end
function App:RequestEndRun()
    self:_log('END RUN requested role=%s', tostring(self.role))
    if self.role == 'client' and self:_endScreenActive() then
        local ok, why = self:_endRunToEndScreen()
        if ok then return true end
        self:_log('END RUN: end screen unavailable (%s); leaving through the menu', tostring(why))
    end
    if self.role == 'host' and self.host then
        local ok, why = false, 'no_handover'
        if allows(self, 'dev_handover') or allows(self, 'production_native') then
            local called, accepted, reason = pcall(self.RequestNormalDeparture, self)
            ok, why = called and accepted == true, called and reason or 'departure_error'
        end
        if ok then
            self.endRunHandoverAt = self.clockNow or 0
            self:_log('END RUN: handing the host over first'); return true
        end
        self:_log('END RUN: ending the run for everyone (%s)', tostring(why))
    end
    return self:_endRunToMenu()
end
function App:_endRunToMenu()
    if self.endRunExit and self.endRunExit.phase == 'pending' then return true end
    local world = self.islandFlow and self.islandFlow.world
    if type(world) == 'table' then
        if type(world.SetWaiting) == 'function' then pcall(world.SetWaiting, world, false) end
        if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
    end
    local factory = self.menuExitFactory or require('gmp_lobby_menu_exit').new
    self.endRunExit = factory{ G = self.bridge and self.bridge.G or {}, world = function() return self.islandFlow and self.islandFlow.world end,
        log = function(line) self:_log('%s', line) end }
    return self.endRunExit:Request('end_run', self.clockNow or 0)
end
-- D59: nobody became host: the run ends for everyone. The host returns the run to the lobby (LOBBY_RETURN: every
-- client gets its host-credited end screen, W9) and the host gets the game's own end screen too; the join list keeps
-- everyone (D20 holds), so anyone can rejoin.
function App:_endRunForEveryone()
    self.endRunHandoverAt = nil
    if self.host and self.host.roster.phase == 'run' then
        local returned, generation = self.host:ReturnToLobby()
        if returned then self:_log('END RUN: nobody became host; LOBBY_RETURN runGeneration=%d', generation) end
    end
    -- the declined offer goes out once more (inactive), so every client's question closes
    self.host.departureBroadcastAt = nil; pcall(self.host.BroadcastDeparture, self.host)
    self.host.departure = nil
    local world = self.islandFlow and self.islandFlow.world
    if type(world) == 'table' and type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
    local ok = self:_endRunToEndScreen()
    if not ok then return self:_endRunToMenu() end
    return true
end
function App:_tickEndRun()
    local d = self.endRunHandoverAt and self.role == 'host' and self.host and self.host.departure
    if d and d.phase == 'declined' then return self:_endRunForEveryone() end
    if self.endRunHandoverAt then
        if not self.normalDeparturePending then self.endRunHandoverAt = nil
        elseif (self.clockNow or 0) - self.endRunHandoverAt >= App.END_RUN_HANDOVER_SECONDS then
            local why = self.normalDepartureError or 'waiting_for_players'
            self.endRunHandoverAt = nil; pcall(self.CancelNormalDeparture, self)
            self:_log('END RUN: the host handover did not start in %ds (%s); ending the run for everyone', App.END_RUN_HANDOVER_SECONDS, tostring(why))
            self:_endRunToMenu()
        end
    end
    if self.endRunExit then pcall(self.endRunExit.Tick, self.endRunExit, self.clockNow or 0) end
end
function App:NormalDepartureSnapshot()
    local session=self.role=='host' and self.host or self.client
    return session and session:DepartureState() or nil
end
function App:ClaimNormalDeparture(request)
    if self.role~='client' or not self.client then return false,'client_claim_only' end
    return self.client:ClaimDeparture(request)
end
function App:CancelNormalDeparture()
    if self.role~='host' or not self.host then return false,'host_cancel_only' end
    if self.normalDeparturePending then self.normalDeparturePending=nil;return true end
    return self.host:CancelDeparture()
end
function App:BindNormalDepartureExit(callback)
    if type(callback)~='function' then return false,'verified_menu_exit_required' end
    self.normalDepartureExit=callback;return true
end
function App:_enforceHandoverFailureHold()
    local control=self.handoverRuntime and self.handoverRuntime.control
    if not self.handoverRuntimeHold or not control or not control.failed then return end
    if self.steamAuthority and self.gracefulControl then pcall(self.steamAuthority.HoldGameplay,self.steamAuthority,self.gracefulControl.commit)end
    local world=self.islandFlow and self.islandFlow.world
    local ok,accepted,reason=pcall(function()
        if not world or type(world.SetSharedPaused)~='function' then return false,'missing_pause_world' end
        return world:SetSharedPaused(true)
    end)
    local problem=(not ok and tostring(accepted)) or (accepted~=true and tostring(reason)) or nil
    if not self.handoverPhysicalHoldReported or problem~=self.handoverPhysicalHoldError then
        self.handoverPhysicalHoldReported=true
        self.handoverPhysicalHoldError=problem
        self:_log('Handover physical hold: %s',problem and ('failed:'..problem):sub(1,300) or 'verified')
    end
    if world and type(world.SetPauseNotice)=='function' then
        pcall(world.SetPauseNotice,world,problem and 'State restore failed. Pause could not be applied.' or 'State restore failed. Game held paused.')
    end
end
function App:_tickHandover()
    if not self.handoverRuntime then self.handoverStartedAt,self.handoverFailedAt=nil,nil end
    if self.handoverRuntime then
        self.handoverRuntime:Tick(self.clockNow)
        local control=self.handoverRuntime.control
        -- Coder C (no freeze): the time limits of a held or unfinished handover (App.HANDOVER_*_SECONDS)
        local now=self.clockNow or 0
        self.handoverStartedAt=self.handoverStartedAt or now
        if control.failed then
            self.handoverFailedAt=self.handoverFailedAt or now
            if now-self.handoverFailedAt>=App.HANDOVER_FAILED_RELEASE_SECONDS then
                return self:_releaseHeldHandover('failed '..tostring(control.failed)..':'..tostring(control.failureReason))
            end
        elseif control.phase~='finished' and now-self.handoverStartedAt>=App.HANDOVER_MAX_SECONDS then
            return self:_releaseHeldHandover('not finished in '..App.HANDOVER_MAX_SECONDS..' s')
        end
        if self.handoverRuntimeHold and not control.failed and control.phase~='finished' then
            local world=self.islandFlow and self.islandFlow.world
            if world and type(world.SetPauseNotice)=='function' then
                local driver=self.handoverRuntime.driver
                local status={active=true,phase=control.phase,restorePhase=driver and driver.phase,
                    role=self.role,activated=control.localActivated==true}
                local ok,text=pcall(function() return require('gmp_handover_presentation').Format(status) end)
                if ok and text then pcall(world.SetPauseNotice,world,text) end
            end
        end
        if control.failed then
            self.handoverRuntimeHold=true
            local session=self.role=='host' and self.host or self.client
            if session then session.handoverHold=true end
        end
        if control.failed and self.handoverError~=control.failed..':'..tostring(control.failureReason) then
            self.handoverError=control.failed..':'..tostring(control.failureReason)
            self:_log('Handover runtime held: %s',self.handoverError)
            if self.handoverGame and self.handoverGame.failureDetail then
                self:_log('Handover native failure detail: %s',self.handoverGame.failureDetail)
            end
        end
        if not control.failed and not self.handoverReleaseApplied and (self.handoverRuntime.control.phase=='released'
            or self.handoverRuntime.control.phase=='finished') then
            self.handoverReleaseApplied=true
            self.handoverRuntimeHold=nil
            local session=self.role=='host' and self.host or self.client
            session.handoverHold=nil
            if self.role=='host' then
                session.sharedPause:ReleaseHandover(self.identity.key);session:PublishPause()
            end
        end
        if not control.failed and control.phase=='finished' then
            if self.authProvider and type(self.authProvider.ClearRetention)=='function' then self.authProvider:ClearRetention() end
            self.handoverRuntime=nil;self.handoverReleaseApplied=nil
            self.nativePublishedContext=nil;self.nativePublicationContext=nil
            self.nativePlayerCaptureContext=nil;self.localNativeState=nil;self.localNativeStateContext=nil
            self.nativeCheckpointPlayers=nil;self.nativeCheckpointPreviewContext=nil
            self.handoverGame=nil
            self:_log('Handover cycle finished; replacement session awaiting fresh checkpoint')
            if self.normalDepartureExitPending then
                self.normalDepartureExitPending=nil
                local callback=self.normalDepartureExit
                if self.role=='client' and type(callback)=='function' then
                    -- Native menu exit is supplied by its verified UI adapter.
                    -- It cannot run before every endpoint's restore/activate/release.
                    local ok,accepted,reason=pcall(callback)
                    if not ok or accepted~=true then self:_log('Departure menu exit unavailable: %s',tostring(ok and reason or accepted))
                    elseif self.client then self.client:Leave('host_departed') end
                else self:_log('Departure completed; verified menu exit is unavailable') end
            end
        end
        return
    end
    if not self.handoverGame then return end
    local commit,state
    if self.role=='host' and self.host:HandoverStageReady() then
        commit=self.host.handoverCommit
        state=commit.kind=='graceful' and self.host.departure.selectedState or self.host.handoverArbiter:Snapshot()
    elseif self.role=='client' and self.client.handoverStage and self.client.handoverStage.ready then
        commit=self.client.handoverStage.commit;state=self.client.handoverStage.state
    end
    if not commit then return end
    local controlTransport
    if allows(self,'production_native') then
        if not self.steamAuthority or not self:_trustedGracefulStage(commit) then return end
        local read,coverage=pcall(self.handoverGame.Readiness,self.handoverGame)
        if not read or type(coverage)~='table' or coverage.ready~=true then return end
        if not self.gracefulControl then
            local context=self.steamAuthority.context
            local lane,reason=require('gmp_graceful_control').new({cfg=self.cfg,provider=self.authProvider,G=self.bridge.G,
                identity=self.identity,clock=function()return self.clockNow end,rng=self.rng,
                reuseEdges=self:_gracefulExistingEdges(commit),verifyStage=function(c)return self:_trustedGracefulStage(c)end,
                verifyApplied=function(c)local r=self.handoverRuntime;return r and r.control.localApplied==true
                    and r.control:_all(r.control.applied) and c.nonce==commit.nonce end,
                current=function(seal)
                    local authority=self.steamAuthority;local current=authority and authority.context
                    if current~=context or not current then return false end
                    if seal then return seal.session==commit.session and seal.term==commit.term-1
                        and seal.nextTerm==commit.term and seal.sequence==commit.sequence and seal.digest==commit.digest end
                    return self:_trustedGracefulStage(commit)
                end},commit,state)
            if not lane then self:_log('Graceful control refused: %s',tostring(reason));return end
            self.gracefulControl=lane
        end
        controlTransport=self.gracefulControl;controlTransport:Tick()
        if not controlTransport:Ready() then return end
        local prepared,reason=self.steamAuthority:PrepareGraceful(commit)
        if prepared~=true then
            if prepared==false then self:_log('Graceful preparation refused: %s',tostring(reason))end
            return
        end
    end
    local runtime,why=require('gmp_handover_runtime').new({mode=self.cfg.MODE,key=self.identity.key,game=self.handoverGame,
        transport=self.transport,controlTransport=controlTransport,productionAuthorization=function()
            local report=require('gmp_native_lifecycle').Read(self,true,commit)
            return report~=nil and self:_trustedGracefulStage(commit)
        end,maxPlayers=self.cfg.MAX_PLAYERS,normalDeparture=commit.kind=='graceful',verifyStage=function(c) return c==commit end,
        activationReady=function()
            local session=self.role=='host' and self.host or self.client
            if not session or session.sid~=commit.session or (session.authorityTerm or 1)~=commit.term then return false end
            if self.role=='client' then return session:State()=='joined' and session.authenticatedHostKey==commit.hostKey end
            if not session.started then return false end
            for _,player in ipairs(state.players)do
                if player.conn=='connected' then local actual=session.roster:Get(player.key);if not actual or actual.conn~='connected'then return false end end
            end
            return true
        end,
        beforeActivate=self.steamAuthority and function(c) return self.steamAuthority:Stage(c) end or nil,
        beforeRelease=self.steamAuthority and function(c)
            local session=self.role=='host' and self.host or self.client
            if allows(self,'production_native') then
                local policy=require('gmp_loss_app')
                local transferred,why=policy.TransferPolicy(self,state.sessionPolicy,c,function(value)
                    local runtime=self.handoverRuntime
                    return runtime and runtime.driver.options.verifyCommit(value)==true
                end)
                if transferred~=true then return transferred,why end
                local protected,reason=policy.CheckPolicy(self,state.sessionPolicy)
                if not protected then return false,reason end
            end
            local finished,why=self.steamAuthority:Finish(session,c)
            if finished~=true then return finished,why end
            if allows(self,'production_native') then
                local G=self.bridge and self.bridge.G;local authority=self.steamAuthority
                if not G or type(G.GMP_Aut_Owned)~='function'then return false,'native_ownership_readback_missing'end
                local ok,owned=pcall(G.GMP_Aut_Owned,authority.context.generation,c.session,c.term,c.hostKey:match('^steam:(%d+)$'))
                if not ok then return false,'native_ownership_readback_error'end
                if owned~=true then return authority:_pending('native_ownership')end
                authority:_clearWait('native_ownership')
            end
            return true
        end or nil,
        activate=function(role,s,c) return self:_activateHandover(role,s,c) end},commit,state,commit.nonce)
    if not runtime then
        if self.handoverError~=why then self.handoverError=why;self:_log('Handover blocked: %s',tostring(why)) end
        return
    end
    self.handoverRuntime=runtime;self.handoverRuntimeHold=true
    if commit.kind=='graceful' and self.normalDepartureOwner==self.identity.key then self.normalDepartureExitPending=true end
    if self.identity.key==commit.formerHost then runtime:Start() end
end

-- Reasons for which a client reconnects by itself. Deliberate ends (left/rejected/kicked) are never retried.
App.RECONNECT_REASONS = { host_timeout = true, resend_exhausted = true, closed_by_peer = true, relay_down = true, connect_timeout = true, transport_closed = true }
App.RECONNECT_DELAY = 1.0
-- Test 9: a connection lost mid-run. The client shows a notice and keeps its world paused, retries with a backoff
-- (RECONNECT_DELAY doubling up to LOST_BACKOFF_MAX) for LOST_GIVE_UP seconds, then leaves the run through the menu exit
-- with a rejoin notice (its slot stays reserved on the host, D20) and stops retrying. In the lobby the plain quick
-- reconnect stays.
App.LOST_BACKOFF_MAX = 8.0
App.LOST_GIVE_UP = 30.0
App.LOST_NOTICE = 'Connection to the host lost, reconnecting...'

function App:_tickClient()
    local c = self.client
    c:Poll(); c:Tick()
    local st, why = c:State()
    if st == 'disconnected' and c.waitMove then return self:_followWaitMove(c) end
    if st == 'joined' then
        -- Rejoin cover: a client that becomes joined while the host's run is in progress (a reconnect after a drop, or a
        -- rejoin from the menu) stays behind the "Rejoining..." pause notice until its rows are ready (gmp_rejoin_cover).
        local mirror = type(c.Roster) == 'function' and c:Roster() or nil
        if self.lastClientState ~= 'joined' and type(mirror) == 'table' and mirror.phase == 'run' then
            self:_rejoinCover():Begin(self.clockNow, self.connectionLost and 'reconnected' or 'rejoined')
        end
        self.clientInRun = self.islandFlow ~= nil and require('gmp_run_context').From(self) ~= nil
        if self.connectionLost then self:_connectionRestored() end
    elseif self.rejoinCover and not (self.autoReconnect and App.RECONNECT_REASONS[why]) then
        self.rejoinCover:Cancel()
    end
    -- Only the host's join decisions end the attempt; transient refusals (e.g. a reused dev ticket) retry as before.
    if st == 'rejected' and self.lastClientState ~= 'rejected' and App.JOIN_REFUSED_TEXT[why] then self:_joinRefused(why) end
    -- t3 friend reports (Coder A): the host closed its lobby (Cancel): back to the multiplayer screen with the reason.
    -- A first Steam join that never reached the host ends with a message instead of reconnecting with fresh
    -- authentications; a player who was in (joined or waiting) keeps the automatic reconnect (test 9).
    if st == 'joined' or st == 'waiting' then self.clientReached = true end
    if st == 'kicked' and why == 'host_closed' and self.lastClientState ~= 'kicked' then
        self.lastClientState = st; self:_log('the host closed the lobby')
        return self:_endClientAttempt(App.HOST_CLOSED_TEXT)
    end
    if st == 'disconnected' and App.RECONNECT_REASONS[why] and not self.clientReached and self.steamLobbyBackend then
        self.lastClientState = st; self:_log('join: the host never answered (%s); the attempt ends', tostring(why))
        return self:_endClientAttempt(App.UNREACHABLE_TEXT)
    end
    self.lastClientState = st
    if st == "disconnected" and self.autoReconnect and App.RECONNECT_REASONS[why] then
        if self.clientInRun and not self.connectionLost then self:_connectionLostBegin(why) end
        local lost = self.connectionLost
        if lost and self.clockNow - lost.at >= App.LOST_GIVE_UP then return self:_connectionGiveUp() end
        if not self.reconnectAt then
            local delay = lost and lost.delay or App.RECONNECT_DELAY
            self.reconnectAt = self.clockNow + delay
            if lost then lost.delay = math.min(App.LOST_BACKOFF_MAX, lost.delay * 2) end
            self:_log("client disconnected (%s): reconnecting in %.1fs with a FRESH authentication", tostring(why), delay)
        elseif self.clockNow >= self.reconnectAt then
            self.reconnectAt = nil
            self.reconnects = (self.reconnects or 0) + 1
            self:_log("client reconnect attempt %d", self.reconnects)
            c:Reconnect(self.steamAddress or "relay")
        end
    else
        self.reconnectAt = nil
        local lost = self.connectionLost
        if lost and st ~= 'joined' and self.clockNow - lost.at >= App.LOST_GIVE_UP then self:_connectionGiveUp() end
    end
end
-- D52: a player waiting for the next game follows a host change (WAIT_MOVE): once the former host's connection ends,
-- the transport is pointed at the new host and term, and the client asks to wait there again with its rank.
-- On a Steam session the waiter is still a member of the Steam lobby, so it does not re-join: it waits until the
-- lobby's own authority mapping (GMP_Lob_Host, published by the new host) commits exactly the host, term and session
-- WAIT_MOVE named, then connects to that Steam ID with the mapping as its expected session, host and term (the same
-- checks as a Steam join) and a fresh ticket. A mapping that never commits is given up after WAIT_MOVE_SECONDS.
App.WAIT_MOVE_SECONDS = 30
function App:_followWaitMove(c)
    local m = c.waitMove
    local t = self.transport
    if (not t or type(t.Retarget) ~= 'function') and self.steamAuthority and type(self.steamAuthority.CurrentHost) == 'function' then
        m.since = m.since or self.clockNow
        local record = self.steamAuthority:CurrentHost()
        if record and record.phase == 'C' and record.hostKey == m.hostKey and record.term == m.term and record.session == m.session then
            c.waitMove = nil
            c.waitRank, c.wantWait, c.resume = m.rank, true, nil
            c.expectedHandoverSession, c.expectedHandoverHost, c.expectedAuthorityTerm = record.session, record.hostKey, record.term
            self.steamAddress, self.steamJoinMapping = record.address, record
            self:_log('waiting: following the host change to %s term %d (rank %d)', Identity.Mask(m.hostKey), m.term, m.rank)
            c:Reconnect(record.address)
            return
        end
        if not m.holdLogged then
            m.holdLogged = true
            self:_log('waiting: the lobby does not map %s term %d yet; holding', Identity.Mask(m.hostKey), m.term)
        end
        if self.clockNow - m.since >= App.WAIT_MOVE_SECONDS then
            c.waitMove = nil
            self:_log('waiting: gave up following the host change to %s (the lobby never mapped it)', Identity.Mask(m.hostKey))
        end
        return
    end
    c.waitMove = nil
    if not t or type(t.Retarget) ~= 'function' then
        self:_log('waiting: cannot follow the host change to %s on this transport', Identity.Mask(m.hostKey))
        return
    end
    local ok, why = t:Retarget(m.hostKey, m.term)
    if not ok then self:_log('waiting: follow to %s refused (%s)', Identity.Mask(m.hostKey), tostring(why)); return end
    c.waitRank, c.wantWait, c.resume = m.rank, true, nil
    self.devSocketHostSlot = t.hostSlot or self.devSocketHostSlot
    self:_log('waiting: following the host change to %s (rank %d)', Identity.Mask(m.hostKey), m.rank)
    c:Reconnect(self.steamAddress or 'relay')
end
function App:_lostWorld() return self.islandFlow and self.islandFlow.world end
function App:_rejoinCover()
    self.rejoinCover = self.rejoinCover or require('gmp_rejoin_cover').new({ log = function(line) self:_log('%s', line) end })
    return self.rejoinCover
end
-- The cover goes up once the island plays (run context), and asks Coder B's RunSync:RejoinReady() -> ready, reason.
-- Test 13: a client reloading the island it already plays (the game's Retry: islands:Retry regenerates the current
-- island) re-creates its world while the host's island is full of enemies: the same pop-in as a rejoin, so the same
-- cover. A coordinated island change (a new island number) is not covered.
function App:_watchIslandReload()
    local c = self.role == 'client' and self.client or nil
    local isl = c and c.islands
    if type(isl) ~= 'table' then return end
    -- keyed on the session too (test 14: epoch/island numbers repeat across hosts)
    local sid = tostring(c.sid)
    if isl.phase == 'playing' then self.lastPlayedIsland = sid .. ':' .. isl.epoch .. ':' .. isl.island; return end
    local p = isl.pending
    if isl.phase == 'generating' and isl.island == 0 and type(p) == 'table' and self.lastPlayedIsland == sid .. ':' .. p.epoch .. ':' .. p.island then
        self.lastPlayedIsland = nil   -- once per reload
        self:_rejoinCover():Begin(self.clockNow, 'island_reload')
    end
end
function App:_tickRejoinCover()
    self:_watchIslandReload()
    local cover = self.rejoinCover
    if not cover or not cover:Active() then return end
    local world = self.islandFlow and self.islandFlow.world
    if world and not require('gmp_run_context').From(self) then world = nil end
    local sync = self.runSync
    local ready = sync and type(sync.RejoinReady) == 'function' and function() return sync:RejoinReady() end or nil
    cover:Tick(self.clockNow or 0, world, ready)
end
function App:_connectionLostBegin(why)
    self.connectionLost = { at = self.clockNow, delay = App.RECONNECT_DELAY, why = why }
    self:_log('connection to the host lost (%s) mid-run: notice shown, world paused, reconnecting for up to %ds', tostring(why), App.LOST_GIVE_UP)
    local world = self:_lostWorld()
    if world then
        if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, true) end
        if type(world.SetPauseNotice) == 'function' then pcall(world.SetPauseNotice, world, App.LOST_NOTICE) end
    end
end
function App:_connectionRestored()
    local lost = self.connectionLost
    self.connectionLost = nil
    self:_log('connection to the host restored after %.1fs; resuming through the rejoin path', self.clockNow - lost.at)
    local world = self:_lostWorld()
    -- The rejoin cover keeps the world paused and replaces the lost notice until the rows are ready.
    if world and not (self.rejoinCover and self.rejoinCover:Active()) then
        if type(world.SetPauseNotice) == 'function' then pcall(world.SetPauseNotice, world, nil) end
        if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
    end
end
function App:_connectionGiveUp()
    local lost = self.connectionLost
    self.connectionLost, self.reconnectAt, self.autoReconnect, self.clientInRun = nil, nil, false, false
    self:_log('connection to the host not restored after %ds: leaving the run (slot held on the host)', App.LOST_GIVE_UP)
    local world = self:_lostWorld()
    if world then
        if type(world.SetPauseNotice) == 'function' then pcall(world.SetPauseNotice, world, nil) end
        if type(world.SetSharedPaused) == 'function' then pcall(world.SetSharedPaused, world, false) end
    end
    self.connectionGaveUp = (self.connectionGaveUp or 0) + 1
    self.connectionExit = { runGeneration = 'connection_lost:' .. self.connectionGaveUp, reason = 'connection_lost' }
    return lost
end
-- Host: a small notice when a player drops out of the run and when they rejoin (6 s each).
App.PLAYER_NOTICE_SECONDS = 6
function App:_tickPlayerNotices()
    if self.role ~= 'host' or not self.host or not self.islandFlow then return end
    local roster = self.host.roster
    local world = self.islandFlow.world
    if type(world) ~= 'table' or type(world.SetPlayerNotice) ~= 'function' then return end
    self.knownConn = self.knownConn or {}
    local now = self.clockNow or 0
    for _, rec in ipairs(roster:Snapshot()) do
        if rec.key ~= self.host.identity.key then
            local before = self.knownConn[rec.key]
            if roster.phase == 'run' and before and before ~= rec.conn then
                local name = rec.name or Identity.Mask(rec.key)
                local text = rec.conn == 'connected' and (name .. ' rejoined.')
                    or (name .. ' lost connection. Their slot is held for 15 minutes.')
                pcall(world.SetPlayerNotice, world, text); self.playerNoticeUntil = now + App.PLAYER_NOTICE_SECONDS
                self:_log('player notice: %s', text)
            end
            self.knownConn[rec.key] = rec.conn
        end
    end
    if self.playerNoticeUntil and now >= self.playerNoticeUntil then
        self.playerNoticeUntil = nil; pcall(world.SetPlayerNotice, world, nil)
    end
end

-- S4 (rev 9, Track W): with world entry wired (islandFlow), presence is scoped to the shared run context. It runs only
-- while that context is playing; every scope change (next island, run end, abort or lobby return, leave, rejoin) clears
-- the presence state (HostPresence:Clear / ClientPresence:Clear) and the driver's markers, anchors and pawn (Driver:Reset).
-- Without world entry, presence is unchanged.
function App:_presenceScope()
    if not self.islandFlow then return true end
    local ctx = require('gmp_run_context').From(self)
    local key = ctx and ctx.key or nil
    local session = self.role == 'host' and self.host or self.role == 'client' and self.client or nil
    -- An ended run (the policy moved to the next generation) is out of scope even while its island still shows.
    local generation = session and type(session.sessionPolicy) == 'table' and session.sessionPolicy.runGeneration or nil
    if key and key == self.presenceScopeKey and self.presenceScopeGeneration and generation and generation > self.presenceScopeGeneration then
        self.presenceEndedKey = key
    end
    if key and key == self.presenceEndedKey then key = nil end
    if key ~= self.presenceScopeKey then
        self.presenceDriver:Reset()
        local host, client = self.host, self.client
        if host and host.presence then host.presence:Clear() end
        if client and client.presence then client.presence:Clear() end
        self.presenceScopeKey, self.presenceScopeGeneration = key, key and generation or nil
        self:_log('PRESENCE scope ctx=%s', key or 'none')
    end
    return key ~= nil
end
function App:_tickPresence()
    if not self.presenceDriver or not self:_presenceScope() then return end
    self.presenceDriver:Tick(self.clockNow)
    self:_presenceStatsLine()
    if self.extras.presenceCheck then
        if not self.presenceProbe then self.presenceProbe=require('gmp_presence_probe').new(function(...) self:_log(...) end,{visual=self.extras.visualCheck,enemies=self.extras.enemyCheck}) end
        self.presenceProbe:Tick(self.presenceDriver,self.clockNow)
    end
end
-- R1 attempt 3 diagnostics: one line a second per side while presence is in scope (the shared pause and the S1 prep hold
-- do not stop presence). tx: host WORLD_STATE broadcasts / client PLAYER_STATE sends; rx: host accepted PLAYER_STATEs /
-- client applied WORLD_STATEs; markers: the driver's marker updates; lastRemote: the newest visible remote position.
-- live/spawned/spawn_failed come from the world's own Status() when it has one (a failed marker spawn is not an error).
function App:_presenceStatsLine()
    local now, driver = self.clockNow or 0, self.presenceDriver
    local session = self.role == 'host' and self.host or self.role == 'client' and self.client or self.host or self.client
    local presence = session and session.presence
    if presence then
        local ok, visible = pcall(presence.Visible, presence, now, self.role ~= 'client' and session.identity and session.identity.key or nil)
        local r = ok and type(visible) == 'table' and visible[1]
        if r then self.presenceLastRemote = string.format('(%s,%s,%s)', tostring(r.x), tostring(r.y), tostring(r.z)) end
    end
    if now < (self.presenceStatsAt or 0) then return end
    self.presenceStatsAt = now + 1
    local d, ps = driver.stats, presence and presence.stats or {}
    local host = presence and session == self.host
    local tx = host and (ps.broadcasts or 0) or d.sends
    local rx = host and (ps.accepted or 0) or (ps.applied or 0)
    local world = driver.world
    local wst = world and type(world.Status) == 'function' and select(2, pcall(world.Status, world)) or nil
    local ws = type(wst) == 'table' and type(wst.stats) == 'table' and wst.stats or {}
    self:_log('PRESENCE tx n=%d rx n=%d markers=%d lastRemote=%s rej=%d partial=%d reads=%d read_nil=%d read_err=%d live=%s spawned=%s spawn_failed=%s',
        tx, rx, d.marker_sets, self.presenceLastRemote or 'none', ps.rejected or 0, d.marker_partial or 0, d.reads, d.read_nil, d.read_errors,
        tostring(type(wst) == 'table' and wst.markers or '-'), tostring(ws.spawned or '-'), tostring(ws.spawn_failed or '-'))
end
-- D41: cheats follow the host. Read by Cheat Mod through GoobiesMPCheatPolicy (main.lua); fails closed on a client.
function App:CheatPolicy()
    if self.role == 'host' and self.host then return { mode = 'host' } end
    if self.role == 'client' and self.client then
        local c, h = self.client, self.client.hostCheats
        local joined = type(c.State) == 'function' and c:State() == 'joined'
        if joined and h and h.sid == c.sid then
            return { mode = 'client', known = true, invulnerable = h.invulnerable, unlockClasses = h.unlockClasses }
        end
        return { mode = 'client', known = false }
    end
    return { mode = 'solo' }
end
function App:SetHostCheats(state)
    if self.role ~= 'host' or not self.host or type(self.host.SetCheatState) ~= 'function' then return false end
    return self.host:SetCheatState(state)
end
function App:_tickCheats()
    if self.role == 'host' and self.host and type(self.host.TickCheatState) == 'function' then self.host:TickCheatState() end
end
-- D56 (Coder D): a client's F6/F7/F8 (Cheat Mod, GoobiesMPCheatRequest) go to the host as CHEAT_REQ; the host's Cheat
-- Mod hands its handler in through GoobiesMPSetCheatHandler (every update, so a new host session after a handover is
-- attached again). Dev and friend only (gmp_cheat_requests.lua).
function App:RequestCheat(key)
    if not allows(self, 'gameplay') then return false, 'production_mode' end
    if self.role ~= 'client' or not self.client or type(self.client.RequestCheat) ~= 'function' then return false, 'not_a_client' end
    return self.client:RequestCheat(key)
end
function App:SetCheatHandler(fn)
    if not allows(self, 'gameplay') or type(fn) ~= 'function' then return false end
    if not self.cheatGate then
        self.cheatGate = require('gmp_cheat_requests').Gate.new({ mode = function() return self.cfg.MODE end })
    end
    self.cheatGate:SetHandler(fn)
    if self.role == 'host' and self.host then self.host.cheatRequests = self.cheatGate end
    return true
end
-- D42: the host hands its gameplay mod manifest to every joined client; a client whose mods differ leaves (a voluntary
-- LEAVE frees its slot, D20) with the list in the lobby and no reconnect. No local registry: the check is skipped.
function App:_tickModCheck()
    if not self.modManifest then return end
    if self.role == 'host' and self.host and type(self.host.SetModManifest) == 'function' then
        self.host:SetModManifest(self.modManifest); self.host:TickModManifest()
    elseif self.role == 'client' and self.client then
        local c = self.client
        if type(c.State) ~= 'function' or c:State() ~= 'joined' or not c.hostModManifest or c.hostModManifestSid ~= c.sid then return end
        if self.modCheckedSid == c.sid then return end
        self.modCheckedSid = c.sid
        local M = require('gmp_mod_manifest')
        local lines = M.Diff(c.hostModManifest, self.modManifest)
        if #lines == 0 then self:_log('mod check: same gameplay mods as the host'); return end
        self.lobbyNotice = M.Notice(lines); self.autoReconnect = false
        self:_log('mod check: mods differ from the host (%s); leaving the lobby', table.concat(lines, '; '))
        c:Leave('mod_mismatch')
    end
end
-- Test 10: each player's live HUD counters show their own host-credited numbers (gmp_live_hud.lua), during a run.
function App:_liveHud()
    local world = self.islandFlow and self.islandFlow.world
    if not world or type(world.LocalWorldPawn) ~= 'function' then return nil end
    local ok, hud = pcall(function() local _, pawn = world:LocalWorldPawn(); return pawn and pawn.HUD end)
    if not ok or hud == nil then return nil end
    local live = pcall(function() return hud:IsValid() end) and hud:IsValid() == true
    return live and hud or nil
end
-- Test 11: one "LIVEHUD <role> ..." line a second during a run (gmp_live_hud.lua Line), or "LIVEHUD <role> off
-- reason=<r>" when the HUD logic cannot run; errors are logged, never swallowed.
App.LIVE_HUD_LOG_SECONDS = 1
function App:_tickLiveHud()
    if not self.islandFlow or (self.role ~= 'host' and self.role ~= 'client') then return end
    local now = self.clockNow or 0
    local function log(line)
        if self.liveHudLogAt and now - self.liveHudLogAt < App.LIVE_HUD_LOG_SECONDS then return end
        self.liveHudLogAt = now; self:_log('%s', line)
    end
    local function off(reason) log(string.format('LIVEHUD %s off reason=%s', self.role, reason)) end
    if not require('gmp_run_context').From(self) then return off('no_run_context') end
    local G = self.bridge and self.bridge.G
    -- UE4SS's global FText is a callable FText userdata, not a Lua function (test 11: this check was 'function').
    if type(G) ~= 'table' or G.FText == nil then return off('no_ftext') end
    local hud = self:_liveHud()
    if not hud then return off('no_hud') end
    local Live = require('gmp_live_hud')
    local ok, err
    if self.role == 'host' and self.host then
        local sync = self.runSync
        local okA, attribution = pcall(function() return sync and type(sync.Attribution) == 'function' and sync:Attribution() or {} end)
        if not okA then return off('attribution_error ' .. tostring(attribution):sub(1, 120)) end
        self.liveHudHost = self.liveHudHost or Live.Host.new({ FText = G.FText, hostKey = self.host.identity.key,
            send = function(key, fields) return self.host:SendLiveStats(key, fields) end })
        local policy = self.host.sessionPolicy
        ok, err = pcall(self.liveHudHost.Tick, self.liveHudHost, now, hud, attribution, policy and policy.runGeneration or 1)
        log(self.liveHudHost:Line() .. (ok and '' or (' error=' .. tostring(err):sub(1, 120))))
    elseif self.role == 'client' and self.client then
        self.liveHudClient = self.liveHudClient or Live.Client.new({ FText = G.FText })
        local policy = self.client.sessionPolicy
        ok, err = pcall(self.liveHudClient.Tick, self.liveHudClient, now, hud, self.client.liveStats, policy and policy.runGeneration or 1)
        log(self.liveHudClient:Line() .. (ok and '' or (' error=' .. tostring(err):sub(1, 120))))
    end
end
-- The lobby picker offers every class while the host has Unlock all classes on (D41).
function App:CheatUnlockAll()
    if self.role == 'host' and self.host then return self.host.cheatState ~= nil and self.host.cheatState.unlockClasses == true end
    local p = self:CheatPolicy()
    return p.mode == 'client' and p.known == true and p.unlockClasses == true
end
-- Lanes (gmp_lanes.lua): the transport's once-a-second "LANES tx ..." line, when it has lanes (qa_four transport).
function App:_tickLanes()
    local t = self.transport
    if type(t) ~= 'table' or type(t.LaneLine) ~= 'function' then return end
    local ok, line = pcall(t.LaneLine, t)
    if ok and type(line) == 'string' then self:_log('%s', line .. self:_laneDelivery()) end
end
-- Test 11 per-hop counters: since the last LANES line, what the session links delivered (d) and dropped as stale (s)
-- per lane, and duplicates, summed over the links (host: one per peer; client: the one to the host).
function App:_laneDelivery()
    local links = {}
    if self.host and type(self.host.peers) == 'table' then
        for _, peer in pairs(self.host.peers) do if type(peer) == 'table' and type(peer.link) == 'table' then links[#links + 1] = peer.link end end
    end
    if self.client and type(self.client.link) == 'table' then links[#links + 1] = self.client.link end
    self.laneSeen = self.laneSeen or setmetatable({}, { __mode = 'k' })
    local d, s, dup = { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }, 0
    for _, link in ipairs(links) do
        local st = link.stats or {}; local lanes = st.lanes
        if type(lanes) == 'table' then
            local last = self.laneSeen[link] or { ok = { [0] = 0, 0, 0, 0 }, stale = { [0] = 0, 0, 0, 0 }, dup = 0 }
            for lane = 0, 3 do
                d[lane] = d[lane] + (lanes.ok[lane] or 0) - last.ok[lane]
                s[lane] = s[lane] + (lanes.stale[lane] or 0) - last.stale[lane]
            end
            dup = dup + (st.duplicate or 0) - last.dup
            self.laneSeen[link] = { ok = { [0] = lanes.ok[0], lanes.ok[1], lanes.ok[2], lanes.ok[3] },
                stale = { [0] = lanes.stale[0], lanes.stale[1], lanes.stale[2], lanes.stale[3] }, dup = st.duplicate or 0 }
        end
    end
    return string.format(' delivered d0=%d d1=%d d2=%d d3=%d stale s0=%d s1=%d s2=%d s3=%d dup=%d', d[0], d[1], d[2], d[3], s[0], s[1], s[2], s[3], dup)
end
function App:_logPresence()
    if self.clockNow < (self.nextPresenceLog or 0) then return end
    self.nextPresenceLog = self.clockNow + 2
    if self.host then
        local t = {}
        for _, p in ipairs(self.host:Players()) do t[#t + 1] = peerLabel(p) end
        self:_log("M3 ROSTER side=host rev=%d phase=%s sig=%s", self.host.roster.rev, self.host.roster.phase, table.concat(t, ";"))
        for _, p in ipairs(self.host:Players()) do
            self:_log("M3 PRESENCE side=host player=%s slot=%d conn=%s heartbeat_age=%s", Identity.Mask(p.key), p.slot, p.conn, p.lastSeen and string.format("%.1f", self.clockNow - p.lastSeen) or "n/a")
        end
    elseif self.client then
        local m, st = self.client:Roster(), self.client:State()
        if m then
            local t = {}
            for _, p in ipairs(m.players) do t[#t + 1] = peerLabel(p) end
            self:_log("M3 ROSTER side=client rev=%d phase=%s state=%s sig=%s", m.rev, tostring(m.phase), st, table.concat(t, ";"))
        else
            self:_log("M3 ROSTER side=client state=%s (no roster yet)", st)
        end
    end
end

-- Stage 1 diagnostic (AUTH_CHECK=1): created once the production identity exists; refuses to run without the real provider.
function App:_tickAuthCheck(dt)
    local env = self.env
    if not self.authcheck and not self.authcheckRefused then
        local ok = allows(self,"production_diagnostics") and self.cfg.AUTH_MODE == "steam" and self.bridge.authProvider ~= nil and self.bridge.steamProvider ~= nil
        if not ok then
            self.authcheckRefused = true
            self:_log("AUTHCHECK not run: needs MODE=production, AUTH_MODE=steam and the native Steam provider (auth=%s steamid=%s)", tostring(self.bridge.authProvider ~= nil), tostring(self.bridge.steamProvider ~= nil))
            if self.netDir then self.fs.write(self.netDir .. "/authcheck_done.txt", "FAIL") end
            return
        end
        self.authcheck = AuthCheck.new({ provider = self.bridge.authProvider, steamId = self.bridge.steamProvider, now = function() return self.clockNow end,
            log = function(...) env:Log(...) end, fs = self.fs, dir = self.netDir })
        self:_log("AUTHCHECK armed: one-shot Steam ticket/validation check on the local account (no network)")
    end
    if self.authcheck then self.authcheck:Tick() end
end

-- Production only, and only when a native SteamID provider exists: Steam not initialised yet => "steamid_unavailable" => retry about once per second
-- (bounded). Never retries a config error, never substitutes any other identity.
App.IDENTITY_RETRY_EVERY, App.IDENTITY_RETRY_MAX = 1.0, 120
function App:WantsIdentityRetry()
    return self.state == "no_identity" and self.reason == "steamid_unavailable" and allows(self,"steam_session")
        and self.bridge.steamProvider ~= nil and (self.identityRetries or 0) < App.IDENTITY_RETRY_MAX
end
function App:_retryIdentity()
    if not self:WantsIdentityRetry() then return end
    local now = self.env:Clock()
    if self.nextIdentityTry and now < self.nextIdentityTry then return end
    self.identityRetries = (self.identityRetries or 0) + 1
    self.nextIdentityTry = now + App.IDENTITY_RETRY_EVERY
    local before = self.identityRetries
    local st = self.extras.steamLobby and self:_bootSteamLobby() or (self.role and self:_startNetSession() or self:_startSession())
    if st == "hosting" or st == "client" then self:_log("identity became available after %d retries", before) end
end

-- One-shot, read-only runtime/identity discovery (M2d). Never changes game state; every step is pcall-protected inside the bridge.
function App:RunProbes()
    local env = self.env
    if self.extras.runtimeFacts then
        local elapsed = env:Clock()
        local wall = os.time() - env:Info().epochStart
        self:_log("RUNTIME tick_count=%d elapsed_clock=%.2fs os_time_elapsed=%ds ticks_per_s=%.1f (expected ~%.1f at TICK_MS=%d)",
            self.ticks, elapsed, wall, elapsed > 0 and self.ticks / elapsed or 0, 1000 / self.extras.tickMs, self.extras.tickMs)
        self:_log("RUNTIME clock_vs_wall_ratio=%.3f (1.0 = os.clock tracks wall time)", wall > 0 and elapsed / wall or 0)
        local fires = self.bridge.loops and self.bridge.loops[1] and self.bridge.loops[1].fires or 0
        self:_log("RUNTIME game_thread_steps=%d (game-thread steps executed by the bridge)", fires)
        self:_log("RUNTIME print_marker GMP-PRINT-%d (search UE4SS.log for this and for '[GoobiesMP' to see whether print() is routed there)", env:Info().epochStart)
    end
    if self.extras.s1Probe ~= "off" then
        local res
        if self.extras.s1Probe == "inspect" then
            res = self.bridge:ProbeS1Inspect({ log = function(...) env:Log(...) end })
            self.s1 = res
            self:_log("S1 inspect finished: stage_a=%s stage_c=%s lua_type=%s keys=%s candidate=%s (not adopted)", tostring(res.a), tostring(res.c), tostring(res.luaType), tostring(res.keyCount), res.candidateMasked or "none")
        else
            res = self.bridge:ProbeS1({ call = (self.extras.s1Probe == "call"), log = function(...) env:Log(...) end })
            self.s1 = res
            self:_log("S1 probe finished: stage_a=%s stage_b=%s stage_c=%s identity_candidate=%s", tostring(res.a), tostring(res.b), tostring(res.c), res.candidateMasked or "none")
        end
    end
end

function App:Status()
    local s = { state = self.state, reason = self.reason, mode = self.cfg.MODE, selftest = self.selftest and { ok = self.selftest.ok, total = self.selftest.total, failed = self.selftest.failed } or nil }
    if self.host then
        local me = self.host:GetPlayer(self.identity.key)
        s.identity, s.slot, s.color, s.currentPlayers, s.phase = self.identity.key, me.slot, me.color, self.host:CurrentPlayers(), self.host.roster.phase
    elseif self.client then
        local st, why = self.client:State()
        s.identity, s.role, s.clientState, s.clientReason = self.identity.key, self.role, st, why
        local me = self.client:Me()
        if me then s.slot, s.color = me.slot, me.color end
        s.currentPlayers = self.client:CurrentPlayers()
    end
    s.role = self.role
    return s
end

return App
