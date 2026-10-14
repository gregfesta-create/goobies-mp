-- GoobiesMP production: per-peer link state = sequence numbers, duplicate/stale detection, reliable-delivery bookkeeping.
-- Pure Lua; time is passed in. One Link exists per transport connection (host: one per peer; client: one, to the host).
--
-- SEQUENCE-NUMBER RULES (M1)
--  * Ownership: the SENDER of a link owns two independent counters, one per channel (R and U), starting at 1 (0 = "nothing yet").
--    Numbering is per sender per channel per link; a new transport connection => a new Link => numbering restarts at 1.
--  * Epoch: each Link has a random-ish nonzero epoch stamped on every packet. The receiver binds the first epoch it sees
--    and drops packets carrying another one ("bad_epoch"), which filters delayed packets from an older connection.
--  * Receive verdicts per packet:  ok | late | duplicate | stale | bad_epoch
--      ok        newest seq so far (a skipped range is counted as gaps)
--      late      reliable only: unseen seq below the newest but inside the window -> ACCEPTED (out-of-order, exactly once)
--      duplicate seq already seen (inside the window) -> dropped
--      stale     unreliable: unseen seq below the newest OF ITS LANE (gmp_lanes) -> dropped; both: seq older than the window
--                -> dropped. Test 11: lanes reorder unreliable messages across lanes (presence is sent before enemy motion)
--                while they share one sequence space, so an unseen seq below the newest of ANOTHER lane is accepted once
--                ("late") and refunds the gap counted when the newer one arrived.
--  * Reliable messages are processed EXACTLY ONCE but NOT in order (order-sensitive state carries its own revision number,
--    e.g. ROSTER.rev). Each packet carries `ack` = cumulative: highest reliable seq such that ALL <= it were received.
--    Unacked reliable messages are resent (Due) until acked or MAX_RESENDS is exceeded (link failure). The sender never has
--    more than WINDOW reliable messages in flight (Stamp returns nil,"window_full"), which bounds the receiver's window.
--  * Unreliable gaps are only counted. NOTHING here has been validated on a real network (M1 = logic + simulation only).
local Lanes = require("gmp_lanes")
local Link = {}
Link.__index = Link
local function laneCounts() return { [0] = 0, 0, 0, 0 } end

function Link.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Link)
    self.window = opts.window or 64
    self.epoch = opts.epoch or 1
    self.tx = { R = 0, U = 0 }
    self.outbox = {}                    -- reliable seq -> { env=, firstSent=, lastSent=, attempts= }
    self.inFlight = 0
    self.ackedByPeer = 0                -- highest cumulative ack the peer has given us
    self.rxEpoch = nil
    self.rx = {                         -- per channel receive state
        R = { hi = 0, contig = 0, seen = {} },
        U = { hi = 0, contig = 0, seen = {}, laneHi = laneCounts() },   -- laneHi: newest unreliable seq per lane
    }
    self.stats = { sent = 0, resent = 0, ok = 0, late = 0, duplicate = 0, stale = 0, bad_epoch = 0, gaps = 0, window_full = 0,
        lanes = { ok = laneCounts(), stale = laneCounts() } }   -- per lane: messages delivered / dropped as stale
    return self
end

-- Fill ep/seq/ack on an outgoing envelope. Reliable envelopes are remembered for resend.
function Link:Stamp(env, now)
    local ch = env.ch
    if ch == "R" and self.inFlight >= self.window then
        self.stats.window_full = self.stats.window_full + 1
        return nil, "window_full"
    end
    self.tx[ch] = self.tx[ch] + 1
    env.ep, env.seq, env.ack = self.epoch, self.tx[ch], self.rx.R.contig
    self.stats.sent = self.stats.sent + 1
    if ch == "R" then
        self.outbox[env.seq] = { env = env, firstSent = now, lastSent = now, attempts = 0 }
        self.inFlight = self.inFlight + 1
    end
    return env
end

-- Process an incoming (already decoded) envelope. Returns accept(bool), verdict(string).
function Link:Receive(env)
    if self.rxEpoch == nil then self.rxEpoch = env.ep
    elseif env.ep ~= self.rxEpoch then
        self.stats.bad_epoch = self.stats.bad_epoch + 1
        return false, "bad_epoch"
    end
    -- the peer's cumulative ack releases our outbox
    if env.ack > self.ackedByPeer then
        for seq in pairs(self.outbox) do
            if seq <= env.ack then self.outbox[seq] = nil; self.inFlight = self.inFlight - 1 end
        end
        self.ackedByPeer = env.ack
    end
    local r = self.rx[env.ch]
    local seq = env.seq
    local lane = Lanes.ForType(env.type)
    if seq <= r.hi - self.window then
        self.stats.stale = self.stats.stale + 1
        self.stats.lanes.stale[lane] = self.stats.lanes.stale[lane] + 1
        return false, "stale"
    end
    if r.seen[seq] or (env.ch == "R" and seq <= r.contig) then
        self.stats.duplicate = self.stats.duplicate + 1
        return false, "duplicate"
    end
    local verdict
    if env.ch == "U" then
        if seq < (r.laneHi[lane] or 0) then             -- latest wins within the lane
            self.stats.stale = self.stats.stale + 1
            self.stats.lanes.stale[lane] = self.stats.lanes.stale[lane] + 1
            return false, "stale"
        end
        r.laneHi[lane] = seq
    end
    if seq > r.hi then
        if seq > r.hi + 1 then self.stats.gaps = self.stats.gaps + (seq - r.hi - 1) end
        r.hi = seq
        verdict = "ok"
    else
        verdict = "late"                                 -- reliable out of order, or unreliable behind another lane
        if env.ch == "U" and self.stats.gaps > 0 then self.stats.gaps = self.stats.gaps - 1 end
    end
    r.seen[seq] = true
    self.stats.lanes.ok[lane] = self.stats.lanes.ok[lane] + 1
    if env.ch == "R" then
        while r.seen[r.contig + 1] do r.contig = r.contig + 1 end
    end
    for s in pairs(r.seen) do                         -- keep the seen-set bounded
        if (env.ch == "R" and s <= r.contig) or (env.ch == "U" and s <= r.hi - self.window) then r.seen[s] = nil end
    end
    self.stats[verdict] = self.stats[verdict] + 1
    return true, verdict
end

-- Reliable envelopes due for resend (their `ack` is refreshed). Returns list, failedCount (attempts > maxResends).
function Link:Due(now, interval, maxResends)
    local out, failed = {}, 0
    local seqs = {}
    for seq in pairs(self.outbox) do seqs[#seqs + 1] = seq end
    table.sort(seqs)
    for _, seq in ipairs(seqs) do
        local o = self.outbox[seq]
        if now - o.lastSent >= interval then
            if o.attempts >= maxResends then failed = failed + 1
            else
                o.attempts, o.lastSent = o.attempts + 1, now
                o.env.ack = self.rx.R.contig
                self.stats.resent = self.stats.resent + 1
                out[#out + 1] = o.env
            end
        end
    end
    return out, failed
end

function Link:Pending() return self.inFlight end
function Link:Ack() return self.rx.R.contig end

return Link
