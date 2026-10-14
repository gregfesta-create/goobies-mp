-- D45/D46 (Coder C; research/RESEARCH_PICKUPS.md 2, 4-6): the host side of shared pickups. Host role only, never raises.
--
-- Every SCAN_SECONDS (and in any tick with claims) the host reads each pickup kind (gmp_pickups_orbs.lua) and streams
-- per-client diffs as PICKUP_DELTA. Kinds (ids of non-orb kinds carry a "<kind>_" prefix):
--   o  XP orbs (D49): the host takes its native BP_EnemyController.XPInstanceComponent instances over every scan: they
--      are merged into virtual orbs (MERGE cm, worth their total; a merged orb stays where its first orb was) and
--      cleared natively in the same tick, so no orb is ever both native and virtual. Virtual orbs are drawn on the host
--      too (the same owned view as the clients, gmp_pickups_view.lua), collected by the host pawn's own proximity
--      (650 + its range), by client claims, or all at once by the host's Magnet (BPC_CheckingForXP MagnetTime?), and
--      awarded through the host pawn's own AddExperience(value) (the host's native level is the team level, D45).
--      A context (island) change drops them, as the game's own Reset clears leftover orbs.
--   h  health: AllConsumableInstances row 0; removed and granted to the toucher only (PICKUP_GRANT, D46)
--   m  Magnet: row 1; removed and the host's own Magnet runs (BPC_CheckingForXP:Magent()) for the whole team (D46)
--   x  XP consumable actors (BP_XPConsumable_C): the host calls the actor's own PickUp(), its XP goes to the team
-- A client's PICKUP_COLLECT is accepted for the current context only, from a connected peer, with a rising sequence,
-- at most COLLECTS_PER_SECOND, not while the shared pause holds, and per clump only when the peer's presence position
-- is within that kind's reach. All claims of a tick come from one scan per kind and are removed together; effects
-- apply to what was really removed. Whoever's claim is processed first in a tick wins; a repeat claim finds nothing
-- left, so nothing is granted twice, and nothing is lost: a pickup stays until someone really removes it.
--
--   H.new{game=<adapter>, log=fn, cell=400}  game defaults to H.Game.new() (the real objects below); a game adapter
--     without a kind's methods simply has no such kind
--   h:Tick(ctx, session, now)  session: EnablePickups/DrainPickups/SendPickups, roster, presence, sharedPause
--   h:Status() -> {clumps, orbs, accepted, refused, xp}
local Orbs = require('gmp_pickups_orbs')
local Wire = require('gmp_pickups_wire')
local H = {}; H.__index = H
H.SCAN_SECONDS = 0.25
H.SEND_SECONDS = 0.25
H.COLLECTS_PER_SECOND = 8
H.DIFF_MAX = 96
H.SUMMARY_SECONDS = 5
H.CONSUMABLE_REACH = 125   -- BPC_CheckingForXP's single consumable trace radius
H.ACTOR_REACH = 200
H.REWARD_REACH = 250       -- BP_RewardItem's overlap sphere (size not dumped; generous)
H.XP_ABSORB_REACH = 500    -- BP_XPConsumable ConsumeXP: 5 sphere traces of radius 100..500 cm around it
-- order = processing order of a tick's claims
H.KINDS = {
    { kind = 'o', cell = 400, scan = 'Orbs', remove = 'ClearOrbs', effect = 'xp', virtual = true },
    { kind = 'h', cell = 100, row = 0, scan = 'Consumables', remove = 'RemoveConsumable', effect = 'heal', reach = H.CONSUMABLE_REACH },
    { kind = 'm', cell = 100, row = 1, scan = 'Consumables', remove = 'RemoveConsumable', effect = 'magnet', reach = H.CONSUMABLE_REACH },
    -- actors are found by class (UE4SS FindAllOf walks the object array): at most once a second unless claimed
    -- an XP consumable absorbs the virtual orbs within XP_ABSORB_REACH of it (claimed, or the host's own pickup)
    { kind = 'x', cell = 100, scan = 'XpActors', remove = 'PickUpXpActors', effect = 'actor', reach = H.ACTOR_REACH, every = 1, natural = true },
    -- D46: loot (row 2), bush gifts (row 3) and reward item actors give EVERY player their own screen: a claim or the
    -- host's own (natural) pickup becomes one reward event (TakeRewards -> gmp_xp_host.lua Reward)
    { kind = 'i', cell = 100, row = 2, scan = 'Consumables', remove = 'RemoveConsumable', effect = 'reward', reward = 'loot',
        reach = H.CONSUMABLE_REACH, natural = true },
    { kind = 'b', cell = 100, row = 3, scan = 'Consumables', remove = 'RemoveConsumable', effect = 'reward', reward = 'bush',
        reach = H.CONSUMABLE_REACH, natural = true },
    { kind = 'r', cell = 100, scan = 'RewardActors', remove = 'TakeRewardActors', effect = 'reward', reach = H.REWARD_REACH,
        every = 1, natural = true },
}
-- BP_RewardItem DropType -> reward kind (dump: 1 loot cards, 2 arboreal 2 cards + counter, 0 and 3 roulette)
H.DROP_REWARD = { [0] = 'roulette', [1] = 'loot', [2] = 'bush', [3] = 'roulette' }

local function number(v)
    local s = string.format('%.15g', v)
    if tonumber(s) ~= v then s = string.format('%.17g', v) end
    return s
end

function H.new(options)
    options = options or {}
    local self = setmetatable({ game = options.game or H.Game.new({ G = options.G }), log = options.log, kinds = {}, order = {},
        views = {}, lastSequence = {}, window = {}, grantSequence = 0, rewards = {}, hostSeen = {},
        virtual = Orbs.Virtual.new({ merge = options.merge }),
        stats = { accepted = 0, refused = 0, xp = 0, reasons = {} }, logged = {} }, H)
    -- D49: the host draws the virtual orbs too (false: no drawing, for tests)
    if options.hostView ~= false then
        self.hostView = options.hostView or require('gmp_pickups_view').new({ G = options.G, log = options.log })
    end
    for _, spec in ipairs(H.KINDS) do
        local copy = {}
        for k, v in pairs(spec) do copy[k] = v end
        if spec.kind == 'o' and options.cell then copy.cell = options.cell end
        copy.prefix = spec.kind == 'o' and '' or (spec.kind .. '_')
        copy.tracker = Orbs.Host.new({ cell = copy.cell })
        self.kinds[spec.kind] = copy
        self.order[#self.order + 1] = copy
    end
    self.clumps = self.kinds.o.tracker   -- the orb clumps (Status, older callers)
    return self
end
function H:_log(fmt, ...)
    if not self.log then return end
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function H:_once(key, fmt, ...)
    if self.logged[key] then return end
    self.logged[key] = true; self:_log(fmt, ...)
end
-- Reward events since the last call: {kind='loot'|'bush'|'roulette', by=<peer key>|'host'} (D46: everyone's screen).
function H:TakeRewards()
    local list = self.rewards
    self.rewards = {}
    return list
end
function H:Status()
    return { clumps = self.virtual:Count(), orbs = self.virtual:Total(), accepted = self.stats.accepted,
        refused = self.stats.refused, xp = self.stats.xp }
end
function H:_has(k) return type(self.game[k.scan]) == 'function' and type(self.game[k.remove]) == 'function' end

local function connectedPeers(session)
    local out = {}
    local ok, players = pcall(function() return session.roster:Snapshot() end)
    if not ok or type(players) ~= 'table' then return out end
    local me = type(session.identity) == 'table' and session.identity.key or nil
    for _, p in ipairs(players) do
        if p.key ~= me and p.conn == 'connected' then out[p.key] = true end
    end
    return out
end
local function positions(session, now)
    local out = {}
    local presence = session.presence
    if type(presence) ~= 'table' or type(presence.Visible) ~= 'function' then return out end
    local ok, list = pcall(presence.Visible, presence, now)
    if ok and type(list) == 'table' then
        for _, v in ipairs(list) do if type(v.x) == 'number' and type(v.y) == 'number' then out[v.key] = v end end
    end
    return out
end
-- kind spec and the tracker id of a wire id, or nil
function H:_split(id)
    if type(id) ~= 'string' then return nil end
    local kind, rest = id:match('^(%a)_(.+)$')
    if kind then
        local k = self.kinds[kind]
        if k and kind ~= 'o' then return k, rest end
        return nil
    end
    return self.kinds.o, id
end
function H:_reach(k, range)
    if k.virtual then
        local extra = type(range) == 'number' and range == range and range or 0
        if extra < 0 then extra = 0 elseif extra > Orbs.MAX_EXTRA_RANGE then extra = Orbs.MAX_EXTRA_RANGE end
        return Orbs.BASE_RANGE + extra + Orbs.SLACK
    end
    if k.kind == 'o' then return Orbs.Reach(range, k.cell) end
    return k.reach + math.floor(k.cell * 0.70710678 + 0.5) + Orbs.SLACK
end

function H:_reset(ctx)
    self.contextKey = ctx.key
    for _, k in ipairs(self.order) do k.tracker:Reset(); k.scanOk = false; k.scannedAt = nil end
    if self.virtual:Count() > 0 then self:_log('PICKUPS host island change: %d virtual orbs (%d XP) dropped like the game', self.virtual:Count(), self.virtual:Total()) end
    self.virtual:Reset()
    self.views, self.lastSequence, self.window = {}, {}, {}
    self.scannedAt, self.sentAt = nil, nil
end
-- D49 takeover: read the native orbs, clear them natively, then hold them virtually (all in this tick).
function H:_takeover(ctx, k)
    local ok, points, why = pcall(self.game.Orbs, self.game, ctx)
    if not ok then points, why = nil, 'exception:' .. tostring(points):sub(1, 120) end
    if not points then
        k.scanOk = false
        self:_once('scan:o' .. tostring(why), 'PICKUPS host o scan unavailable reason=%s', tostring(why))
        return false
    end
    k.scanOk = true
    if #points == 0 then return true end
    if self.virtual:Count() + #points > self.virtual.cap then
        self:_once('virtual_cap', 'PICKUPS host virtual orb cap reached: native orbs stay native')
        return true
    end
    local cok, removed, cwhy = pcall(self.game.ClearOrbs, self.game, ctx, #points)
    if not cok then removed, cwhy = 0, 'exception:' .. tostring(removed):sub(1, 120) end
    removed = math.type(removed) == 'integer' and removed or 0
    if removed <= 0 then
        self:_once('clear:' .. tostring(cwhy), 'PICKUPS host native orb clear refused reason=%s (orbs stay native)', tostring(cwhy))
        return true
    end
    if removed < #points then
        -- never lose XP: hold as many as were really cleared (positions approximate)
        self:_log('PICKUPS host native orb clear partial wanted=%d cleared=%d', #points, removed)
        local part = {}
        for i = 1, removed do part[i] = points[i] end
        points = part
    end
    local absorbed, awhy = self.virtual:Absorb(points)
    if absorbed == nil then
        -- cannot happen after the cap check above; award at once rather than lose anything
        self:_log('PICKUPS host virtual absorb failed reason=%s: awarding %d at once', tostring(awhy), #points)
        pcall(self.game.Award, self.game, ctx, #points)
    end
    return true
end
function H:_scanKind(ctx, k)
    if k.virtual then return self:_takeover(ctx, k) end
    if not self:_has(k) then k.scanOk = false; return false end
    local ok, points, why
    if k.row then ok, points, why = pcall(self.game[k.scan], self.game, ctx, k.row)
    else ok, points, why = pcall(self.game[k.scan], self.game, ctx) end
    if not ok then points, why = nil, 'exception:' .. tostring(points):sub(1, 120) end
    if not points then
        k.scanOk = false
        self:_once('scan:' .. k.kind .. tostring(why), 'PICKUPS host %s scan unavailable reason=%s', k.kind, tostring(why))
        return false
    end
    local before
    if k.natural and k.scanOk then
        before = {}
        for _, it in ipairs(k.tracker:Items()) do before[it.id] = it end
    end
    local updated, uwhy = k.tracker:Update(points)
    if updated == nil then
        k.scanOk = false
        self:_once('update:' .. k.kind .. tostring(uwhy), 'PICKUPS host %s scan refused reason=%s', k.kind, tostring(uwhy))
        return false
    end
    k.scanOk, k.points = true, points
    -- the drop type of each reward clump (its first actor), kept for its claim or its natural disappearance
    if k.kind == 'r' then
        local drops = {}
        for _, p in ipairs(points) do
            local key = math.floor(p.x / k.cell) .. ':' .. math.floor(p.y / k.cell)
            local c = k.tracker.cells[key]
            if c and drops[c.id] == nil then drops[c.id] = p.dropType end
        end
        for id, d in pairs(drops) do k.drops = k.drops or {}; k.drops[id] = d end
    end
    if before then self:_natural(ctx, k, before) end
    return true
end
function H:_rewardKind(k, id, index)
    if k.reward then return k.reward end
    local drop = index and k.points and k.points[index + 1] and k.points[index + 1].dropType
    if drop == nil and k.drops then drop = k.drops[id] end
    return H.DROP_REWARD[drop] or 'roulette'
end
-- Pickups of a natural kind that vanished without a claim, near the host pawn: the host's own game collected them.
function H:_natural(ctx, k, before)
    local claimed = k.claimedNow or {}
    local okPos, at = pcall(self.game.HostPosition, self.game, ctx)
    if not okPos or type(at) ~= 'table' or type(at.x) ~= 'number' then return end
    local reach = self:_reach(k, 0)
    for id, old in pairs(before) do
        if not claimed[id] then
            local now = k.tracker:Find(id)
            local lost = old.n - (now and now.n or 0)
            if lost > 0 and (old.x - at.x) ^ 2 + (old.y - at.y) ^ 2 <= reach * reach then
                if k.effect == 'actor' then self:_absorb(ctx, old.x, old.y)
                else for _ = 1, lost do self.rewards[#self.rewards + 1] = { kind = self:_rewardKind(k, id), by = 'host' } end end
                self:_log('PICKUPS host collected %s itself n=%d', k.kind, lost)
            end
        end
    end
    if k.drops then for id in pairs(k.drops) do if not k.tracker:Find(id) then k.drops[id] = nil end end end
end
-- force: a claim tick (indices must come from this tick's scan)
function H:_scan(ctx, now, force)
    for _, k in ipairs(self.order) do
        if force or not k.every or not k.scannedAt or (now or 0) - k.scannedAt >= k.every then
            k.scannedAt = now; self:_scanKind(ctx, k)
        end
    end
end

function H:_refuse(reply, why)
    reply.refused = reply.refused + 1
    if reply.reason == '' then reply.reason = why end
    self.stats.refused = self.stats.refused + 1
    self.stats.reasons[why] = (self.stats.reasons[why] or 0) + 1
end
-- Apply one kind's wins of this tick: remove the union of instances, then the kind's effect for what was removed.
function H:_applyKind(ctx, session, k, indices, wins)
    table.sort(indices)
    local ok, removed, rwhy
    if k.row then ok, removed, rwhy = pcall(self.game[k.remove], self.game, ctx, k.row, indices)
    else ok, removed, rwhy = pcall(self.game[k.remove], self.game, ctx, indices) end
    if not ok then removed, rwhy = 0, 'exception:' .. tostring(removed):sub(1, 120) end
    removed = math.type(removed) == 'integer' and removed or 0
    if removed > #indices then removed = #indices end
    if removed ~= #indices then
        self:_log('PICKUPS host %s removal mismatch wanted=%d removed=%d reason=%s', k.kind, #indices, removed, tostring(rwhy))
    end
    -- credit in claim order up to what was really removed; the rest is refused (never granted twice)
    local left = removed
    for _, win in ipairs(wins) do
        local got = math.min(left, win.n)
        left = left - got
        win.got = got
        if got == win.n then
            win.reply.accepted = win.reply.accepted + 1; self.stats.accepted = self.stats.accepted + 1
        else self:_refuse(win.reply, 'remove_failed') end
        if k.kind == 'o' then win.reply.xp = win.reply.xp + got end
    end
    if removed > 0 then
        if k.effect == 'xp' then
            local aok, awarded = pcall(self.game.Award, self.game, ctx, removed)
            if not aok or awarded == false then self:_log('PICKUPS host award failed n=%d', removed) end
            self.stats.xp = self.stats.xp + removed
        elseif k.effect == 'magnet' then
            local mok, ran = pcall(self.game.Magnet, self.game, ctx)
            self:_log('PICKUPS host magnet for the team ok=%s', tostring(mok and ran ~= false))
        elseif k.effect == 'heal' then
            local hok, amount = pcall(self.game.HealAmount, self.game, ctx)
            amount = hok and type(amount) == 'number' and amount == amount and amount or 0   -- 0: the client uses its own
            for _, win in ipairs(wins) do
                if win.got > 0 then
                    self.grantSequence = self.grantSequence + 1
                    local f = { context = ctx.key, sequence = self.grantSequence, kind = 'h', value = number(amount * win.got) }
                    if Wire.Validate.PICKUP_GRANT(f) then pcall(session.SendPickups, session, win.peer, 'PICKUP_GRANT', f) end
                    self:_log('PICKUPS host health granted peer=%s n=%d', win.peer:sub(-6), win.got)
                end
            end
        elseif k.effect == 'actor' then
            self:_log('PICKUPS host xp consumables picked up n=%d', removed)
            for _, win in ipairs(wins) do if win.got > 0 then self:_absorb(ctx, win.x, win.y) end end
        elseif k.effect == 'reward' then
            for _, win in ipairs(wins) do
                for i = 1, win.got do
                    local kind = self:_rewardKind(k, win.id, win.indices and win.indices[i])
                    self.rewards[#self.rewards + 1] = { kind = kind, by = win.peer }
                    self:_log('PICKUPS host reward %s for everyone (collected by peer=%s)', kind, win.peer:sub(-6))
                end
            end
        end
    end
    self:_scanKind(ctx, k)
    return removed > 0
end
-- Claims of one tick: validated per message, removed together per kind, results sent per message.
function H:_claims(ctx, session, claims, now)
    if #claims == 0 then return false end
    local peers, where = connectedPeers(session), positions(session, now)
    local paused = type(session.sharedPause) == 'table' and session.sharedPause.paused == true
    -- rescan (this tick) only the kinds the claims name: their indices must come from this tick's scan
    local named = {}
    for _, c in ipairs(claims) do
        for _, wireId in ipairs(c.message.ids) do local k = self:_split(wireId); if k then named[k.kind] = k end end
    end
    for _, k in ipairs(self.order) do if named[k.kind] then k.scannedAt = now; self:_scanKind(ctx, k) end end
    local replies, perKind = {}, {}
    for _, c in ipairs(claims) do
        local m, peer = c.message, c.peer
        local reply = { context = ctx.key, sequence = m.sequence, accepted = 0, refused = 0, xp = 0, reason = '' }
        local why
        if m.sequence <= (self.lastSequence[peer] or 0) then why = 'replayed'
        elseif not peers[peer] then why = 'not_connected'
        else
            self.lastSequence[peer] = m.sequence
            local w = self.window[peer]
            if not w or now - w.start >= 1 then w = { start = now, n = 0 }; self.window[peer] = w end
            w.n = w.n + 1
            if w.n > H.COLLECTS_PER_SECOND then why = 'rate'
            elseif paused then why = 'paused'
            elseif not where[peer] then why = 'no_position' end
        end
        if why then
            for _ = 1, math.max(1, #m.ids) do self:_refuse(reply, why) end
        else
            local at = where[peer]
            for _, wireId in ipairs(m.ids) do
                local k, id = self:_split(wireId)
                if not k then self:_refuse(reply, 'unknown_clump')
                elseif k.virtual then
                    local current = self.virtual:Find(id)
                    local reach = self:_reach(k, m.range)
                    if not current then self:_refuse(reply, 'unknown_clump')
                    elseif (current.x - at.x) ^ 2 + (current.y - at.y) ^ 2 > reach * reach then self:_refuse(reply, 'too_far')
                    else
                        local value = self.virtual:Take(id) or 0
                        local bucket = perKind.o
                        if not bucket then bucket = { indices = {}, wins = {}, value = 0 }; perKind.o = bucket end
                        bucket.value = bucket.value + value
                        bucket.wins[#bucket.wins + 1] = { reply = reply, n = value, peer = peer, id = id }
                    end
                elseif not k.scanOk then self:_refuse(reply, 'scan_unavailable')
                else
                    local current = k.tracker:Find(id)
                    local reach = self:_reach(k, m.range)
                    if not current then self:_refuse(reply, 'unknown_clump')
                    elseif (current.x - at.x) ^ 2 + (current.y - at.y) ^ 2 > reach * reach then self:_refuse(reply, 'too_far')
                    else
                        local list, n = k.tracker:Claim(id)
                        if not list then self:_refuse(reply, n)
                        else
                            local bucket = perKind[k.kind]
                            if not bucket then bucket = { indices = {}, wins = {} }; perKind[k.kind] = bucket end
                            for _, i in ipairs(list) do bucket.indices[#bucket.indices + 1] = i end
                            bucket.wins[#bucket.wins + 1] = { reply = reply, n = n, peer = peer, id = id, indices = list, x = current.x, y = current.y }
                            k.claimedNow = k.claimedNow or {}; k.claimedNow[id] = true
                        end
                    end
                end
            end
        end
        if #m.ids > 0 then replies[#replies + 1] = { peer = peer, reply = reply } end
    end
    local changed = false
    for _, k in ipairs(self.order) do
        local bucket = perKind[k.kind]
        if bucket and k.virtual then
            for _, win in ipairs(bucket.wins) do
                win.reply.accepted = win.reply.accepted + 1; win.reply.xp = win.reply.xp + win.n
                self.stats.accepted = self.stats.accepted + 1
            end
            if self:_award(ctx, bucket.value) then changed = true end
        elseif bucket and #bucket.indices > 0 then
            if self:_applyKind(ctx, session, k, bucket.indices, bucket.wins) then changed = true end
        end
    end
    for _, r in ipairs(replies) do
        if Wire.Validate.PICKUP_RESULT(r.reply) then pcall(session.SendPickups, session, r.peer, 'PICKUP_RESULT', r.reply) end
    end
    return changed
end

function H:_award(ctx, value)
    if value < 1 then return false end
    local ok, awarded = pcall(self.game.Award, self.game, ctx, value)
    if not ok or awarded == false then self:_log('PICKUPS host award failed n=%d', value) end
    self.stats.xp = self.stats.xp + value
    return true
end
-- The XP consumable gap: the game's ConsumeXP only finds native orbs, which the D49 takeover leaves none of, so the
-- virtual orbs within XP_ABSORB_REACH of the consumable are taken and awarded to the team (AddExperience on the host).
function H:_absorb(ctx, x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then return false end
    local sum = 0
    for _, id in ipairs(self.virtual:Near(x, y, H.XP_ABSORB_REACH)) do sum = sum + (self.virtual:Take(id) or 0) end
    if sum > 0 then self:_log('PICKUPS host xp consumable absorbed %d XP of virtual orbs', sum) end
    return self:_award(ctx, sum)
end
-- D49: the host pawn collects virtual orbs by its own proximity; its Magnet sweeps all of them to the team.
function H:_hostPickup(ctx, session)
    if type(self.game.HostPickup) ~= 'function' or self.virtual:Count() == 0 then return false end
    if type(session.sharedPause) == 'table' and session.sharedPause.paused == true then return false end
    local ok, hp = pcall(self.game.HostPickup, self.game, ctx)
    if not ok or type(hp) ~= 'table' then return false end
    local sum = 0
    if hp.magnet == true then
        sum = self.virtual:TakeAll()
        if sum > 0 then self:_log('PICKUPS host magnet swept %d XP for the team', sum) end
    elseif hp.dead ~= true and type(hp.x) == 'number' and type(hp.y) == 'number' then
        local range = type(hp.range) == 'number' and hp.range > 0 and hp.range or 0
        for _, id in ipairs(self.virtual:Near(hp.x, hp.y, Orbs.BASE_RANGE + range)) do sum = sum + (self.virtual:Take(id) or 0) end
    end
    return self:_award(ctx, sum)
end
-- D49: the host's own drawing of the virtual orbs (the same owned view as the clients).
function H:_drawHost(ctx, now)
    local view = self.hostView
    if not view then return end
    if self.hostViewContext ~= ctx.key then
        if self.hostBindAt and now - self.hostBindAt < 2 then return end
        self.hostBindAt = now
        local ok, bound, why = pcall(view.Bind, view, ctx)
        if not ok or bound ~= true then
            self:_once('hostview:' .. tostring(ok and why or bound), 'PICKUPS host orb view unavailable reason=%s', tostring(ok and why or bound))
            return
        end
        self.hostViewContext, self.hostSeen = ctx.key, {}
    end
    for _, it in ipairs(self.virtual:DiffFor(self.hostSeen, 512)) do
        if it.n == 0 then pcall(view.Remove, view, it.id)
        else pcall(view.Set, view, it.id, it.x, it.y, it.z, it.n, false, 'o') end
    end
end
function H:_send(ctx, session)
    local peers = connectedPeers(session)
    for key in pairs(self.views) do if not peers[key] then self.views[key] = nil end end
    for key in pairs(peers) do
        local view = self.views[key]
        if not view then
            -- a new view starts from empty with a higher base: the client clears and takes the complete resend
            self.viewBase = (self.viewBase or 0) + 1
            view = { base = self.viewBase, seen = {} }
            self.views[key] = view
        end
        local items = {}
        for _, k in ipairs(self.order) do
            view.seen[k.kind] = view.seen[k.kind] or {}
            if #items < H.DIFF_MAX then
                local source = k.virtual and self.virtual or k.tracker
                for _, it in ipairs(source:DiffFor(view.seen[k.kind], H.DIFF_MAX - #items)) do
                    it.kind = k.kind; it.id = k.prefix .. it.id
                    items[#items + 1] = it
                end
            end
        end
        for _, f in ipairs(Wire.PackDelta(ctx.key, items, view.base)) do
            local ok, sent = pcall(session.SendPickups, session, key, 'PICKUP_DELTA', f)
            if not ok or sent ~= true then self.views[key] = nil; break end   -- full resend later
        end
    end
    for _, k in ipairs(self.order) do
        local seen = {}
        for key, view in pairs(self.views) do seen[key] = view.seen[k.kind] or {} end
        if k.virtual then seen.__host = self.hostSeen; self.virtual:Compact(seen) else k.tracker:Compact(seen) end
    end
end

function H:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if ctx.key ~= self.contextKey then self:_reset(ctx) end
        if type(session.EnablePickups) ~= 'function' then return self:_once('nosession', 'PICKUPS host session has no pickup intake') end
        session:EnablePickups()
        local claims = {}
        for _, item in ipairs(session:DrainPickups() or {}) do
            if item.type == 'PICKUP_COLLECT' then
                local m = Wire.Validate.PICKUP_COLLECT(item.f)
                if m and m.context == ctx.key and type(item.peer) == 'string' then
                    if m.resync then self.views[item.peer] = nil end
                    if #m.ids > 0 then claims[#claims + 1] = { peer = item.peer, message = m } end
                else self.stats.refused = self.stats.refused + 1 end
            end
        end
        local changed = self:_claims(ctx, session, claims, now)
        if #claims == 0 and (not self.scannedAt or now - self.scannedAt >= H.SCAN_SECONDS) then
            self.scannedAt = now; self:_scan(ctx, now, false)
        elseif #claims > 0 then self.scannedAt = now end
        if self:_hostPickup(ctx, session) then changed = true end
        if changed or not self.sentAt or now - self.sentAt >= H.SEND_SECONDS then
            self.sentAt = now; self:_send(ctx, session); self:_drawHost(ctx, now)
        end
        if not self.summaryAt or now - self.summaryAt >= H.SUMMARY_SECONDS then
            self.summaryAt = now
            local s = self:Status()
            self:_log('PICKUPS host clumps=%d orbs=%d health=%d magnets=%d xpconsumables=%d accepted=%d refused=%d xp=%d',
                s.clumps, s.orbs, self.kinds.h.tracker:Count(), self.kinds.m.tracker:Count(), self.kinds.x.tracker:Count(),
                s.accepted, s.refused, s.xp)
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'PICKUPS host tick error %s', tostring(err):sub(1, 200)) end
end

------------------------------------------------------------------ the real game objects (host)
local Game = {}; Game.__index = Game; H.Game = Game
Game.CAP = Orbs.CAP
Game.XP_CONSUMABLE_CLASS = 'BP_XPConsumable_C'
Game.XP_CONSUMABLE_PATH = '/Game/Blueprints/Consumables/BP_XPConsumable.BP_XPConsumable_C'
Game.REWARD_PATH = '/Game/Blueprints/Consumables/BP_RewardItem.BP_RewardItem_C'
Game.HEALTH_DEFAULT = '/Game/Blueprints/Consumables/BPC_Health.Default__BPC_Health_C'
-- options.findActors(className) -> list (tests); default: GameplayStatics:GetAllActorsOfClass in the local world
-- (an actor iterator that skips actors pending kill), never FindAllOf (test 12: FindAllOf crashed on an object being
-- destroyed); every actor is liveness-checked again (IsValid, not IsActorBeingDestroyed). options.G for
-- StaticFindObject.
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
local function valid(o) return o ~= nil and (type(o) ~= 'table' and type(o) ~= 'userdata' or (o.IsValid == nil or o:IsValid() == true)) end
local function len(arr)
    if arr == nil then return 0 end
    if type(arr) == 'table' and type(arr.GetArrayNum) ~= 'function' then return #arr end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    return ok and n or 0
end
function Game:_objects(ctx)
    local island = ctx.islandWorld
    if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil, 'no_island_world' end
    local _, pawn = island:LocalWorldPawn()
    if not valid(pawn) then return nil, 'no_pawn' end
    local controller = pawn.EnemyController
    if not valid(controller) and type(ctx.world) == 'table' and type(ctx.world._enemyController) == 'function' then
        controller = ctx.world:_enemyController()
    end
    if not valid(controller) then return nil, 'no_controller' end
    return { pawn = pawn, controller = controller }
end
local function readInstances(component)
    local count = component:GetInstanceCount()
    if math.type(count) ~= 'integer' then count = math.tointeger(count) end
    if not count or count < 0 then return nil, 'bad_count' end
    if count > Game.CAP then return nil, 'orb_scan_cap' end
    local points = {}
    for i = 0, count - 1 do
        local tr = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        if component:GetInstanceTransform(i, tr, true) ~= true then return nil, 'transform_unreadable' end
        points[i + 1] = { x = tr.Translation.X, y = tr.Translation.Y, z = tr.Translation.Z }
    end
    return points
end
local function removeInstances(component, indices)
    local before = component:GetInstanceCount()
    local ok = component:RemoveInstances(indices)
    local after = component:GetInstanceCount()
    local removed = (math.tointeger(before) or 0) - (math.tointeger(after) or 0)
    if removed < 0 then removed = 0 elseif removed > #indices then removed = #indices end
    return removed, ok == true and nil or 'remove_returned_false'
end
function Game:_xp(ctx)
    local o, why = self:_objects(ctx)
    if not o then return nil, why end
    local component = o.controller.XPInstanceComponent
    if not valid(component) then return nil, 'no_xp_component' end
    return component, o
end
function Game:Orbs(ctx)
    local component, why = self:_xp(ctx)
    if not component then return nil, why end
    return readInstances(component)
end
-- -> number of instances really removed (count before - count after, bounded), reason
function Game:Remove(ctx, indices)
    local component, why = self:_xp(ctx)
    if not component then return 0, why end
    return removeInstances(component, indices)
end
-- D49: clear every native orb at once, only when the count is still the one just read -> number cleared, reason
function Game:ClearOrbs(ctx, expected)
    local component, why = self:_xp(ctx)
    if not component then return 0, why end
    local before = math.tointeger(component:GetInstanceCount()) or 0
    if before ~= expected then return 0, 'count_changed' end
    component:ClearInstances()
    local after = math.tointeger(component:GetInstanceCount()) or 0
    local cleared = before - after
    if cleared < 0 then cleared = 0 end
    return cleared, after ~= 0 and 'clear_incomplete' or nil
end
-- D49: the host pawn's position, pickup range, death and Magnet state
function Game:HostPickup(ctx)
    local o = self:_objects(ctx)
    if not o then return nil end
    local at = o.pawn:K2_GetActorLocation()
    local checker = o.pawn.BPC_CheckingForXP
    local range = checker and checker.AdditionalPickUpRange or 0
    return { x = at.X, y = at.Y, z = at.Z, range = type(range) == 'number' and range or 0, dead = o.pawn.PlayerIsDead == true,
        magnet = checker ~= nil and checker['MagnetTime?'] == true }
end
function Game:Award(ctx, n)
    local o = self:_objects(ctx)
    if not o or math.type(n) ~= 'integer' or n < 1 then return false end
    o.pawn:AddExperience(n)
    return true
end
-- AllConsumableInstances[row] (DT_Consumables row order: 0 health, 1 magnet, 2 item, 3 bush); none when missing.
function Game:_row(ctx, row)
    local o, why = self:_objects(ctx)
    if not o then return nil, why end
    local list = o.controller.AllConsumableInstances
    if len(list) <= row then return false end
    local component = list[row + 1]
    if not valid(component) then return false end
    return component, o
end
function Game:Consumables(ctx, row)
    local component, why = self:_row(ctx, row)
    if component == nil then return nil, why end
    if component == false then return {} end
    return readInstances(component)
end
function Game:RemoveConsumable(ctx, row, indices)
    local component, why = self:_row(ctx, row)
    if not component then return 0, why or 'no_consumable_row' end
    return removeInstances(component, indices)
end
local Live = require('gmp_pickups_pawncache').Live
-- The live actors of one class in the local world.
function Game:_actorsOf(ctx, className, path)
    local list
    if self.options.findActors then
        list = self.options.findActors(className) or {}
    else
        local island = ctx.islandWorld
        local world, _, library = island:LocalWorldPawn()
        if not world or not library then return {} end
        local G = self.options.G or {}
        local find = G.StaticFindObject or (type(_G.StaticFindObject) == 'function' and _G.StaticFindObject) or nil
        local class = find and find(path)
        if not class or class:IsValid() ~= true then return {} end
        local out = {}
        local ret = library:GetAllActorsOfClass(world, class, out)
        list = (type(ret) == 'table' and #ret > 0) and ret or out
    end
    local live = {}
    for _, a in ipairs(list) do if Live(a) then live[#live + 1] = a end end
    return live
end
function Game:_actors(ctx) return self:_actorsOf(ctx, Game.XP_CONSUMABLE_CLASS, Game.XP_CONSUMABLE_PATH) end
function Game:XpActors(ctx)
    local o, why = self:_objects(ctx)
    if not o then return nil, why end
    local points = {}
    self.actorList = self:_actors(ctx)
    for i, a in ipairs(self.actorList) do
        local at = a:K2_GetActorLocation()
        points[i] = { x = at.X, y = at.Y, z = at.Z }
    end
    return points
end
-- The actor's own PickUp() (BPI_Consumables): ConsumeXP -> AddExperience on the host pawn (the team), then destroys.
function Game:PickUpXpActors(_, indices)
    local n = 0
    for _, i in ipairs(indices) do
        local a = self.actorList and self.actorList[i + 1]
        if valid(a) then a:PickUp(); n = n + 1 end
    end
    return n
end
Game.REWARD_CLASS = 'BP_RewardItem_C'
function Game:RewardActors(ctx)
    local o, why = self:_objects(ctx)
    if not o then return nil, why end
    local list = self:_actorsOf(ctx, Game.REWARD_CLASS, Game.REWARD_PATH)
    self.rewardList = {}
    local points = {}
    for _, a in ipairs(list) do
        if valid(a) then
            local at = a:K2_GetActorLocation()
            local drop = a.DropType
            self.rewardList[#self.rewardList + 1] = a
            points[#points + 1] = { x = at.X, y = at.Y, z = at.Z, dropType = math.tointeger(drop) or 0 }
        end
    end
    return points
end
-- A client took it: the actor goes without its overlap reward (every player gets the reward screen instead, D46).
function Game:TakeRewardActors(_, indices)
    local n = 0
    for _, i in ipairs(indices) do
        local a = self.rewardList and self.rewardList[i + 1]
        if valid(a) then a:K2_DestroyActor(); n = n + 1 end
    end
    return n
end
function Game:HostPosition(ctx)
    local o = self:_objects(ctx)
    if not o then return nil end
    local at = o.pawn:K2_GetActorLocation()
    return { x = at.X, y = at.Y, z = at.Z }
end
function Game:Magnet(ctx)
    local o = self:_objects(ctx)
    local checker = o and o.pawn.BPC_CheckingForXP
    if not checker then return false end
    checker:Magent()
    return true
end
function Game:HealAmount()
    local G = self.options.G
    local find = G and G.StaticFindObject or (type(StaticFindObject) == 'function' and StaticFindObject) or nil
    if not find then return 0 end
    local cdo = find(Game.HEALTH_DEFAULT)
    local v = valid(cdo) and cdo.HpAddAmount or nil
    return type(v) == 'number' and v or 0
end
return H
