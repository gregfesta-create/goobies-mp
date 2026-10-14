-- Host-side native damage binding (PLAN_WORLD_ENTRY.md 3.10 S7a stand-ins; 4 S7b remote hits). Host role only.
--
-- Wraps the slice1 bridge's witness and stand-in endpoints:
--   GMPAuthorityConfigureDevWitness(sid, term, hostKey, peersCsv, epoch)                    -> ok, reason
--   GMPAuthorityStandInCreate(generation, world, controller, peer, epoch, character, paused) -> ok, reason, detail
--   GMPAuthorityStandInRetire(peer, epoch) / GMPAuthorityStandInHold(peer, epoch, held)     -> ok, reason
--   GMPAuthorityStandInPoll()                       -> ok, reason, live, retiring, retiredCsv, failedCsv
--
-- Caller (HD.CALLER): S1 island prep in gmp_run_sync's host prep handler, while PauseForAuthorityPrep holds the pause:
--   1. ConfigureDevWitness(run) - MODE=dev only, once per run epoch. It must come first: the native bridge refuses every
--      stand-in, the synthetic self-peer (STANDIN_SELFTEST) included, until the dev witness is configured.
--   2. PrepareIsland(run, island) - one stand-in per connected peer (cap 4); with island.selfTest (dev, solo) the
--      synthetic self-peer is created, initialized and immediately retired.
--   3. Poll() every tick; EndIsland() at island end; Disconnect/Rejoin/Expire from roster events; EndRun().
-- Lifecycle: disconnect holds a stand-in while reserved; island end retires all (held included) and the next prep
-- recreates the connected ones; a rejoin resumes a still-held stand-in, otherwise the peer is stand_in_missing until the
-- next island prep; expiry and run end retire. Damage is dispatched only through Hit (S7b, below); the self-peer never is.
-- Logs: "STANDIN create peer=<masked|self> ok", "STANDIN retire ok peer=<masked|self>".
local Identity = require('gmp_identity')

local HD = {}
HD.__index = HD
HD.CALLER = 'S1 island prep (gmp_run_sync host prep): ConfigureDevWitness, then PrepareIsland'
-- D54 (no fixed player count): stand-ins for any number of peers, bounded only by the untrusted-row sanity cap
-- (Config.MAX_PLAYERS_LIMIT less the host = the native kSessionPeerLimit, authority_witness.hpp).
HD.CAPACITY = require('gmp_config').MAX_PLAYERS_LIMIT - 1
local GLOBALS = { configureDevWitness = 'GMPAuthorityConfigureDevWitness', standInCreate = 'GMPAuthorityStandInCreate',
    standInRetire = 'GMPAuthorityStandInRetire', standInHold = 'GMPAuthorityStandInHold', standInPoll = 'GMPAuthorityStandInPoll' }

-- The five bridge functions, or nil when any is missing (no partial binding).
function HD.Api(G)
    if type(G) ~= 'table' then return nil, 'stand_in_native_unavailable' end
    local api = {}
    for field, name in pairs(GLOBALS) do
        if type(G[name]) ~= 'function' then return nil, 'stand_in_native_unavailable' end
        api[field] = G[name]
    end
    -- S7b, optional: without it Hit refuses (host_damage_native_unavailable); stand-ins still work.
    if type(G.GMPAuthorityHostDamage) == 'function' then api.hostDamage = G.GMPAuthorityHostDamage end
    if type(G.GMPAuthorityStandInStats) == 'function' then api.standInStats = G.GMPAuthorityStandInStats end
    if type(G.GMPAuthorityHostExplosion) == 'function' then api.hostExplosion = G.GMPAuthorityHostExplosion end
    if type(G.GMPAuthorityHostAoe) == 'function' then api.hostAoe = G.GMPAuthorityHostAoe end
    if type(G.GMPAuthorityHostAoeSettle) == 'function' then api.hostAoeSettle = G.GMPAuthorityHostAoeSettle end
    return api
end

local function int(v, lo, hi) return math.type(v) == 'integer' and v >= lo and v <= hi end
local function text(v, limit, colon)
    if type(v) ~= 'string' or #v == 0 or #v > limit then return false end
    return v:match(colon and '^[%w_%-:]+$' or '^[%w_%-]+$') ~= nil
end
local function peerKey(v)
    if type(v) ~= 'string' or #v > 64 then return false end
    local kind, name = v:match('^(%a+):(.+)$')
    return (kind == 'dev' or kind == 'steam') and text(name, 40, false)
end
local function path(v) return type(v) == 'string' and #v > 0 and #v <= 512 and not v:find('[%c\128-\255]') end

-- D47: the playtest gameplay runs in dev and in the friend test build (gmp_mode_policy 'gameplay'); production never.
-- The stand-in self-test stays dev only (dev scaffolding).
local Policy = require('gmp_mode_policy')
local function gameplay(mode) return Policy.Valid(mode) and Policy.Allows(mode, 'gameplay') end
function HD.new(api, options)
    assert(type(api) == 'table', 'missing_native_api')
    options = options or {}
    return setmetatable({ api = api, mode = options.mode, log = options.log or function() end,
        witness = nil, standIns = {}, generation = 0, hitHeld = {} }, HD)
end

-- User rule (test 13): each player sees only their own damage numbers. These calls apply damage for a client; they run
-- inside self.quiet(fn) when the run sync set it (the host controller's ShowDMGNumbers? off for the call).
HD.QUIET = { hostDamage = true, hostAoe = true, hostExplosion = true }
-- Native calls never raise into the caller.
function HD:_call(name, ...)
    local fn = self.api[name]
    if type(fn) ~= 'function' then return false, 'stand_in_native_unavailable' end
    local results
    if HD.QUIET[name] and type(self.quiet) == 'function' then
        local args = table.pack(...)
        results = table.pack(pcall(self.quiet, function() return fn(table.unpack(args, 1, args.n)) end))
    else
        results = table.pack(pcall(fn, ...))
    end
    if not results[1] then return false, 'stand_in_native_error:' .. tostring(results[2]) end
    return table.unpack(results, 2, results.n)
end
function HD:_label(key)
    if self.witness and key == self.witness.hostKey then return 'self' end
    return Identity.Mask(key)
end
function HD:_logf(fmt, ...) self.log(string.format(fmt, ...)) end

function HD:WitnessEpoch() return self.witness and self.witness.epoch or nil end

function HD:ConfigureDevWitness(run)
    if not gameplay(self.mode) then return false, 'dev_witness_requires_mode_dev' end
    if type(run) ~= 'table' or not text(run.sid, 64, false) or not int(run.term, 1, 2147483647)
        or not peerKey(run.hostKey) or not int(run.epoch, 1, 2147483647) or type(run.peers) ~= 'table' then
        return false, 'dev_witness_bad_context'
    end
    if #run.peers > HD.CAPACITY then return false, 'dev_witness_peer_limit' end
    for _, key in ipairs(run.peers) do if not peerKey(key) then return false, 'dev_witness_bad_peer_key' end end
    local w = self.witness
    if w and w.epoch == run.epoch and w.sid == run.sid and w.term == run.term and w.hostKey == run.hostKey then
        return true, 'dev_witness_already_configured_this_epoch'
    end
    -- Any replacement waits until the previous run's stand-ins are all retired (mirrors the native ledger guard).
    if self:_pending() then return false, 'dev_witness_previous_run_stand_ins_pending' end
    -- Epochs order only within one (sid, term): the island epoch restarts at 1 per hosted session.
    local last = self.lastRun
    if last and last.sid == run.sid and last.term == run.term and run.epoch <= last.epoch then
        return false, 'dev_witness_stale_epoch'
    end
    local ok, why = self:_call('configureDevWitness', run.sid, run.term, run.hostKey, table.concat(run.peers, ','), run.epoch)
    if ok ~= true then return false, tostring(why) end
    self.witness = { sid = run.sid, term = run.term, hostKey = run.hostKey, epoch = run.epoch, solo = #run.peers == 0 }
    self.lastRun = { sid = run.sid, term = run.term, epoch = run.epoch }
    self:_logf('STANDIN witness configured epoch=%d peers=%d', run.epoch, #run.peers)
    return true, why
end

function HD:_pending()
    for _ in pairs(self.standIns) do return true end
    return false
end

function HD:_create(island, key, character, self_)
    -- Never replace (or clean up) an existing stand-in for this key.
    if self.standIns[key] then return false, 'stand_in_already_present' end
    local w = self.witness
    local ok, why, detail = self:_call('standInCreate', island.generation, island.worldPath, island.controllerPath, key, w.epoch,
        character, true)
    if ok == true then
        -- D50: the pawn full name (native detail ";path=..."), for RunSync:StandIn (found again among live objects)
        local path = type(detail) == 'string' and detail:match(';path=(.+)$') or nil
        self.standIns[key] = { epoch = w.epoch, state = 'live', self = self_, path = path }
        self:_logf('STANDIN create peer=%s ok', self:_label(key))
        return true
    end
    self:_logf('STANDIN create peer=%s failed reason=%s', self:_label(key), tostring(why))
    -- A failed native create keeps its owned handles until retired.
    self.standIns[key] = { epoch = w.epoch, state = 'failed', self = self_ }
    self:_retire(key)
    return false, tostring(why)
end

-- Returns ok, created, firstFailure.
function HD:PrepareIsland(run, island)
    if type(island) == 'table' and island.selfTest ~= nil
        and (self.mode ~= 'dev' or type(island.peers) ~= 'table' or #island.peers > 0) then
        return false, 0, 'stand_in_selftest_dev_solo_only'
    end
    local w = self.witness
    if not w then return false, 0, 'stand_in_witness_unconfigured' end
    if type(run) ~= 'table' or run.sid ~= w.sid or run.term ~= w.term or run.hostKey ~= w.hostKey or run.epoch ~= w.epoch then
        return false, 0, 'stand_in_witness_epoch_mismatch'
    end
    if type(island) ~= 'table' or not int(island.generation, 1, 9007199254740991) or not path(island.worldPath)
        or not path(island.controllerPath) or type(island.peers) ~= 'table' then
        return false, 0, island and island.paused ~= true and 'stand_in_requires_prep_pause' or 'stand_in_bad_island'
    end
    if island.paused ~= true then return false, 0, 'stand_in_requires_prep_pause' end
    if self:_pending() then return false, 0, 'stand_in_previous_island_pending' end
    if island.generation <= self.generation then return false, 0, 'stand_in_island_generation_stale' end
    local wanted = island.selfTest ~= nil and 1 or 0
    local seen = {}
    for _, peer in ipairs(island.peers) do
        if type(peer) ~= 'table' or not peerKey(peer.key) or not int(peer.character, 0, 31) then
            return false, 0, 'stand_in_bad_peer'
        end
        -- The host key is a stand-in only as the STANDIN_SELFTEST self-peer (island.selfTest), never as a peer.
        if peer.key == w.hostKey then return false, 0, 'stand_in_peer_is_host' end
        if seen[peer.key] then return false, 0, 'stand_in_duplicate_peer' end
        seen[peer.key] = true
        if peer.connected == true then wanted = wanted + 1 end
    end
    if wanted > HD.CAPACITY then return false, 0, 'stand_in_capacity' end
    self.generation = island.generation
    self.hitHeld = {} -- S7b: a hit hold lasts for its island only
    -- Test 14 (Coder C): the island binding, for a peer that connects after this prep (AddPeer)
    self.island = { generation = island.generation, worldPath = island.worldPath, controllerPath = island.controllerPath }
    local created, failure = 0, nil
    for _, peer in ipairs(island.peers) do
        if peer.connected == true then
            local ok, why = self:_create(island, peer.key, peer.character, false)
            if ok then created = created + 1 else failure = failure or why end
        else
            self:_logf('STANDIN skip peer=%s disconnected', self:_label(peer.key))
        end
    end
    if island.selfTest ~= nil then
        local character = type(island.selfTest) == 'table' and island.selfTest.character or nil
        if not int(character, 0, 31) then
            failure = failure or 'stand_in_bad_peer'
        else
            local ok, why = self:_create(island, w.hostKey, character, true)
            if ok then
                created = created + 1
                -- Synthetic self-peer: create, initialize and retire only.
                self:_retire(w.hostKey)
            else
                failure = failure or why
            end
        end
    end
    self:_logf('STANDIN prep island=%d standIns=%d', island.generation, created)
    return failure == nil, created, failure
end

function HD:_retire(key)
    local entry = self.standIns[key]
    if not entry then return false, 'stand_in_missing' end
    if entry.state == 'retiring' then return true, 'stand_in_retire_pending' end
    local ok, why = self:_call('standInRetire', key, entry.epoch)
    if ok ~= true then
        if why == 'stand_in_missing' then self.standIns[key] = nil end
        return false, tostring(why)
    end
    if why == 'stand_in_retired' then
        self.standIns[key] = nil
        self:_logf('STANDIN retire ok peer=%s', self:_label(key))
    else
        entry.state = 'retiring'
    end
    return true, why
end

-- Test 14 (Coder C): a peer that was disconnected at island prep (or joined after it) gets its stand-in when it is
-- connected mid-island, on the prep's own island binding; it is retired the usual way (EndIsland, Expire, EndRun).
--   AddPeer(key, character) -> ok, reason      IslandBound() -> true between PrepareIsland and EndIsland
function HD:IslandBound() return self.island ~= nil and self.witness ~= nil end
function HD:AddPeer(key, character)
    local w, island = self.witness, self.island
    if not w then return false, 'stand_in_witness_unconfigured' end
    if not island then return false, 'stand_in_island_unbound' end
    if not peerKey(key) or not int(character, 0, 31) then return false, 'stand_in_bad_peer' end
    if key == w.hostKey then return false, 'stand_in_peer_is_host' end
    if self.standIns[key] then return false, 'stand_in_already_present' end
    if self:Count() >= HD.CAPACITY then return false, 'stand_in_capacity' end
    local ok, why = self:_create(island, key, character, false)
    if ok then self:_logf('STANDIN late peer=%s ok island=%d', self:_label(key), island.generation) end
    return ok == true, why
end

function HD:EndIsland()
    self.island = nil
    local keys = {}
    for key in pairs(self.standIns) do keys[#keys + 1] = key end
    table.sort(keys)
    local all = true
    for _, key in ipairs(keys) do
        if not self:_retire(key) then all = false end
    end
    return all
end

function HD:Disconnect(key)
    local entry = self.standIns[key]
    if not entry or entry.state ~= 'live' then return false, 'stand_in_missing' end
    local ok, why = self:_call('standInHold', key, entry.epoch, true)
    if ok ~= true then return false, tostring(why) end
    entry.state = 'held'
    return true, why
end

function HD:Rejoin(key)
    local entry = self.standIns[key]
    if not entry or entry.state ~= 'held' then return entry and entry.state or 'stand_in_missing' end
    local ok = self:_call('standInHold', key, entry.epoch, false)
    if ok == true then entry.state = 'live' end
    return entry.state
end

function HD:Expire(key) return self:_retire(key) end

function HD:EndRun()
    local all = self:EndIsland()
    self.witness = nil
    self.generation = 0
    return all
end

function HD:Poll()
    local ok, why, _, _, retired, failed = self:_call('standInPoll')
    if ok ~= true then return false, tostring(why) end
    for label in tostring(retired or ''):gmatch('[^;]+') do
        local key = label:match('^(.-)@%d+$')
        local entry = key and self.standIns[key]
        if entry then
            self.standIns[key] = nil
            self:_logf('STANDIN retire ok peer=%s', entry.self and 'self' or Identity.Mask(key))
        end
    end
    for item in tostring(failed or ''):gmatch('[^;]+') do
        local key, reason = item:match('^(.-)@%d+:(.*)$')
        local entry = key and self.standIns[key]
        if entry then
            entry.state = 'failed'
            self:_logf('STANDIN retire failed peer=%s reason=%s', entry.self and 'self' or Identity.Mask(key), reason)
        end
    end
    return true, why
end

------------------------------------------------------------------ S7b remote hits
-- Hit(run, hit) -> ok, reason, {damage, killed, weapon}
--   run = {context = RunContext key, epoch = run epoch}; hit = {peer, sequence, attack, enemy = '<epoch>:<id>',
--   target = the host's native row index for that enemy}. The host resolves the target; nothing here comes from
--   a client packet except the authenticated intent identifiers. MODE=dev only until W7 binds the receipt witness.
--   Native: GMPAuthorityHostDamage(context, peer, epoch, sequence, attack, enemy, target)
--             -> ok, reason, damage, killed, held, weaponType
--   A native hold (an uncertain dispatch) holds only that peer, for HD.HOLD_SECONDS (test 14; it was the rest of the
--   island): the ambiguous hit is dropped, the next one after the window is dispatched again.
-- Logs: "HOSTHIT peer=<masked> seq=<n> target=<i> ok damage=<d> killed=<bool>", "HOSTHIT peer=<masked> held reason=<r>".
local HIT_FIELDS = { peer = true, sequence = true, attack = true, enemy = true, target = true }
HD.HOLD_SECONDS = 1.5   -- longer than the native delivery's own hold window (host_damage_delivery.hpp, 1 s)
function HD:_now()
    local ok, t = pcall(type(self.clock) == 'function' and self.clock or os.clock)
    return ok and type(t) == 'number' and t or os.clock()
end
local function validHit(run, h)
    if type(run) ~= 'table' or type(run.context) ~= 'string' or #run.context == 0 or #run.context > 256
        or not int(run.epoch, 1, 2147483647) or type(h) ~= 'table' then return false end
    for key in pairs(h) do if not HIT_FIELDS[key] then return false end end
    return int(h.sequence, 1, 2147483647) and int(h.attack, 1, 1024) and int(h.target, 0, 4095)
        and type(h.enemy) == 'string' and #h.enemy <= 32 and h.enemy:match('^%d+:%d+$') ~= nil
end
function HD:Hit(run, h)
    if not gameplay(self.mode) then return false, 'host_damage_requires_dev_witness' end
    if type(self.api.hostDamage) ~= 'function' then return false, 'host_damage_native_unavailable' end
    local w = self.witness
    if not w then return false, 'stand_in_witness_unconfigured' end
    if not validHit(run, h) then return false, 'host_damage_bad_hit' end
    if run.epoch ~= w.epoch then return false, 'host_damage_witness_epoch_mismatch' end
    if h.peer == w.hostKey then return false, 'host_damage_self_peer' end
    local state = self:Status(h.peer)
    if state ~= 'live' then return false, state:match('^stand_in_') and state or 'stand_in_' .. state end
    -- Test 14 (Coder C): an uncertain hit is dropped (never credited, never replayed: its sequence stays reserved
    -- natively) and holds its peer for HD.HOLD_SECONDS only, not for the rest of the island.
    local now = self:_now()
    local hold = self.hitHeld[h.peer]
    if hold then
        if now - hold.at < HD.HOLD_SECONDS then
            hold.dropped = hold.dropped + 1
            return false, 'host_damage_peer_held'
        end
        self.hitHeld[h.peer] = nil
    end
    local ok, why, damage, killed, held, weapon = self:_call('hostDamage', run.context, h.peer, run.epoch, h.sequence,
        h.attack, h.enemy, h.target)
    if held == true then
        -- since: when this peer's hold began (an older native keeps reporting held: one try per window, one log)
        self.hitHeld[h.peer] = { at = now, since = hold and hold.since or now, dropped = hold and hold.dropped or 0 }
        if not hold then self:_logf('HOSTHIT peer=%s held reason=%s', self:_label(h.peer), tostring(why)) end
    elseif hold then
        self:_logf('HOSTHIT peer=%s hold cleared after=%.1fs dropped=%d', self:_label(h.peer), now - hold.since, hold.dropped)
    end
    if ok ~= true then return false, tostring(why) end
    if type(damage) ~= 'number' or damage ~= damage or damage < 0 or damage > 1e12 or type(killed) ~= 'boolean'
        or type(weapon) ~= 'string' or #weapon == 0 or #weapon > 64 then
        return false, 'host_damage_result_invalid'
    end
    self:_logf('HOSTHIT peer=%s seq=%d target=%d ok damage=%s killed=%s', self:_label(h.peer), h.sequence, h.target,
        tostring(damage), tostring(killed))
    return true, tostring(why), { damage = damage, killed = killed, weapon = weapon }
end

-- CLIENT_UPGRADE_DAMAGE (post-R1, dev flag): put a remote player's reported upgrade multipliers on ITS stand-in
-- weapon, so Hit yields upgraded damage. The host applies them to its own catalog base damage natively
-- (stand_in_stats_policy.hpp: Damage = StartDamage x AOE Damage x damageMulti x aoeMulti; bonus = ProjectileBonusDamage).
--   ApplyStats(run = {epoch}, peer, {damageMulti, aoeMulti, bonusDamage}) -> ok, reason, weaponDamage
--   Native: GMPAuthorityStandInStats(peer, epoch, damageMulti, aoeMulti, bonusDamage) -> ok, reason, weaponDamage
HD.STATS = { MULTI_MIN = 0.01, MULTI_MAX = 1000, BONUS_MAX = 1000000 }
local function statValue(v, lo, hi) return type(v) == 'number' and v == v and v >= lo and v <= hi end
function HD:ApplyStats(run, peer, stats)
    if not gameplay(self.mode) then return false, 'host_damage_requires_dev_witness' end
    if type(self.api.standInStats) ~= 'function' then return false, 'stand_in_stats_native_unavailable' end
    local w = self.witness
    if not w then return false, 'stand_in_witness_unconfigured' end
    if type(run) ~= 'table' or run.epoch ~= w.epoch then return false, 'stand_in_witness_epoch_mismatch' end
    if peer == w.hostKey then return false, 'stand_in_stats_self_peer' end
    local L = HD.STATS
    if type(stats) ~= 'table' or not statValue(stats.damageMulti, L.MULTI_MIN, L.MULTI_MAX)
        or not statValue(stats.aoeMulti, L.MULTI_MIN, L.MULTI_MAX) or not statValue(stats.bonusDamage, 0, L.BONUS_MAX) then
        return false, 'stand_in_stats_bad_values'
    end
    local state = self:Status(peer)
    if state ~= 'live' then return false, state:match('^stand_in_') and state or 'stand_in_' .. state end
    local ok, why, damage = self:_call('standInStats', peer, w.epoch, stats.damageMulti, stats.aoeMulti, stats.bonusDamage)
    if ok ~= true then return false, tostring(why) end
    self:_logf('STANDIN stats peer=%s damage=%s bonus=%s', self:_label(peer), tostring(damage), tostring(stats.bonusDamage))
    return true, tostring(why), damage
end

-- SHARED_LIVES (D32): the revive explosion, one host DamageAOE at the revived player's position (modest: enough to
-- escape). MODE=dev only. Native: GMPAuthorityHostExplosion(context, x, y, radius, damage, knockback) -> ok, reason.
HD.EXPLOSION = { radius = 400, damage = 25, knockback = 800 }
function HD:Explosion(run, x, y)
    if not gameplay(self.mode) then return false, 'host_damage_requires_dev_witness' end
    if type(self.api.hostExplosion) ~= 'function' then return false, 'host_explosion_native_unavailable' end
    if type(run) ~= 'table' or type(run.context) ~= 'string' or #run.context == 0 or #run.context > 256
        or type(x) ~= 'number' or x ~= x or math.abs(x) > 2000000 or type(y) ~= 'number' or y ~= y or math.abs(y) > 2000000 then
        return false, 'host_explosion_bad_values'
    end
    local e = HD.EXPLOSION
    local ok, why = self:_call('hostExplosion', run.context, x, y, e.radius, e.damage, e.knockback)
    self:_logf('HOSTEXPLOSION x=%s y=%s %s', tostring(x), tostring(y), ok == true and 'ok' or ('refused reason=' .. tostring(why)))
    if ok ~= true then return false, tostring(why) end
    return true, tostring(why)
end

-- R1 attempt 5: one client AOE observation (movement/contact class passive) resolved by the host's own DamageAOE.
-- MODE=dev only. Native: GMPAuthorityHostAoe(context, peer, epoch, sequence, x, y, radius, damage)
--   -> ok, reason, dealt, hits, kills (credit = the HP the host read back from its own rows).
function HD:Aoe(run, peer, sequence, aoe)
    if not gameplay(self.mode) then return false, 'host_damage_requires_dev_witness' end
    if type(self.api.hostAoe) ~= 'function' then return false, 'host_aoe_native_unavailable' end
    if type(run) ~= 'table' or type(run.context) ~= 'string' or math.type(run.epoch) ~= 'integer' or type(peer) ~= 'string'
        or math.type(sequence) ~= 'integer' or type(aoe) ~= 'table' then return false, 'host_aoe_bad_values' end
    local ok, why, dealt, hits, kills = self:_call('hostAoe', run.context, peer, run.epoch, sequence, aoe.x + 0.0, aoe.y + 0.0,
        aoe.radius + 0.0, aoe.damage + 0.0)
    if ok ~= true then return false, tostring(why) end
    if type(dealt) ~= 'number' or dealt ~= dealt or dealt < 0 or math.type(hits) ~= 'integer' or math.type(kills) ~= 'integer'
        or hits < 0 or kills < 0 or kills > hits then return false, 'host_aoe_bad_result' end
    return true, tostring(why), { dealt = dealt, hits = hits, kills = kills }
end
-- Test 6: DamageAOE lands after the call; about a second later the same rows are read again and each drop is credited
-- up to the applied damage. Native: GMPAuthorityHostAoeSettle(peer, sequence) -> ok, reason, dealt, hits, kills.
function HD:AoeSettle(peer, sequence)
    if type(self.api.hostAoeSettle) ~= 'function' then return false, 'host_aoe_settle_native_unavailable' end
    local ok, why, dealt, hits, kills = self:_call('hostAoeSettle', peer, sequence)
    if ok ~= true then return false, tostring(why) end
    if type(dealt) ~= 'number' or dealt ~= dealt or dealt < 0 or math.type(hits) ~= 'integer' or math.type(kills) ~= 'integer'
        or hits < 0 or kills < 0 or kills > hits then return false, 'host_aoe_bad_result' end
    return true, tostring(why), { dealt = dealt, hits = hits, kills = kills }
end

-- Artifact 006 Symbol of pain (EnemiesDoubleDamage; research/ARTIFACTS_MP_AUDIT.md): enemies deal double damage to
-- players. When the host decides damage to remote players (D14, after milestone 1) it must apply this factor to them
-- too; the host's own BPC_CheckIfPlayerTakeDamage covers only the host. It never scales a player's outgoing hits.
function HD.ClientDamageTakenMultiplier(artifacts)
    if type(artifacts) ~= 'table' then return 1 end
    for _, path in ipairs(artifacts) do
        if type(path) == 'string' and path:find('EnemiesDoubleDamage', 1, true) then return 2 end
    end
    return 1
end

-- D50: the live stand-in pawn full name for this peer, or nil (not live, or an older native without the detail).
function HD:StandInPath(key)
    local s = self.standIns[key]
    return s and s.state == 'live' and not s.self and s.path or nil
end
function HD:Status(key)
    local entry = self.standIns[key]
    return entry and entry.state or 'stand_in_missing'
end

function HD:Count()
    local n = 0
    for _ in pairs(self.standIns) do n = n + 1 end
    return n
end

return HD
