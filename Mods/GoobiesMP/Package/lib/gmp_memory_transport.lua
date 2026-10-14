-- GoobiesMP: in-memory transport (tests and offline development). Implements the gmp_transport contract.
-- A Hub connects endpoints and can simulate loss, duplication, reordering and latency deterministically
-- (seeded LCG), plus link severing. Time is explicit (hub:Advance). Not a network.
local Hub = {}
Hub.__index = Hub

local function lcg(seed)
    local s = seed or 12345
    return function()
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
end

function Hub.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Hub)
    self.now = 0
    self.rnd = lcg(opts.seed)
    self.loss, self.dup, self.reorder = opts.loss or 0, opts.dup or 0, opts.reorder or 0
    self.latency = opts.latency or 0.01
    self.endpoints = {}       -- name -> endpoint
    self.nextPeer = 0
    self.inflight = {}        -- { at=, toEp=, peerId=, data= }
    self.counters = { sent = 0, dropped = 0, duplicated = 0, delivered = 0 }
    return self
end

local Endpoint = {}
Endpoint.__index = Endpoint

function Hub:NewEndpoint(name, opts)
    local ep = setmetatable({ hub = self, name = name, listening = false, peers = {}, events = {}, authenticated = opts and opts.authenticated or false, verifiedKey = opts and opts.verifiedKey or nil }, Endpoint)
    self.endpoints[name] = ep
    return ep
end

function Hub:Advance(dt)
    self.now = self.now + dt
    table.sort(self.inflight, function(a, b) if a.at == b.at then return a.n < b.n end return a.at < b.at end)
    local keep = {}
    for _, m in ipairs(self.inflight) do
        if m.at <= self.now then
            local ep = m.toEp
            if ep.peers[m.peerId] then
                ep.events[#ep.events + 1] = { kind = "message", peerId = m.peerId, data = m.data }
                self.counters.delivered = self.counters.delivered + 1
            end
        else
            keep[#keep + 1] = m
        end
    end
    self.inflight = keep
end

local seqN = 0
function Hub:_enqueue(toEp, peerId, data)
    self.counters.sent = self.counters.sent + 1
    if self.rnd() < self.loss then self.counters.dropped = self.counters.dropped + 1; return end
    local copies = 1
    if self.rnd() < self.dup then copies = 2; self.counters.duplicated = self.counters.duplicated + 1 end
    for _ = 1, copies do
        local delay = self.latency
        if self.rnd() < self.reorder then delay = delay + self.latency * 3 * self.rnd() end
        seqN = seqN + 1
        self.inflight[#self.inflight + 1] = { at = self.now + delay, toEp = toEp, peerId = peerId, data = data, n = seqN }
    end
end

function Endpoint:Name() return "memory:" .. self.name end
function Endpoint:IsAuthenticated() return self.authenticated end
function Endpoint:Listen() self.listening = true; return true end

-- Connect to the listening endpoint called `address`. Creates a peer entry on both sides.
function Endpoint:Connect(address)
    local host = self.hub.endpoints[address]
    if not host or not host.listening then return nil, "no_such_host" end
    self.hub.nextPeer = self.hub.nextPeer + 1
    local hostSide, clientSide = "p" .. self.hub.nextPeer .. "h", "p" .. self.hub.nextPeer .. "c"
    host.peers[hostSide] = { remote = self, remoteId = clientSide }
    self.peers[clientSide] = { remote = host, remoteId = hostSide }
    host.events[#host.events + 1] = { kind = "peer_connected", peerId = hostSide, identity = self.verifiedKey }
    self.events[#self.events + 1] = { kind = "peer_connected", peerId = clientSide }
    return true
end

function Endpoint:Send(peerId, data)
    local p = self.peers[peerId]
    if not p then return nil, "no_such_peer" end
    self.hub:_enqueue(p.remote, p.remoteId, data)
    return true
end

function Endpoint:Poll()
    local ev = self.events
    self.events = {}
    return ev
end

local function dropPeer(ep, peerId, reason)
    local p = ep.peers[peerId]
    if not p then return end
    ep.peers[peerId] = nil
    local other = p.remote
    if other.peers[p.remoteId] then
        other.peers[p.remoteId] = nil
        other.events[#other.events + 1] = { kind = "peer_disconnected", peerId = p.remoteId, reason = reason or "closed" }
    end
end

function Endpoint:Close(peerId)
    if peerId == nil then
        local ids = {}
        for id in pairs(self.peers) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do dropPeer(self, id, "closed") end
    else
        dropPeer(self, peerId, "closed")
    end
end

-- Test helper: silently sever a connection (no event on either side) - models a dead link that only timeouts can detect.
function Endpoint:Sever(peerId)
    local p = self.peers[peerId]
    if not p then return end
    p.remote.peers[p.remoteId] = nil
    self.peers[peerId] = nil
end

return Hub
