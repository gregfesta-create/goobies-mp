-- GoobiesMP production: CLIENT session. Holds a MIRROR of host state only; it has no API that changes slot/colour/roster.
-- It can send requests (join/rejoin/colour/leave); every authoritative fact arrives from the host.
local Config = require("gmp_config")
local Messages = require("gmp_messages")
local Codec = require("gmp_codec")
local Link = require("gmp_link")
local Identity = require("gmp_identity")
local Transport = require("gmp_transport")
local Auth = require("gmp_auth")
local Compat = require("gmp_compat")

local Client = {}
Client.__index = Client

-- states: idle | connecting | awaiting_info | authenticating | joining | rejoining | joined | rejected | kicked | disconnected
-- opts: cfg, transport, clock, rng, identity, name, gameVer, reqColor, log, authProvider (gmp_auth contract)
-- Authentication (PHASE2 12.18): unless the transport itself authenticates, a client with cfg.AUTH_MODE ~= "off" runs AUTH_HELLO ->
-- AUTH_CHALLENGE -> ticket -> AUTH_TICKET chunks -> AUTH_RESULT before it may send JOIN_REQ/REJOIN_REQ. A fresh ticket is requested on every connect.
function Client.new(opts)
    local tok, missing = Transport.Check(opts.transport)
    if not tok then return nil, "bad_transport: missing " .. table.concat(missing, ",") end
    local policy = Identity.Policy.new(opts.cfg.MODE)
    local pok, why = policy:Check(opts.identity)
    if not pok then return nil, why end            -- e.g. production client with a dev identity: refuse, never fall back
    local self = setmetatable({}, Client)
    self.cfg, self.transport, self.policy = opts.cfg, opts.transport, policy
    self.clock = opts.clock or os.clock
    self.rng = opts.rng or math.random
    self.needsAuth = (opts.cfg.AUTH_MODE ~= "off") and not opts.transport:IsAuthenticated()   -- transport-authenticated peers skip the exchange
    if opts.authProvider ~= nil and self.needsAuth then
        local aok, awhy = Auth.CheckProvider(opts.authProvider, opts.cfg)
        if not aok then return nil, awhy end
    end
    self.authProvider = self.needsAuth and opts.authProvider or nil
    self.auth = nil                    -- { phase = hello|ticketing|submitted, nonce, handle, deadline } while authenticating
    self.identity, self.name = opts.identity, opts.name or opts.identity.value
    self.gameVer, self.reqColor = opts.gameVer or "", opts.reqColor or ""
    -- What THIS install is (for the compatibility gate). Defaults to the real values; tests/launchers may pass others. A client that is
    -- running IS installed and enabled (a disabled mod never starts), so cases A/B are decided before the mod runs (see gmp_compat).
    self.localInfo = opts.localInfo or { installed = true, enabled = true, modVer = Config.MOD_VERSION, protocol = Config.PROTOCOL_VERSION, gameVer = opts.gameVer or "" }
    self.compat = nil                  -- result of the last compatibility check (kept for the UI)
    self.lobby, self.chat, self.chatSeq, self.started = nil, {}, 0, false      -- mirror of the host's lobby state / chat / start
    self.state, self.reason = "idle", nil
    self.peerId, self.link, self.sid = nil, nil, nil
    self.me = nil                      -- { slot, color, token, assignRev } as told by the host
    self.resume = nil                  -- remembered after a successful join, used by Reconnect()
    self.mirror = nil                  -- last ROSTER from the host
    self.lastDenied = nil
    self.hostInfo = nil
    self.stats = { rx = 0, tx = 0, decode_errors = {}, wrong_direction = 0, bad_sid = 0, duplicate = 0, stale = 0, late = 0, bad_epoch = 0, window_full = 0 }
    self.events, self.logfn = {}, opts.log
    self.lastRx, self.lastHb = 0, 0
    -- D52: join as a player waiting for the next game (WAIT_REQ): 'waiting' until the host's lobby return admits it
    self.wantWait = opts.wait == true
    return self
end

function Client:_log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    self.events[#self.events + 1] = line
    if #self.events > 200 then table.remove(self.events, 1) end
    if self.logfn then self.logfn(line) end
end

function Client:_cancelTicket()
    if self.auth and self.auth.handle and self.authProvider then self.authProvider:TicketCancel(self.auth.handle) end
    if self.auth then
        self.auth.handle = nil
        if self.auth.hostSessionKey and self.authProvider then self.authProvider:End(self.auth.hostSessionKey);self.auth.hostSessionKey=nil end
    end
end

function Client:_setState(s, reason)
    self.state, self.reason = s, reason
    if s ~= "joined" and self.presence then self.presence:Clear() end      -- remote states belong to a joined session only
    if s == "disconnected" or s == "rejected" or s == "kicked" then self:_cancelTicket() end          -- successful tickets stay owned until connection/transaction retirement
    self:_log("state -> %s%s", s, reason and (" (" .. reason .. ")") or "")
end

function Client:Connect(address)
    if self.leaving then
        if not self.leaving.closed then self.transport:Close(self.leaving.peerId) end
        self.leaving = nil
    end
    self.snapshotPages=nil
    self.departureOffer=nil;self.authenticatedHostKey=nil;self.sessionPolicy=nil
    self.authenticatedAuthorityTerm=nil
    self.handoverStage=nil;self.handoverStageReceipt=nil
    self:_cancelTicket()
    self.auth = nil
    self.link, self.sid, self.peerId, self.mirror, self.hostInfo = nil, nil, nil, nil, nil
    self.lobby, self.chat, self.chatSeq, self.started, self.compat = nil, {}, 0, false, nil
    local ok, err = self.transport:Connect(address)
    if not ok then self:_setState("disconnected", err or "connect_failed"); return nil, err end
    self.connectStart = self.clock()
    self:_setState("connecting")
    return true
end

-- Reconnect after a drop: same identity; REJOIN_REQ carries the token and the slot/colour this client remembers (as claims).
function Client:Reconnect(address) return self:Connect(address) end
-- Restore local session metadata before fresh authentication to the replacement.
-- Tokens from the old host are not reused; identity proof reclaims reservations.
function Client:StartHandover(checkpoint,commit,address)
    if self.state~='idle' or self.cfg.AUTH_MODE=='off' then return false,'fresh_auth_required' end
    local ok,state=require('gmp_handover').Validate(checkpoint);if not ok then return false,state end
    if type(commit)~='table' or type(commit.session)~='string' or #commit.session<1 or #commit.session>128
        or type(commit.term)~='number' or commit.term%1~=0 or commit.term<2 then return false,'invalid_commit' end
    local localPlayer,host
    for _,player in ipairs(state.players) do
        if player.key==self.identity.key and player.conn=='connected' then localPlayer=player end
        if player.role=='host' then host=player.key end
    end
    if not localPlayer or localPlayer.role~='client' or host~=commit.hostKey then return false,'participant_mismatch' end
    local connected,why=self:Connect(address);if not connected then return false,why end
    self.expectedHandoverSession=commit.session;self.expectedHandoverHost=commit.hostKey;self.authorityTerm=commit.term
    self.expectedAuthorityTerm=commit.term
    self:EnableIslands();self:EnableTravelGate();self:EnablePause();self:EnableEnemies()
    self.islands.epoch=state.manifest.epoch;self.islands.island=state.manifest.island
    self.islands.current=state.manifest;self.islands.phase='playing'
    self.sessionPolicy=state.sessionPolicy
    self.handoverState=state
    -- This flag is a local safety hold, not an authoritative pause revision.
    self.handoverHold=true
    return true
end

function Client:_send(typ, fields)
    local sch = Messages.Schema[typ]
    if not self.link then return false end
    local env = { type = typ, ch = sch.ch, sid = self.sid or "", f = fields }
    local pre = Codec.Encode({ type = typ, ch = sch.ch, ep = 1, seq = 0, ack = 0, sid = env.sid, f = fields })
    if not pre then return false end
    local st, why = self.link:Stamp(env, self.clock())
    if not st then self.stats[why] = (self.stats[why] or 0) + 1; return false end
    self.stats.tx = self.stats.tx + 1
    self.transport:Send(self.peerId, Codec.Encode(env))
    return true
end

function Client:Poll()
    for _, ev in ipairs(self.transport:Poll()) do
        local leaving = self.leaving
        if leaving and ev.peerId == leaving.peerId and ev.kind ~= "peer_connected" then
            if ev.kind == "peer_disconnected" then leaving.closed = true
            elseif ev.kind == "message" and self.link then
                local env = Codec.Decode(ev.data)
                if env then self.link:Receive(env) end
            end
        elseif ev.kind == "peer_connected" then
            self.peerId = ev.peerId
            self.link = Link.new({ epoch = math.floor(self.rng() * 2147483646) + 1, window = self.cfg.WINDOW })
            self.lastRx, self.lastHb = self.clock(), self.clock()
            self:_setState("awaiting_info")
        elseif ev.kind == "peer_disconnected" and ev.peerId == self.peerId then
            if self.state ~= "rejected" and self.state ~= "kicked" then self:_setState("disconnected", ev.reason or "transport_closed") end
        elseif ev.kind == "message" and ev.peerId == self.peerId then
            self:_onMessage(ev.data)
        end
    end
    self:_tickLeaving()
end

function Client:_onMessage(data)
    self.stats.rx = self.stats.rx + 1
    local env, err = Codec.Decode(data)
    if not env then self.stats.decode_errors[err] = (self.stats.decode_errors[err] or 0) + 1; return end
    if Messages.Schema[env.type].dir == "C2H" then self.stats.wrong_direction = self.stats.wrong_direction + 1; return end
    if self.sid == nil then
        if env.type ~= "SESSION_INFO" then return end      -- the first host message must be SESSION_INFO
        if self.expectedHandoverSession and env.sid~=self.expectedHandoverSession then
            self.stats.bad_sid=self.stats.bad_sid+1;return
        end
        self.sid = env.sid
    elseif env.sid ~= self.sid then
        self.stats.bad_sid = self.stats.bad_sid + 1
        return
    end
    local accept, verdict = self.link:Receive(env)
    if verdict ~= "ok" then self.stats[verdict] = (self.stats[verdict] or 0) + 1 end
    if not accept then return end
    self.lastRx = self.clock()
    local h = Client.handlers[env.type]
    if h then h(self, env.f) end
end

Client.handlers = {}
-- This publication feeds the native read-only manifest ledger. It grants no
-- Lua catalog/inventory authority and never changes the client's selection.
function Client.handlers.ACCEPTED_SELECTION(self,f) end
function Client.handlers.STEAM_AUTHORITY_PROOF(self,f)
    if (self.state~='joining' and self.state~='rejoining' and self.state~='joined') or not self.transport.PeerIdentity then return end
    local peer=self.transport:PeerIdentity(self.peerId)
    if not peer or peer.key~=f.hostKey or f.hostKey~=self.authenticatedHostKey or f.term<1 or f.term>0xffffffff
        or type(f.proofNonce)~='string' or #f.proofNonce~=32 or not f.proofNonce:match('^[0-9a-f]+$')
        or (self.state=='joined' and f.term~=(self.authenticatedAuthorityTerm or self.expectedAuthorityTerm or self.authorityTerm or 1))
        or (self.expectedAuthorityTerm and f.term~=self.expectedAuthorityTerm) then
        self.transport:Close(self.peerId)
        return self:_setState('disconnected','authority_term_or_identity_mismatch')
    end
    self.authenticatedAuthorityTerm=f.term;self.authorityTerm=f.term;self.transport.authorityTerm=f.term
    self.authorityProofNonce=f.proofNonce
    self:_send('STEAM_AUTHORITY_ACK',{hostKey=f.hostKey,term=f.term,proofNonce=f.proofNonce})
end

function Client.handlers.SESSION_INFO(self, f)
    self.hostInfo = f
    -- COMPATIBILITY GATE: before authentication, before JOIN, before any lobby state is accepted. A mismatch ends the attempt here.
    local res = Compat.Evaluate({ requiredMod = f.requiredMod, requiredVersion = f.modVer, protocol = f.protocol, gameVer = f.gameVer }, self.localInfo)
    self.compat = res
    if not res.ok then
        self:_log("compatibility check FAILED: %s (host requires %s %s protocol %s; installed %s protocol %s)", res.reason, tostring(f.requiredMod), tostring(f.modVer), tostring(f.protocol), tostring(self.localInfo.modVer), tostring(self.localInfo.protocol))
        self:_setState("rejected", res.reason)
        self.transport:Close(self.peerId)
        return
    end
    self:_log("compatibility check passed: %s %s protocol %s", tostring(f.requiredMod), tostring(f.modVer), tostring(f.protocol))
    if f.mode ~= self.cfg.MODE then
        self:_setState("rejected", "mode_mismatch")
        self.transport:Close(self.peerId)
        return
    end
    if self.needsAuth then return self:_beginAuth() end
    self:_sendJoin()
end

function Client:_sendJoin()
    if self.resume and self.resume.key == self.identity.key then
        self:_setState("rejoining")
        self:_send("REJOIN_REQ", { key = self.identity.key, token = self.resume.token, claimSlot = self.resume.slot or 0,
            claimColor = self.resume.color or "", modVer = Config.MOD_VERSION, gameVer = self.gameVer })
    else
        self:_setState("joining")
        self:_send(self.wantWait and "WAIT_REQ" or "JOIN_REQ", { key = self.identity.key, name = self.name, modVer = Config.MOD_VERSION,
            gameVer = self.gameVer, reqColor = self.reqColor, rank = self.wantWait and (self.waitRank or 0) or nil })
    end
end


------------------------------------------------------------------ authentication (PHASE2 12.18)
local function authReject(self, reason)
    self:_setState("rejected", reason)
    self.transport:Close(self.peerId)
end

function Client:_beginAuth()
    if not self.authProvider then return authReject(self, "auth_unavailable") end
    local ok, why = self.authProvider:Status()
    if not ok then return authReject(self, Auth.WireReason(why or "steam_unavailable")) end
    self.auth = { phase = "hello", deadline = self.clock() + self.cfg.AUTH_TIMEOUT }
    self:_setState("authenticating", "hello")
    self:_send("AUTH_HELLO", { key = self.identity.key, scheme = self.cfg.AUTH_MODE })
end

function Client.handlers.AUTH_CHALLENGE(self, f)
    if self.state ~= "authenticating" or not self.auth or self.auth.phase ~= "hello" then return end
    if f.scheme ~= self.cfg.AUTH_MODE then return authReject(self, "auth_mismatch") end
    if self.expectedHandoverHost and f.hostKey~=self.expectedHandoverHost then return authReject(self,'handover_host_mismatch') end
    local hid = Identity.Parse(f.hostKey)
    if not hid or not self.policy:Check(hid) or hid.kind ~= self.cfg.AUTH_MODE or f.nonce == "" then return authReject(self, "bad_challenge") end
    if self.transport.PeerIdentity then
        local attributed=self.transport:PeerIdentity(self.peerId)
        if not attributed or attributed.key~=hid.key then return authReject(self,'identity_mismatch') end
    end
    local handle, why = self.authProvider:TicketBegin(hid.key)
    if not handle then return authReject(self, "ticket_failed:" .. tostring(why)) end
    self.authenticatedHostKey=hid.key
    self.auth.handle, self.auth.nonce, self.auth.phase = handle, f.nonce, "ticketing"
end

function Client:_submitTicket(size)
    local cb = math.min(self.cfg.AUTH_CHUNK_BYTES, Auth.MAX_CHUNK_BYTES)
    local total = (size + cb - 1) // cb
    if total < 1 or total > Auth.MAX_CHUNKS then return authReject(self, "ticket_too_large") end
    for i = 1, total do
        local data = self.authProvider:TicketChunk(self.auth.handle, (i - 1) * cb, cb)
        if not data or not self:_send("AUTH_TICKET", { nonce = self.auth.nonce, idx = i, total = total, data = data }) then
            return authReject(self, "ticket_send_failed")
        end
    end
    self.auth.phase = "submitted"
    self:_setState("authenticating", "submitted")
end

function Client.handlers.AUTH_RESULT(self, f)
    local early = self.state == "awaiting_info" or self.state == "authenticating" or self.state == "joining" or self.state == "rejoining"
    if not early then return end
    if not f.ok then return authReject(self, f.reason ~= "" and f.reason or "auth_failed") end
    if self.state ~= "authenticating" or f.key ~= self.identity.key then return end       -- a success is only meaningful for me, mid-exchange
    if self.cfg.AUTH_MODE=='steam' and not self.auth.hostValidated then return authReject(self,'host_not_validated') end
    self:_sendJoin()
end

function Client.handlers.AUTH_HOST_TICKET(self,f)
    local a=self.auth
    if self.cfg.AUTH_MODE~='steam' or self.state~='authenticating' or not a or a.phase~='submitted' then return end
    if f.nonce~=a.nonce or f.total<1 or f.total>Auth.MAX_CHUNKS or f.idx<1 or f.idx>f.total
        or not Auth.IsHex(f.data) or #f.data==0 or #f.data>Auth.MAX_CHUNK_BYTES*2 then return authReject(self,'bad_host_ticket') end
    if a.hostTotal and a.hostTotal~=f.total then return authReject(self,'bad_host_ticket') end
    a.hostChunks=a.hostChunks or {};a.hostTotal=f.total
    local old=a.hostChunks[f.idx]
    if old then if old~=f.data then return authReject(self,'bad_host_ticket') end;return end
    a.hostBytes=(a.hostBytes or 0)+#f.data//2
    if a.hostBytes>self.cfg.AUTH_MAX_TICKET_BYTES then return authReject(self,'host_ticket_too_large') end
    a.hostChunks[f.idx]=f.data;a.hostHave=(a.hostHave or 0)+1
    if a.hostHave==f.total then
        a.hostSessionKey=self.authenticatedHostKey
        local ok,why=self.authProvider:Verify(a.hostSessionKey,table.concat(a.hostChunks,''),self.identity.key)
        a.hostChunks=nil
        if not ok then a.hostSessionKey=nil;return authReject(self,Auth.WireReason(why)) end
        if type(why)=='table' and math.type(why.retainedEpoch)=='integer' and why.retainedEpoch>0 then
            a.hostValidated=true;a.nativeHostEpoch=why.retainedEpoch
            self:_send('AUTH_HOST_ACK',{nonce=a.nonce,hostKey=a.hostSessionKey,ok=true,reason=''})
        else a.hostVerifying=true end
    end
end

function Client:_pollHostAuth()
    if self.cfg.AUTH_MODE~='steam' or not self.auth or not self.authProvider then return end
    local a=self.auth
    for _,ev in ipairs(self.authProvider:Poll()) do
        if ev.kind=='validate' and ev.key==a.hostSessionKey then
            if not ev.ok then return authReject(self,Auth.WireReason(ev.reason)) end
            if a.hostVerifying then
                a.hostVerifying=false;a.hostValidated=true
                self:_send('AUTH_HOST_ACK',{nonce=a.nonce,hostKey=a.hostSessionKey,ok=true,reason=''})
            end
        end
    end
end

-- called from Tick while authenticating
function Client:_tickAuth(now)
    self:_pollHostAuth()
    if self.state~="authenticating" then return end
    if now > self.auth.deadline then return authReject(self, "auth_timeout") end
    if self.auth.phase == "ticketing" then
        local st, info = self.authProvider:TicketState(self.auth.handle)
        if st == "failed" then return authReject(self, "ticket_failed:" .. tostring(info)) end
        if st == "ready" then self:_submitTicket(info) end
    end
end

local function accepted(self, f, token)
    if f.key ~= self.identity.key then return end        -- not about me
    self.me = { slot = f.slot, color = f.color, token = token or (self.me and self.me.token) or (self.resume and self.resume.token), assignRev = 0 }
    self.resume = { key = f.key, token = self.me.token, slot = f.slot, color = f.color }
    self:_setState("joined")
end

function Client.handlers.JOIN_ACCEPT(self, f) if self.state == "joining" or self.state == "waiting" then accepted(self, f, f.token) end end
-- D52: the host keeps this player waiting for the next game (connected, outside the roster)
function Client.handlers.WAIT_ACCEPT(self, f) if self.state == "joining" and f.key == self.identity.key then self:_setState("waiting") end end
-- D52: the host changes; the app follows once this connection ends (App:_followWaitMove)
function Client.handlers.WAIT_MOVE(self, f)
    if self.state ~= "waiting" then return end
    self.waitMove = { hostKey = f.hostKey, term = f.term, rank = f.rank, session = self.sid }
    self:_log("waiting: the session moves to %s (rank %d)", tostring(f.hostKey), f.rank)
end
function Client.handlers.REJOIN_ACCEPT(self, f) if self.state == "rejoining" then accepted(self, f, nil) end end

local function rejected(self, f)
    if self.state ~= "joining" and self.state ~= "rejoining" and self.state ~= "waiting" then return end
    self:_setState("rejected", f.reason)
    self.transport:Close(self.peerId)
end
Client.handlers.JOIN_REJECT, Client.handlers.REJOIN_REJECT = rejected, rejected

function Client.handlers.ROSTER(self, f)
    if self.mirror and f.rev <= self.mirror.rev then return end       -- stale revision (reliable delivery is not ordered)
    self.mirror = { rev = f.rev, phase = f.phase, maxPlayers = f.maxPlayers, currentPlayers = f.currentPlayers, players = f.players }
    for _, p in ipairs(f.players) do
        if p.key == self.identity.key and self.me then
            self.me.slot, self.me.color = p.slot, p.color
            if self.resume then self.resume.slot, self.resume.color = p.slot, p.color end
        end
    end
end
for _,kind in ipairs{'ROSTER','LOBBY_STATE'}do
    Client.handlers[kind..'_PAGE']=function(self,f)
        if self.state~='joined' and not (self.state=='waiting' and kind=='ROSTER') then return end
        self.snapshotPages=self.snapshotPages or {}
        local out=require('gmp_snapshot_pages').Receive(self.snapshotPages,kind,f)
        if out then Client.handlers[kind](self,out)end
    end
end

function Client.handlers.ASSIGN(self, f)
    if f.key ~= self.identity.key or not self.me or f.rev <= self.me.assignRev then return end
    self.me.slot, self.me.color, self.me.assignRev = f.slot, f.color, f.rev
    if self.resume then self.resume.slot, self.resume.color = f.slot, f.color end
end

function Client.handlers.REQ_DENIED(self, f) self.lastDenied = { ofType = f.ofType, reason = f.reason } end

function Client.handlers.KICK(self, f)
    self.resume = nil
    self:_setState("kicked", f.reason)
    self.transport:Close(self.peerId)
end

-- Lobby mirror. Accepted only from the host over a joined session; stale revisions are ignored (reliable delivery is not ordered).
function Client.handlers.LOBBY_STATE(self, f)
    if self.state ~= "joined" then return end
    if self.lobby and f.lrev <= self.lobby.lrev then return end
    self.lobby = { sessionPolicy=self.sessionPolicy,lrev = f.lrev, state = f.state, allowRejoin = f.allowRejoin, maxPlayers = f.maxPlayers, players = f.players }
end

function Client.handlers.CHAT(self, f)
    if self.state ~= "joined" or f.seq <= self.chatSeq then return end
    self.chatSeq = f.seq
    self.chat[#self.chat + 1] = { seq = f.seq, key = f.key, name = f.name, text = f.text }
    if #self.chat > Config.LOBBY.CHAT_HISTORY then table.remove(self.chat, 1) end
end


function Client.handlers.HEARTBEAT(self, f) end   -- liveness is tracked through lastRx

-- Reserved (C0) stubs for Track S: authority-prep state, attack results and host-credited run stats
-- (gmp_messages.lua). They only record receipt until the owning S unit implements them.
local function reserved(self, typ)
    self.reservedReceived = self.reservedReceived or {}
    self.reservedReceived[typ] = (self.reservedReceived[typ] or 0) + 1
end
-- S1 (PLAN_WORLD_ENTRY.md 3.11): the host's prep state for the current run context. waiting = set of slots the host
-- still waits for. Invalid states are counted (receipt) but not stored. The run sync (gmp_run_sync.lua) reads it and
-- answers with ReportAuthorityPrep.
local PREP_PHASES = { process = true, island = true }
local PREP_KEY_BYTES, PREP_REASON_BYTES = 200, 120
local function prepKey(key) return type(key) == "string" and #key > 0 and #key <= PREP_KEY_BYTES end
function Client.handlers.AUTHORITY_PREP_STATE(self, f)
    reserved(self, "AUTHORITY_PREP_STATE")
    if not prepKey(f.key) or not PREP_PHASES[f.phase] or type(f.waiting) ~= "table" or #f.waiting > 4 then return end
    local waiting = {}
    for _, row in ipairs(f.waiting) do
        if type(row) ~= "table" or math.type(row.slot) ~= "integer" or row.slot < 1 or row.slot > 4 then return end
        waiting[row.slot] = true
    end
    self.authorityPrepState = { key = f.key, phase = f.phase, waiting = waiting }
end
function Client:AuthorityPrepState() return self.authorityPrepState end
function Client:ReportAuthorityPrep(key, phase, ok, reason)
    if self.state ~= "joined" or not prepKey(key) or not PREP_PHASES[phase] or type(ok) ~= "boolean" then return false end
    return self:_send("AUTHORITY_PREP", { key = key, phase = phase, ok = ok, reason = tostring(reason or ""):sub(1, PREP_REASON_BYTES) }) == true
end
-- S5: the host's answer to one ATTACK_INTENT (ok = the host resolved and delivered the hit). Counted only.
function Client.handlers.ATTACK_RESULT(self, f)
    reserved(self, "ATTACK_RESULT")
    if math.type(f.sequence) ~= "integer" or type(f.ok) ~= "boolean" then return end
    local r = self.attackResults or { accepted = 0, refused = 0 }
    self.attackResults = r
    if f.ok then r.accepted = r.accepted + 1 else r.refused = r.refused + 1 end
    r.last = { sequence = f.sequence, ok = f.ok }
    -- every result, for the client attack source's round-trip measure (bounded)
    self.attackResultQueue = self.attackResultQueue or {}
    if #self.attackResultQueue < 256 then self.attackResultQueue[#self.attackResultQueue + 1] = { sequence = f.sequence, ok = f.ok } end
end
function Client:TakeAttackResults()
    local list = self.attackResultQueue or {}
    self.attackResultQueue = {}
    return list
end
-- CLIENT_UPGRADE_DAMAGE: send this client's weapon upgrade state (numbers) with a rising revision. Refused (false)
-- when not joined or when a value is outside Messages.PlayerStats; the host validates again.
function Client:SendPlayerStats(stats)
    if self.state ~= "joined" or type(stats) ~= "table" then return false end
    local f = { revision = (self.playerStatsRevision or 0) + 1 }
    for _, name in ipairs({ "damageMulti", "aoeMulti", "bonusDamage" }) do
        if type(stats[name]) ~= "number" then return false end
        f[name] = string.format("%.17g", stats[name])
    end
    if f.revision > 2147483647 or not Messages.ValidatePlayerStats(f) then return false end
    if not self:_send("PLAYER_STATS", f) then return false end
    self.playerStatsRevision = f.revision
    return true
end
-- CLIENT_DAMAGE: host contact hits for this client (Messages.ValidateClientHit, rising sequence). Ignored (counted)
-- until the run sync enables the intake; TakeClientHits() hands over the pending ones once.
function Client:EnableClientHits() self.clientHits = self.clientHits or {}; return self.clientHits end
function Client:TakeClientHits()
    if not self.clientHits then return nil end
    local list = self.clientHits; self.clientHits = {}
    return list
end
function Client.handlers.CLIENT_HIT(self, f)
    if self.state ~= "joined" then return end
    if not self.clientHits then self.stats.client_hit_ignored = (self.stats.client_hit_ignored or 0) + 1; return end
    local hit = Messages.ValidateClientHit(f)
    if not hit or hit.sequence <= (self.clientHitSequence or 0) or #self.clientHits >= 64 then
        self.stats.client_hit_refused = (self.stats.client_hit_refused or 0) + 1; return
    end
    self.clientHitSequence = hit.sequence
    self.clientHits[#self.clientHits + 1] = hit
end
-- SHARED_LIVES (D32): the host's lives state (newest revision per context), revives for this client, and this client's
-- down report. Ignored (counted) until the run sync enables them.
function Client:EnableLives() self.livesEnabled = true; self.pendingRevives = self.pendingRevives or {} end
function Client:LivesState() return self.livesState end
function Client:TakeRevives()
    local list = self.pendingRevives or {}
    if self.pendingRevives then self.pendingRevives = {} end
    return list
end
function Client:SendPlayerDown(context)
    if self.state ~= "joined" then return false end
    local f = { context = context, sequence = (self.playerDownSequence or 0) + 1 }
    if not Messages.ValidatePlayerDown(f) or not self:_send("PLAYER_DOWN", f) then return false end
    self.playerDownSequence = f.sequence
    return true
end
function Client.handlers.LIVES_STATE(self, f)
    if self.state ~= "joined" then return end
    if not self.livesEnabled then self.stats.lives_state_ignored = (self.stats.lives_state_ignored or 0) + 1; return end
    local state = Messages.ValidateLivesState(f)
    local last = self.livesState
    if not state or (last and last.context == state.context and state.revision < last.revision) then
        self.stats.lives_state_refused = (self.stats.lives_state_refused or 0) + 1; return
    end
    self.livesState = state
end
function Client.handlers.PLAYER_REVIVE(self, f)
    if self.state ~= "joined" or not self.livesEnabled then return end
    local revive = Messages.ValidatePlayerRevive(f)
    if not revive or revive.sequence <= (self.playerReviveSequence or 0) then
        self.stats.player_revive_refused = (self.stats.player_revive_refused or 0) + 1; return
    end
    self.playerReviveSequence = revive.sequence
    self.pendingRevives[#self.pendingRevives + 1] = revive
end
-- D45 hook (Coder C): shared XP / pickup dev messages (gmp_pickups_sync.lua, flag SHARED_XP). Host messages are
-- queued and drained by the run sync, which validates them; counted and dropped until enabled.
Client.PICKUP_INTAKE_CAP = 512
function Client:EnablePickups() self.pickupIntake = self.pickupIntake or {}; return self.pickupIntake end
function Client:DrainPickups()
    local list = self.pickupIntake or {}
    if self.pickupIntake then self.pickupIntake = {} end
    return list
end
function Client:SendPickups(typ, fields)
    if self.state ~= "joined" then return false end
    return self:_send(typ, fields) == true
end
for _, typ in ipairs({ 'PICKUP_DELTA', 'PICKUP_RESULT', 'PICKUP_GRANT', 'XP_STATE', 'REWARD_SCREEN', 'ENEMY_FX' }) do
    Client.handlers[typ] = function(self, f)
        if self.state ~= "joined" then return end
        local intake = self.pickupIntake
        if not intake or #intake >= Client.PICKUP_INTAKE_CAP then self.stats.pickup_dropped = (self.stats.pickup_dropped or 0) + 1; return end
        intake[#intake + 1] = { type = typ, f = f }
    end
end
-- end D45 hook
function Client:AttackResults()
    local r = self.attackResults or { accepted = 0, refused = 0 }
    return { accepted = r.accepted, refused = r.refused, last = r.last and { sequence = r.last.sequence, ok = r.last.ok } or nil }
end
-- S8 (Track W): receipt is recorded; each part goes to the W9 end screen through onRunStats (gmp_app.lua sets it).
function Client.handlers.RUN_STATS(self, f)
    reserved(self, "RUN_STATS")
    if type(self.onRunStats) == "function" then
        local ok, why = pcall(self.onRunStats, f)
        if not ok then self:_log("run stats hook failed: %s", tostring(why):sub(1, 200)) end
    end
end

-- presence (M3.1; inert unless EnablePresence was called)
function Client:EnablePause()
    if not self.sharedPause then self.sharedPause=require('gmp_pause').Client.new() end
    return self.sharedPause
end
function Client:RequestPause(paused)
    if not self.sharedPause or self.state~='joined' or type(paused)~='boolean' then return false end
    return self:_send('PAUSE_REQ',{paused=paused})
end
function Client.handlers.PAUSE_STATE(self,f)
    if self.sharedPause and self.state=='joined' then self.sharedPause:Apply(f) end
end
function Client.handlers.DEV_CYCLE_READY(self,f)
    local islands=self.islands;local stream=self.checkpointStream
    if self.cfg.MODE~='dev' or not self.devCycleEnabled or self.state~='joined' or not islands or not stream
        or f.term~=(self.authorityTerm or 1) or f.epoch~=islands.epoch or f.island~=islands.island
        or not self.sharedPause or f.revision~=self.sharedPause.revision
        or self.checkpointSession~=self.sid or stream.sequence~=f.sequence or stream.hash~=f.digest then return end
    self.devCycleReady={term=f.term,epoch=f.epoch,island=f.island,revision=f.revision,sequence=f.sequence,digest=f.digest}
end
function Client.handlers.DEV_CYCLE_ABORT(self,f)
    local islands=self.islands
    if self.cfg.MODE~='dev' or not self.devCycleEnabled or self.state~='joined' or not islands
        or f.term~=(self.authorityTerm or 1) or f.epoch~=islands.epoch or f.island~=islands.island then return end
    self.devCycleAbort=tostring(f.reason):sub(1,300)
end
function Client.handlers.DEV_CYCLE_START(self,f)
    local ready=self.devCycleReady
    if self.cfg.MODE~='dev' or not self.devCycleEnabled or self.state~='joined' or not ready
        or not self.sharedPause or not self.sharedPause.paused or f.cycle<1 or f.cycle>4 or f.targetSlot<1 or f.targetSlot>4 then return end
    for _,name in ipairs{'term','epoch','island','revision','sequence','digest'}do if f[name]~=ready[name]then return end end
    if f.term~=(self.authorityTerm or 1) or f.revision~=self.sharedPause.revision then return end
    self.devCycleStart={term=f.term,epoch=f.epoch,island=f.island,revision=f.revision,sequence=f.sequence,digest=f.digest,cycle=f.cycle,targetSlot=f.targetSlot}
end
function Client:PauseApplied()
    local state=self.sharedPause
    if not state or state.revision==0 or self.state~='joined' then return false end
    return self:_send('PAUSE_ACK',{revision=state.revision,paused=state.paused})
end
function Client.handlers.CHECKPOINT_CHUNK(self,f)
    if self.state~='joined' or f.term~=(self.authorityTerm or 1) then return end
    if not self.checkpointStream or self.checkpointSession~=self.sid then
        self.checkpointStream=require('gmp_checkpoint_stream').new(f.term);self.checkpointSession=self.sid
    end
    local ok,why=self.checkpointStream:Receive(f,self.clock())
    if ok and (why=='applied' or why=='duplicate') then
        self.checkpointReceipt={term=f.term,sequence=f.sequence,digest=f.digest}
    end
end
-- Development key binding will call this only after native restore integration.
-- Identity is taken from the authenticated link, never from the request fields.
function Client:RequestForcedHandover()
    local stream=self.checkpointStream
    if self.cfg.MODE~='dev' or self.state~='joined' or self.checkpointSession~=self.sid
        or not stream or stream.sequence<1 or not stream.hash then return false,'checkpoint_unavailable' end
    return self:_send('HANDOVER_FORCE_REQ',{term=stream.term,sequence=stream.sequence,digest=stream.hash})
end
function Client:EnableForcedHandover(options)
    if self.cfg.MODE~='dev' or type(options)~='table' or type(options.prepare)~='function' then return false end
    self.handoverOptions=options;return true
end
local function receiveStage(self,f,normal)
    local stream=self.checkpointStream
    local productionNormal=normal and self.cfg.MODE=='production' and self.cfg.AUTH_MODE=='steam'
        and self.departureOptions and self.departureOptions.productionNative==true
    if (self.cfg.MODE~='dev' and not productionNormal) or self.state~='joined' or not stream or self.checkpointSession~=self.sid
        or f.term~=(self.authorityTerm or 1)+1 or f.sequence~=stream.sequence or f.digest~=stream.hash
        or type(f.nonce)~='string' or #f.nonce~=32 or not f.nonce:match('^%x+$') then return end
    if self.handoverStage then
        local old=self.handoverStage.commit
        if old.term==f.term and old.hostKey==f.hostKey and old.sequence==f.sequence
            and old.formerHost==f.formerHost and old.nonce==f.nonce then
            self.handoverStageReceipt={term=f.term,sequence=f.sequence,digest=f.digest,ready=self.handoverStage.ready}
        end
        return
    end
    if not self.sharedPause or not self.sharedPause.paused or not self.sharedPause.locked then return end
    local state=stream:Snapshot();if not state then return end
    local former,candidate,localPlayer=false,false,false
    for _,player in ipairs(state.players) do
        if player.role=='host' and player.key==f.formerHost then former=true end
        if player.key==f.hostKey and player.role=='client' and player.conn=='connected' then candidate=true end
        if player.key==self.identity.key and player.conn=='connected' then localPlayer=true end
        player.role=player.key==f.hostKey and 'host' or 'client'
    end
    if not former or not candidate or not localPlayer then return end
    local valid,checkpoint=require('gmp_handover').Validate(state);if not valid then return end
    if normal then
        local offer=self.departureOffer
        if not self.departureOptions or not offer or offer.winner~=f.hostKey or offer.phase~='selected'
            or offer.coordinator~=f.formerHost then return end
    end
    local commit={session=self.sid,term=f.term,sequence=f.sequence,hostKey=f.hostKey,formerHost=f.formerHost,
        forced=not normal,kind=normal and 'graceful' or nil,nonce=f.nonce,digest=f.digest}
    local ok,ready=false,false
    local options=normal and self.departureOptions or self.handoverOptions
    if options and type(options.prepare)=='function' then ok,ready=pcall(options.prepare,checkpoint,commit) end
    self.handoverStage={commit=commit,state=checkpoint,ready=ok and ready==true}
    self.handoverStageReceipt={term=f.term,sequence=f.sequence,digest=f.digest,ready=self.handoverStage.ready}
    -- Preparation is not restoration: no role/identity/native state changes here.
end
function Client.handlers.HANDOVER_STAGE(self,f) return receiveStage(self,f,false) end
function Client.handlers.DEPARTURE_STAGE(self,f) return receiveStage(self,f,true) end

function Client:EnablePresence(pcfg)
    if self.presence then return self.presence end
    self.presence = require("gmp_presence").ClientPresence.new({ cfg = pcfg, selfKey = function() return self.identity.key end, log = function(m) self:_log("%s", m) end })
    return self.presence
end

function Client.handlers.WORLD_STATE(self, f)
    if not self.presence or self.state ~= "joined" then return end
    self.presence:Apply(f, self.clock())
end

function Client.handlers.WORLD_STATE_VISUAL(self,f)
    if not self.presence or not self.presence.cfg.animation or self.state~='joined' then return end
    self.presence:Apply(f,self.clock())
end

function Client.handlers.WORLD_AVATAR_STATE(self,f)
    if not self.presence or not self.presence.cfg.appearance or self.state~='joined' then return end
    self.presence:Apply(f,self.clock())
end

-- One PLAYER_STATE (unreliable). Only while joined; the host attributes it to our authenticated key.
function Client:SendPlayerState(s)
    if not self.presence or self.state ~= "joined" or type(s) ~= "table" then return false end
    local f={seg=s.seg,x=s.x,y=s.y,z=s.z,dead=s.dead}
    if self.presence.cfg.animation and s.pose then
        for k,v in pairs(s.pose) do f[k]=v end
        if self.presence.cfg.appearance then f.model=f.model or 0;return self:_send('PLAYER_AVATAR_STATE',f) end
        return self:_send('PLAYER_STATE_VISUAL',f)
    end
    return self:_send('PLAYER_STATE',f)
end

function Client:Tick()
    if self.enemyDelta then self:_enemyViewLog() end
    self:SendNativeStateChunks()
    if self.handoverStageReceipt and self.state=='joined' then
        if self:_send('HANDOVER_STAGE_ACK',self.handoverStageReceipt) then self.handoverStageReceipt=nil end
    end
    if self.checkpointReceipt and self.state=='joined' then
        if self:_send('CHECKPOINT_ACK',self.checkpointReceipt) then self.checkpointReceipt=nil end
    end
    if self.state=="joined" then self:_pollHostAuth() end
    local now = self.clock()
    if self.state == "connecting" and self.connectStart and now - self.connectStart > self.cfg.CONNECT_TIMEOUT then
        self:_setState("disconnected", "connect_timeout")
        self.transport:Close(self.peerId)
        return
    end
    if not self.link or self.state == "idle" or self.state == "disconnected" or self.state == "rejected" or self.state == "kicked" then return end
    if now - self.lastRx > self.cfg.PEER_TIMEOUT then
        self:_setState("disconnected", "host_timeout")
        self.transport:Close(self.peerId)
        return
    end
    if self.state == "authenticating" and self.auth then
        self:_tickAuth(now)
        if self.state ~= "authenticating" then return end
    end
    if now - self.lastHb >= self.cfg.HEARTBEAT_INTERVAL and self.sid then
        self.lastHb = now
        self:_send("HEARTBEAT", { rosterRev = self.mirror and self.mirror.rev or 0 })
    end
    local due, failed = self.link:Due(now, self.cfg.RESEND_INTERVAL, self.cfg.MAX_RESENDS)
    for _, env in ipairs(due) do
        local s = Codec.Encode(env)
        if s then self.transport:Send(self.peerId, s) end
    end
    if failed > 0 then self:_setState("disconnected", "resend_exhausted"); self.transport:Close(self.peerId) end
end

------------------------------------------------------------------ requests (NOT authoritative changes)
function Client:RequestColor(color)
    if self.state ~= "joined" then return false end
    return self:_send("COLOR_REQ", { color = color })
end

-- Host packets reach this handler only after session/direction/link validation.
function Client:EnableEnemies()
    if not self.enemyStream then self.enemyStream=require('gmp_enemy_stream').new() end
    return self.enemyStream
end
local function receiveEnemySnapshot(self,f,version)
    if self.state~='joined' or not self.enemyStream then return end
    local ok,why=self.enemyStream:Receive(f,version)
    if not ok then
        self.stats.enemy_rejected=(self.stats.enemy_rejected or 0)+1
        self.enemyError=why
    end
end
function Client.handlers.ENEMY_SNAPSHOT(self,f) return receiveEnemySnapshot(self,f,1) end
function Client.handlers.ENEMY_SNAPSHOT_V2(self,f) return receiveEnemySnapshot(self,f,2) end
function Client:EnableOutcomes(adapter)
    if type(adapter)~='table' or type(adapter.authorize)~='function' or type(adapter.apply)~='function' or type(adapter.hold)~='function'then return false,'native_outcome_backend_missing'end
    self.outcomeAdapter=adapter;self.outcomeStream=require('gmp_outcome_stream').new(adapter);return true
end
function Client.handlers.OUTCOME_V1(self,f)
    if self.state~='joined' or not self.outcomeStream or f.term~=(self.authorityTerm or 1)then return end
    local ok,why,ack=self.outcomeStream:Receive(f,self.sid)
    if not ok then
        self.outcomeError=why
        if self.outcomeStream.failed then
            local held,verified=pcall(self.outcomeAdapter.hold,why)
            self.outcomePhysicalHold=held and verified==true
        end
        return
    end
    if ack then self:_send('OUTCOME_ACK',ack)end
end
-- Enemy delta stream (dev, gmp_enemy_delta.lua): accepted whenever it arrives (the host decides to use it); once it
-- has an epoch, EnemySnapshot() is its interpolated view. Once a second (when read):
-- "ENEMYVIEW rx hz=<motion packets/s> delay_ms=<buffer> enemies=<n> refused=<n>".
function Client:_enemyDelta()
    if not self.enemyDelta then self.enemyDelta = require('gmp_enemy_delta').Client.new() end
    return self.enemyDelta
end
function Client.handlers.ENEMY_LIFE(self, f)
    if self.state ~= 'joined' then return end
    if not self:_enemyDelta():Life(f, self.clock()) then self.stats.enemy_life_refused = (self.stats.enemy_life_refused or 0) + 1 end
end
function Client.handlers.ENEMY_MOTION(self, f)
    if self.state ~= 'joined' then return end
    self:_enemyDelta():Motion(f, self.clock())
end
function Client:_enemyViewLog()
    local delta = self.enemyDelta
    if not delta or delta.epoch == 0 then return end
    local now = self.clock()
    if not self.enemyViewLoggedAt or now - self.enemyViewLoggedAt >= 1 then
        if self.enemyViewLoggedAt then
            local s = delta:Stats()
            self:_log('ENEMYVIEW rx hz=%.1f delay_ms=%d enemies=%d alive=%d refused=%d unknown_rows=%d corr_cm=%.1f snaps=%d', s.rxHz, s.delayMs, s.enemies,
                s.alive, s.refused, s.unknownRows or 0, s.corrCm or 0, s.snaps or 0)
        end
        self.enemyViewLoggedAt = now
    end
end
-- D43: the host's boss/unique looks, newest per row lifetime (bounded: a full table refuses new ids).
Client.ACTOR_INFO_MAX = 64
function Client.handlers.ACTOR_INFO(self, f)
    if self.state ~= 'joined' then return end
    local info = Messages.ValidateActorInfo(f)
    if not info then self.stats.actor_info_refused = (self.stats.actor_info_refused or 0) + 1; return end
    self.actorInfo = self.actorInfo or {}
    if not self.actorInfo[info.id] then
        local n = 0; for _ in pairs(self.actorInfo) do n = n + 1 end
        if n >= Client.ACTOR_INFO_MAX then self.stats.actor_info_dropped = (self.stats.actor_info_dropped or 0) + 1; return end
    end
    self.actorInfo[info.id] = info
end
function Client:ActorInfo() return self.actorInfo or {} end
-- Test 10 (S): the host's newest portal spots (PORTAL_STATE) for gmp_portal_mirror.lua.
function Client.handlers.PORTAL_STATE(self, f)
    local state = Messages.ValidatePortalState(f)
    if state then self.portalState = state end
end
function Client:PortalState() return self.portalState end
-- players (optional): the positions the enemies chase, for the view's visual-only prediction (gmp_enemy_delta.lua).
function Client:EnemySnapshot(players)
    local delta = self.enemyDelta
    if delta and delta.epoch > 0 then return delta:View(self.clock(), players) end
    return self.enemyStream and self.enemyStream:Snapshot() or nil
end

function Client:QueueNativeState(native)
    local islands=self.islands
    if self.cfg.MODE~='dev' or self.state~='joined' or not islands or islands.phase~='playing' then return false,'not_playing' end
    if self.nativeStateQueue then return false,'transfer_busy' end
    local sequence=(self.nativeStateSequence or 0)+1
    local packets,why=require('gmp_peer_native_state').Packets(self.identity.key,islands.epoch,islands.island,
        native,self.authorityTerm or 1,sequence,self.sid,self.sharedPause and self.sharedPause.revision or 0)
    if not packets then return false,why end
    self.nativeStateSequence=sequence
    self.nativeStateQueue={packets=packets,cursor=1,epoch=islands.epoch,island=islands.island,term=self.authorityTerm or 1}
    return true
end
function Client:SendNativeStateChunks()
    local queue=self.nativeStateQueue;if not queue then return end
    local islands=self.islands
    if self.state~='joined' or not islands or islands.phase~='playing' or queue.epoch~=islands.epoch
        or queue.island~=islands.island or queue.term~=(self.authorityTerm or 1) then self.nativeStateQueue=nil;return end
    for _=1,4 do
        local packet=queue.packets[queue.cursor]
        if not packet then self.nativeStateQueue=nil;return end
        if not self:_send('PLAYER_STATE_CHUNK',packet) then return end
        queue.cursor=queue.cursor+1
    end
end
function Client:SendChat(text) if self.state ~= "joined" or type(text) ~= "string" then return false end return self:_send("CHAT_REQ", { text = text }) end
function Client:LobbyMirror() return self.lobby end
function Client:ChatLog() return self.chat end

-- D20: the connection closes only after the host has the LEAVE (its ack arrives, or the host closes it), or after
-- LEAVE_LINGER seconds, so a voluntary leave can never reach the host as a transport close (which holds the slot).
Client.LEAVE_LINGER = 2.0
function Client:Leave(reason)
    local sent = self.link and (self.state == "joined" or self.state == "waiting") and self:_send("LEAVE", { reason = reason or "quit" })
    -- resume data is KEPT: a leave during a run keeps the host-side reservation (slot/colour), and the player may come back.
    -- The host decides; a lobby leave simply leaves nothing to resume (REJOIN_REJECT no_reservation).
    if sent and self.peerId then
        self.leaving = { peerId = self.peerId, deadline = self.clock() + Client.LEAVE_LINGER }
    elseif self.peerId then self.transport:Close(self.peerId) end
    self:_setState("disconnected", "left")
end
-- While leaving: only the link's acks are read; the connection closes once the LEAVE is acknowledged or the time is up.
function Client:_tickLeaving()
    local l = self.leaving
    if not l then return end
    -- keep resending the LEAVE (the state is no longer joined, so Tick does not)
    if self.link and not l.closed then
        for _, env in ipairs((self.link:Due(self.clock(), self.cfg.RESEND_INTERVAL, self.cfg.MAX_RESENDS))) do
            local text = Codec.Encode(env); if text then self.transport:Send(l.peerId, text) end
        end
    end
    if l.closed or (self.link and self.link:Pending() == 0) or self.clock() >= l.deadline then
        if not l.closed then self.transport:Close(l.peerId) end
        self.leaving = nil
    end
end
function Client:EnableDeparture(options)
    if type(options)~='table' or type(options.paused)~='function' then return false,'departure_bindings_unavailable' end
    self.departureOptions=options;return true
end
function Client.handlers.DEPARTURE_STATE(self,f)
    local stream=self.checkpointStream
    if self.state~='joined' or f.term~=(self.authorityTerm or 1) or f.coordinator~=self.authenticatedHostKey
        or self.checkpointSession~=self.sid or not stream or f.sequence~=stream.sequence or f.digest~=stream.hash then return end
    if self.departureOffer and f.revision<self.departureOffer.revision then return end
    self.departureOffer=f
end
function Client:DepartureState()
    local f=self.departureOffer
    local stream=self.checkpointStream
    if self.state~='joined' or not f or not self.departureOptions or f.term~=(self.authorityTerm or 1)
        or f.coordinator~=self.authenticatedHostKey or self.checkpointSession~=self.sid or not stream
        or f.sequence~=stream.sequence or f.digest~=stream.hash then return nil end
    local ok,paused=pcall(self.departureOptions.paused)
    return {authenticated=true,active=f.active,paused=f.paused and ok and paused==true,sid=self.sid,
        term=f.term,revision=f.revision,me=self.identity.key,eligible=f.eligible,winner=f.winner~='' and f.winner or nil,
        receipt=f.request~='' and {request=f.request,accepted=f.accepted,reason=f.reason~='' and f.reason or nil} or nil,
        phase=f.phase,coordinator=f.coordinator}
end
function Client:ClaimDeparture(request)
    local state=self:DepartureState()
    if not state or not state.active or not state.paused or not state.eligible or state.winner
        or type(request)~='table' or request.key~=self.identity.key or request.sid~=self.sid
        or request.term~=state.term or request.revision~=state.revision then return false,'departure_claim_unavailable' end
    return self:_send('DEPARTURE_CLAIM',{term=request.term,revision=request.revision,request=request.request})
end

function Client:State() return self.state, self.reason end
function Client:Me() return self.me end
function Client:Roster() return self.mirror end
function Client:Display(opts) return self.mirror and require("gmp_roster").DisplayOrder(self.mirror.players, opts) or {} end
function Client:CurrentPlayers() return self.mirror and self.mirror.currentPlayers or 0 end

require('gmp_client_entry').Install(Client)
require('gmp_cheat_requests').Install(nil, Client)   -- D56 (Coder D): Client:RequestCheat (CHEAT_REQ)
return Client
