-- S6 (moved to Track W): the client attack intent source. Client role, during a run with CLIENT_ATTACKS.
-- Drains the native capture ring GMPAuthorityClientAttackPoll() (S0; native_executor_bridge / controller_host_rows.inc):
--   ok, reason, count, drops, rejected, now, payload, hits, kills
--   payload = "worldTime,rowIndex,weaponOrdinal,kind,lifetime,state;..." oldest first; kind h (HitEnemyEvent) or k
--   (KillEnemyEvent, a lethal hit); lifetime = the host lifetime that owned rowIndex AT CAPTURE TIME ("-" if none);
--   state 0 unbound, 1 live, 2 retired.
-- Each live observation becomes one ATTACK_INTENT (C0 schema) for the host's S5 path (RunSync:ApplyRemoteHit):
--   context  = the run context key        sequence = monotonic per session (1..2^31-1)
--   enemyId  = the host lifetime ("a:b")   attack   = weaponOrdinal + 1 (1..1024)
-- Observations only: the client never sends damage, HP, position or kills; the host decides. Unbound, retired, unknown
-- or malformed entries are dropped and counted. At most CAP intents per tick; the rest wait in a queue of QUEUE entries
-- (overflow drops the newest), which a new context clears. A send the link refuses is retried next tick.
local C = {}; C.__index = C
C.CAP, C.QUEUE = 8, 64
C.AOE_PER_SECOND, C.AOE_CELL, C.AOE_BURST = 10, 200, 2
local POLL = 'GMPAuthorityClientAttackPoll'
-- R1 attempt 5 (research section 12): movement/contact class passives (Bingus nova, Hoozey fire trail) damage through
-- the native DamageAOE, which the client fence skips. GMPAuthorityClientAoePoll() -> ok, reason, count, drops, rejected,
-- skipped, payload "t,itemTypeIndex,x,y,radius,damage,sendHit;..." (oldest first, drained). Each observation becomes
-- one ATTACK_AOE {context, sequence (own counter), attack = itemTypeIndex + 1 (0 = no item), x, y, radius, damage}
-- sent through o.sendAoe; the host resolves it itself. Without o.sendAoe they are dropped (no_aoe_route).
local AOE_POLL = 'GMPAuthorityClientAoePoll'
-- Hoozey's fire trail calls DamageAOE once per particle (about 480/s at 60 fps). Observations are merged per item and
-- AOE_CELL cm cell (strongest damage and widest radius kept) and sent at most AOE_PER_SECOND (the host's own limit),
-- so the reliable window stays free for intents, stats, downs and prep acks.

-- o: G, send(fields) -> bool, sendAoe(fields) -> bool (optional), log(line), clock() -> seconds (optional; default
-- os.time, enough for the 1/s summary), feedback(entry {row, kind, attack, enemyId}) (optional: local cosmetic hit
-- feedback, called at once for each live observation), results() -> {{sequence, ok}, ...} (optional: ATTACK_RESULTs
-- since the last call; the 1/s line then ends with result_ms=<average intent -> result round trip>)
-- Logs (R1 attempt 4): "CLIENTATTACK capture active=<bool> reason=<native reason>" on every capture state change, and
-- once a second while in a run "CLIENTATTACK polled n=<ok polls> sent n=<intents> dropped n=<drops> native_hits=<total>
-- native_kills=<total> active=<bool> kinds proj=<intents> aoe=<ATTACK_AOE sent> aoe_native=<skipped DamageAOE calls,
-- total>" (counts per summary window; native_* are the fence's cumulative counters, which tell whether the client's
-- projectiles reach the controller routes at all).
C.SUMMARY_SECONDS = 1
function C.new(o)
    assert(type(o) == 'table' and type(o.send) == 'function', 'client attack source needs send')
    return setmetatable({ o = o, G = o.G or {}, sequence = 0, pending = {}, logged = {},
        clock = type(o.clock) == 'function' and o.clock or os.time, window = { polls = 0, sent = 0, dropped = 0, aoe = 0, merged = 0 },
        native = { hits = 0, kills = 0 }, aoeSequence = 0, aoePending = {}, aoeIndex = {}, aoeNative = 0, aoeTokens = C.AOE_BURST,
        stats = { sent = 0, hits = 0, kills = 0, polls = 0, aoe = 0, aoeMerged = 0, dropped = {} } }, C)
end
function C:_capture(active, reason)
    reason = tostring(reason)
    if self.active == active and self.activeReason == reason then return end
    self.active, self.activeReason = active, reason
    if self.o.log then self.o.log(string.format('CLIENTATTACK capture active=%s reason=%s', tostring(active), reason)) end
end
function C:_results()
    if type(self.o.results) ~= 'function' then return end
    local okNow, now = pcall(self.clock)
    local ok, list = pcall(self.o.results)
    if not ok or type(list) ~= 'table' or not okNow or type(now) ~= 'number' then return end
    for _, r in ipairs(list) do
        local at = self.sentAt and math.type(r.sequence) == 'integer' and self.sentAt[r.sequence]
        if at then
            self.window.rtt, self.window.rttN = (self.window.rtt or 0) + (now - at), (self.window.rttN or 0) + 1
            self.sentAt[r.sequence] = nil
        end
    end
end
function C:_summary()
    self:_results()
    local ok, now = pcall(self.clock)
    if not ok or type(now) ~= 'number' then return end
    if not self.summaryAt then self.summaryAt = now; return end
    if now - self.summaryAt < C.SUMMARY_SECONDS then return end
    self.summaryAt = now
    local w = self.window
    if self.o.log then
        self.o.log(string.format('CLIENTATTACK polled n=%d sent n=%d dropped n=%d native_hits=%d native_kills=%d active=%s kinds proj=%d aoe=%d aoe_native=%d',
            w.polls, w.sent, w.dropped, self.native.hits, self.native.kills, tostring(self.active == true), w.sent, w.aoe,
            self.aoeNative) .. string.format(' aoe_merged=%d result_ms=%s numbers=%d boss_hits=%d/%d', w.merged,
            (w.rttN or 0) > 0 and tostring(math.floor(w.rtt / w.rttN * 1000 + 0.5)) or '-', w.numbers or 0,
            w.bossSeen or 0, w.bossSent or 0))
    end
    self.window = { polls = 0, sent = 0, dropped = 0, aoe = 0, merged = 0 }
end
function C:_once(line) if self.logged[line] then return end; self.logged[line] = true; if self.o.log then self.o.log(line) end end
function C:_drop(why) self.stats.dropped[why] = (self.stats.dropped[why] or 0) + 1; self.window.dropped = self.window.dropped + 1 end
-- One payload entry -> {enemyId, attack, kind} or nil, drop reason.
local function parse(text)
    local f = {}
    for part in (text .. ','):gmatch('([^,]*),') do f[#f + 1] = part end
    if #f ~= 6 then return nil, 'malformed' end
    local time, row, weapon, state = tonumber(f[1]), math.tointeger(tonumber(f[2])), math.tointeger(tonumber(f[3])), f[6]
    if not time or not row or not weapon or (f[4] ~= 'h' and f[4] ~= 'k') or (state ~= '0' and state ~= '1' and state ~= '2') then
        return nil, 'malformed'
    end
    if state == '2' then return nil, 'retired' end
    if state == '0' or f[5] == '-' then return nil, 'unbound' end
    if #f[5] > 32 or not f[5]:match('^%d+:%d+$') then return nil, 'unknown_row' end
    if weapon < 0 or weapon + 1 > 1024 then return nil, 'bad_weapon' end
    return { enemyId = f[5], attack = weapon + 1, kind = f[4], row = row }
end
function C:_poll()
    local fn = self.G[POLL]
    if type(fn) ~= 'function' then self:_once('CLIENTATTACK poll unavailable: ' .. POLL .. ' missing'); return end
    local called, ok, reason, _, _, _, _, payload, hits, kills = pcall(fn)
    if not called then self:_once('CLIENTATTACK poll failed: ' .. tostring(ok):sub(1, 200)); self:_capture(false, 'poll_error'); return end
    self:_capture(ok == true, reason)
    if ok ~= true then self:_once('CLIENTATTACK poll unavailable: ' .. tostring(reason)); return end
    self.stats.polls = self.stats.polls + 1; self.window.polls = self.window.polls + 1
    if math.type(hits) == 'integer' then self.native.hits = hits end
    if math.type(kills) == 'integer' then self.native.kills = kills end
    if type(payload) ~= 'string' or payload == '' then return end
    for entry in (payload .. ';'):gmatch('([^;]*);') do
        if entry ~= '' then
            local item, why = parse(entry)
            if item and type(self.o.classify) == 'function' then
                local okClass, class = pcall(self.o.classify, item)
                if okClass and class == 'actor' then item.actor = true; self.window.bossSeen = (self.window.bossSeen or 0) + 1 end
            end
            if item and type(self.o.feedback) == 'function' then
                local called, shown = pcall(self.o.feedback, item)
                if called and shown == true then self.window.numbers = (self.window.numbers or 0) + 1 end
            end
            -- Dizzy Wizzy's chain blast: derived from this standard hit (o.chain -> an AOE observation, or nil) and sent
            -- like any captured DamageAOE (ATTACK_AOE, host-resolved with every AOE bound)
            if item and type(self.o.chain) == 'function' then
                local called, aoe = pcall(self.o.chain, item)
                if called and type(aoe) == 'table' then
                    self.stats.chains = (self.stats.chains or 0) + 1
                    self:_queueAoe(aoe)
                end
            end
            if not item then self:_drop(why)
            elseif #self.pending >= C.QUEUE then self:_drop('queue_full')
            else self.pending[#self.pending + 1] = item end
        end
    end
end
-- ctx: the gmp_run_context context (client role) or nil.
function C:Tick(ctx)
    if type(ctx) ~= 'table' or ctx.role ~= 'client' or type(ctx.key) ~= 'string' then return end
    if ctx.key ~= self.context then
        if self.context and #self.pending > 0 then self:_drop('context_changed') end
        self.context, self.pending = ctx.key, {}
    end
    if ctx.key ~= self.aoeContext then self.aoeContext, self.aoePending, self.aoeIndex = ctx.key, {}, {} end
    self:_poll()
    self:_pollAoe()
    self:_send(ctx)
    self:_sendAoe(ctx)
    self:_summary()
end
local function parseAoe(text)
    local f = {}
    for part in (text .. ','):gmatch('([^,]*),') do f[#f + 1] = part end
    if #f ~= 7 then return nil end
    local t, item, x, y = tonumber(f[1]), math.tointeger(tonumber(f[2])), tonumber(f[3]), tonumber(f[4])
    local radius, damage = math.tointeger(tonumber(f[5])), tonumber(f[6])
    local function finite(v, bound) return type(v) == 'number' and v == v and math.abs(v) <= bound end
    if not finite(t, 1e12) or not item or item < -1 or item > 255 or not finite(x, 2000000) or not finite(y, 2000000)
        or not radius or radius < 1 or radius > 100000 or not finite(damage, 1e12) or damage < 0
        or (f[7] ~= '0' and f[7] ~= '1') then return nil end
    return { attack = item + 1, x = math.floor(x + 0.5), y = math.floor(y + 0.5), radius = radius, damage = damage }
end
-- One AOE observation into the send queue: merged per item and cell, bounded (shared by captures and derived chains).
function C:_queueAoe(item)
    if type(self.o.sendAoe) ~= 'function' then self:_drop('no_aoe_route'); return end
    if type(item.x) ~= 'number' or type(item.y) ~= 'number' or type(item.radius) ~= 'number' or type(item.damage) ~= 'number'
        or math.type(item.attack) ~= 'integer' then self:_drop('aoe_malformed'); return end
    item.x, item.y, item.radius = math.floor(item.x + 0.5), math.floor(item.y + 0.5), math.floor(item.radius)
    local key = item.attack .. ':' .. math.floor(item.x / C.AOE_CELL) .. ':' .. math.floor(item.y / C.AOE_CELL)
    local same = self.aoeIndex[key]
    if same then
        same.damage, same.radius = math.max(same.damage, item.damage), math.max(same.radius, item.radius)
        self.stats.aoeMerged = self.stats.aoeMerged + 1; self.window.merged = self.window.merged + 1
    elseif #self.aoePending >= C.QUEUE then self:_drop('aoe_queue_full')
    else
        item.key = key
        self.aoePending[#self.aoePending + 1] = item; self.aoeIndex[key] = item
    end
end
function C:_pollAoe()
    local fn = self.G[AOE_POLL]
    if type(fn) ~= 'function' then return end
    local called, ok, reason, _, _, _, skipped, payload = pcall(fn)
    local active = called and ok == true
    local why = called and tostring(reason) or 'poll_error'
    if self.aoeActive ~= active or self.aoeReason ~= why then
        self.aoeActive, self.aoeReason = active, why
        if self.o.log then self.o.log(string.format('CLIENTATTACK aoe capture active=%s reason=%s', tostring(active), why)) end
    end
    if not active then return end
    if math.type(skipped) == 'integer' then self.aoeNative = skipped end
    if type(payload) ~= 'string' or payload == '' then return end
    for entry in (payload .. ';'):gmatch('([^;]*);') do
        if entry ~= '' then
            local item = parseAoe(entry)
            -- test 13: local cosmetic numbers on the enemies inside the radius (o.aoeFeedback -> numbers shown)
            if item and type(self.o.aoeFeedback) == 'function' then
                local called, n = pcall(self.o.aoeFeedback, item)
                if called and math.type(n) == 'integer' and n > 0 then self.window.numbers = (self.window.numbers or 0) + n end
            end
            if not item then self:_drop('aoe_malformed')
            else self:_queueAoe(item) end
        end
    end
end
function C:_sendAoe(ctx)
    local ok, now = pcall(self.clock)
    if ok and type(now) == 'number' then
        if self.aoeRefill then self.aoeTokens = math.min(C.AOE_BURST, self.aoeTokens + (now - self.aoeRefill) * C.AOE_PER_SECOND) end
        self.aoeRefill = now
    end
    local sent = 0
    while sent < C.CAP and #self.aoePending > 0 and self.aoeTokens >= 1 do
        if self.aoeSequence >= 2147483647 then self:_once('CLIENTATTACK aoe sequence exhausted'); return end
        local item = self.aoePending[1]
        local fields = { context = ctx.key, sequence = self.aoeSequence + 1, attack = item.attack, x = item.x, y = item.y,
            radius = item.radius, damage = string.format('%.17g', item.damage) }
        local ok, accepted = pcall(self.o.sendAoe, fields)
        if not ok or accepted ~= true then return end   -- link full: retry next tick
        table.remove(self.aoePending, 1); self.aoeIndex[item.key] = nil
        self.aoeTokens = self.aoeTokens - 1
        self.aoeSequence = fields.sequence; sent = sent + 1
        self.stats.aoe = self.stats.aoe + 1; self.window.aoe = self.window.aoe + 1
    end
end
function C:_send(ctx)
    local sent = 0
    while sent < C.CAP and #self.pending > 0 do
        local item = self.pending[1]
        if self.sequence >= 2147483647 then self:_once('CLIENTATTACK sequence exhausted'); return end
        local fields = { context = ctx.key, sequence = self.sequence + 1, enemyId = item.enemyId, attack = item.attack }
        local ok, accepted = pcall(self.o.send, fields)
        if not ok or accepted ~= true then return end   -- link full: retry this entry next tick
        table.remove(self.pending, 1)
        self.sequence = fields.sequence; sent = sent + 1
        if item.actor then self.window.bossSent = (self.window.bossSent or 0) + 1 end
        local okNow, now = pcall(self.clock)
        if okNow and type(now) == 'number' then
            self.sentAt = self.sentAt or {}
            self.sentAt[fields.sequence] = now
            self.sentAt[fields.sequence - 256] = nil
        end
        self.stats.sent = self.stats.sent + 1; self.window.sent = self.window.sent + 1
        if item.kind == 'k' then self.stats.kills = self.stats.kills + 1 else self.stats.hits = self.stats.hits + 1 end
    end
end
return C
