-- Enemy delta stream (R1 attempt 4 follow-up; dev, client rows mode). Pure policy, no game or transport calls.
-- The full-snapshot stream (gmp_enemy_stream.lua) sends one reliable 8-row fragment per peer per app tick and a client
-- applies only complete snapshots, so with hundreds of enemies the client's view lags by seconds. Instead, per client:
--   Host.new(options):Plan(now, peerKey, records, focus, quality) -> lifePackets, motionPackets
--     records  the host registry's records (gmp_enemies records: id, epoch, slot, enemyType, x, y, hp, dead, damage)
--     focus    that client's presence position {x, y} (nil: no distance priority)
--     quality  {rtt (s) | nil, loss (0..1) | nil, backlog (reliable in flight)}: from the session's link monitor
--     ENEMY_LIFE (reliable): deaths, then spawns (nearest first), then damage updates; each event once; held while the
--       reliable backlog is high (delayed, never dropped); at most lifePackets per tick.
--     ENEMY_MOTION (unreliable, stamped with the host time in ms): enemies that moved more than posEpsilon or changed
--       HP, plus a keepalive for still ones (a lost packet heals). Priority: near and fast first, and the longer an
--       enemy waited the higher it climbs (nothing starves). Near enemies (nearRadius) at the adaptive rate, far ones
--       at most every farDivisor intervals. A token bucket keeps each client under `budget` bytes/s (worst-case
--       header counted); rows that do not fit wait (counted as skipped).
--   Rate: 30/20/15/10/5 Hz, evaluated once a second: down on RTT > 250 ms, loss > 5% or backlog; up after 3 good s.
--   Client.new():Life(f, now) / :Motion(f, now) / :View(now) -> {epoch, revision, enemies} (the snapshot shape the
--     rows path consumes; its rows are valid until the next View: one reused row table per enemy, test 14) /
--     :Delay() / :Stats()
--     Each enemy is interpolated between its samples at (now - clock offset - delay); delay = 1.5 x the measured
--     update interval + 2 x jitter (MIN_DELAY..MAX_DELAY). Past the newest sample it extrapolates along the last
--     velocity for at most EXTRAPOLATE_MAX, then holds. Deaths are final (a lifetime never returns); dead rows are kept
--     DEAD_KEEP seconds for the rows path to retire, then dropped.
local Codec = require('gmp_codec')
local Messages = require('gmp_messages')

local D = {}
-- posEpsilon: a row is sent when the client's own prediction (extrapolation from its last two samples) would be off by
-- more than this many cm (dead reckoning; test 6: resending every moving enemy every tick cost 26 bytes a row).
D.DEFAULTS = { budget = 48000, totalBudget = 96000, maxHz = 30, nearRadius = 3000, farDivisor = 3, posEpsilon = 16, keepalive = 1.0,
    lifePackets = 4, lifeBacklog = 32, mtu = 1100 }
D.LADDER = { 30, 20, 15, 10, 5 }
-- D52 audit (3-4 players): totalBudget is shared among the clients planned for in the last PEER_SECONDS; each client
-- gets at most `budget` (one client keeps its 48 KB/s, three share 96 KB/s).
D.PEER_SECONDS = 2
-- RTT counts against the link's own baseline (its lowest recent RTT): test 6's Steam relay sat at 250-350 ms on one
-- PC and a fixed 250 ms threshold forced 5 Hz. Slow = more than RTT_RISE above the baseline; good = within RTT_CALM.
D.RTT_RISE, D.RTT_CALM = 0.2, 0.1
D.LOSS_HIGH, D.LOSS_GOOD = 0.05, 0.01
-- Test 10 (Coder A, coordinator-approved): q.loss is RELIABLE loss (resends against reliable sends). Unreliable gaps
-- (q.lossU) are mostly expected drops on newest-wins lanes; they count only above LOSS_U_HIGH for LOSS_U_SECONDS in a
-- row, and then step down one level per such stretch. After the first step up, each further calm second climbs a level.
D.LOSS_U_HIGH, D.LOSS_U_SECONDS = 0.30, 3
D.BACKLOG_HIGH = 24
D.GOOD_SECONDS = 3
-- Test 7: delay sat at the old 350 ms cap on relay jitter. With dead reckoning the client extrapolates between rows
-- anyway, so the buffer only absorbs arrival jitter: one interval + the jitter, at most 200 ms.
-- Test 11 (visual lag): at most 100 ms; the prediction below covers the rest between rows.
D.MIN_DELAY, D.MAX_DELAY = 0.05, 0.1
D.EXTRAPOLATE_MAX = 1.0   -- = keepalive: the host resends before the client's prediction drifts (dead reckoning)
-- Visual-only prediction past the newest sample (the host's stream and the collision rows are unchanged): an enemy
-- heading for the nearest player within SEEK_RADIUS cm (within SEEK_COS of its direction) keeps seeking that player at its observed speed;
-- any other keeps its observed turn rate (at most TURN_MAX rad/s). Turning is predicted PREDICT_MAX seconds ahead,
-- then the path continues straight. A new sample's correction fades out over BLEND seconds; one more than SNAP cm off
-- snaps (counted).
D.PREDICT = true
D.PREDICT_MAX, D.PREDICT_STEP = 0.3, 1 / 30
D.SEEK_COS, D.SEEK_RADIUS, D.TURN_MAX = 0.8, 3000, 6
D.BLEND, D.SNAP, D.CORRECT_SPEED = 0.12, 200, 500   -- a large correction fades at most CORRECT_SPEED cm/s
D.DEAD_KEEP = 3
D.SAMPLES = 4
-- Actor-driven classes (uniques/bosses: no mesh template, their actor reads its row's position, HP and death). Their
-- HP change rides ENEMY_LIFE ('u') at most every ACTOR_HP_SECONDS: the client's boss bar reads the row's HP and
-- motion carries none.
D.ACTOR_CLASSES = {}
for kind = 13, 25 do D.ACTOR_CLASSES[kind] = true end
D.ACTOR_HP_SECONDS = 0.2

local function finite(v, limit) return type(v) == 'number' and v == v and math.abs(v) <= (limit or math.huge) end
local function round(v) return math.floor(v + 0.5) end
local function number(v) return string.format('%.6g', v) end

------------------------------------------------------------------ packed motion rows
-- 9 characters a row: 3 for slot*16 + parity (lifetime counter % 16), 3 each for x and y in D.Q cm steps offset by
-- D.QMAX (|v| <= D.QMAX * D.Q, about 5.2 km). URL-safe base64 digits: never escaped by the codec.
D.Q, D.QMAX, D.ROW_CHARS = 4, 131071, 9
local ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local DIGIT = {}
for i = 1, 64 do DIGIT[ALPHA:byte(i)] = i - 1 end
local function enc3(v) return ALPHA:sub(v // 4096 + 1, v // 4096 + 1) .. ALPHA:sub(v // 64 % 64 + 1, v // 64 % 64 + 1) .. ALPHA:sub(v % 64 + 1, v % 64 + 1) end
local function dec3(s, i)
    local a, b, c = DIGIT[s:byte(i)], DIGIT[s:byte(i + 1)], DIGIT[s:byte(i + 2)]
    if not a or not b or not c then return nil end
    return a * 4096 + b * 64 + c
end
function D.EncodeRow(slot, parity, x, y)
    if math.type(slot) ~= 'integer' or slot < 0 or slot > 4095 or math.type(parity) ~= 'integer' or parity < 0 or parity > 15
        or not finite(x) or not finite(y) then return nil end
    local qx, qy = math.floor(x / D.Q + 0.5), math.floor(y / D.Q + 0.5)
    if math.abs(qx) > D.QMAX or math.abs(qy) > D.QMAX then return nil end
    return enc3(slot * 16 + parity) .. enc3(qx + D.QMAX) .. enc3(qy + D.QMAX)
end
function D.DecodeRows(data)
    if type(data) ~= 'string' or #data % D.ROW_CHARS ~= 0 or #data > 4096 then return nil end
    local out = {}
    for i = 1, #data, D.ROW_CHARS do
        local code, qx, qy = dec3(data, i), dec3(data, i + 3), dec3(data, i + 6)
        if not code or not qx or not qy or code > 65535 then return nil end
        out[#out + 1] = { slot = code // 16, parity = code % 16, x = (qx - D.QMAX) * D.Q, y = (qy - D.QMAX) * D.Q }
    end
    return out
end
local function parityOf(id) local n = tonumber(id:match(':(%d+)$')); return n and n % 16 or nil end

------------------------------------------------------------------ rate
local Rate = {}; Rate.__index = Rate; D.Rate = Rate
function Rate.new(maxHz)
    maxHz = maxHz or D.DEFAULTS.maxHz
    local top = #D.LADDER
    for i, hz in ipairs(D.LADDER) do if hz <= maxHz then top = i; break end end
    return setmetatable({ top = top, level = top, good = 0, last = 0, base = nil }, Rate)
end
function Rate:Hz() return D.LADDER[self.level] end
function Rate:Evaluate(now, q)
    if now - self.last < 1 then return end
    self.last = now
    q = q or {}
    if q.rtt then
        -- baseline: the lowest RTT seen, rising slowly (1% a second) so a changed route can raise it
        if not self.base or q.rtt < self.base then self.base = q.rtt else self.base = self.base + (q.rtt - self.base) * 0.01 end
    end
    local slow = q.rtt and self.base and q.rtt > self.base + D.RTT_RISE
    local calm = q.rtt == nil or (self.base and q.rtt <= self.base + D.RTT_CALM)
    local lossyU = q.lossU ~= nil and q.lossU > D.LOSS_U_HIGH
    self.lossyU = lossyU and (self.lossyU or 0) + 1 or 0
    local sustainedU = self.lossyU >= D.LOSS_U_SECONDS
    if sustainedU then self.lossyU = 0 end
    local bad = slow or (q.loss and q.loss > D.LOSS_HIGH) or (q.backlog or 0) > D.BACKLOG_HIGH or sustainedU
    if bad then
        self.level, self.good = math.min(#D.LADDER, self.level + 1), 0
    elseif calm and not lossyU and (q.loss == nil or q.loss <= D.LOSS_GOOD) then
        self.good = self.good + 1
        -- quick recovery: once climbing, a further calm second is enough for the next level
        if self.good >= D.GOOD_SECONDS and self.level > self.top then self.level, self.good = self.level - 1, D.GOOD_SECONDS - 1 end
    else
        self.good = 0
    end
end

------------------------------------------------------------------ host
local Host = {}; Host.__index = Host; D.Host = Host
function Host.new(options)
    local o = {}
    for k, v in pairs(D.DEFAULTS) do o[k] = (options or {})[k] == nil and v or options[k] end
    assert(finite(o.budget) and o.budget >= 2000 and o.budget <= 1000000, 'enemy_delta_budget')
    assert(math.type(o.mtu) == 'integer' and o.mtu >= 300 and o.mtu <= Codec.MAX_PACKET, 'enemy_delta_mtu')
    return setmetatable({ o = o, peers = {} }, Host)
end

-- Worst-case framing: the largest legal header counters, as gmp_enemy_stream.lua does.
local function size(kind, f)
    local s = Codec.Encode({ type = kind, ch = Messages.Schema[kind].ch, ep = 2147483647, seq = 9007199254740991,
        ack = 9007199254740991, sid = 'Sffffffff', f = f })
    return s and #s or nil
end
-- Packs items (already ordered) into packets of `kind`; `fieldName` is the list field. Each item's encoded length is
-- additive (atoms joined by ',' and records by ';'), so a packet is measured once when it is closed. Returns packets,
-- total bytes, the number of items packed. Stops before `maxBytes` total or `maxPackets` packets.
local function pack(kind, base, fieldName, items, atoms, mtu, maxBytes, maxPackets)
    local packets, total, packed = {}, 0, 0
    local empty = {}; for k, v in pairs(base) do empty[k] = v end; empty[fieldName] = {}
    local head = assert(size(kind, empty), 'enemy_delta_header')
    local current, length = nil, 0
    local function close()
        if not current then return end
        local bytes = assert(size(kind, current), 'enemy_delta_packet')
        packets[#packets + 1] = current; total = total + bytes
        current, length = nil, 0
    end
    for _, item in ipairs(items) do
        local itemLength = #table.concat(atoms(item), ',') + 1
        if current and head + length + itemLength > mtu then close() end
        if not current then
            if #packets >= maxPackets or total + head + itemLength > maxBytes then break end
            current = {}; for k, v in pairs(base) do current[k] = v end; current[fieldName] = {}
        end
        if total + head + length + itemLength > maxBytes then break end
        current[fieldName][#current[fieldName] + 1] = item; length = length + itemLength; packed = packed + 1
    end
    close()
    return packets, total, packed
end
local function lifeAtoms(e) return { e.kind, e.id, tostring(e.slot), tostring(e.enemyType), tostring(e.x), tostring(e.y), e.hp, e.damage } end
-- What the client draws for k at host time `now`: its last sample, extrapolated along the last two (as Client does).
local function predict(k, now)
    if not k.px or k.at <= k.pt then return k.x, k.y end
    local ahead = math.min(now - k.at, D.EXTRAPOLATE_MAX)
    local dt = k.at - k.pt
    return k.x + (k.x - k.px) / dt * ahead, k.y + (k.y - k.py) / dt * ahead
end

function Host:_peer(key, now)
    local p = self.peers[key]
    if not p then
        p = { known = {}, rate = Rate.new(self.o.maxHz), nextMotion = now, tokens = 0, refill = now,
            window = { start = now, bytes = 0, sent = 0, skipped = 0, sends = 0 }, stats = { bytesPerS = 0, sent = 0, skipped = 0, sends = 0 } }
        self.peers[key] = p
    end
    return p
end
function Host:Forget(key) self.peers[key] = nil end

local function distance(r, focus)
    if not focus or not finite(focus.x) or not finite(focus.y) then return 0 end
    return math.sqrt((r.x - focus.x) ^ 2 + (r.y - focus.y) ^ 2)
end

function Host:Plan(now, key, records, focus, quality)
    local o, p = self.o, self:_peer(key, now)
    quality = quality or {}
    local epoch
    for _, r in pairs(records or {}) do epoch = r.epoch; break end
    if epoch and epoch ~= p.epoch then p.epoch, p.known = epoch, {} end
    p.rate:Evaluate(now, quality)
    if now - p.window.start >= 1 then
        local w = p.window
        local span = now - w.start
        p.stats = { bytesPerS = math.floor(w.bytes / span + 0.5), sent = w.sent, skipped = w.skipped, sends = w.sends,
            rttMs = quality.rtt and math.floor(quality.rtt * 1000 + 0.5) or nil }
        p.window = { start = now, bytes = 0, sent = 0, skipped = 0, sends = 0 }
    end
    if not p.epoch then return {}, {} end
    -- token bucket: `budget` bytes per second, at most ~1.5 sends' worth banked
    local hz = p.rate:Hz()
    p.planned = now
    local active = 0
    for _, q in pairs(self.peers) do if q.planned and now - q.planned <= D.PEER_SECONDS then active = active + 1 end end
    local budget = math.min(o.budget, (o.totalBudget or o.budget) / math.max(1, active))
    p.tokens = math.min(p.tokens + budget * math.max(0, now - p.refill), math.max(budget / hz * 1.5, o.mtu + 200))
    p.refill = now

    ------------------------------------------------ life: deaths, spawns (nearest first), damage updates
    local deaths, spawns, updates = {}, {}, {}
    for id, k in pairs(p.known) do
        local r = records[id]
        if not k.dead and (not r or r.dead) then
            deaths[#deaths + 1] = { kind = 'd', id = id, slot = k.slot, enemyType = k.enemyType, x = 0, y = 0, hp = '0', damage = '' }
        end
    end
    for id, r in pairs(records) do
        local k = p.known[id]
        if not k and not r.dead then
            spawns[#spawns + 1] = { kind = 's', id = id, slot = r.slot, enemyType = r.enemyType, x = round(r.x), y = round(r.y),
                hp = number(r.hp), damage = r.damage ~= nil and number(r.damage) or '', d = distance(r, focus) }
        elseif k and not k.dead and not r.dead and (r.damage ~= k.damage
            or (D.ACTOR_CLASSES[r.enemyType] and r.hp ~= k.hp and now - (k.hpAt or -math.huge) + 1e-9 >= D.ACTOR_HP_SECONDS)) then
            updates[#updates + 1] = { kind = 'u', id = id, slot = r.slot, enemyType = r.enemyType, x = round(r.x), y = round(r.y),
                hp = number(r.hp), damage = r.damage ~= nil and number(r.damage) or '' }
        end
    end
    table.sort(deaths, function(a, b) return a.id < b.id end)
    table.sort(spawns, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
    table.sort(updates, function(a, b) return a.id < b.id end)
    local events = {}
    for _, list in ipairs({ deaths, spawns, updates }) do for _, e in ipairs(list) do events[#events + 1] = e end end
    local life = {}
    if #events > 0 and (quality.backlog or 0) < o.lifeBacklog then
        local clean = {}
        for i, e in ipairs(events) do
            clean[i] = { kind = e.kind, id = e.id, slot = e.slot, enemyType = e.enemyType, x = e.x, y = e.y, hp = e.hp, damage = e.damage }
        end
        local bytes
        life, bytes = pack('ENEMY_LIFE', { epoch = p.epoch }, 'events', clean, lifeAtoms, o.mtu, math.huge, o.lifePackets)
        p.window.bytes = p.window.bytes + bytes; p.tokens = p.tokens - bytes
        for _, packet in ipairs(life) do
            for _, e in ipairs(packet.events) do
                local r = records[e.id]
                if e.kind == 'd' then
                    p.known[e.id].dead = true
                elseif e.kind == 's' then
                    p.known[e.id] = { slot = r.slot, enemyType = r.enemyType, x = r.x, y = r.y, hp = r.hp, damage = r.damage, at = now,
                        hpAt = now }
                else
                    p.known[e.id].damage, p.known[e.id].hp, p.known[e.id].hpAt = r.damage, r.hp, now
                end
            end
        end
    end

    ------------------------------------------------ motion
    local motion = {}
    if now + 1e-9 >= p.nextMotion then
        local interval = 1 / hz
        p.nextMotion = math.max(p.nextMotion + interval, now + interval * 0.5)
        local candidates = {}
        for id, k in pairs(p.known) do
            local r = records[id]
            if not k.dead and r and not r.dead and k.at < now then
                local ex, ey = predict(k, now)
                local moved = math.sqrt((r.x - ex) ^ 2 + (r.y - ey) ^ 2)
                local age = now - k.at
                local changed = moved > o.posEpsilon
                local d = distance(r, focus)
                local far = d > o.nearRadius
                local due = changed and (not far or age + 1e-9 >= o.farDivisor * interval) or age + 1e-9 >= o.keepalive
                if due then
                    local speed = moved / math.max(age, 1e-3)
                    candidates[#candidates + 1] = { id = id, r = r, k = k,
                        score = (d + 100) / ((1 + age * 4) * (1 + speed / 600)) * (changed and 1 or 4) }
                end
            end
        end
        table.sort(candidates, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.id < b.id end)
        -- packed rows (9 characters each, no escaping): exact packet sizes without per-row encoding
        local base = { epoch = p.epoch, t = round(now * 1000), data = '' }
        local head = assert(size('ENEMY_MOTION', base), 'enemy_delta_header')
        local perPacket = math.max(1, (o.mtu - head) // D.ROW_CHARS)
        local budget = math.max(0, p.tokens)
        local bytes, packed, chunk, chunkRows = 0, 0, {}, 0
        local function flush()
            if chunkRows == 0 then return end
            local f = { epoch = p.epoch, t = base.t, data = table.concat(chunk) }
            motion[#motion + 1] = f; bytes = bytes + head + chunkRows * D.ROW_CHARS
            chunk, chunkRows = {}, 0
        end
        local sentRows = {}
        for _, c in ipairs(candidates) do
            local extra = (chunkRows == 0 and head or 0) + D.ROW_CHARS
            if bytes + (chunkRows > 0 and head + chunkRows * D.ROW_CHARS or 0) + extra > budget then break end
            local row = D.EncodeRow(c.r.slot, parityOf(c.id) or 0, c.r.x, c.r.y)
            if row then
                chunk[#chunk + 1] = row; chunkRows = chunkRows + 1; packed = packed + 1
                sentRows[#sentRows + 1] = c
                if chunkRows >= perPacket then flush() end
            end
        end
        flush()
        if #motion == 0 and budget >= head then
            -- a heartbeat every motion tick (no rows): the client's clock offset and update interval stay measured
            motion[1] = { epoch = p.epoch, t = base.t, data = '' }; bytes = bytes + head
        end
        for _, c in ipairs(sentRows) do
            local q = D.DecodeRows(D.EncodeRow(c.r.slot, 0, c.r.x, c.r.y))[1]   -- what the client receives (quantized)
            c.k.px, c.k.py, c.k.pt = c.k.x, c.k.y, c.k.sent and c.k.at or nil
            if not c.k.sent then c.k.px = nil end
            c.k.x, c.k.y, c.k.at, c.k.sent = q.x, q.y, now, true
        end
        p.tokens = p.tokens - bytes
        p.window.bytes = p.window.bytes + bytes; p.window.sent = p.window.sent + packed
        p.window.skipped = p.window.skipped + (#candidates - packed)
        if #motion > 0 then p.window.sends = p.window.sends + 1 end
    end
    return life, motion
end

-- A life packet the link refused (window full): its events are planned again on the next Plan, never lost.
function Host:Revert(key, packet)
    local p = self.peers[key]
    if not p or type(packet) ~= 'table' or packet.epoch ~= p.epoch or type(packet.events) ~= 'table' then return end
    for _, e in ipairs(packet.events) do
        local k = p.known[e.id]
        if e.kind == 's' then p.known[e.id] = nil
        elseif k and e.kind == 'd' then k.dead = false
        elseif k then k.damage = nil end
    end
end

-- {hz, bytesPerS, sent, skipped, sends, rttMs}: the last complete second.
function Host:Stats(key)
    local p = self.peers[key]
    if not p then return nil end
    local s = p.stats
    return { hz = p.rate:Hz(), bytesPerS = s.bytesPerS, sent = s.sent, skipped = s.skipped, sends = s.sends, rttMs = s.rttMs }
end

------------------------------------------------------------------ client
local Client = {}; Client.__index = Client; D.Client = Client
local position   -- defined below (the drawn path); Motion uses it for corrections
-- Test 15 rejoin stall (Coder B): life events are applied at most LIFE_EVENTS_PER_TICK per tick (between two Views);
-- the rest wait in arrival order and View applies them, so a crowded rejoin fills over several ticks.
D.LIFE_EVENTS_PER_TICK = 600
function Client.new()
    return setmetatable({ epoch = 0, enemies = {}, retired = {}, offset = nil, interval = 0.1, jitter = 0, lastArrival = nil,
        revision = 0, refused = 0, window = { start = nil, motions = 0 }, rxHz = 0, bySlot = {},
        lifeQueue = {}, lifeBudget = D.LIFE_EVENTS_PER_TICK }, Client)
end
local function lifetime(id) return type(id) == 'string' and #id <= 32 and id:match('^%d+:%d+$') ~= nil end
local function hpOf(s)
    if type(s) ~= 'string' or #s > 32 then return nil end
    local v = tonumber(s)
    if not finite(v, 1e12) or v < 0 then return nil end
    return v
end
function Client:_refuse() self.refused = self.refused + 1; return false end
function Client:_epoch(epoch)
    if math.type(epoch) ~= 'integer' or epoch < 1 or epoch > 2147483647 or epoch < self.epoch then return false end
    if epoch > self.epoch then
        self.epoch, self.enemies, self.retired, self.bySlot = epoch, {}, {}, {}
    end
    return true
end
local KINDS = { s = true, d = true, u = true }
function Client:Life(f, now)
    if type(f) ~= 'table' or type(f.events) ~= 'table' or #f.events > 512 then return self:_refuse() end
    -- validate the whole packet before applying any of it
    for _, e in ipairs(f.events) do
        if type(e) ~= 'table' or not KINDS[e.kind] or not lifetime(e.id) or math.type(e.slot) ~= 'integer'
            or math.type(e.enemyType) ~= 'integer' or e.enemyType < 0 or e.enemyType > 63
            or not finite(e.x, 2000000) or not finite(e.y, 2000000) or not hpOf(e.hp)
            or (e.damage ~= '' and not hpOf(e.damage)) then
            return self:_refuse()
        end
    end
    -- the epoch is checked against the newest one received (queued frames included); applied in order later
    local newest = self.lifeQueueEpoch or self.epoch
    if math.type(f.epoch) ~= 'integer' or f.epoch < 1 or f.epoch > 2147483647 or f.epoch < newest then return self:_refuse() end
    local queue = self.lifeQueue
    if #queue == 0 and #f.events <= self.lifeBudget then
        self.lifeBudget = self.lifeBudget - #f.events
        self:_applyLife(f, now)
        return true
    end
    queue[#queue + 1] = { f = f, now = now }
    self.lifeQueueEpoch = math.max(newest, f.epoch)
    return true
end
-- Applies the queued life frames that fit this tick's budget (in order), then opens the next tick's budget.
function Client:_drainLife()
    local queue = self.lifeQueue
    while #queue > 0 and #queue[1].f.events <= self.lifeBudget do
        local item = table.remove(queue, 1)
        self.lifeBudget = self.lifeBudget - #item.f.events
        self:_applyLife(item.f, item.now)
    end
    if #queue == 0 then self.lifeQueueEpoch = nil end
    self.lifeBudget = D.LIFE_EVENTS_PER_TICK
end
function Client:_applyLife(f, now)
    self:_epoch(f.epoch)
    for _, e in ipairs(f.events) do
        local enemy = self.enemies[e.id]
        if e.kind == 'd' then
            if enemy then
                if not enemy.dead then enemy.dead, enemy.deadAt, enemy.hp = true, now, 0 end
                if self.bySlot[enemy.slot] == e.id then self.bySlot[enemy.slot] = nil end
            else
                self.retired[e.id] = true
            end
        elseif e.kind == 's' then
            if not enemy and not self.retired[e.id] then
                self.enemies[e.id] = { id = e.id, slot = e.slot, enemyType = e.enemyType, hp = hpOf(e.hp),
                    damage = e.damage ~= '' and hpOf(e.damage) or nil, base = { x = e.x, y = e.y }, samples = {} }
                self.bySlot[e.slot] = e.id
            end
        elseif enemy and not enemy.dead then
            enemy.damage = e.damage ~= '' and hpOf(e.damage) or nil
            enemy.hp = hpOf(e.hp)
        end
    end
end
function Client:Motion(f, now)
    if type(f) ~= 'table' or math.type(f.t) ~= 'integer' or f.t < 0 then return self:_refuse() end
    if f.epoch ~= self.epoch then return self:_refuse() end
    local rows = D.DecodeRows(f.data)
    if not rows then return self:_refuse() end
    local heartbeat = #rows == 0
    local t = f.t / 1000
    -- clock offset (client time - host time): the smallest seen, drifting up slowly so a clock drift cannot pin it
    local sample = now - t
    if not self.offset or sample < self.offset then self.offset = sample
    else self.offset = self.offset + (sample - self.offset) * 0.02 end
    if self.lastArrival then
        local dt = now - self.lastArrival
        if dt > 0 then
            local dev = math.abs(dt - self.interval)
            self.interval = math.max(0.01, math.min(1, self.interval * 0.8 + dt * 0.2))
            self.jitter = self.jitter * 0.8 + dev * 0.2
        end
    end
    self.lastArrival = now
    self:_count(now)
    local applied = 0
    for _, row in ipairs(rows) do
        local id = self.bySlot[row.slot]
        local enemy = id and parityOf(id) == row.parity and self.enemies[id]
        if not enemy then
            -- lanes: motion (lane 3) can overtake its spawn (lane 2); refused as before, and counted
            self.unknownRows = (self.unknownRows or 0) + 1
        elseif not enemy.dead then
            local s = enemy.samples
            if #s == 0 or t > s[#s].t then
                -- the drawn position must not jump: the change this sample makes is faded out (D.BLEND)
                local rt = now - self.offset - self:RenderDelay()   -- test 15 (Coder C): the drawn time
                local ox, oy = self:_drawn(enemy, rt, now)
                s[#s + 1] = { t = t, x = row.x, y = row.y }
                if #s > D.SAMPLES then table.remove(s, 1) end
                applied = applied + 1
                if ox then
                    local nx, ny = position(enemy, rt, self.players)
                    local cx, cy = ox - nx, oy - ny
                    local d = math.sqrt(cx * cx + cy * cy)
                    self:_leadLearn(d)   -- test 15 (Coder C): adaptive lead
                    if d > D.SNAP then
                        self.snaps = (self.snaps or 0) + 1; cx, cy = 0, 0
                    end
                    enemy.corr = { x = cx, y = cy, at = now, span = math.max(D.BLEND + (D.PRESENT_LEAD and (self.leadApplied or 0) or 0), math.sqrt(cx * cx + cy * cy) / D.CORRECT_SPEED) }   -- test 15 (Coder C): a drawn-ahead correction fades over the lead too
                    self.window.corrSum, self.window.corrN = (self.window.corrSum or 0) + d, (self.window.corrN or 0) + 1
                end
            end
        end
    end
    if applied == 0 and not heartbeat then return self:_refuse() end
    return true
end
function Client:_count(now)
    local w = self.window
    if not w.start then w.start = now end
    w.motions = w.motions + 1
    if now - w.start >= 1 then
        self.rxHz = w.motions / (now - w.start)
        self.corrCm = (w.corrN or 0) > 0 and w.corrSum / w.corrN or 0
        self.window = { start = now, motions = 0 }
    end
end
-- The drawn position: the prediction plus the fading correction of the newest sample (nil before any sample).
function Client:_drawn(enemy, rt, now)
    if #enemy.samples == 0 then return nil end
    local x, y = position(enemy, rt, self.players)
    local c = enemy.corr
    if c then
        local fade = 1 - (now - c.at) / (c.span or D.BLEND)
        if fade > 0 then x, y = x + c.x * fade, y + c.y * fade else enemy.corr = nil end
    end
    return x, y
end
function Client:Delay()
    return math.max(D.MIN_DELAY, math.min(D.MAX_DELAY, self.interval + self.jitter))
end
-- Visual lag (test 15, Coder C): presentation only. Enemies are drawn LEAD ahead of the buffered time, about at the
-- host's present: the buffer (Delay) plus about one way of the link (LEAD_ONEWAY; test 15: RTT 100-180 ms), at most
-- LEAD_MAX. Past the newest sample the prediction above carries them and new samples fade in as before. Offline
-- model at test 15's link: ~136 -> ~88 ms behind for weaving chasers, ~125 -> ~34 ms for steady ones, with smaller
-- frame-to-frame jerk. The host stream and the rows it feeds stay as they are; PRESENT_LEAD = false is the old drawing.
D.PRESENT_LEAD, D.LEAD_ONEWAY, D.LEAD_MAX = true, 0.06, 0.15
-- Adaptive: the lead shrinks while the prediction proves wrong (corrections over LEAD_BAD cm: lossy link or erratic paths)
-- and grows back while it is right, so a bad link falls back towards the buffered drawing instead of jittering.
D.LEAD_BAD, D.LEAD_DOWN, D.LEAD_UP = 100, 0.15, 0.02
-- The drawn lead follows its target at most LEAD_SLEW seconds per second (a 10% time warp for a moment), never a jump.
D.LEAD_SLEW = 0.1
function Client:_leadTarget(delay)
    return math.min(D.LEAD_MAX, delay + D.LEAD_ONEWAY) * (self.leadK or 1)
end
function Client:RenderDelay()
    local delay = self:Delay()
    if not D.PRESENT_LEAD then return delay end
    return delay - (self.leadApplied or self:_leadTarget(delay))
end
-- once per View: move the drawn lead towards its target
function Client:_leadStep(now)
    local target = self:_leadTarget(self:Delay())
    local last = self.leadAt
    self.leadAt = now
    if not self.leadApplied or not last then self.leadApplied = target; return end
    local step = D.LEAD_SLEW * math.max(0, math.min(0.1, now - last))
    local a = self.leadApplied
    if target > a then a = math.min(target, a + step) else a = math.max(target, a - step) end
    self.leadApplied = a
end
function Client:_leadLearn(distance)
    local k = self.leadK or 1
    if distance > D.LEAD_BAD then k = math.max(0, k - D.LEAD_DOWN) else k = math.min(1, k + D.LEAD_UP) end
    self.leadK = k
end
local function wrap(a) while a > math.pi do a = a - 2 * math.pi end; while a < -math.pi do a = a + 2 * math.pi end; return a end
-- Past the newest sample: seek the nearest player, or keep the observed turn rate, then straight on (see D.PREDICT).
local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end
local function predict(s, ahead, players)
    local last, prev = s[#s], s[#s - 1]
    local dt = last.t - prev.t
    local vx, vy = (last.x - prev.x) / dt, (last.y - prev.y) / dt
    local speed = math.sqrt(vx * vx + vy * vy)
    if not D.PREDICT or speed < 1 then return last.x + vx * ahead, last.y + vy * ahead end
    local heading = math.atan(vy, vx)
    -- seeking weight: how squarely the enemy heads for the nearest player, faded out towards SEEK_RADIUS (no
    -- on/off flapping between frames)
    local target, seek = nil, 0
    if type(players) == 'table' then
        local best
        for _, p in ipairs(players) do
            if type(p) == 'table' and finite(p.x) and finite(p.y) then
                local d = (p.x - last.x) ^ 2 + (p.y - last.y) ^ 2
                if not best or d < best then best, target = d, p end
            end
        end
        if target then
            local dx, dy = target.x - last.x, target.y - last.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d >= 1 then
                local cos = (vx * dx + vy * dy) / (speed * d)
                seek = clamp01((cos - (D.SEEK_COS - 0.2)) / 0.2) * clamp01((D.SEEK_RADIUS - d) / 1000)
            end
        end
    end
    local omega = 0
    local older = s[#s - 2]
    if older and prev.t > older.t then
        local h0 = math.atan(prev.y - older.y, prev.x - older.x)
        omega = wrap(heading - h0) / ((last.t - older.t) / 2)
        omega = math.max(-D.TURN_MAX, math.min(D.TURN_MAX, omega)) * (1 - seek)
    end
    -- the observed turn is measured at the middle of the last interval: bring the heading up to the newest sample
    heading = heading + omega * dt / 2
    local x, y, left = last.x, last.y, ahead
    local turning = math.min(ahead, D.PREDICT_MAX)
    while turning > 1e-9 do
        local h = math.min(D.PREDICT_STEP, turning)
        heading = heading + omega * h / 2
        if seek > 0 then
            local dx, dy = target.x - x, target.y - y
            if dx * dx + dy * dy <= (speed * h) ^ 2 then return target.x, target.y end   -- reached the player
            heading = heading + seek * wrap(math.atan(dy, dx) - heading)
        end
        x, y = x + math.cos(heading) * speed * h, y + math.sin(heading) * speed * h
        heading = heading + omega * h / 2
        turning, left = turning - h, left - h
    end
    if left > 0 then x, y = x + math.cos(heading) * speed * left, y + math.sin(heading) * speed * left end
    return x, y
end
position = function(enemy, rt, players)
    local s = enemy.samples
    if #s == 0 or not rt then
        local last = s[#s] or enemy.base
        return last.x, last.y
    end
    if rt <= s[1].t then return s[1].x, s[1].y end
    for i = 1, #s - 1 do
        local a, b = s[i], s[i + 1]
        if rt <= b.t then
            local u = (rt - a.t) / (b.t - a.t)
            return a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u
        end
    end
    local last = s[#s]
    local prev = s[#s - 1]
    if not prev or last.t <= prev.t then return last.x, last.y end
    -- test 15 (Coder C): drawn ahead by up to LEAD_MAX, the keepalive-long extrapolation must reach that far too
    return predict(s, math.min(rt - last.t, D.EXTRAPOLATE_MAX + (D.PRESENT_LEAD and D.LEAD_MAX or 0)), players)
end
-- players: the positions the enemies may chase ({x, y} list; the newest is kept for the prediction).
function Client:View(now, players)
    self:_drainLife()   -- test 15 (Coder B): the queued life frames of a burst, within this tick's budget
    if type(players) == 'table' then self.players = players end
    if D.PRESENT_LEAD then self:_leadStep(now) end   -- test 15 (Coder C)
    local rt = self.offset and (now - self.offset - self:RenderDelay()) or nil   -- test 15 (Coder C): drawn ahead
    -- Test 14 (about 3850 live host enemies: 50 ms a tick): one row table per enemy, reused every view (consumers
    -- read it during the tick and copy what they keep); the order changes only when the set of enemies changed.
    local drop = {}
    local order, set = self.viewOrder, self.viewSet
    local n, changed = 0, order == nil
    for id, e in pairs(self.enemies) do
        if e.dead and now - e.deadAt > D.DEAD_KEEP then
            drop[#drop + 1] = id
        else
            n = n + 1
            if not changed and not set[id] then changed = true end
        end
    end
    for _, id in ipairs(drop) do
        local e = self.enemies[id]
        if e and self.bySlot[e.slot] == id then self.bySlot[e.slot] = nil end
        self.enemies[id] = nil; self.retired[id] = true
    end
    if changed or n ~= #order then
        -- Coder B (test 15 rejoin): a burst fills over several ticks, so the order is kept and only extended: the ids
        -- still present keep their place, the new ones are appended in id order (no full sort of every id each tick)
        local kept, keptSet, fresh = {}, {}, {}
        for _, id in ipairs(order or {}) do
            if self.enemies[id] then kept[#kept + 1] = id; keptSet[id] = true end
        end
        for id in pairs(self.enemies) do if not keptSet[id] then fresh[#fresh + 1] = id end end
        table.sort(fresh)
        for _, id in ipairs(fresh) do kept[#kept + 1] = id; keptSet[id] = true end
        order, set = kept, keptSet
        self.viewOrder, self.viewSet = order, set
    end
    local rows = {}
    for i, id in ipairs(order) do
        local e = self.enemies[id]
        local x, y
        if rt then x, y = self:_drawn(e, rt, now) end
        if not x then x, y = position(e, rt, self.players) end
        local row = e.view
        if not row then row = { id = id, z = 0 }; e.view = row end
        row.epoch, row.slot, row.enemyType, row.x, row.y = self.epoch, e.slot, e.enemyType, x, y
        row.hp, row.dead, row.damage = e.hp or 0, e.dead == true, e.damage
        rows[i] = row
    end
    self.revision = self.revision + 1
    return { epoch = self.epoch, revision = self.revision, enemies = rows }
end
function Client:Stats()
    local n, alive = 0, 0
    for _, e in pairs(self.enemies) do n = n + 1; if not e.dead then alive = alive + 1 end end
    -- test 15 (Coder C): delayMs is the delay really drawn behind the newest sample (negative = drawn ahead)
    local queued = 0   -- Coder B: life events waiting for a tick
    for _, item in ipairs(self.lifeQueue) do queued = queued + #item.f.events end
    return { rxHz = self.rxHz, delayMs = math.floor(self:RenderDelay() * 1000 + 0.5), enemies = n, alive = alive, refused = self.refused, queued = queued,
        unknownRows = self.unknownRows or 0, corrCm = self.corrCm or 0, snaps = self.snaps or 0 }
end

return D
