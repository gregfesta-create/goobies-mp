-- GoobiesMP: RELAY-BACKED TRANSPORT (M3). Implements the gmp_transport contract on top of the existing UDP sidecar relay.
--
--   Lua  <-- append-only text files -->  relay process  <-- UDP, loopback only -->  relay process  <-- files -->  Lua
--
-- UE4SS Lua has no sockets (Phase 0), so a sidecar relay moves lines between files and UDP (tools/m3/relay_m3.c, same
-- architecture and UDP framing as the Phase 1 POC relay). The relay itself is a SINGLE-PEER, connection-less pipe: it only knows
-- "connected to the other relay". This module adds the connection semantics the transport contract needs, INSIDE the relay payload:
--
--   frame (one text line, carried as the relay's data payload; the GMP wire format inside M frames is untouched):
--     T1|C|<cid>           client -> host   connect request (repeated until accepted)
--     T1|A|<cid>           host   -> client accept
--     T1|X|<cid>           either way       close notification (best effort)
--     T1|M|<cid>|<packet>  either way       one GMP packet
--
-- <cid> is a random per-connection id chosen by the client, so a stale packet of an earlier connection can never be mistaken for
-- the current one, and a client that reconnects (new cid) supersedes the old connection on the host immediately.
-- peerId is opaque and new for every connection ("rp1", "rp2", ...); it is never identity. IsAuthenticated() is false: identity is
-- a claim until the authentication stage (gmp_host / gmp_client + gmp_auth) has run.
--
-- Properties (documented limits): one remote peer at a time; no encryption; loopback only (the relay refuses other peers); latency
-- is dominated by file polling (Phase 1: ~90 ms RTT, max ~460 ms); a framed line must stay below 1400 bytes (relay limit), so
-- Send() refuses a packet above RelayTransport.MAX_PACKET.
local RT = {}
RT.__index = RT

RT.MAX_PACKET = 1380            -- 1399 (relay line limit) minus the longest frame header "T1|M|<8 hex>|"
RT.PREFIX = "T1|"

------------------------------------------------------------------ file system (injectable for tests)
local RealFs = {}
function RealFs.read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("a"); f:close(); return s
end
function RealFs.size(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local n = f:seek("end"); f:close(); return n
end
function RealFs.readFrom(path, offset)
    local f = io.open(path, "rb"); if not f then return nil end
    f:seek("set", offset)
    local s = f:read("a"); f:close(); return s
end
function RealFs.write(path, text)
    local f = io.open(path, "wb"); if not f then return false end
    f:write(text); f:close(); return true
end
function RealFs.append(path, text)
    local f = io.open(path, "ab"); if not f then return false end
    f:write(text); f:close(); return true
end
RT.RealFs = RealFs

local function hex(rng, n)
    local t = {}
    for i = 1, n do t[i] = string.format("%02x", math.floor(rng() * 256) % 256) end
    return table.concat(t)
end

-- opts: role ("host"|"client"), dir (folder holding <role>_out.txt / _in.txt / _status.txt, with trailing separator or not),
--       clock()->seconds, rng()->[0,1), fs (default RealFs), log(fmt, ...), helloEvery (s, default 0.5), statusEvery (default 0.25)
function RT.new(opts)
    assert(opts.role == "host" or opts.role == "client", "role must be host or client")
    local self = setmetatable({}, RT)
    self.role = opts.role
    self.endpointRole = opts.role -- Physical IPC endpoint never changes with authority.
    self.authorityTerm = 1
    local dir = opts.dir or "."
    if not dir:match("[/\\]$") then dir = dir .. "/" end
    self.outPath, self.inPath, self.statPath = dir .. opts.role .. "_out.txt", dir .. opts.role .. "_in.txt", dir .. opts.role .. "_status.txt"
    self.clock = opts.clock or os.clock
    self.rng = opts.rng or math.random
    self.fs = opts.fs or RealFs
    self.logfn = opts.log
    self.helloEvery, self.statusEvery = opts.helloEvery or 0.5, opts.statusEvery or 0.25
    self.inOffset = nil                  -- set on first Poll/Listen/Connect: stale backlog from an earlier run is skipped
    self.relayUp = false                 -- relay reports connected to its peer relay
    self.lastStatus = -1
    self.statusInvalidSince = nil
    self.listening, self.wantConnect = false, false
    self.conn = nil                      -- { peerId, cid }
    self.peerSeq = 0
    self.events = {}
    self.severed = false
    self.lastHello = -1
    self.lastX = {}                      -- cid -> time of the last X we sent for it (rate limit)
    self.stats = { tx = 0, rx = 0, dropped_not_connected = 0, too_large = 0, bad_frame = 0, stale_cid = 0, superseded = 0, relay_down = 0 }
    return self
end

function RT:_log(...) if self.logfn then self.logfn(...) end end

function RT:Name() return "relay(" .. self.role .. ",udp-loopback,file-ipc)" end
function RT:IsAuthenticated() return false end

-- Called only after a trusted handover commit. Bidirectional UDP endpoints
-- remain bound; only the virtual Listen/Connect role changes. Fresh connection
-- IDs and skipped backlog isolate old-session traffic from the new authority.
function RT:SwitchRole(role,term)
    if role~='host' and role~='client' then return false,'bad_role' end
    if type(term)~='number' or term%1~=0 or term<=self.authorityTerm or term>2147483647 then return false,'stale_term' end
    self:Close()
    self.role,self.authorityTerm=role,term
    self.conn=nil;self.cid=nil;self.events={};self.listening=false;self.wantConnect=false
    self.severed=false;self.lastHello=-1;self.lastX={}
    self.inOffset=self.fs.size(self.inPath) or 0
    return true
end

function RT:_skipBacklog()
    if self.inOffset == nil then self.inOffset = self.fs.size(self.inPath) or 0 end
end

function RT:Listen()
    if self.role ~= "host" then return nil, "listen_is_host_only" end
    self:_skipBacklog()
    self.listening = true
    return true
end

function RT:Connect(address)
    if self.role ~= "client" then return nil, "connect_is_client_only" end
    self:_skipBacklog()
    if self.conn then self.conn = nil end                 -- a fresh Connect always starts a fresh connection id
    self.wantConnect = true
    self.cid = hex(self.rng, 4)
    self.lastHello = -1
    self.severed = false
    return true
end

------------------------------------------------------------------ raw line IO
function RT:_sendLine(line)
    if self.severed then return false end
    if not self.relayUp then self.stats.dropped_not_connected = self.stats.dropped_not_connected + 1; return false end
    if not self.fs.append(self.outPath, line .. "\n") then return false end
    self.stats.tx = self.stats.tx + 1
    return true
end

function RT:_sendX(cid)
    local now = self.clock()
    if self.lastX[cid] and now - self.lastX[cid] < 1.0 then return end
    self.lastX[cid] = now
    self:_sendLine(RT.PREFIX .. "X|" .. cid)
end

function RT:_refreshStatus(force)
    local now = self.clock()
    if not force and self.lastStatus >= 0 and now - self.lastStatus < self.statusEvery then return end
    self.lastStatus = now
    local s = self.fs.read(self.statPath)
    -- The sidecar truncates this file before writing its next snapshot. An
    -- empty/partial read is unknown, not a disconnected link. Bound the grace
    -- period so a permanently unreadable status still drops the connection.
    local line = s and s:match("^([^\n]*)\n")
    local bit = line and (line:match("^connected=([01])%s") or line:match("^connected=([01])$"))
    if not bit then
        self.statusInvalidSince = self.statusInvalidSince or now
        if now - self.statusInvalidSince < 3 then return end
    else
        self.statusInvalidSince = nil
    end
    local up = bit == "1"
    if up ~= self.relayUp then
        self.relayUp = up
        self:_log("relay %s", up and "connected" or "DISCONNECTED")
        if not up and self.conn then
            -- the relay lost its peer (3 s of UDP silence): the virtual connection is gone
            self.stats.relay_down = self.stats.relay_down + 1
            local pid = self.conn.peerId
            self.conn = nil
            self.events[#self.events + 1] = { kind = "peer_disconnected", peerId = pid, reason = "relay_down" }
        end
    end
end

function RT:_newConn(cid)
    self.peerSeq = self.peerSeq + 1
    self.conn = { peerId = "rp" .. self.peerSeq, cid = cid }
    return self.conn
end

------------------------------------------------------------------ Send / Close
function RT:Send(peerId, data)
    if type(data) ~= "string" or data:find("[\r\n]") then return nil, "bad_packet" end
    if #data > RT.MAX_PACKET then self.stats.too_large = self.stats.too_large + 1; return nil, "too_large" end
    local c = self.conn
    if not c or c.peerId ~= peerId then return nil, "no_such_peer" end
    if not self:_sendLine(RT.PREFIX .. "M|" .. c.cid .. "|" .. data) then return nil, "relay_not_connected" end
    return true
end
-- Opt-in development migration lane tied to a trusted staged nonce. It stays
-- on the physical relay endpoint when virtual connections/roles are replaced.
function RT:BindHandoverControl(nonce)
    if type(nonce)~='string' or not nonce:match('^%x+$') or #nonce~=32 then return false end
    self.controlNonce=nonce;self.controlEvents={};return true
end
function RT:SendHandoverControl(payload)
    if not self.controlNonce or type(payload)~='string' or #payload>512
        or payload:find('[\r\n|]') then return false end
    return self:_sendLine(RT.PREFIX..'G|'..self.controlNonce..'|'..payload)
end
function RT:PollHandoverControl()
    local events=self.controlEvents or {};self.controlEvents={};return events
end

local function dropConn(self, notify)
    local c = self.conn
    if not c then return end
    if notify then self:_sendLine(RT.PREFIX .. "X|" .. c.cid) end
    self.conn = nil
end

function RT:Close(peerId)
    if peerId == nil or (self.conn and self.conn.peerId == peerId) then
        dropConn(self, true)
        if self.role == "client" then self.wantConnect = false end
    end
end

-- Test/dev hook: model a dead link. Nothing is sent or received until Unsever(); no notification either way.
function RT:Sever() self.severed = true end
function RT:Unsever() self.severed = false end

------------------------------------------------------------------ Poll
local function handleFrame(self, line)
    local kind, rest = line:match("^T1|(%u)|(.*)$")
    if not kind then self.stats.bad_frame = self.stats.bad_frame + 1; return end
    if kind=='G' then
        local nonce,payload=rest:match('^(%x+)|([^|]+)$')
        if self.controlNonce and nonce==self.controlNonce and #payload<=512 then
            self.controlEvents=self.controlEvents or {}
            if #self.controlEvents<16 then self.controlEvents[#self.controlEvents+1]=payload end
        end
        return
    end
    local cid, payload = rest:match("^(%x+)|(.*)$")
    if not cid then cid = rest:match("^(%x+)$") end
    if not cid then self.stats.bad_frame = self.stats.bad_frame + 1; return end
    local c = self.conn
    if self.role == "host" then
        if kind == "C" then
            if c and c.cid == cid then
                self:_sendLine(RT.PREFIX .. "A|" .. cid)                       -- our accept was lost: repeat it
            elseif self.listening then
                if c then
                    self.stats.superseded = self.stats.superseded + 1
                    self.events[#self.events + 1] = { kind = "peer_disconnected", peerId = c.peerId, reason = "superseded" }
                end
                local n = self:_newConn(cid)
                self:_sendLine(RT.PREFIX .. "A|" .. cid)
                self.events[#self.events + 1] = { kind = "peer_connected", peerId = n.peerId }
            end
        elseif kind == "M" then
            if c and c.cid == cid and payload then
                self.stats.rx = self.stats.rx + 1
                self.events[#self.events + 1] = { kind = "message", peerId = c.peerId, data = payload }
            else
                self.stats.stale_cid = self.stats.stale_cid + 1
                self:_sendX(cid)                                               -- tell a stale client its connection is gone
            end
        elseif kind == "X" then
            if c and c.cid == cid then
                self.events[#self.events + 1] = { kind = "peer_disconnected", peerId = c.peerId, reason = "closed_by_peer" }
                self.conn = nil
            end
        end
    else
        if not self.wantConnect or cid ~= self.cid then self.stats.stale_cid = self.stats.stale_cid + 1; return end
        if kind == "A" then
            if not c then
                local n = self:_newConn(cid)
                self.events[#self.events + 1] = { kind = "peer_connected", peerId = n.peerId }
            end
        elseif kind == "M" then
            if c and payload then
                self.stats.rx = self.stats.rx + 1
                self.events[#self.events + 1] = { kind = "message", peerId = c.peerId, data = payload }
            end
        elseif kind == "X" then
            if c then
                self.events[#self.events + 1] = { kind = "peer_disconnected", peerId = c.peerId, reason = "closed_by_peer" }
                self.conn = nil
                self.wantConnect = false
            end
        end
    end
end

function RT:Poll()
    self:_skipBacklog()
    self:_refreshStatus(false)
    local data = self.fs.readFrom(self.inPath, self.inOffset)
    if data and #data > 0 then
        local last = 0
        for i = #data, 1, -1 do if data:byte(i) == 10 then last = i; break end end
        if last > 0 then
            self.inOffset = self.inOffset + last
            if not self.severed then
                for line in data:sub(1, last):gmatch("([^\n]*)\n") do
                    line = line:gsub("\r$", "")
                    if #line > 0 then handleFrame(self, line) end
                end
            end                                                                -- severed: the lines are consumed and discarded
        end
    end
    -- client: keep asking until the host accepts (only while the relay link is up; lines sent earlier would be dropped by the relay)
    if self.role == "client" and self.wantConnect and not self.conn and not self.severed and self.relayUp then
        local now = self.clock()
        if self.lastHello < 0 or now - self.lastHello >= self.helloEvery then
            self.lastHello = now
            self:_sendLine(RT.PREFIX .. "C|" .. self.cid)
        end
    end
    local ev = self.events
    self.events = {}
    return ev
end

return RT
