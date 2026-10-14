-- RunSync (PLAN_WORLD_ENTRY.md 3.2 item 9; S1 = 3.11 prep lifecycle). The interface W wires against (gmp_app.lua W3):
--   RunSync.new{G, factory, log, clock, flags, standinSelftest}
--     flags            {runSyncEnemies, clientAttacks, authorityPrep, clientEnemyRows} (W3); nil = all off
--     standinSelftest  function() -> ok, why: may island prep create the STANDIN_SELFTEST self-peer now (W3)
--   :Tick(ctx, session, now)      ctx = gmp_run_context.lua context or nil; session = the host or client session
--   :Stop(reason)                 idempotent; a stopped sync stays stopped
--   :PauseRequest()               nil, or {paused, reason='authority_prep'|'island_prep'}
--   :Capabilities()               {enemy_authority, enemy_authority_scope='none'|'ordinary_dev'|'production', client_attacks}
--   :Status()                     {state, reason, contextKey, prep={hook,native,blueprint,standIns,...},
--                                  enemies={applied,presented}, attacks={sent,accepted,refused,held},
--                                  attribution={[peer]={kills, damage, weapons={[type]={damage,kills}}}}}  (a copy)
-- Without flags.authorityPrep it is the inert C0 stub: no authority, no attacks, no pause, it never reads the game.
--
-- S1 prep (flags.authorityPrep):
--   Process prep, once per process (per G) on both roles: GMPAuthorityHookSelfTest -> NativeSelfTest -> BlueprintSelfTest
--   (the gmp_dev_dispatch_probe.lua order, one per tick) while the island is visible (ctx.islandWorld:DiagnosticVisible),
--   the live binding (worldPath, controllerPath, generation) is unchanged and the shared pause is physically applied.
--   A later run in the same process reuses the result (logged cached=true); a helper failure is cached too.
--   Host: asks for the pause (reason authority_prep); the W3 app holds it through host:PauseForAuthorityPrep(key,
--   'process'). After its own self-tests it waits until host:AuthorityPrepStatus(key).waiting is empty (every connected
--   client reported AUTHORITY_PREP ok), then asks for the island prep pause (island_prep): MODE=dev ConfigureDevWitness
--   first, then PrepareIsland (gmp_native_host_damage.lua: one stand-in per connected peer; the STANDIN_SELFTEST
--   self-peer only when options.standinSelftest() allows it), then the clients' island acknowledgements, then it
--   withdraws the request (the app releases). Every later island repeats only the island prep. The stand-in binding is
--   shared per process, so a new run's witness waits until the previous run's stand-ins are retired.
--   Client: when the host's AUTHORITY_PREP_STATE for this context lists its slot and its shared pause is applied, it
--   runs (or reuses) its process self-tests and reports AUTHORITY_PREP{key, phase, ok, reason}. It never asks for a pause.
--   Any failure keeps the host's pause request (the hold is visible and logged until W10 adds the abort).
-- Logs: "RunSync prep phase=process hook=ok native=ok blueprint=ok", "RunSync prep phase=island standIns=<n>",
--   "RunSync prep phase=<p> failed reason=<r>", "RunSync prep phase=<p> reported ok", plus the STANDIN lines.
--
-- S7b remote hits (flags.clientAttacks, host only, after this island's prep):
--   :ApplyRemoteHit(ctx, session, peer, intent, target) -> ok, reason, {damage, killed, weapon}
--     intent = the authenticated ATTACK_INTENT {context, sequence, enemyId, attack} (gmp_host_combat.lua schema; no
--     other field), peer = its bound sender key, target = the host's native row index the host resolved for enemyId
--     (S5). The hit is dispatched natively (gmp_native_host_damage.lua Hit); only a native-proven hit is counted in
--     attacks.accepted and credited to Status().attribution, keyed by peer key:
--       {[peerKey] = {kills, damage, weapons = {[weaponType] = {damage, kills}}}}   (S8: Host.RunStatsRows)
--     A refusal counts attacks.refused; an uncertain native dispatch counts attacks.held and holds that peer for
--     the island. CLIENT_ATTACKS needs AUTHORITY_PREP (the stand-ins are made at island prep).
--   :Attribution() -> a copy of that table.
--   S5 host attack resolution: with CLIENT_ATTACKS the host enables its ATTACK_INTENT intake, drains it every tick
--   into the gmp_host_combat queue (per-peer replay check, context, live enemy, backpressure; at most 8 resolved per
--   tick, none while the shared pause holds), maps the intent's enemyId (the host lifetime) to the host's native row
--   (host.enemies records[id].slot, HOST_ENEMY_CAPTURE) and calls ApplyRemoteHit. Every intent is answered with
--   ATTACK_RESULT {sequence, ok}. Log: "RunSync attack refused peer=<key> seq=<n> reason=<r>".
--
-- S2/S3 client rows mode (flags.clientEnemyRows, client only, MODE=dev; gmp_run_sync_rows.lua):
--   At each island prep, after its self-tests and before acknowledging the island, the client fences its controller and
--   binds the owned presentation (the previous island's rows are disabled first). After that every tick mirrors the
--   host's enemy snapshot (Client:EnemySnapshot(), HOST_ENEMY_CAPTURE on the host) into native rows the client's
--   weapons can hit; host deaths and vanished lifetimes are retired. A rows failure fails the island acknowledgement,
--   so the host keeps the pause. Status().enemies = {applied = snapshots mirrored, presented = live rows};
--   Capabilities() reports enemy_authority=true, scope 'ordinary_dev' while the rows are active.
--   options.rowsFactory(ctx) -> a gmp_run_sync_rows object (tests); default: the slice1 bridge + gmp_native_enemy_instances.
--   :Rows() -> the rows object (client), e.g. :SlotOf(enemyId) / :EnemyIdAt(slot).
--
-- CLIENT_UPGRADE_DAMAGE (flags.clientUpgradeDamage, post-R1 dev flag, off by default):
--   Client: reads its pawn's DamageMultiplier, "AOE DamageMultiplier" and ProjectileBonusDamage (the inputs of the
--   standard weapon's damage, research in stand_in_stats_policy.hpp) and sends PLAYER_STATS when they change (at most
--   every UPGRADE_SEND_SECONDS). Host: enables the PLAYER_STATS intake and, once this island's stand-ins exist, puts
--   each peer's newest stats on its stand-in (gmp_native_host_damage.lua ApplyStats) before resolving hits, again on
--   every new revision and every new island. Crit is not applied (controller-wide on the host).
--   Status().upgrades: host {[peerKey] = applied revision}; client {sent = n}.
--
-- CLIENT_DAMAGE (flags.clientDamage, post-R1 dev flag, off by default; research/RESEARCH_GAMEPLAY.md section 10):
--   Host: while the shared pause is off, compares each client's presence position (host.presence) with its own enemy
--   rows (host.enemies) by the game's contact rule (gmp_run_sync_contact.lua) and sends CLIENT_HIT to that client.
--   Client: switches its own BPC_CheckIfPlayerTakeDamage off (its rows mirror host enemies, S2) and applies each hit of
--   the current run context with BP_Player.ChangeHP(damage x the component's DamageMultiplier, false), the game's own
--   path (invincibility frames, HUD, TotalDamageTaken, Death). Artifact 006 counts once through that multiplier
--   (fallback when unreadable: HD.ClientDamageTakenMultiplier(policy artifacts)).
--   Status().damage: host {sent = n}; client {hits = n, taken = sum}.
-- SHARED_LIVES (flags.sharedLives, post-R1 dev flag, off by default; DECISIONS.md D32; research section 11):
--   Implies the CLIENT_DAMAGE path for every player, the host included (its own contact check is switched off too and
--   its presence record is touched like a client's). A hit that would reach 0 HP is never applied: the player becomes a
--   ghost (IncomingDamageReduction 0, HP kept, still moves and picks up XP) and is reported (client PLAYER_DOWN). The
--   host owns the pool (options.lives, default 3; gmp_run_sync_lives.lua), ghost state and revive progress, publishes
--   LIVES_STATE and, on a revive, heals (ChangeHP add, reviveHp x HP_MAX), grants invulnerability (SetInvincible, also
--   honoured by host contact) and fires one explosion (HD:Explosion). When every player is a ghost each player runs the
--   game's own Death(false) once (end screen). Status().lives = {lives, ghosts, ended, ghost, slots = {[slot]=progress}}.
local HD = require('gmp_native_host_damage')
local Attribution = require('gmp_run_sync_attribution')
local Rows = require('gmp_run_sync_rows')
local Liveness = require('gmp_run_sync_liveness')
local Policy = require('gmp_mode_policy')   -- D47: dev and friend play the playtest gameplay
local Contact = require('gmp_run_sync_contact')
local HostCombat = require('gmp_host_combat')
local Lives = require('gmp_run_sync_lives')
local ActorScan = require('gmp_actor_scan')
local PortalMirror = require('gmp_portal_mirror')

local R = {}
R.__index = R

local SELF_TESTS = {
    { field = 'hook', name = 'GMPAuthorityHookSelfTest', proof = 'math_skip_unregister_verified' },
    { field = 'native', name = 'GMPAuthorityNativeSelfTest', proof = 'native_math_consume_restore_verified' },
    { field = 'blueprint', name = 'GMPAuthorityBlueprintSelfTest', proof = 'blueprint_internal_skip_outputs_unregister_verified' },
}
local PAUSE_REASON = { process = 'authority_prep', island = 'island_prep' }
local REPUBLISH_SECONDS = 1
R.ROWS_RECOVER_SECONDS = 2     -- a held client rows is recovered after this long (gmp_run_sync_rows.lua Recover)
-- Test 10: five recoveries 2 s apart were all lost again at once and the rows then stayed dead (the client simulated
-- its own enemies). Now a recovery that relapses at once doubles the wait (2, 4, 8, 16 s, then every 16 s), its cause
-- is logged once, and while held the fail-safe keeps the controller fenced (rows:EnsureFence).
R.ROWS_RECOVER_BACKOFF_MAX = 3 -- doublings
-- D43: the host's boss/unique looks (gmp_actor_scan.lua) are scanned once a second and sent to every connected client
-- every ACTOR_RESEND_SECONDS (a new look at once): small, idempotent on the client, survives reconnects.
R.ACTOR_SCAN_SECONDS, R.ACTOR_RESEND_SECONDS = 1, 5
R.ACTOR_PROXY_CLASS = 5   -- the giant: an ordinary class with a large radius, for the proxy rows of bosses/uniques
R.AOE_PER_SECOND = 10          -- resolved client AOE observations per peer per second (Bingus nova ~3/s)
R.AOE_PLAYER_RANGE = 1500      -- cm: an AOE must be this close to that client's presence position
R.AOE_SETTLE_SECONDS = 1.1     -- DamageAOE lands after the call: the credit is read back this much later
R.AOE_PENDING_MAX = 64
local UPGRADE_SEND_SECONDS = 0.5
local LIVES_PROGRESS_SECONDS = 0.25   -- LIVES_STATE for revive progress at most this often (changes are sent at once)
local LIVES_REPUBLISH_SECONDS = 2

local function counters()
    return { prep = { hook = false, native = false, blueprint = false, standIns = false },
        enemies = { applied = 0, presented = 0 }, attacks = { sent = 0, accepted = 0, refused = 0, held = 0 }, attribution = {} }
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- Process-wide state per bridge G (the real G is the Lua state's globals: one per game process).
local PROCESS = setmetatable({}, { __mode = 'k' })
local function processState(G)
    local state = PROCESS[G]
    if not state then
        state = { tests = { state = 'pending', step = 1, hook = false, native = false, blueprint = false }, generation = 0 }
        PROCESS[G] = state
    end
    return state
end

function R.new(options)
    assert(type(options) == 'table', 'RunSync options required')
    for _, name in ipairs({ 'factory', 'log', 'clock', 'standinSelftest', 'rowsFactory' }) do
        assert(options[name] == nil or type(options[name]) == 'function', 'RunSync ' .. name .. ' must be a function')
    end
    assert(options.flags == nil or type(options.flags) == 'table', 'RunSync flags must be a table')
    local self = setmetatable({ options = options, flags = options.flags or {}, state = 'idle', reason = nil, contextKey = nil }, R)
    self.counters = counters()
    self.attribution = Attribution.new()   -- per run (one RunSync per run)
    if self.flags.sharedLives == true then self.lives = Lives.new({ lives = options.lives }) end   -- the pool is per run
    return self
end

function R:_log(fmt, ...)
    local log = self.options.log
    if not log then return end
    local ok, line = pcall(string.format, fmt, ...)
    pcall(log, ok and line or tostring(fmt))
end

------------------------------------------------------------------ observation (never raises)
local function visible(ctx)
    local world = ctx.islandWorld
    if type(world) ~= 'table' or type(world.DiagnosticVisible) ~= 'function' then return false end
    local ok, value = pcall(world.DiagnosticVisible, world)
    return ok and value == true
end
-- true = physically paused (global time dilation ~0, as App:_testPhysicalPause), false = running, nil = unknown.
local function physicallyPaused(ctx)
    local ok, value = pcall(function()
        local world, library
        local native = ctx.world
        if type(native) == 'table' and type(native._world) == 'function' and type(native._statics) == 'function' then
            world, library = native:_world(), native:_statics()
        end
        local island = ctx.islandWorld
        if (not world or not library) and type(island) == 'table' and type(island.LocalWorldPawn) == 'function' then
            local pawn
            world, pawn, library = island:LocalWorldPawn()
            if not pawn then return nil end
        end
        if not world or not library then return nil end
        return library:GetGlobalTimeDilation(world)
    end)
    if not ok or type(value) ~= 'number' or value ~= value or value <= 0 or value > 1.01 then return nil end
    return value <= .001
end
local function bindingOf(ctx)
    if type(ctx.worldPath) ~= 'string' or type(ctx.controllerPath) ~= 'string' then return nil end
    return { worldPath = ctx.worldPath, controllerPath = ctx.controllerPath, generation = ctx.generation }
end
local function sameBinding(a, ctx)
    return a ~= nil and a.worldPath == ctx.worldPath and a.controllerPath == ctx.controllerPath and a.generation == ctx.generation
end
-- nil when the self-tests or stand-in creation may run now, otherwise why not.
local function prepConditions(ctx, binding)
    if not visible(ctx) or not sameBinding(binding, ctx) then return 'binding_or_visibility_changed' end
    if physicallyPaused(ctx) ~= true then return 'physical_pause_lost' end
    return nil
end

------------------------------------------------------------------ process self-tests (shared per G)
local function callHelper(G, test, binding)
    local fn = G[test.name]
    if type(fn) ~= 'function' then return false, 'missing_helper:' .. test.name end
    local values
    if test.field == 'blueprint' then
        values = table.pack(pcall(fn, binding.generation, binding.worldPath, binding.controllerPath))
    else
        values = table.pack(pcall(fn))
    end
    if values[1] ~= true or values[2] ~= true then return false, 'helper_failed:' .. test.name end
    if values[3] ~= test.proof then return false, 'unexpected_proof_reason:' .. test.name end
    if test.field ~= 'blueprint' then
        if values[4] ~= 1 then return false, 'unexpected_skip_count:' .. test.name end
        return true
    end
    for i = 4, 6 do
        local n = values[i]
        if type(n) ~= 'number' or n % 1 ~= 0 or n < 0 or n > 100 then return false, 'invalid_dispatch_count' end
    end
    if values[4] < 1 or values[5] < 1 then return false, 'dispatch_not_observed' end
    return true, nil, values[6] == 0
end
-- One self-test per call. Returns 'running' | 'ok' | 'failed', reason, cached.
function R:_stepSelfTests(binding)
    local G = self.options.G
    if type(G) ~= 'table' then return 'failed', 'native_unavailable' end
    local tests = processState(G).tests
    if tests.state == 'ok' or tests.state == 'failed' then return tests.state, tests.reason, true end
    local test = SELF_TESTS[tests.step]
    local ok, why, unproven = callHelper(G, test, binding)
    if not ok then
        tests.state, tests.reason = 'failed', why
        return 'failed', why
    end
    if unproven then self:_log('RunSync prep blueprint local_script_route_unproven count=0') end
    tests[test.field] = true
    tests.step = tests.step + 1
    if tests.step > #SELF_TESTS then tests.state = 'ok'; return 'ok' end
    return 'running'
end
function R:_logSelfTests(cached)
    self:_log('RunSync prep phase=process hook=ok native=ok blueprint=ok%s', cached and ' cached=true' or '')
end

------------------------------------------------------------------ host
-- User rule (test 13): each player sees only their own damage numbers. QuietNumbers(controller) -> quiet(fn): runs fn
-- with the host controller's ShowDMGNumbers? false (its SpawnHitNumber then draws no number and shakes no camera)
-- and restores it; the host's own hits never pass through it. A host with the setting off stays off.
function R.QuietNumbers(controller)
    return function(fn)
        local manager
        pcall(function() manager = controller() end)
        local was
        if manager then pcall(function() was = manager['ShowDMGNumbers?'] end) end
        if was == true then pcall(function() manager['ShowDMGNumbers?'] = false end) end
        local results = table.pack(pcall(fn))
        if was == true then pcall(function() manager['ShowDMGNumbers?'] = true end) end
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end
end
function R:_hd()
    local G = self.options.G
    if type(G) ~= 'table' then return nil end
    local state = processState(G)
    if not state.hd then
        local api = HD.Api(G)
        if not api then return nil end
        state.hd = HD.new(api, { mode = self.mode })
    end
    -- The binding logs through the sync that currently owns it.
    state.hd.log = function(line) self:_log('%s', line) end
    state.hd.clock = self.options.clock or os.clock   -- test 14: the short hit hold window
    state.hd.quiet = R.QuietNumbers(function() return self.quietController and self.quietController() end)
    self.usedHd = state.hd
    return state.hd
end
local function remotePlayers(session)
    local out = {}
    local ok, players = pcall(function() return session.roster:Snapshot() end)
    if not ok or type(players) ~= 'table' then return out end
    for _, player in ipairs(players) do
        if player.key ~= session.identity.key then out[#out + 1] = player end
    end
    return out
end
-- Lobby class token "character_<n>" (gmp_lobby_native_selection.lua) -> the stand-in Character ordinal; 0 otherwise.
local function characterOf(session, key)
    local ok, rec = pcall(function() return session.roster:Get(key) end)
    local n = ok and type(rec) == 'table' and type(rec.class) == 'string' and tonumber(rec.class:match('^character_(%d+)$'))
    if n and n >= 0 and n <= 31 then return math.tointeger(n) or 0 end
    return 0
end
function R:_trackRoster(session, hd)
    local previous, now = self.roster or {}, {}
    for _, player in ipairs(remotePlayers(session)) do
        now[player.key] = player.conn
        local before = previous[player.key]
        if before == 'connected' and player.conn ~= 'connected' then hd:Disconnect(player.key)
        elseif before and before ~= 'connected' and player.conn == 'connected' then hd:Rejoin(player.key) end
    end
    for key in pairs(previous) do if now[key] == nil then hd:Expire(key) end end
    self.roster = now
end
-- Test 14 (Coder C): every connected peer without a stand-in gets one mid-island (it was disconnected at the island
-- prep, joined after it, or rejoined after its held stand-in was retired), with its stats re-applied by the upgrades
-- tick. A refusal is retried after LATE_STANDIN_SECONDS and logged once per reason. D54: any player count.
R.LATE_STANDIN_SECONDS = 2
R.LATE_STANDIN_MAX_SECONDS = 30   -- test 15 (Coder C): the same refusal again doubles the wait, up to this
-- Test 15 (Coder C): the native stand-in create refuses unless the host world is physically paused (global time
-- dilation <= 0.001, stand_in_ledger.hpp StandInPauseRefusal), as at island prep. Mid-island the host freezes only its
-- own world and only for the create itself: the dilation is set and restored inside this one call, so no frame passes
-- and no other window pauses. An already paused world (shared or Esc pause) is left as it is.
R.FROZEN_DILATION = 0.0001
function R.FrameFrozen(ctx, fn)
    local world, library
    if type(ctx) == 'table' then
        pcall(function()
            local native = ctx.world
            if type(native) == 'table' and type(native._world) == 'function' and type(native._statics) == 'function' then
                world, library = native:_world(), native:_statics()
            end
            local island = ctx.islandWorld
            if (not world or not library) and type(island) == 'table' and type(island.LocalWorldPawn) == 'function' then
                local pawn
                world, pawn, library = island:LocalWorldPawn()
                if not pawn then world, library = nil, nil end
            end
        end)
    end
    local okRead, before = false, nil
    if world and library then okRead, before = pcall(library.GetGlobalTimeDilation, library, world) end
    if not okRead or type(before) ~= 'number' or before ~= before or before <= 0 or before <= 0.001 then return fn() end
    pcall(library.SetGlobalTimeDilation, library, world, R.FROZEN_DILATION)
    local results = table.pack(pcall(fn))
    pcall(library.SetGlobalTimeDilation, library, world, before)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end
function R:_lateStandIns(session, hd, now, ctx)
    if type(hd) ~= 'table' or type(hd.AddPeer) ~= 'function' or type(hd.IslandBound) ~= 'function' or not hd:IslandBound() then return end
    self.lateTried = self.lateTried or {}
    for _, player in ipairs(remotePlayers(session)) do
        local key = player.key
        local tried = self.lateTried[key]
        if player.conn == 'connected' and hd:Status(key) == 'stand_in_missing'
            and (not tried or now - tried.at >= (tried.wait or R.LATE_STANDIN_SECONDS)) then
            local okCall, ok, why = pcall(R.FrameFrozen, ctx, function() return hd:AddPeer(key, characterOf(session, key)) end)
            if not okCall then ok, why = false, 'late_stand_in_error:' .. tostring(ok):sub(1, 120) end
            if ok then
                self.lateTried[key] = nil
                if self.upgradeApplied then self.upgradeApplied[key] = nil end
                if self.upgradeRefused then self.upgradeRefused[key] = nil end
                self:_log('RunSync late stand-in peer=%s created', key)
            else
                local reason = tostring(why)
                if not tried or tried.reason ~= reason then
                    self:_log('RunSync late stand-in peer=%s refused reason=%s', key, reason)
                end
                local wait = (tried and tried.reason == reason) and math.min(R.LATE_STANDIN_MAX_SECONDS, (tried.wait or R.LATE_STANDIN_SECONDS) * 2)
                    or R.LATE_STANDIN_SECONDS
                self.lateTried[key] = { at = now, reason = reason, wait = wait }
            end
        end
    end
end

function R:_fail(p, reason)
    p.stage, p.reason = 'failed', tostring(reason):sub(1, 300)
    self.state, self.reason = 'prep_failed', p.reason
    self:_log('RunSync prep phase=%s failed reason=%s', p.phase, p.reason)
end
function R:_waitOnce(p, reason)
    if p.waitReason == reason then return end
    p.waitReason = reason
    self:_log('RunSync prep phase=%s waiting reason=%s', p.phase, reason)
end

-- Test 15 (Coder B): a fresh process that rejoins mid-island has no process self-tests, and those only run under a
-- host-held prep pause, so its rows never bound. The host remembers which connected clients passed the process prep
-- since they (re)connected (any reconnection may be a new process); when the island is ready and a connected client
-- has not, it runs a short late-join process prep: one brief shared pause, every client reports (the others from
-- their cache), then the island stays ready (no island re-prep). A client that fails it, or that does not report
-- within LATE_PREP_SECONDS, is logged and not asked again until it reconnects; the run goes on either way.
R.LATE_PREP_SECONDS = 10
function R:_lateJoiners(session)
    self.processOk = self.processOk or {}
    local out = {}
    for _, player in ipairs(remotePlayers(session)) do
        if player.conn ~= 'connected' then self.processOk[player.key] = nil
        elseif self.processOk[player.key] == nil then out[#out + 1] = player.key end
    end
    return out
end
function R:_markProcessOk(session, value)
    self.processOk = self.processOk or {}
    for _, player in ipairs(remotePlayers(session)) do
        if player.conn == 'connected' and self.processOk[player.key] == nil then self.processOk[player.key] = value end
    end
end
function R:_hostTick(ctx, session, now)
    local hd = self:_hd()
    if hd then hd:Poll(); self:_trackRoster(session, hd) end
    local p = self.prep
    if not p or p.key ~= ctx.key then
        if p and hd then hd:EndIsland() end
        p = { key = ctx.key, phase = self.processDone and 'island' or 'process', stage = 'visible', standIns = 0 }
        self.prep = p
        self.state, self.reason = 'prep', nil
    end
    -- Test 14 (Coder C): after this island's prep created the stand-ins, late peers get theirs here
    if hd and p.phase == 'island' and (p.stage == 'done' or p.stage == 'waiting') then self:_lateStandIns(session, hd, now, ctx) end
    local late = self:_lateJoiners(session)
    if p.stage == 'done' and #late > 0 and p.binding then
        p.late, p.lateAt, p.phase, p.stage, p.waitReason, p.publishedAt = late, now, 'process', 'pausing', nil, nil
        self:_log('RunSync late join prep phase=process peers=%d', #late)
    end
    if p.late and now - (p.lateAt or now) >= R.LATE_PREP_SECONDS then
        self:_log('RunSync late join prep done gave_up=%d (no report within %ds; the run goes on)', #p.late, R.LATE_PREP_SECONDS)
        self:_markProcessOk(session, 'gave_up')
        p.late, p.phase, p.stage = nil, 'island', 'done'
        return
    end
    if p.stage == 'done' or p.stage == 'failed' then return end
    if p.stage == 'visible' then
        local binding = bindingOf(ctx)
        if binding and visible(ctx) then p.binding = binding; p.stage = 'pausing' end
        return
    end
    if p.stage == 'pausing' then
        if not sameBinding(p.binding, ctx) then p.stage = 'visible'; return end
        local status = session:AuthorityPrepStatus(ctx.key)
        if status and status.phase == p.phase and visible(ctx) and physicallyPaused(ctx) == true then p.stage = 'run' end
        return
    end
    if p.stage == 'run' then
        local why = prepConditions(ctx, p.binding)
        if why then return self:_fail(p, why) end
        if p.phase == 'process' then return self:_hostProcess(p) end
        return self:_hostIsland(p, ctx, session, hd)
    end
    if p.stage == 'waiting' then
        local status = session:AuthorityPrepStatus(ctx.key)
        if not status or status.phase ~= p.phase then p.stage = 'pausing'; return end
        if status.failed and p.late then
            -- a late joiner that fails its self-tests never stops the run: its rows simply stay off
            self:_log('RunSync late join prep done failed slot=%d reason=%s', status.failed.slot, tostring(status.failed.reason))
            self:_markProcessOk(session, 'failed')
            p.late, p.phase, p.stage = nil, 'island', 'done'
            return
        end
        if status.failed then
            return self:_fail(p, string.format('client_failed:slot=%d:%s', status.failed.slot, tostring(status.failed.reason)))
        end
        if #status.waiting > 0 then
            if not p.publishedAt or now - p.publishedAt >= REPUBLISH_SECONDS then
                p.publishedAt = now; pcall(session.PublishAuthorityPrep, session)
            end
            return
        end
        if p.phase == 'process' then
            self.processDone = true
            self:_markProcessOk(session, true)
            if p.late then
                self:_log('RunSync late join prep done peers=%d', #p.late)
                p.late, p.phase, p.stage, p.waitReason, p.publishedAt = nil, 'island', 'done', nil, nil
                return
            end
            p.phase, p.stage, p.waitReason, p.publishedAt = 'island', 'pausing', nil, nil
        else
            p.stage = 'done'; self.state, self.reason = 'ready', nil
            self:_markProcessOk(session, true)   -- test 15: the island prep ran (or reused) every client's self-tests
            self:_log('RunSync prep phase=island complete standIns=%d', p.standIns)
        end
    end
end

function R:_hostRow(session, id)
    local registry = session.enemies
    local record = type(registry) == 'table' and type(id) == 'string' and registry.records and registry.records[id] or nil
    if not record or registry.slots[record.slot] ~= id then return nil end
    return record
end
function R:_combatTick(ctx, session)
    session:EnableAttackIntents()
    if not self.combat then
        self.combat = HostCombat.new({ budget = 8, capacity = 128, perPeer = 16,
            context = function() return self.combatKey end,
            connected = function(peer)
                for _, player in ipairs(remotePlayers(session)) do
                    if player.key == peer and player.conn == 'connected' then return true end
                end
                return false
            end,
            enemy = function(id) return self:_hostRow(session, id) end,
            paused = function() return type(session.sharedPause) == 'table' and session.sharedPause.paused == true end,
            resolve = function(peer, id, attack, sequence, context)
                local record = self:_hostRow(session, id)
                local ok, why = self:ApplyRemoteHit(self.combatCtx, session, peer,
                    { context = context, sequence = sequence, enemyId = id, attack = attack }, record and record.slot)
                if not ok then self:_log('RunSync attack refused peer=%s seq=%d reason=%s', peer, sequence, tostring(why)) end
                return ok == true
            end,
            result = function(peer, sequence, ok) session:SendAttackResult(peer, sequence, ok) end })
    end
    self.combatCtx = ctx
    if self.combatKey ~= ctx.key then self.combatKey = ctx.key; self.combat:Reset(ctx.key) end
    for _, item in ipairs(session:DrainAttackIntents()) do
        local ok, why = self.combat:Submit(item.peer, item.intent)
        if not ok then
            self.counters.attacks.refused = self.counters.attacks.refused + 1
            local sequence = type(item.intent) == 'table' and math.type(item.intent.sequence) == 'integer' and item.intent.sequence or 0
            self:_log('RunSync attack refused peer=%s seq=%d reason=%s', tostring(item.peer), sequence, tostring(why))
            if sequence > 0 then session:SendAttackResult(item.peer, sequence, false) end
        end
    end
    self.combat:Tick()
end

-- Diagnostics (test 10 was silent): "ACTORSCAN found=<class:n,...> mapped=<n> sent=<n> skip=<reason:n,...>" whenever
-- that line changes, and "ACTORSCAN off reason=no_send_route|no_registry" once when the host cannot scan at all.
function R:_actorsHostTick(ctx, session, now)
    local off = type(session.SendActorInfo) ~= 'function' and 'no_send_route' or type(session.enemies) ~= 'table' and 'no_registry' or nil
    if off then
        if self.actorScanOff ~= off then self.actorScanOff = off; self:_log('ACTORSCAN off reason=%s', off) end
        return
    end
    self.actorScanOff = nil
    if self.actorScanAt and now - self.actorScanAt < R.ACTOR_SCAN_SECONDS then return end
    self.actorScanAt = now
    local looks, stats = ActorScan.Scan(self.options.G, session.enemies, ctx.epoch)
    local sentCount = 0
    self.actorSent = self.actorSent or {}
    local hostKey = session.identity and session.identity.key
    for _, player in ipairs(remotePlayers(session)) do
        if player.conn == 'connected' and player.key ~= hostKey then
            local sent = self.actorSent[player.key] or {}
            self.actorSent[player.key] = sent
            for _, info in ipairs(looks) do
                local at = sent[info.id]
                if not at or now - at >= R.ACTOR_RESEND_SECONDS then
                    if session:SendActorInfo(player.key, info) then sent[info.id] = now; sentCount = sentCount + 1 end
                end
            end
        end
    end
    local line = ActorScan.Summary(stats, #looks, sentCount)
    if line ~= self.actorScanLine then self.actorScanLine = line; self:_log('ACTORSCAN %s', line) end
end
-- Handler classes (D43 follow-up): how common each enemy class is on the host. The registry is sampled once a second;
-- every CENSUS_SECONDS one line "HOSTCLASSES alive=<class:n,...> peak=<class:n,...> seen=<class:n,...>" (seen = new
-- lifetimes found at the samples, so a row born and retired between two samples is missed). Counts restart per island.
R.CENSUS_SECONDS = 10
local function classList(counts)
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = k .. ':' .. counts[k] end
    return #out > 0 and table.concat(out, ',') or '-'
end
function R:_classCensusTick(session, now)
    local reg = type(session) == 'table' and session.enemies
    if type(reg) ~= 'table' or type(reg.records) ~= 'table' then return nil end
    local c = self.census
    if not c or c.epoch ~= reg.epoch then
        c = { epoch = reg.epoch, start = now, peak = {}, seen = {}, last = 0 }
        self.census = c
    end
    if c.at and now - c.at < 1 then return true end
    c.at = now
    local alive, newest = {}, c.last
    for id, record in pairs(reg.records) do
        local class = record.enemyType
        if math.type(class) == 'integer' then
            if not record.dead then alive[class] = (alive[class] or 0) + 1 end
            local n = tonumber(tostring(id):match(':(%d+)$'))
            if n and n > c.last then
                c.seen[class] = (c.seen[class] or 0) + 1
                if n > newest then newest = n end
            end
        end
    end
    c.last = newest
    for class, n in pairs(alive) do if n > (c.peak[class] or 0) then c.peak[class] = n end end
    if now - c.start >= R.CENSUS_SECONDS then
        c.start = now
        self:_log('HOSTCLASSES alive=%s peak=%s seen=%s', classList(alive), classList(c.peak), classList(c.seen))
    end
    return true
end
-- Portals on clients (test 10): the host scans its portals once a second and sends "PORTAL_STATE" to every connected
-- client when its spots change, to a new (late or rejoined) peer at once and every PORTAL_RESEND_SECONDS; each change
-- per peer is logged "PORTAL sent peer=<key> spots=<n>". The client mirrors them (gmp_portal_mirror.lua).
R.PORTAL_SCAN_SECONDS, R.PORTAL_RESEND_SECONDS = 1, 5
function R:_portalsHostTick(ctx, session, now)
    if type(session.SendPortalState) ~= 'function' then return end
    if self.portalScanAt and now - self.portalScanAt < R.PORTAL_SCAN_SECONDS then return end
    self.portalScanAt = now
    local list, seen = PortalMirror.HostSpots(self.options.G)
    local spots = PortalMirror.Encode(list)
    local f = { epoch = math.tointeger(ctx.epoch) or 0, island = math.tointeger(ctx.island) or 0, spots = spots }
    -- test 11: only spots=0 ever went out; say what the scan sees whenever that changes
    local scanLine = string.format('PORTAL scan raw=%d game=%d spots=%d island=%d sample=%s', seen.raw, seen.game, #list, f.island,
        tostring(seen.sample or '-'))
    if scanLine ~= self.portalScanLine then self.portalScanLine = scanLine; self:_log('%s', scanLine) end
    local state = f.epoch .. ':' .. f.island .. ':' .. spots
    self.portalSent = self.portalSent or {}
    local hostKey = session.identity and session.identity.key
    for _, player in ipairs(remotePlayers(session)) do
        if player.conn == 'connected' and player.key ~= hostKey then
            local last = self.portalSent[player.key]
            if not last or last.state ~= state or now - last.at >= R.PORTAL_RESEND_SECONDS then
                if session:SendPortalState(player.key, f) then
                    if not last or last.state ~= state then
                        local n = 0; for _ in spots:gmatch('[^;]+') do n = n + 1 end
                        self:_log('PORTAL sent peer=%s spots=%d island=%d', player.key, n, f.island)
                    end
                    self.portalSent[player.key] = { state = state, at = now }
                end
            end
        end
    end
end
function R:_portalsClientTick(ctx, session)
    if type(session.PortalState) ~= 'function' then return end
    self.portalMirror = self.portalMirror or PortalMirror.new({ G = self.options.G, log = function(line) self:_log('%s', line) end })
    local ok, why = pcall(self.portalMirror.Tick, self.portalMirror, ctx, session:PortalState())
    if not ok and self.portalMirrorError ~= tostring(why) then
        self.portalMirrorError = tostring(why); self:_log('PORTAL shown ok=false reason=%s', tostring(why))
    end
end
-- R1 attempt 5: client AOE observations (ATTACK_AOE) of movement/contact class passives. Each is resolved once by the
-- host's own DamageAOE (gmp_native_host_damage.lua Aoe) when it is for this context, after this island's prep, from a
-- connected peer, within AOE_PLAYER_RANGE of that peer's presence position and within AOE_PER_SECOND; credit (damage,
-- kills) is only what the host read back from its own rows, under weapon "aoe_item_<itemTypeIndex>" ("aoe_passive").
-- Logged once a second per peer: "RunSync aoe peer=<key> resolved=<n> dealt=<sum> hits=<sum> kills=<sum> refused=<n>
-- reasons=<reason:n,...>" (a particle flood never floods the log). A client sequence is a replay only on the same
-- connection (a reconnected client starts again at 1); the native resolver gets the host's own per-peer sequence.
function R:_aoeReport(now)
    for peer, sum in pairs(self.aoeSummary or {}) do
        if now - sum.start >= 1 then
            if sum.resolved + sum.refused + sum.hits + (sum.unsettled or 0) > 0 or sum.dealt > 0 then
                local reasons = {}
                for _, why in ipairs(sum.order) do reasons[#reasons + 1] = why .. ':' .. sum.reasons[why] end
                self:_log('RunSync aoe peer=%s resolved=%d dealt=%s hits=%d kills=%d refused=%d reasons=%s', peer, sum.resolved,
                    tostring(sum.dealt), sum.hits, sum.kills, sum.refused, #reasons > 0 and table.concat(reasons, ',') or '-')
            end
            self.aoeSummary[peer] = nil
        end
    end
end
function R:_aoeSum(peer, now)
    self.aoeSummary = self.aoeSummary or {}
    local sum = self.aoeSummary[peer]
    if not sum then
        sum = { start = now, resolved = 0, dealt = 0, hits = 0, kills = 0, refused = 0, reasons = {}, order = {} }
        self.aoeSummary[peer] = sum
    end
    return sum
end
-- User rule (own numbers only): a client AOE lands about a second after the host's call, outside QuietNumbers. The
-- host hooks its controller's SpawnHitNumber(damage, location, ...) once and, inside a client AOE's circle until its
-- settle window has passed, sets that call's damage parameter to 0 (under DamageNumbersLowLimit: no number and no
-- camera shake; real damage is never touched). At most QUIET_ZONES circles; the host's own numbers elsewhere stay.
R.SPAWN_HIT_NUMBER = '/Game/Blueprints/EnemyController/BP_EnemyController.BP_EnemyController_C:SpawnHitNumber'
R.QUIET_ZONES = 64
function R:_quietZone(x, y, radius, untilT)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(radius) ~= 'number' or type(untilT) ~= 'number' then return end
    self.quietZones = self.quietZones or {}
    local zones = self.quietZones
    if #zones >= R.QUIET_ZONES then table.remove(zones, 1) end
    zones[#zones + 1] = { x = x, y = y, r2 = radius * radius, untilT = untilT }
end
function R:_hitNumberHook()
    local G = self.options.G
    if self.hitNumberHooked or type(G) ~= 'table' or type(G.RegisterHook) ~= 'function' or type(G.StaticFindObject) ~= 'function' then return end
    local okFind, fn = pcall(G.StaticFindObject, R.SPAWN_HIT_NUMBER)
    if not (okFind and fn ~= nil and pcall(function() return fn:IsValid() end)) then return end
    self.hitNumberHooked = true
    local ok, why = pcall(G.RegisterHook, R.SPAWN_HIT_NUMBER, function(_, damage, location)
        pcall(function()
            local zones = self.quietZones
            if not zones or #zones == 0 then return end
            local okNow, now = pcall(self.options.clock or os.clock)
            now = okNow and type(now) == 'number' and now or 0
            local at = location:get()
            local x, y = at.X, at.Y
            local keep = {}
            local inside = false
            for _, z in ipairs(zones) do
                if now <= z.untilT then
                    keep[#keep + 1] = z
                    if (x - z.x) ^ 2 + (y - z.y) ^ 2 <= z.r2 then inside = true end
                end
            end
            self.quietZones = keep
            if inside then damage:set(0); self.numbersZeroed = (self.numbersZeroed or 0) + 1 end
        end)
    end)
    self:_log('RunSync own-numbers hook installed=%s %s', tostring(ok), ok and '' or tostring(why))
end
function R:_aoeSettleTick(now)
    local pending = self.aoePending
    if not pending or #pending == 0 then return end
    local hd = self:_hd()
    local keep = {}
    for _, item in ipairs(pending) do
        if now < item.due or not hd then keep[#keep + 1] = item
        else
            local ok, why, result = hd:AoeSettle(item.peer, item.sequence)
            local sum = self:_aoeSum(item.peer, now)
            if ok then
                sum.dealt, sum.hits, sum.kills = sum.dealt + result.dealt, sum.hits + result.hits, sum.kills + result.kills
                if result.hits > 0 then
                    self.attribution:Record(item.peer, item.weapon, result.dealt, false)
                    for _ = 1, result.kills do self.attribution:Record(item.peer, item.weapon, 0, true) end
                end
            else
                sum.unsettled = (sum.unsettled or 0) + 1
                if not sum.reasons['settle:' .. tostring(why)] then sum.reasons['settle:' .. tostring(why)] = 0; sum.order[#sum.order + 1] = 'settle:' .. tostring(why) end
                sum.reasons['settle:' .. tostring(why)] = sum.reasons['settle:' .. tostring(why)] + 1
            end
        end
    end
    self.aoePending = keep
end
function R:_aoeTick(ctx, session, now)
    self:_hitNumberHook()
    session:EnableAttackAoe()
    local items = session:DrainAttackAoe()
    self:_aoeReport(now)
    self:_aoeSettleTick(now)
    if #items == 0 then return end
    self.aoeWindow = self.aoeWindow or {}
    self.aoeLastSequence = self.aoeLastSequence or setmetatable({}, { __mode = 'k' })
    self.aoeHostSequence = self.aoeHostSequence or {}
    local positions
    for _, item in ipairs(items) do
        local aoe, peer, why = item.aoe, item.peer, nil
        local p = self.prep
        local conn = item.conn or peer
        if aoe.sequence <= (self.aoeLastSequence[conn] or 0) then why = 'aoe_replayed'
        elseif aoe.context ~= ctx.key then why = 'context_changed'
        elseif not p or p.key ~= ctx.key or p.stage ~= 'done' then why = 'prep_not_ready'
        elseif type(session.sharedPause) == 'table' and session.sharedPause.paused == true then why = 'paused'
        else
            local connected = false
            for _, player in ipairs(remotePlayers(session)) do
                if player.key == peer and player.conn == 'connected' then connected = true end
            end
            if not connected then why = 'peer_not_connected' end
        end
        if not why then
            if not positions then
                positions = {}
                local presence = session.presence
                local ok, list = false, nil
                if type(presence) == 'table' then ok, list = pcall(presence.Visible, presence, now) end
                if ok and type(list) == 'table' then for _, v in ipairs(list) do positions[v.key] = v end end
            end
            local at = positions[peer]
            if not at or type(at.x) ~= 'number' or type(at.y) ~= 'number' then why = 'aoe_no_player_position'
            elseif (at.x - aoe.x) ^ 2 + (at.y - aoe.y) ^ 2 > R.AOE_PLAYER_RANGE ^ 2 then why = 'aoe_far_from_player' end
        end
        if not why then
            local w = self.aoeWindow[peer]
            if not w or now - w.start >= 1 then w = { start = now, n = 0 }; self.aoeWindow[peer] = w end
            if w.n >= R.AOE_PER_SECOND then why = 'aoe_rate' else w.n = w.n + 1 end
        end
        local result
        if not why then
            local hd = self:_hd()
            if not hd then why = 'stand_in_native_unavailable'
            else
                local ok, reason
                local sequence = (self.aoeHostSequence[peer] or 0) + 1
                self.aoeHostSequence[peer] = sequence
                ok, reason, result = hd:Aoe({ context = ctx.key, epoch = ctx.epoch }, peer, sequence, aoe)
                if not ok then why = reason
                else self:_quietZone(aoe.x, aoe.y, aoe.radius + 100, now + R.AOE_SETTLE_SECONDS + 0.3) end
            end
        end
        if why ~= 'aoe_replayed' and why ~= 'context_changed' then self.aoeLastSequence[conn] = aoe.sequence end
        local sum = self:_aoeSum(peer, now)
        if why then
            self.counters.attacks.refused = self.counters.attacks.refused + 1
            sum.refused = sum.refused + 1
            if not sum.reasons[why] then sum.reasons[why] = 0; sum.order[#sum.order + 1] = why end
            sum.reasons[why] = sum.reasons[why] + 1
        else
            self.counters.attacks.accepted = self.counters.attacks.accepted + 1
            sum.resolved = sum.resolved + 1
            -- credited only by the settle (the immediate read-back cannot see DamageAOE's damage yet)
            self.aoePending = self.aoePending or {}
            if #self.aoePending >= R.AOE_PENDING_MAX then table.remove(self.aoePending, 1) end
            self.aoePending[#self.aoePending + 1] = { peer = peer, sequence = self.aoeHostSequence[peer], due = now + R.AOE_SETTLE_SECONDS,
                weapon = aoe.attack > 0 and ('aoe_item_' .. (aoe.attack - 1)) or 'aoe_passive' }
        end
    end
end

function R:_damageHostTick(ctx, session, now)
    if type(session.sharedPause) == 'table' and session.sharedPause.paused == true then return end
    local presence, registry = session.presence, session.enemies
    if type(presence) ~= 'table' or type(registry) ~= 'table' or type(registry.records) ~= 'table' then return end
    local lives, hostKey = self.lives, session.identity.key
    local ok, clients
    if lives then ok, clients = pcall(presence.Visible, presence, now)          -- the host's own player too
    else ok, clients = pcall(presence.Visible, presence, now, hostKey) end
    if not ok or type(clients) ~= 'table' then return end
    if lives then
        local touchable = {}
        for _, c in ipairs(clients) do
            local shielded = lives.ghosts[c.key] ~= nil or (self.invulnerableUntil and (self.invulnerableUntil[c.key] or -1) > now)
            touchable[#touchable + 1] = { key = c.key, x = c.x, y = c.y, dead = c.dead or shielded }
        end
        clients = touchable
    end
    local enemies = {}
    for _, record in pairs(registry.records) do
        enemies[#enemies + 1] = { x = record.x, y = record.y, damage = record.damage, dead = record.dead }
    end
    self.contact = self.contact or Contact.new()
    local own = {}
    for _, hit in ipairs(self.contact:Hits(now, clients, enemies)) do
        self.hitSequence = (self.hitSequence or 0) + 1
        if lives and hit.peer == hostKey then
            own[#own + 1] = { context = ctx.key, sequence = self.hitSequence, damage = hit.damage }
        elseif session:SendClientHit(hit.peer, { context = ctx.key, sequence = self.hitSequence, damage = hit.damage, enemies = hit.enemies }) then
            self.damageSent = (self.damageSent or 0) + 1
        end
    end
    if lives then self:_takeHits(ctx, session, own, now) end
end
-- The local player's pawn (both roles), its contact check switched off once per pawn.
function R:_localPawn(ctx)
    local ok, pawn = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil end
        return select(2, island:LocalWorldPawn())
    end)
    if not ok or pawn == nil then return nil end
    local identity = Liveness.Address(pawn) or pawn
    local component = pawn.BPC_CheckIfPlayerTakeDamage
    if self.contactOffPawn ~= identity and component ~= nil then
        local off = pcall(component.SetComponentTickEnabled, component, false)
        if off then self.contactOffPawn = identity; self:_log('RunSync client damage: local contact check off') end
    end
    if self.ghost and self.ghostPawn ~= identity then
        -- a ghost's new pawn (island change) is a ghost too
        if pcall(function() pawn.IncomingDamageReduction = 0.0 end) then self.ghostPawn = identity end
    end
    return pawn, component
end
local function number(pawn, field)
    local ok, v = pcall(function() return pawn[field] end)
    if ok and type(v) == 'number' and v == v then return v end
    return nil
end
-- Applies host hits of this context through the game's ChangeHP. With SHARED_LIVES a hit that would reach 0 HP makes
-- the player a ghost instead (never the game's Death); a ghost takes no hits.
function R:_takeHits(ctx, session, hits, now)
    local pawn, component = self:_localPawn(ctx)
    if not pawn or #hits == 0 then return end
    local paused = type(session.sharedPause) == 'table' and session.sharedPause.paused == true
    local multiplier = component and component.DamageMultiplier
    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1000 then
        local policy = session.sessionPolicy
        multiplier = HD.ClientDamageTakenMultiplier(type(policy) == 'table' and policy.artifacts or nil)
    end
    for _, hit in ipairs(hits) do
        if hit.context == ctx.key and not paused and not self.ghost then
            local amount = hit.damage * multiplier + 0.0
            local lethal = false
            if self.lives then
                local hp, reduction = number(pawn, 'HP_Current'), number(pawn, 'IncomingDamageReduction') or 1
                local ok, invincible = pcall(function() return pawn['Invincible?'] end)
                lethal = hp ~= nil and not (ok and invincible == true) and amount * reduction >= hp
            end
            if lethal then
                self:_becomeGhost(ctx, session, pawn, now)
            elseif pcall(pawn.ChangeHP, pawn, amount, false) then
                self.damageHits = (self.damageHits or 0) + 1
                self.damageTaken = (self.damageTaken or 0) + amount
            end
        end
    end
end
------------------------------------------------------------------ D50 (enemy attacks hit clients; Coder C API)
-- RunSync:QueueClientHit(key, damage, source) -> ok: one hit of `damage` (game HP, before the receiver's own
-- DamageMultiplier, like CLIENT_HIT) for player `key`, the host's own key included. Refused at once for bad values,
-- while the shared pause is on, for a ghost and inside an invulnerability window; sent in the next host tick through
-- the existing path (a client: CLIENT_HIT with this sync's sequence; the host: _takeHits, lives-aware). At most
-- CLIENT_HITS_QUEUE pending; "RunSync d50 hits sent=<n> refused=<reason:n> sources=<source:n>" once a second.
R.CLIENT_HITS_QUEUE = 64
function R:_hitRefusal(key, now)
    local s = self.hostSession
    if type(s) == 'table' and type(s.sharedPause) == 'table' and s.sharedPause.paused == true then return 'paused' end
    if self.lives and self.lives.ghosts[key] ~= nil then return 'ghost' end
    if self.invulnerableUntil and (self.invulnerableUntil[key] or -1) > (now or 0) then return 'invulnerable' end
    if self.ghost and s and s.identity and key == s.identity.key then return 'ghost' end
    return nil
end
function R:QueueClientHit(key, damage, source)
    if type(key) ~= 'string' or key == '' or #key > 64 or type(damage) ~= 'number' or damage ~= damage or damage <= 0
        or damage > 1e6 then return false end
    source = type(source) == 'string' and source:sub(1, 32) or '?'
    local okNow, now = pcall(self.options.clock or os.clock)
    local why = self:_hitRefusal(key, okNow and now or 0)
    local w = self.hitWindow or { sent = 0, refused = {}, sources = {} }
    self.hitWindow = w
    if why then w.refused[why] = (w.refused[why] or 0) + 1; return false end
    self.queuedHits = self.queuedHits or {}
    if #self.queuedHits >= R.CLIENT_HITS_QUEUE then w.refused.queue_full = (w.refused.queue_full or 0) + 1; return false end
    self.queuedHits[#self.queuedHits + 1] = { key = key, damage = damage, source = source }
    w.sources[source] = (w.sources[source] or 0) + 1
    return true
end
local function countList(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. ':' .. t[k] end
    return #keys > 0 and table.concat(keys, ',') or '-'
end
function R:_clientHitsTick(ctx, session, now)
    self.hostSession = session
    local queue = self.queuedHits
    local w = self.hitWindow
    if queue and #queue > 0 then
        self.queuedHits = {}
        local hostKey = session.identity and session.identity.key
        local own = {}
        for _, h in ipairs(queue) do
            local why = self:_hitRefusal(h.key, now)
            if why then w.refused[why] = (w.refused[why] or 0) + 1
            else
                self.hitSequence = (self.hitSequence or 0) + 1
                if h.key == hostKey then
                    own[#own + 1] = { context = ctx.key, sequence = self.hitSequence, damage = h.damage }
                    w.sent = w.sent + 1
                elseif type(session.SendClientHit) == 'function'
                    and session:SendClientHit(h.key, { context = ctx.key, sequence = self.hitSequence, damage = h.damage, enemies = 0 }) then
                    w.sent = w.sent + 1
                else
                    w.refused.not_sent = (w.refused.not_sent or 0) + 1
                end
            end
        end
        if #own > 0 then self:_takeHits(ctx, session, own, now) end
    end
    if w then
        w.start = w.start or now
        if now - w.start >= 1 then
            if w.sent > 0 or next(w.refused) then
                self:_log('RunSync d50 hits sent=%d refused=%s sources=%s', w.sent, countList(w.refused), countList(w.sources))
            end
            self.hitWindow = { sent = 0, refused = {}, sources = {}, start = now }
        end
    end
end
-- RunSync:StandIn(key) -> BP_Player | nil: the peer stand-in, found again among the live BP_Player objects by the full
-- name the native create reported (gmp_run_sync_liveness rule; the fresh handle is reused at most STANDIN_FIND_SECONDS).
-- With flags.enemyAttacks every stand-in follows its client presence position each host tick (teleport) and is set up
-- once: invincible, hidden, collision off (it never collects pickups or triggers overlaps credited to the host), and the
-- host EnemyController (the queen component reads Player.EnemyController before it fires). Its ChangeHP belongs to
-- Coder C (per-attack routing); nothing here hooks it.
R.STANDIN_FIND_SECONDS = 0.5
function R:StandIn(key)
    local hd = self.usedHd
    if type(key) ~= 'string' or type(hd) ~= 'table' or type(hd.StandInPath) ~= 'function' then return nil end
    local okPath, path = pcall(hd.StandInPath, hd, key)
    if not okPath or type(path) ~= 'string' then return nil end
    local okNow, now = pcall(self.options.clock or os.clock)
    now = okNow and type(now) == 'number' and now or 0
    self.standInFound = self.standInFound or {}
    local c = self.standInFound[key]
    if c and c.path == path and now - c.at < R.STANDIN_FIND_SECONDS then return c.pawn end
    local G = self.options.G
    local found
    if type(G) == 'table' and type(G.FindAllOf) == 'function' then
        local ok, list = pcall(G.FindAllOf, 'BP_Player_C')
        if ok and type(list) == 'table' then
            for _, actor in ipairs(list) do
                local okName, name = pcall(function() return actor:IsValid() == true and actor:GetFullName() end)
                if okName and name == path then found = actor; break end
            end
        end
    end
    self.standInFound[key] = found and { pawn = found, path = path, at = now } or nil
    return found
end
function R:_standInsFollowTick(ctx, session, now)
    if self.standInsKey ~= ctx.key then self.standInsKey, self.standInFound, self.standInsReady = ctx.key, {}, {} end
    local presence = session.presence
    if type(presence) ~= 'table' or type(presence.Visible) ~= 'function' then return end
    local ok, list = pcall(presence.Visible, presence, now)
    if not ok or type(list) ~= 'table' then return end
    local hostKey = session.identity and session.identity.key
    for _, p in ipairs(list) do
        if type(p) == 'table' and p.key ~= hostKey and type(p.x) == 'number' and type(p.y) == 'number' then
            local pawn = self:StandIn(p.key)
            if pawn then
                local address = Liveness.Address(pawn) or pawn
                if self.standInsReady[p.key] ~= address then
                    self.standInsReady[p.key] = address
                    pcall(function() pawn['Invincible?'] = true end)
                    pcall(function() pawn:SetActorHiddenInGame(true) end)
                    pcall(function() pawn:SetActorEnableCollision(false) end)
                    pcall(function()
                        local controller = ctx.world and ctx.world:_enemyController()
                        if controller then pawn.EnemyController = controller end
                    end)
                    self:_log('RunSync d50 stand-in ready peer=%s', tostring(p.key))
                end
                pcall(function() pawn:K2_SetActorLocation({ X = p.x, Y = p.y, Z = p.z or 0 }, false, {}, true) end)
            end
        end
    end
end
function R:_becomeGhost(ctx, session, pawn, now)
    self.ghost = true
    self.ghostReduction = number(pawn, 'IncomingDamageReduction') or 1.0
    if pcall(function() pawn.IncomingDamageReduction = 0.0 end) then self.ghostPawn = Liveness.Address(pawn) or pawn end
    self:_log('RunSync lives: down (ghost)')
    if ctx.role == 'host' then self.lives:Down(session.identity.key, now)
    elseif not session:SendPlayerDown(ctx.key) then self:_log('RunSync lives: down report not sent') end
end
function R:_revive(ctx, hp, invulnerable)
    local pawn = self:_localPawn(ctx)
    if not pawn or not self.ghost then return false end
    pcall(function() pawn.IncomingDamageReduction = self.ghostReduction or 1.0 end)
    local max, current = number(pawn, 'HP_MAX'), number(pawn, 'HP_Current')
    if max and current and hp * max > current then pcall(pawn.ChangeHP, pawn, hp * max - current, true) end
    pcall(pawn.SetInvincible, pawn, invulnerable)
    self.ghost, self.ghostPawn = false, nil
    self:_log('RunSync lives: revived')
    return true
end
function R:_endRun(ctx)
    if self.livesEnded then return end
    local pawn = self:_localPawn(ctx)
    if not pawn then return end
    self.livesEnded = true
    local ok = pcall(pawn.Death, pawn, false)
    self:_log('RunSync lives: run ended (every player is a ghost) death=%s', ok and 'ok' or 'failed')
end
function R:_damageClientTick(ctx, session, now)
    session:EnableClientHits()
    self:_takeHits(ctx, session, session:TakeClientHits() or {}, now)
end
function R:_livesHostTick(ctx, session, now)
    local lives = self.lives
    session:EnableLives()
    self:_localPawn(ctx)
    for _, down in ipairs(session:DrainPlayerDowns()) do
        if down.context == ctx.key and lives:Down(down.peer, now) then self:_log('RunSync lives: down peer=%s', down.peer) end
    end
    local presence = session.presence
    local paused = type(session.sharedPause) == 'table' and session.sharedPause.paused == true
    local ok, players = false, nil
    if type(presence) == 'table' then ok, players = pcall(presence.Visible, presence, now) end
    if paused then lives:Pause()
    elseif ok and type(players) == 'table' then
        for _, event in ipairs(lives:Tick(now, players)) do
            if event.kind == 'revive' then
                local o = lives.options
                self.invulnerableUntil = self.invulnerableUntil or {}
                self.invulnerableUntil[event.key] = now + o.invulnerable
                local sent
                if event.key == session.identity.key then sent = self:_revive(ctx, o.reviveHp, o.invulnerable)
                else
                    self.reviveSequence = (self.reviveSequence or 0) + 1
                    sent = session:SendPlayerRevive(event.key, { context = ctx.key, sequence = self.reviveSequence,
                        hp = o.reviveHp, invulnerable = o.invulnerable })
                end
                local hd = self:_hd()
                local blast, why = false, 'stand_in_native_unavailable'
                if hd then blast, why = hd:Explosion({ context = ctx.key }, event.x, event.y) end
                self:_log('RunSync lives: revive peer=%s lives=%d sent=%s explosion=%s', event.key, lives.lives,
                    tostring(sent == true), blast and 'ok' or tostring(why))
            elseif event.kind == 'ended' then
                self:_log('RunSync lives: every player is a ghost; run ends')
            end
        end
    end
    if lives.ended then self:_endRun(ctx) end
    -- LIVES_STATE: at once on a change, progress at most every LIVES_PROGRESS_SECONDS, republished every 2 s.
    local state = lives:State()
    local slots, ghosts = {}, {}
    if ok and type(players) == 'table' then for _, pl in ipairs(players) do slots[pl.key] = pl.slot end end
    for key, progress in pairs(state.ghosts) do
        local slot = slots[key]
        if not slot and type(session.roster) == 'table' and type(session.roster.Get) == 'function' then
            local r = session.roster:Get(key); slot = r and r.slot
        end
        if math.type(slot) == 'integer' and slot >= 1 and slot <= 4 then
            ghosts[#ghosts + 1] = { slot = slot, progress = math.floor(progress * 1000 + 0.5) }
        end
    end
    table.sort(ghosts, function(a, b) return a.slot < b.slot end)
    self.livesSlots = ghosts
    local signature = table.concat({ state.revision, state.lives, tostring(state.ended) }, ':')
    local marks = {}
    for _, g in ipairs(ghosts) do marks[#marks + 1] = g.slot .. '=' .. g.progress end
    local progress = table.concat(marks, ',')
    local last = self.livesSent
    local due = not last or last.signature ~= signature or last.context ~= ctx.key
        or (last.progress ~= progress and now - last.at >= LIVES_PROGRESS_SECONDS) or now - last.at >= LIVES_REPUBLISH_SECONDS
    if due then
        session:SendLivesState({ context = ctx.key, revision = state.revision, lives = state.lives, ended = state.ended, ghosts = ghosts })
        self.livesSent = { signature = signature, progress = progress, at = now, context = ctx.key }
    end
end
function R:_livesClientTick(ctx, session)
    session:EnableLives()
    for _, revive in ipairs(session:TakeRevives()) do
        if revive.context == ctx.key then self:_revive(ctx, revive.hp, revive.invulnerable) end
    end
    local state = session:LivesState()
    if state and state.context == ctx.key then
        self.clientLives = state
        if state.ended then self:_endRun(ctx) end
    end
end
function R:_upgradesHostTick(ctx, session, baseOnly)
    session:EnablePlayerStats()
    local p, hd = self.prep, self:_hd()
    if not hd or not p or p.key ~= ctx.key or p.phase ~= 'island' or (p.stage ~= 'waiting' and p.stage ~= 'done') then return end
    self.upgradeApplied, self.upgradeRefused = self.upgradeApplied or {}, self.upgradeRefused or {}
    for _, player in ipairs(remotePlayers(session)) do
        local stats = player.conn == 'connected' and session:PlayerStats(player.key) or nil
        -- base only: the first stats this stand-in generation (island) receives, later revisions are not applied
        local mark = stats and ((baseOnly and 'base' or stats.revision) .. ':' .. tostring(hd.generation)) or nil
        if mark and self.upgradeApplied[player.key] ~= mark and self.upgradeRefused[player.key] ~= mark then
            local ok, why, damage = hd:ApplyStats({ epoch = ctx.epoch }, player.key, stats)
            if ok then
                self.upgradeApplied[player.key] = mark
                self.upgradeRevision = self.upgradeRevision or {}
                self.upgradeRevision[player.key] = stats.revision
                self:_log('RunSync upgrades peer=%s revision=%d weaponDamage=%s', player.key, stats.revision, tostring(damage))
            else
                self.upgradeRefused[player.key] = mark
                self:_log('RunSync upgrades refused peer=%s revision=%d reason=%s', player.key, stats.revision, tostring(why))
            end
        end
    end
end
function R:_upgradesClientTick(ctx, session, now, baseOnly)
    if baseOnly and self.upgradeBaseKey == ctx.key then return end
    local weaponDamage
    local ok, pawnStats = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil end
        local _, pawn = island:LocalWorldPawn()
        if not pawn then return nil end
        -- for the launch check only: the client's own standard-weapon damage (the stand-in derives its own)
        pcall(function() weaponDamage = pawn.PlayerItemsActors[1].BPC_DamageComponent.Damage end)
        if type(weaponDamage) == 'number' then self.lastWeaponDamage = weaponDamage end
        return { damageMulti = pawn.DamageMultiplier, aoeMulti = pawn['AOE DamageMultiplier'], bonusDamage = pawn.ProjectileBonusDamage }
    end)
    if not ok or type(pawnStats) ~= 'table' then return end
    for _, name in ipairs({ 'damageMulti', 'aoeMulti', 'bonusDamage' }) do
        if type(pawnStats[name]) ~= 'number' then return end
    end
    local last = self.upgradeSent
    if last and last.damageMulti == pawnStats.damageMulti and last.aoeMulti == pawnStats.aoeMulti
        and last.bonusDamage == pawnStats.bonusDamage then return end
    if self.upgradeSentAt and now - self.upgradeSentAt < UPGRADE_SEND_SECONDS then return end
    if type(session.SendPlayerStats) == 'function' and session:SendPlayerStats(pawnStats) then
        self.upgradeSent, self.upgradeSentAt = pawnStats, now
        self.upgradeSends = (self.upgradeSends or 0) + 1
        if baseOnly or self.upgradeSends == 1 then
            self:_log('RunSync stats base damageMulti=%s aoeMulti=%s bonusDamage=%s weaponDamage=%s', tostring(pawnStats.damageMulti),
                tostring(pawnStats.aoeMulti), tostring(pawnStats.bonusDamage), tostring(weaponDamage))
        end
        if baseOnly then self.upgradeBaseKey = ctx.key end
    end
end

function R:_hostProcess(p)
    local result, why, cached = self:_stepSelfTests(p.binding)
    if result == 'running' then return end
    if result == 'failed' then return self:_fail(p, why) end
    self:_logSelfTests(cached)
    p.stage = 'waiting'
end

function R:_hostIsland(p, ctx, session, hd)
    if not hd then return self:_fail(p, 'stand_in_native_unavailable') end
    local players = remotePlayers(session)
    local run = { sid = ctx.sid, term = ctx.term, hostKey = ctx.hostKey, epoch = ctx.epoch, peers = {} }
    for i, player in ipairs(players) do run.peers[i] = player.key end
    if Policy.Valid(self.mode) and Policy.Allows(self.mode, 'gameplay') then   -- D47: dev and the friend test build
        local ok, why = hd:ConfigureDevWitness(run)
        if not ok then
            if why == 'dev_witness_previous_run_stand_ins_pending' then return self:_waitOnce(p, why) end
            return self:_fail(p, why)
        end
    end
    local state = processState(self.options.G)
    local island = { generation = state.generation + 1, worldPath = p.binding.worldPath,
        controllerPath = p.binding.controllerPath, paused = true, peers = {} }
    for i, player in ipairs(players) do
        island.peers[i] = { key = player.key, character = characterOf(session, player.key), connected = player.conn == 'connected' }
    end
    if #players == 0 and self.options.standinSelftest then
        local ok, allowed = pcall(self.options.standinSelftest)
        if ok and allowed == true then island.selfTest = { character = characterOf(session, ctx.hostKey) } end
    end
    local ok, created, failure = hd:PrepareIsland(run, island)
    if hd.generation == island.generation then state.generation = island.generation end
    if not ok and failure == 'stand_in_previous_island_pending' then return self:_waitOnce(p, failure) end
    p.standIns = created or 0
    if not ok then return self:_fail(p, failure) end
    self:_log('RunSync prep phase=island standIns=%d', p.standIns)
    p.stage = 'waiting'
end

------------------------------------------------------------------ client
function R:_rowsWanted(ctx) return self.flags.clientEnemyRows == true and ctx.role == 'client' end
function R:_newRows(ctx)
    if self.options.rowsFactory then return self.options.rowsFactory(ctx) end
    local G = self.options.G
    local presentation = require('gmp_native_enemy_instances').new(ctx.world, { cap = 4096,
        log = function(line) self:_log('%s', line) end })
    return Rows.new({ api = { configure = G.GMPAuthorityControllerConfigure, status = G.GMPAuthorityControllerStatus,
        spawn = G.GMPAuthorityHostSpawn, update = G.GMPAuthorityHostUpdate, retire = G.GMPAuthorityHostRetire,
        mapRefresh = G.GMPAuthorityClientMapRefresh },
        -- D43: bosses/uniques get an invisible proxy row of this ordinary class (hits) and an owned visual copy
        proxyClass = R.ACTOR_PROXY_CLASS,
        -- R1 attempt 4: client projectiles must collide with host rows for CLIENT_ATTACKS (gmp_run_sync_rows.lua)
        mapRefresh = self.flags.clientAttacks == true,
        -- test 9 (6.5 ms per apply at TICK_MS=16): presentation at 30 Hz, the collision map at 10 Hz
        presentHz = 30, mapRefreshHz = 10,
        presentation = presentation, log = function(line) self:_log('%s', line) end,
        worldLive = function(path) return Liveness.WorldLive(G, path) end })
end
-- false while a previous island's rows are still being disabled.
-- Test 7: a disable that kept failing was retried every tick forever (and blocked the next island and the next run).
-- Now: a pending component cleanup or a failed disable is retried at most ROWS_SETTLE_TRIES times, ROWS_SETTLE_SECONDS
-- apart, then the rows are force-released (fence and ledger), with one log line.
R.ROWS_SETTLE_TRIES, R.ROWS_SETTLE_SECONDS = 3, 0.5
function R:_rowsSettle(ctx)
    local rows = self.rows
    if not rows or self.rowsKey == ctx.key or rows:Status().state == 'idle' then self.rowsSettle = nil; return true end
    local now = 0
    if self.options.clock then local ok, t = pcall(self.options.clock); if ok and type(t) == 'number' then now = t end end
    local s = self.rowsSettle
    if not s or s.key ~= ctx.key then s = { key = ctx.key, tries = 0, at = -math.huge }; self.rowsSettle = s end
    if now - s.at < R.ROWS_SETTLE_SECONDS then return false end
    s.tries, s.at = s.tries + 1, now
    local done, why = rows:Disable()
    if done == true then self.rowsKey, self.rowsSettle = nil, nil; return true end
    if s.tries < R.ROWS_SETTLE_TRIES then
        if s.tries == 1 then self:_log('RunSync rows disable pending reason=%s (retrying)', tostring(why)) end
        return false
    end
    rows:ForceRelease('disable_failed:' .. tostring(why))
    self:_log('RunSync rows force released after %d tries reason=%s', s.tries, tostring(why))
    self.rowsKey, self.rowsSettle = nil, nil
    return true
end
function R:_rowsEnable(ctx)
    if not (Policy.Valid(self.mode) and Policy.Allows(self.mode, 'gameplay')) then return false, 'rows_require_mode_dev' end
    if not self.rows then
        local ok, rows = pcall(self._newRows, self, ctx)
        if not ok or type(rows) ~= 'table' then return false, 'rows_unavailable:' .. tostring(rows) end
        self.rows = rows
    end
    local ok, why = self.rows:Enable(ctx)
    if ok then self.rowsKey = ctx.key; self:_log('RunSync rows enabled ctx=%s', ctx.key) end
    return ok, why
end
-- Test 11 (visual lag): the players the enemies chase, for the client view's visual-only prediction
-- (gmp_enemy_delta.lua): this client's own pawn and every live presence position.
R.CHASE_READ_SECONDS = 0.1   -- test 12 crash audit: the own pawn read walks the engine objects; at most this often
function R:_chaseTargets(ctx, session)
    local out = {}
    local world = ctx.world
    local okClock, t = pcall(self.options.clock or os.clock)
    t = okClock and type(t) == 'number' and t or nil
    if type(world) == 'table' and type(world.ReadLocal) == 'function' then
        local c = self.chaseSelf
        if not (c and t and c.key == ctx.key and t - c.at < R.CHASE_READ_SECONDS) then
            local ok, me = pcall(world.ReadLocal, world)
            local pos = ok and type(me) == 'table' and type(me.x) == 'number' and type(me.y) == 'number' and not me.dead
                and { x = me.x, y = me.y } or nil
            c = { key = ctx.key, at = t or 0, pos = pos }
            self.chaseSelf = c
        end
        if c.pos then out[#out + 1] = { x = c.pos.x, y = c.pos.y } end
    end
    local presence = session.presence
    if type(presence) == 'table' and type(presence.Visible) == 'function' then
        local clock = self.options.clock
        local okNow, now = pcall(clock or os.clock)
        local ok, list = pcall(presence.Visible, presence, okNow and now or 0)
        if ok and type(list) == 'table' then
            for _, p in ipairs(list) do
                if type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number' and not p.dead then out[#out + 1] = { x = p.x, y = p.y } end
            end
        end
    end
    return out
end
function R:_rowsTick(ctx, session)
    local rows = self.rows
    if not rows or self.rowsKey ~= ctx.key then return end
    local viewStart = os.clock()
    local snapshot = type(session.EnemySnapshot) == 'function' and session:EnemySnapshot(self:_chaseTargets(ctx, session)) or nil
    -- test 14: native rows are a capped nearest-first subset; the ranking follows the local player
    if type(snapshot) == 'table' and self.chaseSelf and self.chaseSelf.key == ctx.key and self.chaseSelf.pos then
        snapshot.focus = self.chaseSelf.pos
    end
    -- D43: the host's boss/unique looks for the rows' visual copies
    if type(snapshot) == 'table' and type(session.ActorInfo) == 'function' then
        snapshot.actors = session:ActorInfo()
        -- one line per new or changed host look (ACTOR_INFO), so a silent boss path shows where it stops
        self.actorLooksLogged = self.actorLooksLogged or {}
        local ids = {}
        for id in pairs(type(snapshot.actors) == 'table' and snapshot.actors or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local look = snapshot.actors[id]
            local key = type(look) == 'table' and (tostring(look.kind) .. '|' .. tostring(look.mesh)) or '?'
            if self.actorLooksLogged[id] ~= key and type(look) == 'table' then
                self.actorLooksLogged[id] = key
                self:_log('ACTORINFO recv id=%s kind=%s name=%s mesh=%s', tostring(id), tostring(look.kind), tostring(look.name), tostring(look.mesh))
            end
        end
    end
    if type(rows.NoteView) == 'function' then rows:NoteView((os.clock() - viewStart) * 1000) end
    local ok, why = rows:Apply(ctx, snapshot)
    -- RejoinReady: a hold in this context (island reload) arms the cover's question again
    if rows:Status().state == 'held' and self.rejoinArmedKey ~= ctx.key then
        self.rejoinArmedKey = ctx.key
        local okNow, t = pcall(self.options.clock or os.clock)
        self.firstSeenAt = okNow and type(t) == 'number' and t or 0
    end
    -- RejoinReady: when the view last changed size (and since when rows were active for this context)
    if self.options.clock then
        local okT, t = pcall(self.options.clock)
        if okT and type(t) == 'number' then
            local received = rows.received or 0
            local v = self.rejoinView
            if not v or v.key ~= ctx.key then self.rejoinView = { key = ctx.key, received = received, since = t, enabledAt = t }
            elseif v.received ~= received then v.received, v.since = received, t end
        end
    end
    if not ok and self.rowsHeld ~= why then self.rowsHeld = why; self:_log('RunSync rows held reason=%s', tostring(why)) end
    -- self-heal: a held rows is recovered after a short wait and resyncs from the next full state
    local clockFn = self.options.clock
    local okNow, now = false, nil
    if clockFn then okNow, now = pcall(clockFn) end
    if okNow and type(now) == 'number' and type(rows.Recover) == 'function' and rows:Status().state == 'held' then
        if type(rows.EnsureFence) == 'function' then pcall(rows.EnsureFence, rows) end
        if self.rowsRecoverKey ~= ctx.key then self.rowsRecoverKey, self.rowsRecoveries, self.rowsRelapses = ctx.key, 0, 0 end
        self.rowsHeldAt = self.rowsHeldAt or now
        local wait = R.ROWS_RECOVER_SECONDS * 2 ^ math.min(self.rowsRelapses or 0, R.ROWS_RECOVER_BACKOFF_MAX)
        if now - self.rowsHeldAt >= wait then
            self.rowsRecoveries = self.rowsRecoveries + 1
            local cause = self.rowsHeld
            local recovered, rwhy = rows:Recover(ctx)
            if recovered then
                self:_log('RunSync rows recovered attempt=%d after=%s', self.rowsRecoveries, tostring(cause))
                self.rowsHeld, self.rowsHeldAt = nil, nil
                local applied, again = rows:Apply(ctx, snapshot)
                if not applied and rows:Status().state == 'held' then
                    -- lost again at once: the cause persists; back off and say so once per cause
                    self.rowsRelapses = (self.rowsRelapses or 0) + 1
                    self.rowsHeld, self.rowsHeldAt = again, now
                    if self.rowsRelapseLogged ~= tostring(again) then
                        self.rowsRelapseLogged = tostring(again)
                        self:_log('RunSync rows relapse reason=%s (cause persists; next recovery in %ds)', tostring(again),
                            math.floor(R.ROWS_RECOVER_SECONDS * 2 ^ math.min(self.rowsRelapses, R.ROWS_RECOVER_BACKOFF_MAX)))
                    end
                else
                    self.rowsRelapses = 0
                end
            else
                self.rowsHeldAt = now
                self:_log('RunSync rows recover failed attempt=%d reason=%s', self.rowsRecoveries, tostring(rwhy))
            end
        end
    else
        self.rowsHeldAt = nil
    end
    local status = rows:Status()
    self.counters.enemies.applied, self.counters.enemies.presented = status.applied, status.live
    -- the 1/s "ROWS received=... applied=... presented=... pending=..." line (gmp_run_sync_rows.lua Report)
    local clock = self.options.clock
    if clock and type(rows.Report) == 'function' then
        local ok, now = pcall(clock)
        if ok then pcall(rows.Report, rows, now) end
    end
end
function R:Rows() return self.rows end
-- D43: 'actor' when a client hit landed on a boss/unique proxy row (the boss_hits counter), else nil.
function R:ClassifyHit(entry)
    local rows = self.rows
    if not rows or type(entry) ~= 'table' or math.type(entry.row) ~= 'integer' or type(rows.IsActorSlot) ~= 'function' then return nil end
    local ok, actor = pcall(rows.IsActorSlot, rows, entry.row)
    return ok and actor == true and 'actor' or nil
end
-- Cosmetic, client: the game's damage number at once where a client hit landed (gmp_client_attacks feedback); the host
-- still decides the damage. The client's own weapon damage (read with its stats) is the number. At most
-- FEEDBACK_PER_SECOND.
R.FEEDBACK_PER_SECOND = 20
function R:Feedback(entry, now)
    local rows = self.rows
    if not rows or type(entry) ~= 'table' or math.type(entry.row) ~= 'integer' then return false end
    local t = now or 0
    if self.options.clock then local ok, c = pcall(self.options.clock); if ok and type(c) == 'number' then t = c end end
    local w = self.feedbackWindow
    if not w or t - w.start >= 1 then w = { start = t, n = 0 }; self.feedbackWindow = w end
    if w.n >= R.FEEDBACK_PER_SECOND then return false end
    local x, y = rows:PositionOfSlot(entry.row)
    local p = rows.presentation
    if not x or type(p) ~= 'table' or type(p.HitNumber) ~= 'function' then return false end
    w.n = w.n + 1
    local called, shown, why = pcall(p.HitNumber, p, x, y, self.lastWeaponDamage or 1)
    if called and shown ~= false then return true end
    if not self.numberRefusalLogged then
        self.numberRefusalLogged = true
        self:_log('RunSync damage number refused reason=%s', tostring(called and why or shown))
    end
    return false
end

-- Dizzy Wizzy's chain blast (RESEARCH_GAMEPLAY section 12; evidence/class_trail_static_20261010/BP_DizzyWizzyPassive):
-- on each standard-weapon hit the passive runs DamageAOE at the hit location with damage = BPC_DamageComponent
-- "AOE Damage" x (hit damage x 0.5) and radius = trunc(Radius x AOE RadiusMultiplier). On a client that body is fenced
-- (HitEnemyEvent), so ChainOf derives the same AOE from a captured standard hit (attack 1) of this client's own Dizzy
-- passive; it is sent as an ordinary ATTACK_AOE (the host's own DamageAOE route and every AOE bound). The hit damage is
-- this client's standard weapon damage x its DamageMultiplier (no crit). The passive is looked up again only every
-- CHAIN_READ_SECONDS (upgrades change its values).
R.CHAIN_READ_SECONDS = 2
R.CHAIN_PASSIVE = 'BP_DizzyWizzyPassive_C'
function R:_chainPassive(now)
    local c = self.chainPassive
    if c and now - c.at < R.CHAIN_READ_SECONDS then return c end
    c = { at = now }
    self.chainPassive = c
    local ctx = self.chainCtx
    local ok = pcall(function()
        local island = ctx and ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return end
        local _, pawn = island:LocalWorldPawn()
        if not pawn then return end
        local items = pawn.PlayerItemsActors
        local n = 0
        pcall(function() n = #items end)
        for i = 1, math.min(n, 16) do
            local a = items[i]
            local okName, name = pcall(function() return a:GetFullName() end)
            if okName and type(name) == 'string' and name:find(R.CHAIN_PASSIVE .. ' ', 1, true) == 1 then
                local radius, mult, aoe, dmult = a.Radius, pawn['AOE RadiusMultiplier'], a.BPC_DamageComponent['AOE Damage'], pawn.DamageMultiplier
                if type(radius) == 'number' and type(mult) == 'number' and type(aoe) == 'number' then
                    c.radius, c.aoeDamage = math.floor(radius * mult), aoe
                    c.damageMulti = type(dmult) == 'number' and dmult or 1
                end
                return
            end
        end
    end)
    if not ok then c.radius = nil end
    return c
end
function R:ChainOf(item)
    if type(item) ~= 'table' or item.attack ~= 1 or math.type(item.row) ~= 'integer' then return nil end
    local rows = self.rows
    if not rows or type(rows.PositionOfSlot) ~= 'function' then return nil end
    local okNow, now = pcall(self.options.clock or os.clock)
    now = okNow and type(now) == 'number' and now or 0
    local c = self:_chainPassive(now)
    if not c.radius or c.radius < 1 then return nil end
    local x, y = rows:PositionOfSlot(item.row)
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    local hit = (self.lastWeaponDamage or 0) * (c.damageMulti or 1)
    if hit <= 0 then return nil end
    return { attack = 0, x = x, y = y, radius = c.radius, damage = c.aoeDamage * hit * 0.5 }
end

-- Test 13: an area hit (AOE observation) shows the game's number on every mirrored enemy inside its radius (drawn
-- positions), at most AOE_PER_ITEM per hit and AOE_FEEDBACK_PER_SECOND in all; cosmetic, client-local, own hits only.
R.AOE_PER_ITEM, R.AOE_FEEDBACK_PER_SECOND = 8, 30
function R:AoeFeedback(item)
    local rows = self.rows
    if not rows or type(item) ~= 'table' or type(item.x) ~= 'number' or type(item.y) ~= 'number'
        or type(item.radius) ~= 'number' or type(item.damage) ~= 'number' or type(rows.RowsWithin) ~= 'function' then return 0 end
    local p = rows.presentation
    if type(p) ~= 'table' or type(p.HitNumber) ~= 'function' then return 0 end
    local t = 0
    if self.options.clock then local ok, c = pcall(self.options.clock); if ok and type(c) == 'number' then t = c end end
    local w = self.aoeFeedbackWindow
    if not w or t - w.start >= 1 then w = { start = t, n = 0 }; self.aoeFeedbackWindow = w end
    local room = math.min(R.AOE_PER_ITEM, R.AOE_FEEDBACK_PER_SECOND - w.n)
    if room <= 0 then return 0 end
    local ok, list = pcall(rows.RowsWithin, rows, item.x, item.y, item.radius, room)
    if not ok or type(list) ~= 'table' then return 0 end
    local shown = 0
    for _, at in ipairs(list) do
        local called, done, why = pcall(p.HitNumber, p, at.x, at.y, item.damage)
        if called and done ~= false then shown = shown + 1
        elseif not self.numberRefusalLogged then
            self.numberRefusalLogged = true
            self:_log('RunSync damage number refused reason=%s', tostring(called and why or done))
        end
    end
    w.n = w.n + shown
    return shown
end

-- The client's readiness for its prep self-tests: its pawn exists and no reward screen is open. Unlike the host it does
-- NOT require the HUD fade-in to be complete: the host pauses about as soon as its own island is visible, and a paused
-- game never advances the client's fade (R1 attempt 3: the client then waited forever).
local function clientReady(ctx)
    local ok, pawn = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil end
        return select(2, island:LocalWorldPawn())
    end)
    if not ok or pawn == nil then return false, 'no_pawn' end
    local read, present = pcall(function() return pawn['PresentTime?'] end)
    if read and present == true then return false, 'reward_screen' end
    return true
end
local function clientConditions(ctx, binding)
    if not sameBinding(binding, ctx) then return 'binding_changed' end
    local ready, why = clientReady(ctx)
    if not ready then return why end
    if physicallyPaused(ctx) ~= true then return 'physical_pause_lost' end
    return nil
end
-- One log line per client prep state change, so a launch shows exactly where the client stops.
function R:_clientWait(p, phase, reason)
    local mark = tostring(phase) .. ':' .. reason
    if p.waitMark == mark then return end
    p.waitMark = mark
    if phase then self:_log('RunSync client prep waiting phase=%s reason=%s', phase, reason)
    else self:_log('RunSync client prep waiting reason=%s', reason) end
end
-- Test 10: a client that rejoined mid-island is not in that island's prep (no enemies after the rejoin until the next
-- island). When this process already proved its self-tests, the island has been playing unpaused for
-- ROWS_REJOIN_SECONDS and the host's prep is not waiting for this client, the rows are enabled without a prep.
R.ROWS_REJOIN_SECONDS = 0.5   -- test 11: was 3 s; the rejoin cover (RejoinReady) hides this short grace
function R:_rowsRejoin(ctx, session)
    if self.rowsKey == ctx.key or self.rowsRejoinRefused == ctx.key or type(self.options.G) ~= 'table' then return end
    local okNow, now = false, nil
    if self.options.clock then okNow, now = pcall(self.options.clock) end
    if not okNow or type(now) ~= 'number' then return end
    if not self.rowsSeen or self.rowsSeen.key ~= ctx.key then self.rowsSeen = { key = ctx.key, at = now } end
    local pause = session.sharedPause
    if type(pause) == 'table' and pause.paused == true then self.rowsSeen.at = now; return end
    if now - self.rowsSeen.at < R.ROWS_REJOIN_SECONDS or processState(self.options.G).tests.state ~= 'ok' then return end
    local state = type(session.AuthorityPrepState) == 'function' and session:AuthorityPrepState() or nil
    local me = type(session.Me) == 'function' and session:Me() or nil
    if type(state) == 'table' and state.key == ctx.key and type(me) == 'table' and type(state.waiting) == 'table'
        and state.waiting[me.slot] == true then return end   -- the prep is for us: it enables the rows
    local ok, why = self:_rowsEnable(ctx)
    if ok then self:_log('RunSync rows enabled without a prep (rejoin) ctx=%s', ctx.key)
    else self.rowsRejoinRefused = ctx.key; self:_log('RunSync rows rejoin enable refused reason=%s', tostring(why)) end
end
-- Rejoin cover (test 11, Coder A's API): RejoinReady() -> ready, reason. A sync whose first context is mid-island (no
-- prep listed it) is rejoining until its rows are enabled, the host's enemies are drawn (presented = received) and the
-- view has not grown for REJOIN_STABLE_SECONDS (an empty island counts after REJOIN_EMPTY_SECONDS). Reasons:
-- 'not_rejoining', 'waiting_rows', 'waiting_full_state', 'presenting <n>/<m>', 'ready' (logged once with the time).
R.REJOIN_STABLE_SECONDS, R.REJOIN_EMPTY_SECONDS = 0.2, 1
function R:RejoinReady()
    local key = self.contextKey
    if self.state == 'stopped' then return false, 'not_rejoining' end
    -- test 13: asked before this sync's first tick (the cover went up first): still waiting, never "not rejoining";
    -- a rejoin that went through the island prep is ready once its rows are filled like any other; and a rows hold in
    -- the current context (a client-local island reload: suppression_lost, then recovered) arms the question again
    if not key or not self.firstKey then return false, 'waiting_rows' end
    if self.rejoinArmedKey ~= key then return false, 'not_rejoining' end
    if self.flags.clientEnemyRows ~= true then return self:_rejoinReady('ready') end
    local rows = self.rows
    if not rows or self.rowsKey ~= key or rows:Status().state ~= 'active' then return false, 'waiting_rows' end
    local okNow, now = pcall(self.options.clock or os.clock)
    now = okNow and type(now) == 'number' and now or 0
    local received, live = rows.received or 0, rows:Status().live or 0
    -- the view's size history comes from the rows ticks (_rowsTick), so the first question can already be answered
    local v = self.rejoinView
    if not v or v.key ~= key or v.received ~= received then
        v = { key = key, received = received, since = now, enabledAt = (v and v.key == key) and v.enabledAt or now }
        self.rejoinView = v
    end
    if received == 0 then
        if now - v.enabledAt >= R.REJOIN_EMPTY_SECONDS then return self:_rejoinReady('ready') end
        return false, 'waiting_full_state'
    end
    -- test 14: on a crowded island the native rows stop at the cap (nearest first) while every enemy is drawn
    local fill = rows:Status().fill
    if type(fill) == 'table' then
        if fill.native < fill.nativeTarget or fill.drawn < fill.drawnTarget then
            return false, string.format('presenting %d/%d', math.min(fill.native, fill.drawn), math.max(fill.nativeTarget, fill.drawnTarget))
        end
    elseif live < received then return false, string.format('presenting %d/%d', live, received) end
    if now - v.since < R.REJOIN_STABLE_SECONDS then return false, 'waiting_full_state' end
    return self:_rejoinReady('ready')
end
function R:_rejoinReady(reason)
    self.rejoinArmedKey = nil
    local okNow, now = pcall(self.options.clock or os.clock)
    local since = self.firstSeenAt and okNow and type(now) == 'number' and now - self.firstSeenAt or 0
    self:_log('RunSync rejoin ready after %.1fs presented=%d', since, self.rows and self.rows:Status().live or 0)
    return true, reason
end
function R:_clientTick(ctx, session)
    self.chainCtx = ctx   -- Dizzy chain: the local pawn, read outside the tick (ChainOf)
    if not self.firstKey then
        self.firstKey = ctx.key
        self.rejoinArmedKey = ctx.key
        local okNow, now = pcall(self.options.clock or os.clock)
        self.firstSeenAt = okNow and type(now) == 'number' and now or 0
    end
    local p = self.prep
    if not p or p.key ~= ctx.key then p = { key = ctx.key, reported = {}, running = {} }; self.prep = p end
    if self:_rowsWanted(ctx) then
        if not self:_rowsSettle(ctx) then return end
        self:_rowsTick(ctx, session)
        self:_rowsRejoin(ctx, session)
    end
    local state = type(session.AuthorityPrepState) == 'function' and session:AuthorityPrepState() or nil
    if type(state) ~= 'table' then return self:_clientWait(p, nil, 'no_state') end
    if state.key ~= ctx.key then return self:_clientWait(p, nil, 'state_for_other_context') end
    local me = type(session.Me) == 'function' and session:Me() or nil
    local slot = type(me) == 'table' and me.slot or nil
    local phase = state.phase
    if not slot then return self:_clientWait(p, phase, 'no_slot') end
    local listed = state.waiting[slot] == true
    local seen = phase .. ':' .. tostring(listed)
    if p.stateMark ~= seen then
        p.stateMark = seen
        self:_log('RunSync client prep state phase=%s listed=%s', phase, listed and 'yes' or 'no')
    end
    -- test 15: a later hold of the same phase (the host's late-join prep) lists this client again: report again (the
    -- self-tests are cached per process, so at once)
    p.listedBefore = p.listedBefore or {}
    if listed and p.listedBefore[phase] == false and p.reported[phase] then p.reported[phase], p.running[phase] = nil, nil end
    p.listedBefore[phase] = listed
    if listed then self.preppedKey = ctx.key end   -- the island prep is for this sync: not a rejoin
    if not listed or p.reported[phase] then return end
    p.phase = phase
    local pause = session.sharedPause
    if not (type(pause) == 'table' and pause.paused == true) then return self:_clientWait(p, phase, 'not_paused') end
    if not p.binding then
        local binding = bindingOf(ctx)
        if not binding then return self:_clientWait(p, phase, 'no_binding') end
        local ready, why = clientReady(ctx)
        if not ready then return self:_clientWait(p, phase, why) end
        if physicallyPaused(ctx) ~= true then return self:_clientWait(p, phase, 'not_physically_paused') end
        p.binding = binding
    end
    if not p.running[phase] then p.running[phase] = true; self:_log('RunSync client prep running phase=%s', phase) end
    local result, why, cached
    local blocked = clientConditions(ctx, p.binding)
    if blocked then
        result, why = 'failed', blocked
    else
        result, why, cached = self:_stepSelfTests(p.binding)
    end
    if result == 'running' then return end
    if result == 'ok' and phase == 'island' and self:_rowsWanted(ctx) and self.rowsKey ~= ctx.key then
        local ok, rwhy = self:_rowsEnable(ctx)
        if not ok then result, why = 'failed', tostring(rwhy) end
    end
    p.reported[phase] = true
    if result == 'failed' then
        self.state, self.reason = 'prep_failed', why
        self:_log('RunSync prep phase=%s failed reason=%s', phase, tostring(why))
        session:ReportAuthorityPrep(ctx.key, phase, false, why)
        return
    end
    if not self.selfTestsLogged then self.selfTestsLogged = true; self:_logSelfTests(cached) end
    session:ReportAuthorityPrep(ctx.key, phase, true, '')
    self:_log('RunSync prep phase=%s reported ok', phase)
    if self.state ~= 'prep_failed' then self.state, self.reason = 'ready', nil end
end

------------------------------------------------------------------ contract
-- D45 hook (Coder C): shared XP and pickups (gmp_pickups_sync.lua, dev flag SHARED_XP); never raises.
function R:_d45Tick(ctx, session, now)
    if not self.d45 then
        self.d45 = require('gmp_pickups_sync').new({ G = self.options.G, flags = self.flags, log = function(line) self:_log('%s', line) end,
            hit = function(key, damage, source) return self:QueueClientHit(key, damage, source) end,   -- D50 hook (Coder C)
            standIn = function(key) return self:StandIn(key) end })
    end
    self.d45:Tick(ctx, session, now)
end
-- D44 (Coder B; amended 2026-10-14, test 15), with the shared XP sync: (1) the roulette auto-click (gmp_roulette_auto)
-- plugs into the XP modules' auto-pick; (2) on the host, EVERY roulette the host's game presents to the host's own pawn
-- becomes one shared round (gmp_xp_host Reward, by = 'host', source = 'present'): every player gets their own spin with
-- the same rarity and title, all open together. The sources (static dumps): a boss kill (BossDefeated -> a dilation
-- timeline -> PresentRoulette(0, DeathText)), a boss or unique reward item the host picks up (BP_MiniBoss ->
-- MiniBossDeath -> BP_RewardItem DropType 3, "{name} provides..."), and any other PresentRoulette on the host pawn.
-- The round opens when the host's own roulette is presented, so the shared pause can no longer hold the host's own
-- spin back (it froze the boss timeline when the round opened at BossDefeated).
-- PresentRoulette is a Blueprint function, so the hook runs after it: a new request was presented (PresentQueue
-- unchanged) or queued (+1); RouletteFinished presenting the next queued one shows as -1 and is not a new round. Not
-- rounds either: the RouletteOnly artifact's level-up roulette (Level is already above the team level the XP sync saw:
-- levels are their own rounds), the host's own copy of a reward a client collected (gmp_xp_host Present), a stand-in
-- or any pawn other than the host's own. The hook only queues; the rounds open in this tick, outside the game call.
R.BOSS_DEFEATED = '/Game/Blueprints/BP_Player.BP_Player_C:BossDefeated'
R.PRESENT_ROULETTE = '/Game/Blueprints/BP_Player.BP_Player_C:PresentRoulette'
R.ROULETTE_REQUESTS_MAX = 16
local function queueLength(pawn)
    local ok, n = pcall(function() return require('gmp_xp_host').Len(pawn.PresentQueue) end)
    return ok and math.tointeger(n) or 0
end
function R:_onHostRoulette(pawn, rarityParam, textParam)
    local name = pawn and pawn:GetFullName()
    if type(name) ~= 'string' or not name:find('/Game/Maps/Game.', 1, true) then return end
    if self.hostPawnName and name ~= self.hostPawnName then return end      -- a stand-in, not the host's own pawn
    local queued = queueLength(pawn)
    local delta = queued - (self.hostQueue or queued)
    self.hostQueue = queued
    if delta < 0 then return end                                           -- RouletteFinished: the next queued one
    if (require('gmp_xp_host').presenting or 0) > 0 then return end         -- our copy of a client's reward
    local xpHost = self.d45 and self.d45.xpHost
    local level = math.tointeger(pawn.Level)
    if xpHost and math.type(xpHost.levelSeen) == 'integer' and level and level > xpHost.levelSeen then return end
    local rarity, text = -1, nil
    pcall(function() rarity = math.floor(rarityParam:get()) end)
    pcall(function() text = textParam:get():ToString() end)
    if math.type(rarity) ~= 'integer' or rarity < -1 or rarity > 3 then rarity = -1 end
    self.rouletteRequests = self.rouletteRequests or {}
    if #self.rouletteRequests < R.ROULETTE_REQUESTS_MAX then
        self.rouletteRequests[#self.rouletteRequests + 1] = { rarity = rarity, text = type(text) == 'string' and text:sub(1, 200) or nil }
    end
end
function R:_d44Tick(ctx, session, now)
    local d45 = self.d45
    if not d45 then return end
    local G = self.options.G
    if not self.rouletteAutoPlugged and type(d45.SetAutoPickOther) == 'function' then
        self.rouletteAutoPlugged = true
        pcall(d45.SetAutoPickOther, d45, require('gmp_roulette_auto').Plugin(G))
    end
    if ctx.role ~= 'host' or type(G) ~= 'table' then return end
    -- the host's own pawn and its queue as of this tick (the hook compares against them)
    local okPawn, _, pawn = pcall(function() return ctx.islandWorld:LocalWorldPawn() end)
    if okPawn and pawn then
        local okName, name = pcall(function() return pawn:GetFullName() end)
        if okName and type(name) == 'string' then self.hostPawnName = name end
        self.hostQueue = queueLength(pawn)
    end
    if not self.rouletteHooked and type(G.RegisterHook) == 'function' and type(G.StaticFindObject) == 'function' then
        local okFind, fn = pcall(G.StaticFindObject, R.PRESENT_ROULETTE)
        local found = okFind and fn ~= nil and pcall(function() return fn:IsValid() end)
        if found then
            self.rouletteHooked = true
            local ok, why = pcall(G.RegisterHook, R.PRESENT_ROULETTE, function(context, rarity, text)
                pcall(function() self:_onHostRoulette(context:get(), rarity, text) end)
            end)
            self:_log('D44 host roulette hook installed=%s %s', tostring(ok), ok and '' or tostring(why))
        end
    end
    -- the pickup sync's own "the host collected a roulette item" event is the same reward: the hook has it
    if self.rouletteHooked and d45.xpHost then d45.xpHost.rouletteHooked = true end
    local requests = self.rouletteRequests
    if requests and #requests > 0 and d45.xpHost and type(d45.xpHost.Reward) == 'function' then
        self.rouletteRequests = {}
        for _, r in ipairs(requests) do
            local event = { kind = 'roulette', by = 'host', rarity = r.rarity, text = r.text, source = 'present' }
            pcall(d45.xpHost.Reward, d45.xpHost, ctx, session, now, event)
            self:_log('D44 host roulette shared rarity=%d text=%s', r.rarity, tostring(r.text))
        end
    end
end
function R:Tick(ctx, session, now)
    if self.state == 'stopped' then return false, 'stopped' end
    local key = type(ctx) == 'table' and ctx.key or nil
    if key ~= self.contextKey then
        self.contextKey = key
        local prep, attacks = self.counters.prep, self.counters.attacks
        self.counters = counters(); self.counters.prep, self.counters.attacks = prep, attacks
    end
    if not self.flags.authorityPrep or not key or type(session) ~= 'table' then
        self.state = key and 'inert' or 'idle'
        self.reason = key and 'run_sync_stub' or nil
        return true
    end
    self.role = ctx.role
    self.mode = type(session.cfg) == 'table' and session.cfg.MODE or nil
    if self.state == 'idle' or self.state == 'inert' then self.state, self.reason = 'prep', nil end
    local ok, err = pcall(function()
        if ctx.role == 'host' then
            -- client-credited host damage runs with the host's damage numbers off (QuietNumbers)
            local world = ctx.world
            self.quietController = type(world) == 'table' and type(world._enemyController) == 'function'
                and function() return world:_enemyController() end or nil
            self:_hostTick(ctx, session, now or 0)
            -- client rows mode: enemies stream per client through the delta stream (gmp_enemy_delta.lua)
            if self.flags.clientEnemyRows == true and type(session.EnableEnemyDelta) == 'function' then session:EnableEnemyDelta() end
            if self.flags.clientEnemyRows == true then
                self:_actorsHostTick(ctx, session, now or 0); self:_classCensusTick(session, now or 0)
                self:_portalsHostTick(ctx, session, now or 0)
            end
            -- R1 attempt 5: with CLIENT_ATTACKS alone the client's real run-start stats still reach its stand-in
            -- (once per island); CLIENT_UPGRADE_DAMAGE also follows later upgrades.
            local stats = self.flags.clientUpgradeDamage == true or self.flags.clientAttacks == true
            if stats then self:_upgradesHostTick(ctx, session, self.flags.clientUpgradeDamage ~= true) end
            if self.flags.clientDamage == true or self.lives then self:_damageHostTick(ctx, session, now or 0) end
            -- D50: queued enemy-attack hits (QueueClientHit) and, with ENEMY_ATTACKS, stand-ins that follow their client
            self:_clientHitsTick(ctx, session, now or 0)
            if self.flags.enemyAttacks == true then self:_standInsFollowTick(ctx, session, now or 0) end
            if self.lives then self:_livesHostTick(ctx, session, now or 0) end
            if self.flags.clientAttacks == true then self:_combatTick(ctx, session); self:_aoeTick(ctx, session, now or 0) end
        elseif ctx.role == 'client' then
            self:_clientTick(ctx, session)
            if self.flags.clientEnemyRows == true then self:_portalsClientTick(ctx, session) end
            local stats = self.flags.clientUpgradeDamage == true or self.flags.clientAttacks == true
            if stats then self:_upgradesClientTick(ctx, session, now or 0, self.flags.clientUpgradeDamage ~= true) end
            if self.flags.clientDamage == true or self.lives then self:_damageClientTick(ctx, session, now or 0) end
            if self.lives then self:_livesClientTick(ctx, session) end
        end
        if self.flags.sharedXp == true or self.flags.enemyFx == true or self.flags.enemyAttacks == true then self:_d45Tick(ctx, session, now or 0) end   -- D45 hook (Coder C)
        if self.flags.sharedXp == true then self:_d44Tick(ctx, session, now or 0) end   -- D44 (Coder B)
    end)
    if not ok then
        self.state, self.reason = 'prep_failed', 'exception:' .. tostring(err):sub(1, 200)
        if self.prep then self.prep.stage, self.prep.reason = 'failed', self.reason end
        self:_log('RunSync prep failed reason=%s', self.reason)
    end
    return true
end

function R:Stop(reason)
    if self.state == 'stopped' then return false end
    if self.usedHd then pcall(self.usedHd.EndRun, self.usedHd) end
    if self.d45 then pcall(self.d45.Stop, self.d45) end   -- D45 hook (Coder C)
    if self.rows then
        local ok, done, why = pcall(self.rows.Disable, self.rows)
        if not ok or done ~= true then
            -- run end/abort must always release the fence and the binding (test 7: a stuck binding blocked the next run)
            pcall(self.rows.ForceRelease, self.rows, 'stop:' .. tostring(ok and why or done))
            self:_log('RunSync rows force released at stop: %s', tostring(ok and why or done))
        end
    end
    self.state, self.reason, self.contextKey = 'stopped', tostring(reason or 'stopped'), nil
    return true
end

function R:PauseRequest()
    if not self.flags.authorityPrep or self.state == 'stopped' or self.role ~= 'host' then return nil end
    local p = self.prep
    if not p or p.stage == 'visible' or p.stage == 'done' then return nil end
    return { paused = true, reason = PAUSE_REASON[p.phase] }
end

function R:Capabilities()
    local attacks = false
    if self.flags.clientAttacks == true and self.flags.authorityPrep == true and self.role == 'host' and self.state ~= 'stopped' then
        local G = self.options.G
        attacks = type(G) == 'table' and type(rawget(G, 'GMPAuthorityHostDamage') or G.GMPAuthorityHostDamage) == 'function'
    end
    local rows = self.role == 'client' and self.state ~= 'stopped' and self.rows and self.rows:Status().state == 'active'
    if rows then return { enemy_authority = true, enemy_authority_scope = 'ordinary_dev', client_attacks = false } end
    return { enemy_authority = false, enemy_authority_scope = 'none', client_attacks = attacks }
end

local INTENT_FIELDS = { context = true, sequence = true, enemyId = true, attack = true }
function R:_refuse(why) self.counters.attacks.refused = self.counters.attacks.refused + 1; return false, why end
function R:ApplyRemoteHit(ctx, session, peer, intent, target)
    if self.state == 'stopped' then return false, 'stopped' end
    if self.flags.clientAttacks ~= true then return false, 'client_attacks_off' end
    if type(ctx) ~= 'table' or ctx.role ~= 'host' or type(session) ~= 'table' then return false, 'host_only' end
    if type(intent) ~= 'table' then return self:_refuse('invalid_intent') end
    for k in pairs(intent) do if not INTENT_FIELDS[k] then return self:_refuse('invalid_intent') end end
    if intent.context ~= ctx.key then return self:_refuse('context_changed') end
    local p = self.prep
    if not p or p.key ~= ctx.key or p.stage ~= 'done' then return self:_refuse('prep_not_ready') end
    local connected = false
    for _, player in ipairs(remotePlayers(session)) do
        if player.key == peer and player.conn == 'connected' then connected = true end
    end
    if not connected then return self:_refuse('peer_not_connected') end
    local hd = self:_hd()
    if not hd then return self:_refuse('stand_in_native_unavailable') end
    local heldBefore = hd.hitHeld and hd.hitHeld[peer]
    local ok, why, result = hd:Hit({ context = ctx.key, epoch = ctx.epoch },
        { peer = peer, sequence = intent.sequence, attack = intent.attack, enemy = intent.enemyId, target = target })
    if not ok then
        if hd.hitHeld and hd.hitHeld[peer] and hd.hitHeld[peer] ~= heldBefore then   -- test 14: a new (short) hold
            self.counters.attacks.held = self.counters.attacks.held + 1
            return false, why
        end
        return self:_refuse(why)
    end
    self.counters.attacks.accepted = self.counters.attacks.accepted + 1
    local credited, cwhy = self.attribution:Record(peer, result.weapon, result.damage, result.killed)
    if not credited then self:_log('RunSync attribution refused peer=%s reason=%s', tostring(peer), tostring(cwhy)) end
    return true, why, result
end

function R:Attribution() return self.attribution:Snapshot() end

function R:Status()
    local c = copy(self.counters)
    local prep = c.prep
    if self.flags.authorityPrep and self.prep then
        local G = self.options.G
        local tests = type(G) == 'table' and processState(G).tests or {}
        prep = { hook = tests.hook == true, native = tests.native == true, blueprint = tests.blueprint == true,
            standIns = self.prep.standIns or 0, phase = self.prep.phase, stage = self.prep.stage, reason = self.prep.reason }
    end
    local upgrades
    if self.flags.clientUpgradeDamage == true then
        if self.role == 'client' then upgrades = { sent = self.upgradeSends or 0 }
        else upgrades = copy(self.upgradeRevision or {}) end
    end
    local damage
    if self.flags.clientDamage == true or self.lives then
        if self.role == 'client' then damage = { hits = self.damageHits or 0, taken = self.damageTaken or 0 }
        else damage = { sent = self.damageSent or 0 } end
    end
    local lives
    if self.lives then
        local slots, count = {}, 0
        if self.role == 'client' then
            local state = self.clientLives
            if state then for _, g in ipairs(state.ghosts) do slots[g.slot] = g.progress / 1000; count = count + 1 end end
            lives = { lives = state and state.lives, ghosts = count, ended = state ~= nil and state.ended == true,
                ghost = self.ghost == true, slots = slots }
        else
            local state = self.lives:State()
            for _ in pairs(state.ghosts) do count = count + 1 end
            for _, g in ipairs(self.livesSlots or {}) do slots[g.slot] = g.progress / 1000 end
            lives = { lives = state.lives, ghosts = count, ended = state.ended, ghost = self.ghost == true, slots = slots }
        end
    end
    return { state = self.state, reason = self.reason, contextKey = self.contextKey, prep = prep,
        enemies = c.enemies, attacks = c.attacks, attribution = self.attribution:Snapshot(), upgrades = upgrades, damage = damage,
        lives = lives }
end

return R
