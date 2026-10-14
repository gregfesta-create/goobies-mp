-- GoobiesMP M3.1 "presence in the world": PURE LOGIC. No Unreal references, no UE4SS globals, no file or network access.
-- It talks to the game only through an injected `world` object (see gmp_world.lua) and to the session only through Host/Client methods.
-- Nothing here runs at require time: requiring this module defines tables and functions and does nothing else.
--
-- What it carries (VS-1 / D2: PROVISIONAL, each process reports its own pawn; final movement authority is OPEN):
--   PLAYER_STATE  client -> host  unreliable   seg x y z dead        (integer centimetres; no key: the host uses the peer's bound key)
--   WORLD_STATE   host -> client  unreliable   list of {key seg x y z dead age}   (everyone except the receiver; age in ms at the host)
--
-- APPROXIMATE: until a shared world exists (M5) the two games have DIFFERENT islands. A remote player's marker is therefore drawn at
--   anchor + (remote - remoteOrigin) + (400, 0): RELATIVE MOTION ONLY, anchored where the local player stood when the remote appeared.
--   It is not a world position. The 400 is the POC's display offset (so the marker does not overlap the local pawn), not a calibration.
--
-- Safety properties (each has tests in test_presence*.lua):
--   * identity comes from the host's peer binding; PLAYER_STATE has no key field and a client cannot place another player
--   * a message is validated COMPLETELY into temporaries and only then committed: a rejected or malformed message never alters stored state
--   * one record per roster key (host) / per remote key (client), hard-capped; `seg` is a plain field and never creates state
--   * records expire; disconnected or unknown keys are never retained or broadcast
--   * WORLD_STATE is built against a byte budget measured with the real codec at a worst-case header, so an oversized packet is never sent
local Codec = require("gmp_codec")
local Visual = require("gmp_presentation")

local P = {}

P.LIMITS = {
    XY = 2000000,            -- |x|,|y| <= 20 km in cm (POC values were ~6000)
    Z = 100000,              -- |z| <= 1 km in cm (observed 0)
    SEG_MAX = 1000000,       -- seg is in 0..SEG_MAX; the sender wraps to 1
    MAX_REMOTES = 64,        -- hard cap on tracked remote players (= Config.MAX_PLAYERS_LIMIT)
    MAX_SPEED = 20000,       -- cm/s; a larger jump is COUNTED (teleport_suspect), never rejected
    AGE_MAX = 60000,         -- ms; larger ages are malformed
    KEY_MAX = 64,
    BURST = 15,              -- token-bucket capacity per peer (half a second at 30 Hz: a hitch burst; test 7)
    MARKER_OFFSET_X = 400,   -- POC display offset (not a calibration)
    FAIL_LATCH = 3,          -- consecutive world failures before a world operation is latched off
    PACKET_HARD = 1380,      -- relay transport MAX_PACKET
}
local L = P.LIMITS

function P.Defaults()
    return { enabled = false, read = true, markers = false, hz = 30, stale = 1.0, expire = 3.0, maxPacket = 1340, selfEcho = false, worldSpace = false, smooth = false, animation = false, appearance = false }
end

local function bool(v)
    if v == "1" or v == "true" then return true elseif v == "0" or v == "false" then return false end
    return nil
end

-- gmp_config.txt keys: PRESENCE, PRESENCE_READ, PRESENCE_MARKERS, PRESENCE_HZ, PRESENCE_STALE, PRESENCE_EXPIRE, PRESENCE_MAX_PACKET, PRESENCE_SELF_ECHO.
-- Bad values keep the default and are reported. Unknown keys are ignored (the session config ignores these keys the same way).
function P.ParseConfig(text)
    local c, errs = P.Defaults(), {}
    for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local k, v = line:match("^(PRESENCE[%w_]*)%s*=%s*(.-)$")
        if k then
            local n = tonumber(v)
            if k == "PRESENCE" or k == "PRESENCE_READ" or k == "PRESENCE_MARKERS" or k == "PRESENCE_SELF_ECHO" or k == "PRESENCE_WORLD_SPACE" or k == "PRESENCE_SMOOTH" or k == "PRESENCE_ANIMATION" or k == "PRESENCE_APPEARANCE" then
                local b = bool(v)
                local field = ({ PRESENCE = "enabled", PRESENCE_READ = "read", PRESENCE_MARKERS = "markers", PRESENCE_SELF_ECHO = "selfEcho", PRESENCE_WORLD_SPACE = "worldSpace", PRESENCE_SMOOTH = "smooth", PRESENCE_ANIMATION = "animation", PRESENCE_APPEARANCE = "appearance" })[k]
                if b == nil then errs[#errs + 1] = "bad " .. k else c[field] = b end
            elseif k == "PRESENCE_HZ" then
                if n then c.hz = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "PRESENCE_STALE" then
                if n then c.stale = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "PRESENCE_EXPIRE" then
                if n then c.expire = n else errs[#errs + 1] = "bad " .. k end
            elseif k == "PRESENCE_MAX_PACKET" then
                if n and n == math.floor(n) then c.maxPacket = math.floor(n) else errs[#errs + 1] = "bad " .. k end
            end
        end
    end
    return c, errs
end

-- Returns ok, errors[]. A config that fails validation is NOT used (presence stays off).
function P.Validate(c)
    local errs = {}
    if type(c) ~= "table" then return false, { "presence config missing" } end
    if type(c.hz) ~= "number" or c.hz < 1 or c.hz > 30 then errs[#errs + 1] = "PRESENCE_HZ must be 1..30" end   -- the adaptive rate's maximum
    if type(c.stale) ~= "number" or c.stale < 0.2 or c.stale > 30 then errs[#errs + 1] = "PRESENCE_STALE must be 0.2..30 seconds" end
    if type(c.expire) ~= "number" or c.expire < 0.5 or c.expire > 120 then errs[#errs + 1] = "PRESENCE_EXPIRE must be 0.5..120 seconds" end
    if type(c.stale) == "number" and type(c.expire) == "number" and c.expire < c.stale then errs[#errs + 1] = "PRESENCE_EXPIRE must be >= PRESENCE_STALE" end
    if type(c.maxPacket) ~= "number" or c.maxPacket < 200 or c.maxPacket > L.PACKET_HARD or c.maxPacket > Codec.MAX_PACKET then
        errs[#errs + 1] = "PRESENCE_MAX_PACKET must be 200.." .. L.PACKET_HARD
    end
    if c.appearance and not c.animation then errs[#errs+1]="PRESENCE_APPEARANCE requires PRESENCE_ANIMATION" end
    if c.markers and not c.read then errs[#errs + 1] = "PRESENCE_MARKERS requires PRESENCE_READ" end
    if c.selfEcho and not c.markers then errs[#errs + 1] = "PRESENCE_SELF_ECHO requires PRESENCE_MARKERS" end
    return #errs == 0, errs
end

------------------------------------------------------------------ numbers
-- Half away from zero to a Lua integer, or nil for anything that is not a finite number below 2^53.
function P.Round(v)
    local t = math.type(v)
    if t == "integer" then return v end
    if t ~= "float" then return nil end
    if v ~= v or v == math.huge or v == -math.huge or math.abs(v) >= 2 ^ 53 then return nil end
    local r = (v >= 0) and math.floor(v + 0.5) or -math.floor(-v + 0.5)
    return math.tointeger(r)
end

-- Validate an already-integer state (wire or local). Returns ok, reason.
function P.CheckState(s)
    if type(s) ~= "table" then return false, "bad_type" end
    for _, k in ipairs({ "seg", "x", "y", "z" }) do
        if math.type(s[k]) ~= "integer" then return false, "bad_type" end
    end
    if s.pose~=nil and not Visual.valid(s.pose) then return false,"bad_pose" end
    if type(s.dead) ~= "boolean" then return false, "bad_type" end
    if s.seg < 0 or s.seg > L.SEG_MAX then return false, "bad_range" end
    if math.abs(s.x) > L.XY or math.abs(s.y) > L.XY or math.abs(s.z) > L.Z then return false, "bad_range" end
    return true
end

-- raw world reading {x,y,z (floats/ints), dead} -> integer-centimetre state (without seg), or nil, reason
function P.ToState(raw)
    if type(raw) ~= "table" then return nil, "bad_type" end
    local x, y, z = P.Round(raw.x), P.Round(raw.y), P.Round(raw.z)
    if not (x and y and z) then return nil, "bad_value" end
    if math.abs(x) > L.XY or math.abs(y) > L.XY or math.abs(z) > L.Z then return nil, "bad_range" end
    return { x = x, y = y, z = z, dead = raw.dead == true, pose = Visual.pack(raw.pose) }
end

local function validKey(k) return type(k) == "string" and #k >= 3 and #k <= L.KEY_MAX and k:match("^%a+:[%w_%-]+$") ~= nil end

------------------------------------------------------------------ host side
local HostPresence = {}
HostPresence.__index = HostPresence
P.HostPresence = HostPresence

-- opts: cfg (presence config), roster (gmp_roster: Get(key) -> {conn, slot}), log(fmt, ...)
function HostPresence.new(opts)
    return setmetatable({ cfg = opts.cfg, roster = opts.roster, log = opts.log or function() end,
        entries = {}, bucket = {}, cursor = {}, gen = 0,
        stats = { accepted = 0, rejected = 0, reasons = {}, teleport_suspect = 0, truncated = 0, unfit = 0, broadcasts = 0, records_sent = 0 } }, HostPresence)
end

function HostPresence:_connected(key)
    local r = self.roster:Get(key)
    return r ~= nil and r.conn == "connected"
end

function HostPresence:_reject(reason)
    local s = self.stats
    s.rejected = s.rejected + 1
    s.reasons[reason] = (s.reasons[reason] or 0) + 1
    return false, reason
end

function HostPresence:_commit(key, f, now)
    local e = self.entries[key]
    if not e then
        self.gen = self.gen + 1
        e = { gen = self.gen }
        self.entries[key] = e
    elseif e.seg ~= f.seg then
        self.gen = self.gen + 1
        e.gen = self.gen
    end
    e.pose=Visual.copy(f.pose)
    e.seg, e.x, e.y, e.z, e.dead, e.at = f.seg, f.x, f.y, f.z, f.dead, now
end

-- A PLAYER_STATE from the peer bound to `key`. Order: connected check, rate, validation, then ONE commit.
function HostPresence:OnState(key, f, now)
    if not validKey(key) or not self:_connected(key) then return self:_reject("not_connected") end
    local b = self.bucket[key]
    if not b then b = { tokens = L.BURST, last = now }; self.bucket[key] = b end
    local dt = now - b.last
    if dt < 0 then dt = 0 end
    b.tokens = math.min(L.BURST, b.tokens + dt * 2 * self.cfg.hz)
    b.last = now
    if b.tokens < 1 then return self:_reject("rate") end
    b.tokens = b.tokens - 1
    local ok, why = P.CheckState(f)
    if not ok then return self:_reject(why) end
    local prev = self.entries[key]
    if prev and prev.seg == f.seg then
        local d = math.max(now - prev.at, 0.05)
        local dx, dy = f.x - prev.x, f.y - prev.y
        if dx * dx + dy * dy > (L.MAX_SPEED * d) ^ 2 then self.stats.teleport_suspect = self.stats.teleport_suspect + 1 end
    end
    self:_commit(key, f, now)
    self.stats.accepted = self.stats.accepted + 1
    return true
end

-- The host's own pawn state (already integer; no rate limit, but the same validation).
function HostPresence:SetLocal(key, s, now)
    if not self:_connected(key) then return false, "not_connected" end
    local ok, why = P.CheckState(s)
    if not ok then return false, why end
    self:_commit(key, s, now)
    return true
end

function HostPresence:Remove(key)
    self.entries[key], self.bucket[key], self.cursor[key] = nil, nil, nil
end

-- CR (S4): drop every record at once (run or island change); the next SetLocal/OnState starts fresh.
function HostPresence:Clear()
    self.entries, self.bucket, self.cursor = {}, {}, {}
end

function HostPresence:Prune(now)
    local drop = {}
    for key, e in pairs(self.entries) do
        if now - e.at > self.cfg.expire or not self:_connected(key) then drop[#drop + 1] = key end
    end
    for key in pairs(self.bucket) do if not self:_connected(key) then drop[#drop + 1] = key end end
    for key in pairs(self.cursor) do if not self:_connected(key) then drop[#drop + 1] = key end end
    for _, key in ipairs(drop) do self:Remove(key) end
end

function HostPresence:Count() local n = 0 for _ in pairs(self.entries) do n = n + 1 end return n end

-- Visible = connected and fresher than `stale`. Sorted by slot then key (deterministic). `exclude` omits one key.
function HostPresence:Visible(now, exclude)
    local out = {}
    for key, e in pairs(self.entries) do
        if key ~= exclude and now - e.at <= self.cfg.stale then
            local r = self.roster:Get(key)
            if r and r.conn == "connected" then
                out[#out + 1] = { key = key, slot = r.slot or 0, seg = e.seg, x = e.x, y = e.y, z = e.z, dead = e.dead, gen = e.gen, at = e.at, pose=Visual.copy(e.pose) }
            end
        end
    end
    table.sort(out, function(a, b) if a.slot ~= b.slot then return a.slot < b.slot end return a.key < b.key end)
    return out
end

-- Worst-case header: 10-digit epoch, 12-digit sequence/ack, 9-character session id. Real packets can only be shorter.
local function probe(players, sid, animation, appearance)
    local s = Codec.Encode({ type = appearance and "WORLD_AVATAR_STATE" or animation and "WORLD_STATE_VISUAL" or "WORLD_STATE", ch = "U", ep = 2147483646, seq = 999999999999, ack = 999999999999, sid = sid or "Sffffffff", f = { players = players } })
    return s and #s or nil
end
P._probe = probe

local function wireRecord(e, now, animation, appearance)
    local age = math.floor((now - e.at) * 1000)
    if age < 0 then age = 0 elseif age > L.AGE_MAX then age = L.AGE_MAX end
    local r={ key = e.key, seg = e.seg, x = e.x, y = e.y, z = e.z, dead = e.dead, age = age }
    if animation then local p=e.pose or {pitch=0,yaw=0,roll=0,motion=0}; for k,v in pairs(p) do r[k]=v end end
    if appearance then r.model=r.model or 0 end
    return r
end

-- receivers: array of keys. Returns map key -> array of wire records, each list guaranteed to fit `cfg.maxPacket` bytes (worst-case header).
-- When not everything fits, the list is cut and the cursor rotates so that every player is served over successive broadcasts.
function HostPresence:Plan(now, receivers, sid)
    local elig = self:Visible(now)
    local plan = {}
    self.lastBytes = {}      -- receiver key -> bytes of its planned WORLD_STATE (worst-case header; the rate budget)
    local base = probe({}, sid, self.cfg.animation, self.cfg.appearance)
    local lens = {}
    for _, e in ipairs(elig) do
        local one = probe({ wireRecord(e, now, self.cfg.animation, self.cfg.appearance) }, sid, self.cfg.animation, self.cfg.appearance)
        lens[e.key] = (one and base) and (one - base) or nil
    end
    for _, r in ipairs(receivers) do
        local cand = {}
        for _, e in ipairs(elig) do if e.key ~= r and lens[e.key] then cand[#cand + 1] = e end end
        local n, out = #cand, {}
        plan[r] = out
        if n > 0 and base then
            local start = (self.cursor[r] or 0) % n
            local total, used = base, 0
            for i = 0, n - 1 do
                local c = cand[(start + i) % n + 1]
                local add = lens[c.key] + (used > 0 and 1 or 0)
                if total + add > self.cfg.maxPacket then break end
                total = total + add
                used = used + 1
                out[used] = wireRecord(c, now, self.cfg.animation, self.cfg.appearance)
            end
            if used == 0 then
                self.stats.unfit = self.stats.unfit + 1
                self.cursor[r] = (start + 1) % n
            else
                self.cursor[r] = (start + used) % n
                self.lastBytes[r] = total
                if used < n then self.stats.truncated = self.stats.truncated + 1 end
                self.stats.records_sent = self.stats.records_sent + used
            end
        end
    end
    self.stats.broadcasts = self.stats.broadcasts + 1
    return plan
end

------------------------------------------------------------------ client side
local ClientPresence = {}
ClientPresence.__index = ClientPresence
P.ClientPresence = ClientPresence

-- opts: cfg, selfKey() -> own identity key (own record is ignored), log
function ClientPresence.new(opts)
    return setmetatable({ cfg = opts.cfg, selfKey = opts.selfKey or function() return nil end, log = opts.log or function() end,
        entries = {}, count = 0, gen = 0,
        stats = { applied = 0, rejected = 0, reasons = {} } }, ClientPresence)
end

function ClientPresence:_reject(reason)
    local s = self.stats
    s.rejected = s.rejected + 1
    s.reasons[reason] = (s.reasons[reason] or 0) + 1
    return false, reason
end

-- f = decoded WORLD_STATE fields. Whole-message validation first; nothing is stored unless every record is valid.
function ClientPresence:Apply(f, now)
    local list = type(f) == "table" and f.players or nil
    if type(list) ~= "table" then return self:_reject("bad_list") end
    if #list > L.MAX_REMOTES then return self:_reject("too_many") end
    local seen, parsed, me = {}, {}, self.selfKey()
    for _, r in ipairs(list) do
        if type(r) ~= "table" or not validKey(r.key) then return self:_reject("bad_key") end
        if seen[r.key] then return self:_reject("duplicate_key") end
        seen[r.key] = true
        if r.pitch~=nil then
            if not Visual.valid(r) then return self:_reject("bad_pose") end
        end
        local ok, why = P.CheckState(r)
        if not ok then return self:_reject(why) end
        if math.type(r.age) ~= "integer" or r.age < 0 or r.age > L.AGE_MAX then return self:_reject("bad_age") end
        if r.key ~= me then parsed[#parsed + 1] = r end
    end
    local fresh = 0
    for _, r in ipairs(parsed) do if not self.entries[r.key] then fresh = fresh + 1 end end
    if self.count + fresh > L.MAX_REMOTES then return self:_reject("capacity") end
    for _, r in ipairs(parsed) do
        local e = self.entries[r.key]
        if not e then
            self.gen = self.gen + 1
            e = { gen = self.gen }
            self.entries[r.key] = e
            self.count = self.count + 1
        elseif e.seg ~= r.seg then
            self.gen = self.gen + 1
            e.gen = self.gen
        end
        e.pose=Visual.copy(r)
        e.seg, e.x, e.y, e.z, e.dead, e.at = r.seg, r.x, r.y, r.z, r.dead, now - r.age / 1000
    end
    self.stats.applied = self.stats.applied + 1
    return true
end

function ClientPresence:Prune(now)
    local drop = {}
    for key, e in pairs(self.entries) do if now - e.at > self.cfg.expire then drop[#drop + 1] = key end end
    for _, key in ipairs(drop) do self.entries[key] = nil; self.count = self.count - 1 end
end

function ClientPresence:Clear() self.entries, self.count = {}, 0 end

function ClientPresence:Visible(now)
    local out = {}
    for key, e in pairs(self.entries) do
        if now - e.at <= self.cfg.stale then out[#out + 1] = { key = key, seg = e.seg, x = e.x, y = e.y, z = e.z, dead = e.dead, gen = e.gen, at = e.at, pose=Visual.copy(e.pose) } end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

------------------------------------------------------------------ approximate marker placement
local Mapper = {}
Mapper.__index = Mapper
P.Mapper = Mapper

function Mapper.new(opts) return setmetatable({ anchors = {}, offsetX = (opts and opts.offsetX) or L.MARKER_OFFSET_X, worldSpace = opts and opts.worldSpace == true }, Mapper) end

-- remotes: visible list (with gen); lp: local pawn state or nil. Returns markers {key,x,y,z,dead,approx=true}.
-- The anchor (local position + remote origin) is captured when a remote appears or its `gen` changes (new seg / reappearance).
function Mapper:Update(remotes, lp)
    if not lp then return {} end
    -- Explicit development mode for independently started, matching-seed runs.
    -- The caller must ensure a shared coordinate system; no automatic seed sync.
    if self.worldSpace then
        local out = {}
        self.anchors = {}
        for _, r in ipairs(remotes) do
            out[#out + 1] = { key = r.key, x = r.x, y = r.y, z = r.z, dead = r.dead, approx = false, gen = r.gen, at = r.at, pose=Visual.copy(r.pose) }
        end
        return out
    end
    local out, live = {}, {}
    for _, r in ipairs(remotes) do
        live[r.key] = true
        local a = self.anchors[r.key]
        if not a or a.gen ~= r.gen then
            a = { gen = r.gen, ox = r.x, oy = r.y, ax = lp.x, ay = lp.y, az = lp.z }
            self.anchors[r.key] = a
        end
        out[#out + 1] = { key = r.key, x = a.ax + (r.x - a.ox) + self.offsetX, y = a.ay + (r.y - a.oy), z = a.az, dead = r.dead, approx = true, gen = r.gen, at = r.at, pose=Visual.copy(r.pose) }
    end
    for key in pairs(self.anchors) do if not live[key] then self.anchors[key] = nil end end
    return out
end

-- Display-only smoothing; never modifies network state.
-- Untimed markers (no `at`): interpolation over `period` to the latest received target, never beyond it.
-- Timed markers (`at` = when the sample was taken, on this side's clock; R1 attempt 4, the remote looked delayed):
--   * the target is the newest sample extrapolated along its measured velocity for the sample's age, capped at
--     EXTRAPOLATE_MAX, so the marker tracks the live position instead of trailing it by a send interval;
--   * a new sample does not jump: the difference between what was shown and the new target is an offset that decays
--     to zero over a buffer that follows the measured arrival interval and its jitter (1.5 intervals + 2 deviations,
--     BUFFER_MIN..BUFFER_MAX), so jittery links stay smooth while steady motion is tracked without lag.
-- New generations and large teleports snap.
local Smoother = {}
Smoother.__index = Smoother
P.Smoother = Smoother
Smoother.EXTRAPOLATE_MAX = 0.15
Smoother.BUFFER_MIN, Smoother.BUFFER_MAX = 0.03, 0.25
Smoother.SNAP = 1200
-- VELOCITY_GAIN: arrival times are receive times on the host (frame hitches add jitter), so each raw velocity is
-- blended in rather than taken whole (test 7: "jumping" at 10 Hz). snaps counts teleports/new generations shown at once.
Smoother.VELOCITY_GAIN = 0.5
function Smoother.new(period) return setmetatable({entries={},period=period,snaps=0}, Smoother) end
-- Remote players' lead (test 15 follow-up, Coder C): presentation only. A sample's `at` covers only the host's holding
-- time, not the network legs (sender -> host on the host; that plus host -> this client on a client), so a moving
-- remote player was drawn about one or two legs behind (~110 ms on a client at test 15's RTT). Each timed marker is
-- extrapolated `legs x oneWay` further (SetLead: oneWay = RTT / 2 from the driver's link monitor; legs(key) = 1 on the
-- host and for the host player, 2 for another client), at most LEAD_MAX. Adaptive: the lead shrinks while a new sample
-- lands more than LEAD_BAD cm from what was drawn and grows back while it lands close; the drawn lead follows its target
-- at most LEAD_SLEW s per s (no jump). Smoother.LEAD = false is the old drawing.
Smoother.LEAD, Smoother.LEAD_MAX, Smoother.LEAD_GAIN = true, 0.08, 0.3
Smoother.LEAD_BAD, Smoother.LEAD_DOWN, Smoother.LEAD_UP, Smoother.LEAD_SLEW = 80, 0.15, 0.02, 0.1
function Smoother:SetLead(oneWay, legs) self.leadOneWay, self.leadLegs = oneWay, legs end
function Smoother:LeadFor(key)
    local w = self.leadOneWay
    if not Smoother.LEAD or type(w) ~= 'number' or w ~= w or w <= 0 then return 0 end
    local ok, legs = true, 1
    if type(self.leadLegs) == 'function' then ok, legs = pcall(self.leadLegs, key) end
    if not ok or type(legs) ~= 'number' or legs ~= legs or legs < 0 then legs = 1 end
    return math.min(Smoother.LEAD_MAX, w * legs) * (self.leadK or 1)
end
function Smoother:_leadLearn(off)
    local k = self.leadK or 1
    if off > Smoother.LEAD_BAD then k = math.max(0, k - Smoother.LEAD_DOWN) else k = math.min(1, k + Smoother.LEAD_UP) end
    self.leadK = k
end
function Smoother:Buffer(e)
    if not e.timed then return self.period end
    return math.max(Smoother.BUFFER_MIN, math.min(Smoother.BUFFER_MAX, 1.5 * e.interval + 2 * e.dev))
end
local function progress(self,e,now) return math.max(0,math.min(1,(now-e.cstart)/self:Buffer(e))) end
local function target(e,now)
    if not e.timed then return e.x,e.y,e.z end
    local h=math.max(0,math.min(Smoother.EXTRAPOLATE_MAX,now-e.at))
    -- test 15 (Coder C): + the lead, along a steadier velocity (LEAD_GAIN): the lead must not magnify arrival jitter
    local l=e.lead or 0
    return e.x+e.vx*h+(e.lvx or e.vx)*l,e.y+e.vy*h+(e.lvy or e.vy)*l,e.z+e.vz*h+(e.lvz or e.vz)*l
end
local function sample(self,e,now)
    local k=1-progress(self,e,now)
    local tx,ty,tz=target(e,now)
    return tx+e.ox*k,ty+e.oy*k,tz+e.oz*k
end
local function posed(a,b)
    return (a~=nil and b==nil) or (b and (not a or b.yaw~=a.yaw or b.roll~=a.roll or b.pitch~=a.pitch or b.motion~=a.motion or b.model~=a.model))
end
function Smoother:Update(markers,now)
    local out,live={},{}
    for _,m in ipairs(markers) do
        live[m.key]=true
        local e=self.entries[m.key]
        local timed=type(m.at)=='number'
        if not e or e.gen~=m.gen or e.timed~=timed or (m.x-e.x)^2+(m.y-e.y)^2+(m.z-e.z)^2>Smoother.SNAP^2 then
            if e then self.snaps=self.snaps+1 end
            e={ox=0,oy=0,oz=0,x=m.x,y=m.y,z=m.z,vx=0,vy=0,vz=0,gen=m.gen,timed=timed,at=timed and m.at or now,
                arrived=now,cstart=now-1,interval=self.period,dev=0,pose=Visual.copy(m.pose),startPose=Visual.copy(m.pose),
                lead=timed and self:LeadFor(m.key) or 0,leadAt=now}   -- test 15 (Coder C)
            self.entries[m.key]=e
        elseif (timed and m.at~=e.at) or (not timed and (e.x~=m.x or e.y~=m.y or e.z~=m.z or posed(e.pose,m.pose))) then
            e.startPose=Visual.blend(e.startPose,e.pose,progress(self,e,now))
            e.pose=Visual.copy(m.pose)
            local sx,sy,sz=sample(self,e,now)
            if timed then
                local dt=m.at-e.at
                if dt>0.005 and dt<0.5 then
                    local vx,vy,vz=(m.x-e.x)/dt,(m.y-e.y)/dt,(m.z-e.z)/dt
                    local speed=math.sqrt(vx*vx+vy*vy+vz*vz)
                    local k=speed>L.MAX_SPEED and L.MAX_SPEED/speed or 1
                    local g=speed==0 and 1 or Smoother.VELOCITY_GAIN   -- a stop stops at once
                    e.vx,e.vy,e.vz=e.vx+(vx*k-e.vx)*g,e.vy+(vy*k-e.vy)*g,e.vz+(vz*k-e.vz)*g
                    local lg=speed==0 and 1 or Smoother.LEAD_GAIN   -- test 15 (Coder C)
                    e.lvx,e.lvy,e.lvz=(e.lvx or e.vx)+(vx*k-(e.lvx or e.vx))*lg,(e.lvy or e.vy)+(vy*k-(e.lvy or e.vy))*lg,(e.lvz or e.vz)+(vz*k-(e.lvz or e.vz))*lg
                elseif dt>=0.5 then e.vx,e.vy,e.vz=0,0,0 end
                local ia=now-e.arrived
                if ia>0 and ia<1 then
                    e.dev=e.dev+(math.abs(ia-e.interval)-e.dev)*0.25
                    e.interval=e.interval+(ia-e.interval)*0.125
                end
                e.at=m.at
            end
            e.arrived,e.cstart=now,now
            e.x,e.y,e.z=m.x,m.y,m.z
            local tx,ty,tz=target(e,now)
            e.ox,e.oy,e.oz=sx-tx,sy-ty,sz-tz
            -- test 15 (Coder C): how far the new sample landed from what was drawn teaches the lead
            if timed and Smoother.LEAD and self.leadOneWay then self:_leadLearn(math.sqrt(e.ox*e.ox+e.oy*e.oy)) end
        end
        if timed then   -- test 15 (Coder C): the drawn lead follows its target, slewed
            local want=self:LeadFor(m.key);local step=Smoother.LEAD_SLEW*math.max(0,math.min(0.1,now-(e.leadAt or now)))
            local a=e.lead or 0
            if want>a then a=math.min(want,a+step) else a=math.max(want,a-step) end
            e.lead,e.leadAt=a,now
        end
        local x,y,z=sample(self,e,now)
        out[#out+1]={key=m.key,x=x,y=y,z=z,dead=m.dead,approx=m.approx,gen=m.gen,pose=Visual.blend(e.startPose,e.pose,progress(self,e,now))}
    end
    for key in pairs(self.entries) do if not live[key] then self.entries[key]=nil end end
    return out
end
-- The widest current buffer (seconds), for the rate log.
function Smoother:MaxBuffer()
    local b=0
    for _,e in pairs(self.entries) do b=math.max(b,self:Buffer(e)) end
    return b
end

------------------------------------------------------------------ adaptive send rate (local and relayed Steam P2P)
-- Rate: one send rate per side (the host's broadcast serves every peer at the same rate, so the worst peer decides).
-- The decision is Coder B's link-baseline rule (gmp_enemy_delta.lua Rate, reused, not copied): slow = RTT more than
-- RTT_RISE above the link's own lowest RTT (rising slowly), or loss or backlog; calm for GOOD_SECONDS -> one level up.
-- Test 7: an absolute 250 ms threshold held presence at 10 Hz on a steady ~240 ms link. Evaluated once a second;
-- then capped so the busiest peer stays within BUDGET bytes a second (packets + OVERHEAD per packet).
local Delta = require('gmp_enemy_delta')
local Lanes = require('gmp_lanes')
local Rate = {}
Rate.__index = Rate
P.Rate = Rate
Rate.LEVELS = Delta.LADDER
Rate.BUDGET = 5000           -- bytes per second per peer (well under 8 KB/s)
Rate.OVERHEAD = 40           -- per packet: link and transport headers, estimated
-- Resends in a second: once the RTT passes the resend interval no clean sample exists (Karn), so repeated resends
-- count as a backed-up reliable channel (backlog) for the shared rule.
Rate.RESENT_HIGH = 3
function Rate.new(maxHz, now)
    local inner = Delta.Rate.new(maxHz)
    return setmetatable({ inner = inner, windowStart = now or 0, peers = {}, status = { hz = inner:Hz(), bytesPerS = 0 } }, Rate)
end
function Rate:Hz() return self.inner:Hz() end
function Rate:Start(now) self.windowStart, self.peers = now, {} end
-- One packet of `bytes` (with overhead) sent to `peer`.
function Rate:Sent(peer, bytes, now)
    local p = self.peers[peer]
    if not p then p = { bytes = 0, packets = 0 }; self.peers[peer] = p end
    p.bytes, p.packets = p.bytes + bytes, p.packets + 1
end
function Rate:Due(now) return now - self.windowStart >= 1 end
-- q = { rtt = seconds | nil, loss = 0..1 | nil, backlog = n }. Evaluates once a second; returns true then.
function Rate:Evaluate(now, q)
    if not self:Due(now) then return false end
    q = q or {}
    local window = math.max(1, now - self.windowStart)
    local busiest
    for _, p in pairs(self.peers) do if not busiest or p.bytes > busiest.bytes then busiest = p end end
    self.windowStart, self.peers = now, {}
    local inner = self.inner
    inner.last = -math.huge          -- this Rate keeps the once-a-second window
    local backlog = q.backlog or 0
    if (q.resent or 0) >= Rate.RESENT_HIGH then backlog = math.max(backlog, Delta.BACKLOG_HIGH + 1) end
    inner:Evaluate(now, { rtt = q.rtt, loss = q.loss, lossU = q.lossU, backlog = backlog })
    if busiest and busiest.packets > 0 then
        local budgetHz = Rate.BUDGET / (busiest.bytes / busiest.packets)
        while inner.level < #Delta.LADDER and Delta.LADDER[inner.level] > budgetHz do inner.level = inner.level + 1 end
    end
    self.status = { hz = self:Hz(), bytesPerS = busiest and math.floor(busiest.bytes / window + 0.5) or 0, rtt = q.rtt,
        base = inner.base, loss = q.loss, lossU = q.lossU, backlog = q.backlog or 0 }
    return true
end
function Rate:Status() return self.status end

-- LinkMonitor: link quality read from the session's gmp_link objects (the transports expose none; Steam neither).
--   RTT: a reliable message sent once and then released by the peer's cumulative ack (Karn: resent ones never count).
--        The ack rides the peer's next packet, so one sample includes up to one peer send interval (test 7: 88 ms at
--        30 Hz, 226-292 ms at 10 Hz on one link). The reported RTT is the LOWEST sample of the quality window, else
--        the last window's while fresh (RTT_STALE); samples resolved after an observation gap (HITCH: a frame hitch,
--        an island load) are dropped (test 6: one such sample held the client at 968 ms for minutes).
--   loss: RELIABLE loss: resends against reliable messages sent, per quality window (test 10).
--   lossU: unreliable receive gaps against the unreliable sequence range; on newest-wins lanes (0, 3) most of these
--   are intended drops (the relay or Steam replacing a stale frame), so the rate rule weighs them only when very high.
--   backlog: reliable messages in flight on lanes 0-1 (gmp_lanes; largest over the links), so an enemy spawn wave on
--   lane 2 never counts as presence backlog; lanes = in flight per lane; resent: resends in the window.
local LinkMonitor = {}
LinkMonitor.__index = LinkMonitor
P.LinkMonitor = LinkMonitor
LinkMonitor.HITCH = 0.25
LinkMonitor.RTT_STALE = 10
function LinkMonitor.new()
    return setmetatable({ state = setmetatable({}, { __mode = 'k' }), winMin = nil, rtt = nil, rttAt = nil, lastObserve = nil,
        gaps = 0, got = 0, resent = 0, backlog = 0, dropped = 0 }, LinkMonitor)
end
function LinkMonitor:Observe(links, now)
    local hitch = self.lastObserve ~= nil and now - self.lastObserve > LinkMonitor.HITCH
    self.lastObserve = now
    local backlog, lanes = 0, { [0] = 0, 0, 0, 0 }
    for _, link in ipairs(links) do
        local st = self.state[link]
        local s = link.stats or {}
        local rx, tx = link.rx or {}, link.tx or {}
        local uHi, rContig, rSent = rx.U and rx.U.hi or 0, rx.R and rx.R.contig or 0, tx.R or 0
        if not st then
            st = { pending = {}, ok = (s.ok or 0) + (s.late or 0), gaps = s.gaps or 0, resent = s.resent or 0,
                uHi = uHi, rContig = rContig, rSent = rSent }
            self.state[link] = st
        end
        local seen, perLane = {}, { [0] = 0, 0, 0, 0 }
        for seq, o in pairs(link.outbox or {}) do
            seen[seq] = true
            local lane = Lanes.ForType(type(o.env) == 'table' and o.env.type or nil)
            perLane[lane] = perLane[lane] + 1
            local p = st.pending[seq]
            if not p then st.pending[seq] = { first = o.firstSent, clean = (o.attempts or 0) == 0 }
            elseif (o.attempts or 0) > 0 then p.clean = false end
        end
        for seq, p in pairs(st.pending) do
            if not seen[seq] then
                if p.clean and type(p.first) == 'number' and now >= p.first then
                    if hitch then self.dropped = self.dropped + 1
                    else
                        local r = now - p.first
                        if not self.winMin or r < self.winMin then self.winMin = r end
                        self.rtt, self.rttAt = self.winMin, now
                    end
                end
                st.pending[seq] = nil
            end
        end
        local ok, gaps, resent = (s.ok or 0) + (s.late or 0), s.gaps or 0, s.resent or 0
        local uRange, rGot = uHi - st.uHi, rContig - st.rContig
        local uGot = math.max(0, (ok - st.ok) - rGot)
        self.uRange, self.uGot = (self.uRange or 0) + math.max(0, uRange), (self.uGot or 0) + math.min(uGot, math.max(0, uRange))
        self.rSent = (self.rSent or 0) + math.max(0, rSent - st.rSent)
        self.got, self.gaps, self.resent = self.got + (ok - st.ok), self.gaps + (gaps - st.gaps), self.resent + (resent - st.resent)
        st.ok, st.gaps, st.resent, st.uHi, st.rContig, st.rSent = ok, gaps, resent, uHi, rContig, rSent
        backlog = math.max(backlog, perLane[0] + perLane[1])
        for lane = 0, 3 do lanes[lane] = math.max(lanes[lane], perLane[lane]) end
    end
    self.backlog, self.lanes = backlog, lanes
end
-- The quality of the window since the previous read. `now` (optional) expires an RTT older than RTT_STALE.
function LinkMonitor:Quality(now)
    local rtt = self.winMin or self.rtt
    if rtt and now and self.rttAt and now - self.rttAt > LinkMonitor.RTT_STALE then rtt = nil; self.rtt = nil end
    local uRange, rSent = self.uRange or 0, self.rSent or 0
    local q = { rtt = rtt, loss = rSent > 0 and math.min(1, self.resent / rSent) or nil,
        lossU = uRange > 0 and math.max(0, 1 - (self.uGot or 0) / uRange) or nil,
        backlog = self.backlog, resent = self.resent, lanes = self.lanes or { [0] = 0, 0, 0, 0 } }
    self.got, self.gaps, self.resent, self.winMin, self.uRange, self.uGot, self.rSent = 0, 0, 0, nil, 0, 0, 0
    return q
end

-- Size of one PLAYER_STATE (or its visual/avatar form) for `s`, with a worst-case header; used for the bandwidth budget.
function P.StateBytes(cfg, s)
    local f = { seg = s.seg, x = s.x, y = s.y, z = s.z, dead = s.dead }
    local kind = 'PLAYER_STATE'
    if cfg.animation and s.pose then
        for k, v in pairs(s.pose) do f[k] = v end
        kind = cfg.appearance and 'PLAYER_AVATAR_STATE' or 'PLAYER_STATE_VISUAL'
        if cfg.appearance then f.model = f.model or 0 end
    end
    local ok, enc = pcall(Codec.Encode, { type = kind, ch = 'U', ep = 2147483646, seq = 999999999999, ack = 999999999999, sid = 'Sffffffff', f = f })
    return ok and type(enc) == 'string' and #enc or 120
end

------------------------------------------------------------------ driver
-- Ties a world object to the session. The ONLY place that calls the world. Marker operations are gated by cfg.markers and are never
-- reached when it is false; every world call is pcall-protected and latched off after FAIL_LATCH consecutive failures.
local Driver = {}
Driver.__index = Driver
P.Driver = Driver

-- o: cfg (validated presence config), world (ReadLocal/SetMarkers/ClearMarkers), getHost(), getClient(), log(fmt, ...)
function Driver.new(o)
    return setmetatable({ cfg = o.cfg, world = o.world, getHost = o.getHost or function() end, getClient = o.getClient or function() end,
        log = o.log or function() end, seg = 0, pawnId = nil, havePawn = false, localState = nil,
        readFail = 0, markFail = 0, readLatched = false, markLatched = false, markersShown = false, nextAt = 0,
        mapper = Mapper.new({worldSpace = o.cfg.worldSpace}), smoother = Smoother.new(1/o.cfg.hz),
        rate = Rate.new(o.cfg.hz), links = LinkMonitor.new(), rateStarted = false, stats = { reads = 0, read_nil = 0, read_errors = 0, bad_reading = 0, marker_sets = 0, marker_partial = 0, marker_errors = 0, sends = 0 } }, Driver)
end

function Driver:_read()
    self.stats.reads = self.stats.reads + 1
    local ok, raw = pcall(self.world.ReadLocal, self.world)
    if not ok then
        self.stats.read_errors = self.stats.read_errors + 1
        self.readFail = self.readFail + 1
        if self.readFail >= L.FAIL_LATCH then
            self.readLatched = true
            self.log("presence: world reads failed %d times in a row (%s); reading latched OFF", self.readFail, tostring(raw))
        end
        return nil
    end
    self.readFail = 0
    if raw == nil then
        self.stats.read_nil = self.stats.read_nil + 1
        self.havePawn = false
        return nil
    end
    if self.cfg.animation and type(self.world.ReadPresentation)=="function" then
        local poseOK,pose=pcall(self.world.ReadPresentation,self.world)
        if poseOK then
            if pose and not self.cfg.appearance then pose.mesh=nil end
            raw.pose=pose
        end
    end
    local s, why = P.ToState(raw)
    if not s then self.stats.bad_reading = self.stats.bad_reading + 1; self.havePawn = false; return nil end
    local pid = type(raw) == "table" and raw.pawnId or nil
    if not self.havePawn or pid ~= self.pawnId then self.seg = self.seg % L.SEG_MAX + 1 end
    self.havePawn, self.pawnId = true, pid
    s.seg = self.seg
    return s
end

function Driver:_markers(now, host, client, state)
    if self.markLatched then return end
    local remotes = {}
    if host and host.presence then
        remotes = host.presence:Visible(now, host.identity.key)
    elseif client and client.presence and client:State() == "joined" then
        remotes = client.presence:Visible(now)
    end
    if self.cfg.selfEcho and state then remotes[#remotes + 1] = { key = "dev:self_echo", seg = state.seg, x = state.x, y = state.y, z = state.z, dead = state.dead, gen = state.seg, pose=Visual.copy(state.pose) } end
    local markers = self.havePawn and self.mapper:Update(remotes, self.localState) or {}
    if self.cfg.smooth then markers=self.smoother:Update(markers,now) end
    if #markers == 0 and not self.markersShown then return end
    local ok, err, wanted = pcall(self.world.SetMarkers, self.world, markers)
    if ok then
        self.markFail = 0
        -- A world that reports (shown, wanted): a marker that could not be spawned is not a success (R1 attempt 4).
        -- It is not a world failure either (no latch): the world retries the spawn with its own backoff.
        local shown = math.type(err) == "integer" and math.type(wanted) == "integer" and err or nil
        self.markersShown = shown and shown > 0 or (shown == nil and #markers > 0)
        if shown and shown < wanted then self.stats.marker_partial = self.stats.marker_partial + 1
        else self.stats.marker_sets = self.stats.marker_sets + 1 end
    else
        self.stats.marker_errors = self.stats.marker_errors + 1
        self.markFail = self.markFail + 1
        if self.markFail >= L.FAIL_LATCH then
            self.markLatched = true
            self.log("presence: marker operations failed %d times in a row (%s); markers latched OFF", self.markFail, tostring(err))
            pcall(self.world.ClearMarkers, self.world)
            self.markersShown = false
        end
    end
end

function Driver:Tick(now)
    local host, client = self.getHost(), self.getClient()
    if host and not host.presence then host:EnablePresence(self.cfg) end
    if client and not client.presence then client:EnablePresence(self.cfg) end
    if host and host.presence then host.presence:Prune(now) end
    if client and client.presence then client.presence:Prune(now) end
    self:_rateTick(now, host, client)
    if now + 1e-6 < self.nextAt then
        if self.cfg.smooth and self.cfg.markers and self.world then self:_markers(now,host,client,self.havePawn and self.localState or nil) end
        return
    end           -- epsilon: float accumulation of tick times must not skip a slot
    local period = 1 / self.rate:Hz()
    self.nextAt = self.nextAt + period
    if self.nextAt <= now then self.nextAt = now + period end   -- never burst to catch up after a stall
    local state
    if self.cfg.read and not self.readLatched and self.world then state = self:_read() end
    if state then
        self.localState = state
        if host and host.presence then host.presence:SetLocal(host.identity.key, state, now) end
        if client and client.presence and client:SendPlayerState(state) then
            self.stats.sends = self.stats.sends + 1
            self.rate:Sent('host', P.StateBytes(self.cfg, state) + Rate.OVERHEAD, now)
        end
    end
    if host and host.presence then
        host:BroadcastPresence()
        for key, bytes in pairs(host.presence.lastBytes or {}) do self.rate:Sent(key, bytes + Rate.OVERHEAD, now) end
    end
    if self.cfg.markers and self.world then self:_markers(now, host, client, state) end
end

-- The session's links (host: one per peer; client: the one to the host), for the LinkMonitor.
function Driver:_links(host, client)
    local out = {}
    if host and type(host.peers) == "table" then
        for _, peer in pairs(host.peers) do if type(peer) == "table" and type(peer.link) == "table" then out[#out + 1] = peer.link end end
    end
    if client and type(client.link) == "table" then out[#out + 1] = client.link end
    return out
end
-- Every tick: observe the links; once a second: re-evaluate the send rate and log it.
function Driver:_rateTick(now, host, client)
    if not self.rateStarted then self.rateStarted = true; self.rate:Start(now) end
    self.links:Observe(self:_links(host, client), now)
    if not self.rate:Due(now) then return end
    local quality = self.links:Quality(now)
    self.rate:Evaluate(now, quality)
    -- test 15 (Coder C): the remote markers' lead, one leg = RTT / 2; legs per marker (see Smoother:SetLead)
    local rtt = type(quality) == 'table' and quality.rtt or nil
    local hostKey = not host and client and client.authenticatedHostKey or nil
    self.smoother:SetLead(type(rtt) == 'number' and rtt > 0 and rtt / 2 or nil,
        function(key) if host or key == hostKey then return 1 end; return 2 end)
    local st = self.rate:Status()
    local snaps = self.smoother.snaps - (self.snapsLogged or 0)
    self.snapsLogged = self.smoother.snaps
    self.log("PRESENCE rate hz=%d bytes_per_s=%d rtt_ms=%s loss=%s loss_u=%s backlog=%d buffer_ms=%d snaps=%d", st.hz, st.bytesPerS,
        st.rtt and tostring(math.floor(st.rtt * 1000 + 0.5)) or "-", st.loss and string.format("%.2f", st.loss) or "-",
        st.lossU and string.format("%.2f", st.lossU) or "-",
        st.backlog, math.floor(self.smoother:MaxBuffer() * 1000 + 0.5), snaps)
end

-- CR (S4): forget the previous island. Mapper anchors, smoothing state, the local pawn tracking and the markers go;
-- the seg COUNTER keeps counting, so the next pawn reading opens a new segment (havePawn=false bumps seg) and no
-- receiver can mistake it for an old island's segment.
function Driver:Reset()
    self.mapper.anchors = {}
    self.smoother.entries = {}
    self.pawnId, self.havePawn, self.localState = nil, false, nil
    -- Always with markers on, even when nothing was shown: the world also resets its spawn tries (R1 attempt 4).
    if self.world and self.cfg.markers then
        pcall(self.world.ClearMarkers, self.world)
        self.markersShown = false
    end
end

-- Remove every marker we created (only if markers were ever enabled and shown).
function Driver:Shutdown()
    self.smoother.entries={}
    if self.cfg.markers and self.world and self.markersShown then
        pcall(self.world.ClearMarkers, self.world)
        self.markersShown = false
    end
end

return P
