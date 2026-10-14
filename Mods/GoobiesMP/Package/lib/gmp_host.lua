-- GoobiesMP production: HOST session (authoritative). Pure Lua over the gmp_transport contract; no game access.
-- The host decides membership, slots, colours, connection state, reconnect eligibility and session phase.
-- Clients may only REQUEST (JOIN_REQ, REJOIN_REQ, COLOR_REQ, LEAVE); anything else from a client is dropped.
-- Message attribution comes from the host's own peer binding (peerId -> identity key), never from a claim inside a packet.
local Config = require("gmp_config")
local Messages = require("gmp_messages")
local Codec = require("gmp_codec")
local Link = require("gmp_link")
local Identity = require("gmp_identity")
local Roster = require("gmp_roster")
local Transport = require("gmp_transport")
local Auth = require("gmp_auth")
local Compat = require("gmp_compat")

local Host = {}
Host.__index = Host

local function hex(rng, n)
    local t = {}
    for i = 1, n do t[i] = string.format("%02x", math.floor(rng() * 256) % 256) end
    return table.concat(t)
end

-- opts: cfg, transport, clock()->seconds, rng()->[0,1), identity (host Identity), name, gameVer, log(msg), authProvider (gmp_auth contract; optional)
-- Authentication (PHASE2 12.18): a peer is AUTHENTICATED when either the transport itself vouches for it (transport:IsAuthenticated, peer.verifiedKey)
-- or, when cfg.AUTH_MODE ~= "off", the AUTH exchange succeeded with the provider. JOIN/REJOIN are accepted only for the authenticated key.
-- A host with AUTH_MODE steam/dev but no provider is valid and fails CLOSED: every remote peer is refused (auth_unavailable).
function Host.new(opts)
    local ok, errs = Config.Validate(opts.cfg)
    if not ok then return nil, "bad_config: " .. table.concat(errs, "; ") end
    local tok, missing = Transport.Check(opts.transport)
    if not tok then return nil, "bad_transport: missing " .. table.concat(missing, ",") end
    local self = setmetatable({}, Host)
    self.cfg, self.transport = opts.cfg, opts.transport
    self.clock = opts.clock or os.clock
    self.rng = opts.rng or math.random
    self.sessionPolicy={locked=false,revision=1,runGeneration=1,artifacts={},hostUnlocked={}}   -- gmp_messages.lua policy schema
    self.policy = Identity.Policy.new(opts.cfg.MODE)
    local pok, why = self.policy:Check(opts.identity)
    if not pok then return nil, why end
    self.identity, self.name, self.gameVer = opts.identity, opts.name or opts.identity.value, opts.gameVer or ""
    local prov = opts.authProvider
    self.exchange = (opts.cfg.AUTH_MODE ~= "off") and not opts.transport:IsAuthenticated()   -- run the AUTH exchange for each peer
    if prov ~= nil and self.exchange then
        local aok, awhy = Auth.CheckProvider(prov, opts.cfg)
        if not aok then return nil, awhy end
    end
    self.authProvider = self.exchange and prov or nil
    self.verifying = {}                     -- claimed key -> peer whose Verify is in flight (serialised per key)
    self.authCount = {}                     -- key -> number of successful authentications (diagnostic; a reconnect must raise it)
    self.peerCounter = 0
    self.sid = "S" .. hex(self.rng, 4)
    self.roster = Roster.new(opts.cfg, { rng = self.rng })
    self.peers = {}                         -- peerId -> { peerId, link, key, lastRx, lastHb, closeAt, verifiedKey }
    self.stats = { rx = 0, tx = 0, decode_errors = {}, wrong_direction = 0, bad_sid = 0, unbound_peer = 0, unknown_peer = 0,
                   duplicate = 0, stale = 0, late = 0, bad_epoch = 0, encode_errors = 0, window_full = 0, rejects = 0,
                   auth_ok = 0, auth_fail = 0, auth_ignored = 0 }
    self.chat, self.chatSeq, self.chatTimes = {}, 0, {}      -- bounded history (newest last), message counter, key -> recent send times
    self.events = {}                        -- bounded diagnostic ring
    self.logfn = opts.log
    self.started = false
    return self
end

function Host:_log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    self.events[#self.events + 1] = line
    if #self.events > 200 then table.remove(self.events, 1) end
    if self.logfn then self.logfn(line) end
end

function Host:Start()
    local ok, err = self.transport:Listen()
    if not ok then return nil, err end
    local rec, why = self.roster:AddHost(self.identity, self.name, self.clock())
    if not rec then return nil, why end
    self.started = true
    self:_log("host started sid=%s mode=%s max=%d host=%s slot=%d color=%s auth=%s%s", self.sid, self.cfg.MODE, self.roster.maxPlayers, Identity.Mask(rec.key), rec.slot, rec.color,
        self.cfg.AUTH_MODE, self.exchange and (self.authProvider and (" provider=" .. self.authProvider:Name()) or " provider=NONE (remote peers refused)") or (self.cfg.AUTH_MODE ~= "off" and " (transport-authenticated)" or ""))
    return true
end

-- Only a coordinator-confirmed checkpoint may enter this path. Game adapters
-- must restore first; this does not invent missing XP/reward/world state.
function Host:StartHandover(checkpoint,session,term)
    if self.started or next(self.peers) then return false,'already_started' end
    local ok,state=require('gmp_handover').Validate(checkpoint)
    if not ok then return false,state end
    if type(session)~='string' or #session<1 or #session>128 or type(term)~='number' or term%1~=0 or term<2 then return false,'invalid_commit' end
    local policy=state.sessionPolicy
    if not policy then
     if self.cfg.MODE~='dev' then return false,'missing_session_policy'end
     policy={locked=true,revision=1}
    end
    if type(policy)~='table' or policy.locked~=true then return false,'invalid_session_policy'end
    if self.cfg.MODE~='dev' and (math.type(policy.runGeneration)~='integer' or policy.runGeneration<1 or policy.runGeneration>9007199254740991) then return false,'invalid_run_generation'end
    -- Adopt only a schema-valid policy (gmp_messages.lua); a stale achievement flag or a reserved `lives` is refused.
    local adopted={}
    for key,value in pairs(policy) do adopted[key]=value end
    adopted.revision=adopted.revision or 1;adopted.runGeneration=adopted.runGeneration or 1
    adopted.artifacts=adopted.artifacts or {};adopted.hostUnlocked=adopted.hostUnlocked or {}
    if not Messages.ValidatePolicy(adopted) then return false,'invalid_session_policy'end
    local pickups
    if state.world.pickups~=nil then
        pickups=require('gmp_pickups').new()
        local accepted,reason=pickups:Restore(state.world.pickups)
        if not accepted then return false,'pickup_restore:'..tostring(reason) end
        if pickups.epoch~=state.manifest.epoch or pickups.island~=state.manifest.island then return false,'pickup_generation_mismatch' end
    end
    local imported,why=self.roster:ImportHandover(state.players,self.identity.key,self.clock())
    if not imported then return false,why end
    self:EnableIslands();self:EnableTravelGate();self:EnableEnemies()
    local restored,err=self.enemies:Restore(state.enemies);if not restored then return false,err end
    self.islands.epoch=state.manifest.epoch;self.islands.island=state.manifest.island
    self.islands.current=state.manifest;self.islands.phase='playing';self.islands.required={};self.islands.ready={}
    self.sessionPolicy=Messages.CopyPolicy(adopted)
    self.sid=session;self.authorityTerm=term;self.handoverState=state;self.pickups=pickups
    local listened,reason=self.transport:Listen();if not listened then return false,reason end
    self.started=true;return true
end

------------------------------------------------------------------ sending
function Host:_send(peer, typ, fields)
    if typ == "LOBBY_STATE" then
        fields={lrev=fields.lrev,state=fields.state,allowRejoin=fields.allowRejoin,maxPlayers=fields.maxPlayers,players=fields.players}
    end
    local function queuedSnapshot()
        if typ~='ROSTER' and typ~='LOBBY_STATE'then return false end
        local pages,why=require('gmp_snapshot_pages').Build(typ,fields)
        if not pages then return false,why end
        peer.snapshotPending=peer.snapshotPending or {};peer.snapshotPending[typ]={pages=pages,cursor=1}
        if typ=='LOBBY_STATE'then
            -- An invalid policy (nil, why; logged once by LobbyAchievementPolicy) queues nothing and drops any stale one.
            local policy=self:LobbyAchievementPolicy()
            peer.pendingPolicy=policy and {revision=policy.revision,locked=policy.locked,runGeneration=policy.runGeneration} or nil
        end
        return true
    end
    local sch = Messages.Schema[typ]
    local env = { type = typ, ch = sch.ch, sid = self.sid, f = fields }
    local pre, perr = Codec.Encode({ type = typ, ch = sch.ch, ep = 1, seq = 0, ack = 0, sid = self.sid, f = fields })
    if not pre and perr=='too_large' and (typ=='ROSTER' or typ=='LOBBY_STATE')then
        local queued,why=queuedSnapshot()
        if queued then return true end
        perr=why
    end
    if not pre then self.stats.encode_errors = self.stats.encode_errors + 1; self:_log("encode error %s: %s", typ, tostring(perr)); return false end
    local st, why = peer.link:Stamp(env, self.clock())
    if not st then
        if why=='window_full' and queuedSnapshot()then return true end
        self.stats[why] = (self.stats[why] or 0) + 1; self:_log("send %s dropped: %s", typ, tostring(why)); return false
    end
    local s = Codec.Encode(env)
    self.stats.tx = self.stats.tx + 1
    self.transport:Send(peer.peerId, s)
    if typ=='LOBBY_STATE' then
        local policy=self:LobbyAchievementPolicy()
        if policy then
            local packet={revision=policy.revision,locked=policy.locked,runGeneration=policy.runGeneration}
            if not self:_send(peer,'SESSION_POLICY',packet)then peer.pendingPolicy=packet end
        else
            peer.pendingPolicy=nil -- never deliver a stale revision while the current policy is refused
        end
    end
    if self.transport.PeerIdentity and (typ=='JOIN_ACCEPT' or typ=='REJOIN_ACCEPT') then
        self:_sendAuthorityProof(peer)
    end
    return true
end
function Host:_sendAuthorityProof(peer)
    local revision=self.roster.rev
    if peer.authorityProofRevision~=revision or not peer.authorityProofNonce then
        peer.authorityProofRevision=revision;peer.authorityProofNonce=hex(self.rng,16)
        peer.authorityProofAck=nil;peer.authorityProofSent=nil
    end
    peer.authorityProofSent=self:_send(peer,'STEAM_AUTHORITY_PROOF',{
        hostKey=self.identity.key,term=self.authorityTerm or 1,proofNonce=peer.authorityProofNonce})
    peer.authorityProofAt=self.clock()+self.cfg.HEARTBEAT_INTERVAL
end


function Host:_broadcastRoster()
    local fields = { rev = self.roster.rev, phase = self.roster.phase, maxPlayers = self.roster.maxPlayers,
                     currentPlayers = self.roster:CurrentPlayers(), players = self.roster:Snapshot() }
    -- D52: a player waiting for the next game sees the roster too (it is in nothing else)
    for _, peer in pairs(self.peers) do if peer.key or peer.waiting then self:_send(peer, "ROSTER", fields) end end
end

function Host:_sessionInfo(peer)
    local adv = Compat.Advert(Config, self.gameVer)
    self:_send(peer, "SESSION_INFO", { mode = self.cfg.MODE, maxPlayers = self.roster.maxPlayers, currentPlayers = self.roster:CurrentPlayers(),
        phase = self.roster.phase, allowRejoin = self.cfg.ALLOW_AUTO_REJOIN, modVer = Config.MOD_VERSION,
        requiredMod = adv.requiredMod, protocol = adv.protocol, gameVer = adv.gameVer })
end

function Host:_lobbyFields()
    local r = self.roster
    return { sessionPolicy=self:LobbyAchievementPolicy(),lrev = r.lrev, state = r.lobbyState, allowRejoin = self.cfg.ALLOW_AUTO_REJOIN, maxPlayers = r.maxPlayers, players = r:LobbySnapshot() }
end
function Host:_broadcastLobby()
    local f = self:_lobbyFields()
    for _, peer in pairs(self.peers) do if peer.key then self:_send(peer, "LOBBY_STATE", f) end end
    self:_queueAcceptedSelections()
end
-- Native publication is authoritative acceptance, never a SELECT_REQ echo.
-- It is queued only for actual identity-attributed transports and stays within
-- the same four-packet Tick budget as existing bounded lobby snapshots.
function Host:_queueAcceptedSelections()
 if not self.transport.PeerIdentity then return end
 local rows=self.roster:LobbySnapshot()
 for _,peer in pairs(self.peers)do if peer.key and peer.auth and peer.auth.state=='authenticated' then
  local queue={};for _,row in ipairs(rows)do if row.class~='' then queue[#queue+1]={term=self.authorityTerm or 1,key=row.key,revision=self.roster.lrev,class=row.class,artifacts=row.artifacts,frozen=self.sessionPolicy.locked==true,runGeneration=self.sessionPolicy.runGeneration or 1} end end
  local token=table.concat({self.authorityTerm or 1,self.roster.lrev,self.sessionPolicy.runGeneration or 1,self.sessionPolicy.locked and 1 or 0},':')
  local pending=peer.acceptedSelections
  -- Reliable authority ACK retries must not rewind a partially delivered manifest.
  -- A completed queue may refresh the current native provider generation.
  if not pending or pending.token~=token or pending.cursor>#pending.rows then
   peer.acceptedSelections={rows=queue,cursor=1,token=token}
  end
 end end
end

function Host:_reject(peer, typ, reason)
    self.stats.rejects = self.stats.rejects + 1
    self:_log("%s -> %s (peer %s)", typ, reason, tostring(peer.peerId))
    self:_send(peer, typ, { reason = reason })
    peer.closeAt = self.clock() + 1.5      -- let the reliable reject be delivered/resent, then drop the peer
end

------------------------------------------------------------------ peers / transport events
function Host:_newPeer(peerId, verifiedKey)
    local now = self.clock()
    self.peerCounter = self.peerCounter + 1
    local peer = { peerId = peerId, link = Link.new({ epoch = math.floor(self.rng() * 2147483646) + 1, window = self.cfg.WINDOW }),
                   key = nil, lastRx = now, lastHb = now, verifiedKey = verifiedKey, order = self.peerCounter,
                   authKey = nil,                                  -- the key this peer PROVED (never a claim)
                   auth = { state = "n/a" } }
    if self.exchange then
        peer.auth = { state = "unauthenticated", deadline = now + self.cfg.AUTH_TIMEOUT }
    elseif self.cfg.AUTH_MODE ~= "off" and self.transport:IsAuthenticated() and verifiedKey then
        peer.authKey, peer.auth = verifiedKey, { state = "authenticated" }
    end
    self.peers[peerId] = peer
    return peer
end

function Host:_dropPeer(peer, reason)
    if peer.key then
        if self.checkpointAcks then self.checkpointAcks[peer.key]=nil end
        if self.handoverArbiter then self.handoverArbiter:ParticipantLeft(peer.key,self.handoverArbiter.term) end
        if self.sharedPause then self.sharedPause.required[peer.key]=nil;self.sharedPause.acks[peer.key]=nil end
        -- D20 (W8): the departure reason decides the hold. A voluntary leave ("left:<why>") or a kick frees the slot; any
        -- accidental drop (timeout, transport closed, resends exhausted), in the lobby as in a run, keeps it reserved.
        local res = self.roster:Disconnect(peer.key, self.clock(), reason)
        self:_log("player %s disconnected (%s) -> %s", Identity.Mask(peer.key), reason, tostring(res))
        if self.presence then self.presence:Remove(peer.key) end
        -- Roster disconnection is the explicit session decision to release this wait.
        if self.islands then self.islands:RemoveParticipant(peer.key) end
        if self.travelCheck then self.travelCheck.required[peer.key]=nil;self.travelCheck.blocked[peer.key]=nil end
        peer.key = nil
        self:_broadcastRoster(); self:_broadcastLobby()
    end
    self.peers[peer.peerId] = nil
    self:_authCleanup(peer)
    if reason ~= "transport_closed" then self.transport:Close(peer.peerId) end
end

function Host:Poll()
    for _, ev in ipairs(self.transport:Poll()) do
        if ev.kind == "peer_connected" then
            local peer = self:_newPeer(ev.peerId, ev.identity)
            self:_log("peer connected %s", tostring(ev.peerId))
            self:_sessionInfo(peer)
            if self.exchange and self:_pendingCount() > self.cfg.AUTH_MAX_PENDING then self:_authFail(peer, "server_busy") end
        elseif ev.kind == "peer_disconnected" then
            local peer = self.peers[ev.peerId]
            if peer then self:_dropPeer(peer, "transport_closed") end
        elseif ev.kind == "message" then
            self:_onMessage(ev.peerId, ev.data)
        end
    end
    self:_pollAuth()
end

function Host:_onMessage(peerId, data)
    local peer = self.peers[peerId]
    if not peer then self.stats.unknown_peer = self.stats.unknown_peer + 1; return end
    self.stats.rx = self.stats.rx + 1
    local env, err = Codec.Decode(data)
    if not env then
        self.stats.decode_errors[err] = (self.stats.decode_errors[err] or 0) + 1
        self:_log("decode error from %s: %s", tostring(peerId), tostring(err))
        return
    end
    local dir = Messages.Schema[env.type].dir
    if dir == "H2C" then                                   -- a client trying to speak with the host's voice
        self.stats.wrong_direction = self.stats.wrong_direction + 1
        self:_log("dropped %s from client peer %s (wrong direction)", env.type, tostring(peerId))
        return
    end
    if env.sid ~= self.sid then self.stats.bad_sid = self.stats.bad_sid + 1; return end
    local accept, verdict = peer.link:Receive(env)
    if verdict ~= "ok" then self.stats[verdict] = (self.stats[verdict] or 0) + 1 end
    if not accept then return end
    peer.lastRx = self.clock()
    local h = Host.handlers[env.type]
    if h then h(self, peer, env.f) end
end

------------------------------------------------------------------ handlers (all are REQUESTS; the host decides)
-- Identity of a JOIN/REJOIN request. The claimed key must equal the key the peer PROVED (transport-verified, or via the AUTH exchange).
-- AUTH_MODE=off (dev only) keeps the old claim-only behaviour for offline tests.
local function parseIdentity(self, peer, key)
    local id, why = Identity.Parse(key)
    if not id then return nil, why end
    local ok, pwhy = self.policy:Check(id)
    if not ok then return nil, pwhy end
    if self.transport:IsAuthenticated() then
        if peer.verifiedKey ~= id.key then return nil, "identity_mismatch" end
    elseif self.cfg.AUTH_MODE ~= "off" then
        if peer.authKey == nil then return nil, "not_authenticated" end
        if peer.authKey ~= id.key then return nil, "identity_mismatch" end
    end
    return id
end

-- true when parseIdentity's success means the key was PROVED (not merely claimed)
local function proven(self) return self.transport:IsAuthenticated() or self.cfg.AUTH_MODE ~= "off" end

Host.handlers = {}
function Host.handlers.STEAM_AUTHORITY_ACK(self,peer,f)
    if not peer.key or not peer.auth or peer.auth.state~='authenticated'
        or f.hostKey~=self.identity.key or f.term~=(self.authorityTerm or 1)
        or peer.authorityProofRevision~=self.roster.rev or f.proofNonce~=peer.authorityProofNonce then return end
    peer.authorityProofAck=f.proofNonce
    self:_queueAcceptedSelections()
end

-- Defence in depth only: modVer/gameVer in a request are CLAIMS (a modified client can lie), so this never replaces the
-- client-side gate; it just refuses honest-but-mismatched peers that skipped it.
local function claimIncompatible(self, f)
    if f.modVer ~= Config.MOD_VERSION then return "version_mismatch" end
    if self.gameVer ~= "" and f.gameVer ~= "" and f.gameVer ~= self.gameVer then return "game_version_mismatch" end
end

function Host.handlers.JOIN_REQ(self, peer, f)
    if peer.key then return self:_reject(peer, "JOIN_REJECT", "already_joined") end
    local id, why = parseIdentity(self, peer, f.key)
    if not id then return self:_reject(peer, "JOIN_REJECT", why) end          -- identity/authentication problems are reported first
    local bad = claimIncompatible(self, f)
    if bad then return self:_reject(peer, "JOIN_REJECT", bad) end
    -- An AUTHENTICATED returning identity that still has a reservation reclaims it even if the client lost its resume token
    -- (e.g. it restarted): the proof of identity replaces the token. A claim alone never reaches this branch.
    if proven(self) and self.roster:ReconnectEligible(id.key) then
        local rec, rwhy = self.roster:Rejoin(id, peer.peerId, self.clock(), { authenticated = true })
        if not rec then return self:_reject(peer, "JOIN_REJECT", rwhy) end
        peer.key = rec.key
        self:_log("authenticated return of %s reclaimed slot=%d color=%s", Identity.Mask(rec.key), rec.slot, rec.color)
        self:_send(peer, "JOIN_ACCEPT", { key = rec.key, slot = rec.slot, color = rec.color, token = rec.token, rosterRev = self.roster.rev })
        self:_broadcastRoster(); self:_broadcastLobby()
        return
    end
    local rec, rwhy = self.roster:Join(id, f.name, peer.peerId, self.clock(), { reqColor = f.reqColor, modVer = f.modVer, gameVer = f.gameVer })
    if not rec then return self:_reject(peer, "JOIN_REJECT", rwhy) end
    peer.key = rec.key
    self:_log("join accepted %s slot=%d color=%s", Identity.Mask(rec.key), rec.slot, rec.color)
    self:_send(peer, "JOIN_ACCEPT", { key = rec.key, slot = rec.slot, color = rec.color, token = rec.token, rosterRev = self.roster.rev })
    self:_broadcastRoster(); self:_broadcastLobby()
    self:_replayChat(peer)
end

-- D52: wait for the next game. A player that cannot join the run in progress (no held slot) asks to wait: it stays
-- connected OUTSIDE the roster (peer.waiting; no peer.key, so nothing that walks the roster or the bound peers sees it:
-- no run, prep, manifests, D40 or scaling), gets the roster, and is admitted when the host is back in the lobby
-- (Host:_admitWaiting, arrival order; a full lobby keeps it waiting). While the lobby is open, or for a player that
-- holds a slot, WAIT_REQ is a plain JOIN_REQ.
Host.WAIT_MAX = Config.MAX_PLAYERS_LIMIT
function Host.handlers.WAIT_REQ(self, peer, f)
    if peer.key or peer.waiting then return self:_reject(peer, "JOIN_REJECT", "already_joined") end
    local id, why = parseIdentity(self, peer, f.key)
    if not id then return self:_reject(peer, "JOIN_REJECT", why) end
    local bad = claimIncompatible(self, f)
    if bad then return self:_reject(peer, "JOIN_REJECT", bad) end
    if self.roster.phase ~= "run" or self.roster:Get(id.key) then return Host.handlers.JOIN_REQ(self, peer, f) end
    if self.roster.kicked[id.key] then return self:_reject(peer, "JOIN_REJECT", "kicked") end
    local count = 0
    for _, p in pairs(self.peers) do
        if p.waiting then
            count = count + 1
            if p.waiting.id.key == id.key then return self:_reject(peer, "JOIN_REJECT", "duplicate_identity") end
        end
    end
    if count >= Host.WAIT_MAX then return self:_reject(peer, "JOIN_REJECT", "wait_list_full") end
    self.waitSerial = (self.waitSerial or 0) + 1
    -- a waiter that followed a host change keeps its place (its rank on the former host); new arrivals queue after
    local rank = math.type(f.rank) == 'integer' and f.rank >= 1 and f.rank <= Host.WAIT_MAX and f.rank or nil
    peer.waiting = { id = id, name = f.name, order = rank or (Host.WAIT_MAX + self.waitSerial),
        extra = { reqColor = f.reqColor, modVer = f.modVer, gameVer = f.gameVer } }
    self:_log("%s waits for the next game (%d waiting)", Identity.Mask(id.key), count + 1)
    self:_send(peer, "WAIT_ACCEPT", { key = id.key, rosterRev = self.roster.rev })
    self:_send(peer, "ROSTER", { rev = self.roster.rev, phase = self.roster.phase, maxPlayers = self.roster.maxPlayers,
        currentPlayers = self.roster:CurrentPlayers(), players = self.roster:Snapshot() })
end
-- The players waiting for the next game, in arrival order: { {key, name, order} }.
function Host:WaitingPlayers()
    local out = {}
    for _, p in pairs(self.peers) do if p.waiting then out[#out + 1] = { key = p.waiting.id.key, name = p.waiting.name, order = p.waiting.order, peer = p } end end
    table.sort(out, function(a, b) return a.order < b.order end)
    return out
end
-- Back in the lobby: waiting players take free slots in arrival order (JOIN_ACCEPT, as a normal join). A full lobby
-- keeps the rest waiting; any other refusal (a bad name...) ends that player's wait.
function Host:_admitWaiting()
    if self.roster.phase ~= "lobby" then return end
    for _, w in ipairs(self:WaitingPlayers()) do
        local peer, wait = w.peer, w.peer.waiting
        local rec, why = self.roster:Join(wait.id, wait.name, peer.peerId, self.clock(), wait.extra)
        if not rec then
            if why == "session_full" then return end
            peer.waiting = nil
            self:_reject(peer, "JOIN_REJECT", why)
        else
            peer.waiting, peer.key = nil, rec.key
            self:_log("waiting player %s admitted slot=%d color=%s", Identity.Mask(rec.key), rec.slot, rec.color)
            self:_send(peer, "JOIN_ACCEPT", { key = rec.key, slot = rec.slot, color = rec.color, token = rec.token, rosterRev = self.roster.rev })
            self:_broadcastRoster(); self:_broadcastLobby()
            self:_replayChat(peer)
        end
    end
end

function Host.handlers.REJOIN_REQ(self, peer, f)
    if peer.key then return self:_reject(peer, "REJOIN_REJECT", "already_joined") end
    local id, why = parseIdentity(self, peer, f.key)
    if not id then return self:_reject(peer, "REJOIN_REJECT", why) end
    local bad = claimIncompatible(self, f)
    if bad then return self:_reject(peer, "REJOIN_REJECT", bad) end
    local rec, rwhy = self.roster:Rejoin(id, peer.peerId, self.clock(), { token = f.token, claimSlot = f.claimSlot, claimColor = f.claimColor,
        authenticated = proven(self) })
    if not rec then return self:_reject(peer, "REJOIN_REJECT", rwhy) end
    peer.key = rec.key
    self:_log("rejoin accepted %s slot=%d color=%s", Identity.Mask(rec.key), rec.slot, rec.color)
    self:_send(peer, "REJOIN_ACCEPT", { key = rec.key, slot = rec.slot, color = rec.color, rosterRev = self.roster.rev })
    self:_broadcastRoster(); self:_broadcastLobby()
end

------------------------------------------------------------------ authentication stage (PHASE2 12.18)
-- Peer auth states: n/a (no exchange needed) | unauthenticated -> challenged -> receiving -> queued/verifying -> authenticated | failed
local PENDING = { unauthenticated = true, challenged = true, receiving = true, queued = true, verifying = true, mutual = true }

function Host:_pendingCount()
    local n = 0
    for _, p in pairs(self.peers) do if PENDING[p.auth.state] then n = n + 1 end end
    return n
end

-- Reject the authentication attempt of one peer: tell it why, free everything, close the link shortly.
function Host:_authFail(peer, reason)
    local a = peer.auth
    if a.state == "failed" then return end
    self.stats.auth_fail = self.stats.auth_fail + 1
    self:_log("auth FAILED for peer %s claim=%s: %s", tostring(peer.peerId), Identity.Mask(a.claim), tostring(reason))
    self:_authCleanup(peer)
    a.state, a.chunks = "failed", nil
    self:_send(peer, "AUTH_RESULT", { ok = false, key = "", reason = reason })
    peer.closeAt = self.clock() + 1.5
end

-- Release provider/verification state owned by a peer. Safe to call repeatedly.
-- Role replacement keeps the physical transport alive; retire only resources
-- owned by the old logical host, without starting queued authentication work.
function Host:RetireAuthentication()
    for _,peer in pairs(self.peers) do
        local auth=peer.auth
        if auth then
            if auth.sessionKey and self.authProvider then self.authProvider:End(auth.sessionKey) end
            if auth.hostTicket and self.authProvider then self.authProvider:TicketCancel(auth.hostTicket);auth.hostTicket=nil end
            auth.sessionKey=nil;auth.chunks=nil;auth.state='retired'
        end
    end
    self.verifying={}
end
function Host:_authCleanup(peer)
    local a = peer.auth
    if not a then return end
    local key = a.claim
    if key and self.verifying[key] == peer then self.verifying[key] = nil end
    if a.sessionKey and self.authProvider then self.authProvider:End(a.sessionKey) end
    a.sessionKey = nil
    if a.hostTicket and self.authProvider then self.authProvider:TicketCancel(a.hostTicket);a.hostTicket=nil end
    a.chunks = nil
    if key then self:_startQueued(key) end
end

function Host:_peerAuthenticatedAs(key, except)
    for _, p in pairs(self.peers) do
        if p ~= except and p.auth.state == "authenticated" and p.authKey == key then return p end
    end
end

function Host:_startQueued(key)
    if self.verifying[key] then return end
    local best
    for _, p in pairs(self.peers) do
        if p.auth.state == "queued" and p.auth.claim == key and (not best or p.order < best.order) then best = p end
    end
    if best then self:_authStartVerify(best) end
end

function Host:_authStartVerify(peer)
    local a, key = peer.auth, peer.auth.claim
    if self.verifying[key] then a.state = "queued"; return end                    -- one Verify per key at a time
    local existing = self:_peerAuthenticatedAs(key, peer)
    if existing then
        if not self.cfg.AUTH_TAKEOVER then return self:_authFail(peer, "duplicate_identity") end
        if existing.auth.sessionKey then self.authProvider:End(existing.auth.sessionKey); existing.auth.sessionKey = nil end   -- free Steam's session slot for the new proof
    end
    local ticket = table.concat(a.chunks, "")
    a.chunks = nil
    self.verifying[key] = peer
    a.state, a.verifyDeadline = "verifying", self.clock() + self.cfg.AUTH_VERIFY_TIMEOUT
    a.sessionKey = key
    local ok, why = self.authProvider:Verify(key, ticket, self.identity.key)
    if not ok then
        a.sessionKey = nil
        self.verifying[key] = nil
        return self:_authFail(peer, Auth.WireReason(why))
    end
    if type(why)=='table' and math.type(why.retainedEpoch)=='integer' and why.retainedEpoch>0 then
        a.nativeEpoch=why.retainedEpoch;self.verifying[key]=nil;self:_authSucceed(peer)
    end
end

function Host:_authSucceed(peer)
    if self.cfg.AUTH_MODE=='steam' and not peer.auth.mutualValidated then
        local a=peer.auth
        local handle,why=self.authProvider:TicketBegin(a.claim)
        if not handle then return self:_authFail(peer,'host_ticket_failed:'..tostring(why)) end
        a.hostTicket=handle;a.state='mutual';a.deadline=self.clock()+self.cfg.AUTH_TIMEOUT
        return
    end
    local a, key = peer.auth, peer.auth.claim
    if self.roster:IsKicked(key) then return self:_authFail(peer, "kicked") end
    local existing = self:_peerAuthenticatedAs(key, peer)
    peer.authKey = key
    a.state, a.deadline = "authenticated", self.clock() + self.cfg.AUTH_TIMEOUT          -- must JOIN within AUTH_TIMEOUT
    self.stats.auth_ok = self.stats.auth_ok + 1
    self.authCount[key] = (self.authCount[key] or 0) + 1
    self:_log("auth OK peer %s -> %s", tostring(peer.peerId), Identity.Mask(key))
    self:_send(peer, "AUTH_RESULT", { ok = true, key = key, reason = "" })
    if existing then
        self:_log("authenticated reconnect of %s replaces the older link %s", Identity.Mask(key), tostring(existing.peerId))
        existing.auth.sessionKey = nil                                                    -- the session now belongs to the new peer
        self:_dropPeer(existing, "replaced_by_reauth")
    end
end

function Host:_tickMutualAuth(peer)
    local a=peer.auth
    if a.state~='mutual' or a.hostTicketSent then return end
    local state,size=self.authProvider:TicketState(a.hostTicket)
    if state=='failed' then return self:_authFail(peer,'host_ticket_failed') end
    if state~='ready' then return end
    local cb=math.min(self.cfg.AUTH_CHUNK_BYTES,Auth.MAX_CHUNK_BYTES)
    local total=(size+cb-1)//cb
    if total<1 or total>Auth.MAX_CHUNKS then return self:_authFail(peer,'host_ticket_too_large') end
    for i=1,total do
        local data=self.authProvider:TicketChunk(a.hostTicket,(i-1)*cb,cb)
        if not data or not self:_send(peer,'AUTH_HOST_TICKET',{nonce=a.nonce,idx=i,total=total,data=data}) then
            return self:_authFail(peer,'host_ticket_send_failed')
        end
    end
    a.hostTicketSent=true
end
function Host.handlers.AUTH_HOST_ACK(self,peer,f)
    local a=peer.auth
    if self.cfg.AUTH_MODE~='steam' or a.state~='mutual' or not a.hostTicketSent
        or f.nonce~=a.nonce or f.hostKey~=self.identity.key then return end
    if not f.ok then return self:_authFail(peer,'host_validation_refused') end
    a.mutualValidated=true;self:_authSucceed(peer)
end

function Host:_pollAuth()
    if not self.authProvider then return end
    for _, ev in ipairs(self.authProvider:Poll()) do
        if ev.kind == "validate" then
            local peer = self.verifying[ev.key]
            if peer and peer.auth.state == "verifying" then
                self.verifying[ev.key] = nil
                if ev.ok and ev.key == peer.auth.claim then
                    self:_authSucceed(peer)
                    self:_startQueued(ev.key)
                else
                    -- Steam started a session for this key even though validation failed: _authFail's cleanup ends it (EndAuthSession)
                    self:_authFail(peer, Auth.WireReason(ev.reason))
                end
            elseif not ev.ok then
                -- Steam reports an already authenticated peer is gone / cancelled its ticket: that is a disconnect, not a kick
                local p = self:_peerAuthenticatedAs(ev.key)
                if not p then for _,candidate in pairs(self.peers)do if candidate.auth.state=='mutual' and candidate.auth.sessionKey==ev.key then p=candidate;break end end end
                if p then self:_dropPeer(p, "auth_revoked") end
            end
        end
    end
end

local HEX_CAP = Auth.MAX_CHUNK_BYTES * 2

function Host.handlers.AUTH_HELLO(self, peer, f)
    local a = peer.auth
    if not self.exchange then
        -- AUTH_MODE=off (the client wants auth the host does not run) or the transport already authenticated this peer
        if self.cfg.AUTH_MODE == "off" then return self:_authFail(peer, "auth_mismatch") end
        if a.state == "authenticated" and peer.authKey == f.key then
            return self:_send(peer, "AUTH_RESULT", { ok = true, key = f.key, reason = "" })
        end
        return self:_authFail(peer, "identity_mismatch")
    end
    if a.state ~= "unauthenticated" then self.stats.auth_ignored = self.stats.auth_ignored + 1; return end    -- one HELLO per link
    if f.scheme ~= self.cfg.AUTH_MODE then return self:_authFail(peer, "auth_mismatch") end
    local id, why = Identity.Parse(f.key)
    if not id then return self:_authFail(peer, why) end
    if self.transport.PeerIdentity then
        local attributed=self.transport:PeerIdentity(peer.peerId)
        if not attributed or attributed.key~=id.key then return self:_authFail(peer,'identity_mismatch') end
    end
    local ok, pwhy = self.policy:Check(id)
    if not ok then return self:_authFail(peer, pwhy) end                                 -- production refuses dev: here, before any ticket work
    if id.kind ~= self.cfg.AUTH_MODE then return self:_authFail(peer, "auth_mismatch") end   -- steam scheme <-> steam: keys, dev scheme <-> dev: keys
    if not self.authProvider then return self:_authFail(peer, "auth_unavailable") end
    local sok, swhy = self.authProvider:Status()
    if not sok then return self:_authFail(peer, Auth.WireReason(swhy or "steam_unavailable")) end
    if self.roster:IsKicked(id.key) then return self:_authFail(peer, "kicked") end
    a.claim, a.nonce, a.state = id.key, hex(self.rng, 8), "challenged"
    a.chunks, a.have, a.total, a.bytes = {}, 0, nil, 0
    self:_send(peer, "AUTH_CHALLENGE", { hostKey = self.identity.key, nonce = a.nonce, scheme = self.cfg.AUTH_MODE })
end

function Host.handlers.AUTH_TICKET(self, peer, f)
    local a = peer.auth
    if a.state ~= "challenged" and a.state ~= "receiving" then self.stats.auth_ignored = self.stats.auth_ignored + 1; return end
    if f.nonce ~= a.nonce then return self:_authFail(peer, "bad_nonce") end
    if f.total < 1 or f.total > Auth.MAX_CHUNKS or f.idx < 1 or f.idx > f.total then return self:_authFail(peer, "bad_ticket") end
    if a.total and a.total ~= f.total then return self:_authFail(peer, "bad_ticket") end
    if #f.data == 0 or #f.data > HEX_CAP or not Auth.IsHex(f.data) then return self:_authFail(peer, "bad_ticket") end
    a.total, a.state = f.total, "receiving"
    local prev = a.chunks[f.idx]
    if prev ~= nil then
        if prev ~= f.data then return self:_authFail(peer, "bad_ticket") end
        return                                                                            -- identical duplicate
    end
    a.bytes = a.bytes + #f.data // 2
    if a.bytes > self.cfg.AUTH_MAX_TICKET_BYTES then return self:_authFail(peer, "ticket_too_large") end
    a.chunks[f.idx], a.have = f.data, a.have + 1
    if a.have == a.total then self:_authStartVerify(peer) end
end

function Host.handlers.COLOR_REQ(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    local rec, why = self.roster:SetColor(peer.key, f.color)
    if not rec then
        self:_log("COLOR_REQ %s from %s denied: %s", f.color, Identity.Mask(peer.key), why)
        return self:_send(peer, "REQ_DENIED", { ofType = "COLOR_REQ", reason = why })
    end
    self:_send(peer, "ASSIGN", { rev = self.roster.rev, key = rec.key, slot = rec.slot, color = rec.color })
    self:_broadcastRoster()
end

------------------------------------------------------------------ lobby requests (identity ALWAYS comes from peer.key)
-- READY_REQ, SELECT_REQ and SESSION_POLICY_ACK live in gmp_host_entry.lua.
-- Host-only actions requested by a client are ALWAYS refused (the host acts locally through Host:Kick/SetAllowAutoRejoin/...; it is never a peer).
local function notHost(ofType)
    return function(self, peer, f)
        if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
        self:_log("%s from %s denied: not_host", ofType, Identity.Mask(peer.key))
        self:_send(peer, "REQ_DENIED", { ofType = ofType, reason = "not_host" })
    end
end
Host.handlers.SETTINGS_REQ, Host.handlers.KICK_REQ, Host.handlers.START_REQ = notHost("SETTINGS_REQ"), notHost("KICK_REQ"), notHost("START_REQ")

-- Chat. Text is validated here (never trusted): non-empty, <= MAX_CHAT_BYTES, no control characters, rate limited per identity.
function Host:_chatAccept(key, text)
    local L = Config.LOBBY
    if type(text) ~= "string" then return nil, "bad_text" end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "empty" end
    if #text > L.MAX_CHAT_BYTES then return nil, "too_long" end
    if text:find("%c") then return nil, "bad_text" end
    local now = self.clock()
    local t = self.chatTimes[key] or {}
    local keep = {}
    for _, at in ipairs(t) do if now - at < L.CHAT_WINDOW then keep[#keep + 1] = at end end
    if #keep >= L.CHAT_BURST then self.chatTimes[key] = keep; return nil, "rate_limited" end
    keep[#keep + 1] = now
    self.chatTimes[key] = keep
    return text
end

function Host:_publishChat(key, text)
    local rec = self.roster:Get(key)
    if not rec then return nil, "unknown_player" end
    local clean, why = self:_chatAccept(key, text)
    if not clean then return nil, why end
    self.chatSeq = self.chatSeq + 1
    local m = { seq = self.chatSeq, key = key, name = rec.name, text = clean }
    self.chat[#self.chat + 1] = m
    if #self.chat > Config.LOBBY.CHAT_HISTORY then table.remove(self.chat, 1) end
    for _, peer in pairs(self.peers) do if peer.key then self:_send(peer, "CHAT", m) end end
    return m
end

function Host.handlers.CHAT_REQ(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    local m, why = self:_publishChat(peer.key, f.text)
    if not m then self:_send(peer, "REQ_DENIED", { ofType = "CHAT_REQ", reason = why }) end
end

-- A newcomer sees the recent history (so chat does not start empty after a join).
function Host:_replayChat(peer)
    for _, m in ipairs(self.chat) do self:_send(peer, "CHAT", m) end
end

function Host.handlers.LEAVE(self, peer, f)
    if peer.waiting then
        self:_log("%s stopped waiting for the next game", Identity.Mask(peer.waiting.id.key))
        peer.waiting = nil
        return self:_dropPeer(peer, "left:" .. tostring(f.reason))
    end
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    self:_dropPeer(peer, "left:" .. tostring(f.reason))
end

function Host.handlers.HEARTBEAT(self, peer, f)
    if peer.waiting then return end          -- D52: a waiting player's liveness is its lastRx
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    local rec = self.roster:Get(peer.key)
    if rec then rec.lastSeen = self.clock(); rec.clientRosterRev = f.rosterRev end
end

-- Reserved (C0) stubs for Track S: client authority-prep reports and attack intents (gmp_messages.lua). They only
-- record receipt; no state changes until the owning S unit implements them.
local function reserved(self, typ)
    self.reservedReceived = self.reservedReceived or {}
    self.reservedReceived[typ] = (self.reservedReceived[typ] or 0) + 1
end
-- S5: client attack intents (C0 ATTACK_INTENT {context, sequence, enemyId, attack}; S6 sends them). The intake is off
-- until the run sync enables it (CLIENT_ATTACKS); it is bounded and drained by RunSync, which validates, queues
-- (gmp_host_combat.lua) and resolves them. Attribution comes from the peer's bound key, never from the packet.
Host.ATTACK_INTAKE_CAP = 128
function Host:EnableAttackIntents() self.attackIntake = self.attackIntake or {}; return self.attackIntake end
function Host:DrainAttackIntents()
    local list = self.attackIntake or {}
    if self.attackIntake then self.attackIntake = {} end
    return list
end
function Host:SendAttackResult(key, sequence, ok)
    for _, peer in pairs(self.peers) do
        if peer.key == key then return self:_send(peer, "ATTACK_RESULT", { sequence = sequence, ok = ok == true }) end
    end
    return false
end
-- CLIENT_UPGRADE_DAMAGE: the newest valid PLAYER_STATS per bound peer key (Messages.ValidatePlayerStats; revision
-- strictly rising). Ignored (counted) until the run sync enables the intake.
function Host:EnablePlayerStats() self.playerStats = self.playerStats or {}; return self.playerStats end
function Host:PlayerStats(key)
    local s = self.playerStats and self.playerStats[key]
    return s and { revision = s.revision, damageMulti = s.damageMulti, aoeMulti = s.aoeMulti, bonusDamage = s.bonusDamage } or nil
end
function Host.handlers.PLAYER_STATS(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    if not self.playerStats then self.stats.player_stats_ignored = (self.stats.player_stats_ignored or 0) + 1; return end
    local stats = Messages.ValidatePlayerStats(f)
    local last = self.playerStats[peer.key]
    if not stats or (last and stats.revision <= last.revision) then
        self.stats.player_stats_refused = (self.stats.player_stats_refused or 0) + 1; return
    end
    self.playerStats[peer.key] = stats
end
-- CLIENT_DAMAGE: one contact hit to one client (fields {context, sequence, damage number, enemies}); false when the
-- peer is not bound or the values are out of range.
function Host:SendClientHit(key, hit)
    if type(hit) ~= "table" or type(hit.damage) ~= "number" then return false end
    local f = { context = hit.context, sequence = hit.sequence, damage = string.format("%.17g", hit.damage), enemies = hit.enemies }
    if not Messages.ValidateClientHit(f) then return false end
    for _, peer in pairs(self.peers) do
        if peer.key == key then return self:_send(peer, "CLIENT_HIT", f) end
    end
    return false
end
-- SHARED_LIVES (D32): clients report going down (PLAYER_DOWN); the host publishes LIVES_STATE to everyone and sends
-- PLAYER_REVIVE to the revived client. Ignored (counted) until the run sync enables the intake.
function Host:EnableLives() self.playerDowns = self.playerDowns or {}; return self.playerDowns end
function Host:DrainPlayerDowns()
    local list = self.playerDowns or {}
    if self.playerDowns then self.playerDowns = {} end
    return list
end
function Host:SendLivesState(state)
    if not Messages.ValidateLivesState(state) then return false end
    local sent = true
    for _, peer in pairs(self.peers) do if peer.key then sent = self:_send(peer, "LIVES_STATE", state) and sent end end
    return sent
end
function Host:SendPlayerRevive(key, revive)
    if type(revive) ~= "table" or type(revive.hp) ~= "number" or type(revive.invulnerable) ~= "number" then return false end
    local f = { context = revive.context, sequence = revive.sequence, hp = string.format("%.17g", revive.hp),
        invulnerable = string.format("%.17g", revive.invulnerable) }
    if not Messages.ValidatePlayerRevive(f) then return false end
    for _, peer in pairs(self.peers) do if peer.key == key then return self:_send(peer, "PLAYER_REVIVE", f) end end
    return false
end
function Host.handlers.PLAYER_DOWN(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    if not self.playerDowns then self.stats.player_down_ignored = (self.stats.player_down_ignored or 0) + 1; return end
    local down = Messages.ValidatePlayerDown(f)
    if not down or #self.playerDowns >= 16 then self.stats.player_down_refused = (self.stats.player_down_refused or 0) + 1; return end
    self.playerDowns[#self.playerDowns + 1] = { peer = peer.key, context = down.context, sequence = down.sequence }
end
-- ATTACK_AOE (dev, CLIENT_ATTACKS): a client's skipped DamageAOE observation, bound to the peer's key; the run sync
-- drains and resolves them (gmp_run_sync.lua). Counted and dropped until enabled.
Host.ATTACK_AOE_CAP = 128
function Host:EnableAttackAoe() self.attackAoeIntake = self.attackAoeIntake or {}; return self.attackAoeIntake end
function Host:DrainAttackAoe()
    local list = self.attackAoeIntake or {}
    if self.attackAoeIntake then self.attackAoeIntake = {} end
    return list
end
function Host.handlers.ATTACK_AOE(self, peer, f)
    if not peer.key then return end
    local intake = self.attackAoeIntake
    if not intake then self.stats.attack_aoe_ignored = (self.stats.attack_aoe_ignored or 0) + 1; return end
    local aoe = Messages.ValidateAttackAoe(f)
    if not aoe then self.stats.attack_aoe_refused = (self.stats.attack_aoe_refused or 0) + 1; return end
    if #intake >= Host.ATTACK_AOE_CAP then self.stats.attack_aoe_dropped = (self.stats.attack_aoe_dropped or 0) + 1; return end
    intake[#intake + 1] = { peer = peer.key, conn = peer, aoe = aoe }   -- conn: replays are judged per connection
end
-- D45 hook (Coder C): shared XP / pickup dev messages (gmp_pickups_sync.lua, flag SHARED_XP). Client reports are queued
-- with the peer's bound key and drained by the run sync, which validates them; counted and dropped until enabled.
Host.PICKUP_INTAKE_CAP = 256
function Host:EnablePickups() self.pickupIntake = self.pickupIntake or {}; return self.pickupIntake end
function Host:DrainPickups()
    local list = self.pickupIntake or {}
    if self.pickupIntake then self.pickupIntake = {} end
    return list
end
function Host:SendPickups(key, typ, fields)
    for _, peer in pairs(self.peers) do if peer.key == key then return self:_send(peer, typ, fields) == true end end
    return false
end
for _, typ in ipairs({ 'PICKUP_COLLECT', 'PICKUP_LOCAL_XP', 'REWARD_DONE', 'XP_BONUS' }) do
    Host.handlers[typ] = function(self, peer, f)
        if not peer.key then return end
        local intake = self.pickupIntake
        if not intake or #intake >= Host.PICKUP_INTAKE_CAP then self.stats.pickup_dropped = (self.stats.pickup_dropped or 0) + 1; return end
        intake[#intake + 1] = { peer = peer.key, type = typ, f = f }
    end
end
-- end D45 hook
function Host.handlers.ATTACK_INTENT(self, peer, f)
    if not peer.key then return end
    reserved(self, "ATTACK_INTENT")
    local intake = self.attackIntake
    if not intake then return end
    if #intake >= Host.ATTACK_INTAKE_CAP then
        self.stats.attack_intent_dropped = (self.stats.attack_intent_dropped or 0) + 1; return
    end
    intake[#intake + 1] = { peer = peer.key, intent = { context = f.context, sequence = f.sequence, enemyId = f.enemyId, attack = f.attack } }
end

------------------------------------------------------------------ authority prep (S1, PLAN_WORLD_ENTRY.md 3.11)
-- The W3 app holds the shared pause for prep through host:PauseForAuthorityPrep(key, 'process'|'island') while the run
-- sync (gmp_run_sync.lua) asks for it, and releases it with (key, false). Clients report AUTHORITY_PREP{key, phase, ok,
-- reason}; the host publishes AUTHORITY_PREP_STATE{key, phase, waiting=<connected client slots not yet reported ok>}.
-- A failed client report is sticky: the slot keeps waiting, so the pause stays (visible, logged) until W10 aborts.
-- While prep holds, manual pause requests are refused; release restores the pause state from before the hold unless a
-- handover lock took the pause meanwhile. The user pause policy (hostOnly) is never touched.
local PREP_REASON = { process = "authority_prep", island = "island_prep" }
local PREP_KEY_BYTES, PREP_REASON_BYTES = 200, 120
Host.AUTHORITY_PREP_REASON = PREP_REASON
local function prepKey(key) return type(key) == "string" and #key > 0 and #key <= PREP_KEY_BYTES end
function Host:_prepClients()
    local out = {}
    for _, player in ipairs(self.roster:Snapshot()) do
        if player.key ~= self.identity.key and player.conn == "connected" then out[#out + 1] = player end
    end
    return out
end
function Host:_prepWaiting(prep)
    local waiting, failed = {}, nil
    for _, player in ipairs(self:_prepClients()) do
        local report = prep.reports[player.key]
        if not (report and report.ok) then waiting[#waiting + 1] = player.slot end
        if report and not report.ok and not failed then failed = { slot = player.slot, reason = report.reason } end
    end
    table.sort(waiting)
    return waiting, failed
end
function Host:PublishAuthorityPrep()
    local prep = self.authorityPrep
    if not prep then return false end
    local rows = {}
    for i, slot in ipairs((self:_prepWaiting(prep))) do rows[i] = { slot = slot } end
    local sent = true
    for _, peer in pairs(self.peers) do
        if peer.key then sent = self:_send(peer, "AUTHORITY_PREP_STATE", { key = prep.key, phase = prep.phase, waiting = rows }) and sent end
    end
    return sent
end
function Host:PauseForAuthorityPrep(key, phase)
    if not prepKey(key) then return false, "bad_prep_key" end
    local prep = self.authorityPrep
    if phase == false then
        if not prep or prep.key ~= key then return false, "not_held" end
        self.authorityPrep = nil
        local pause = self.sharedPause
        if pause and pause.paused and not pause.locked then
            local prior, ok = prep.prior, nil
            if prior.paused and prior.owner and pause.participants()[prior.owner] then
                ok = pause:Set(prior.owner, true, false, prior.reason)
            else
                ok = pause:Set(self.identity.key, false, false, "authority_prep_released")
            end
            if ok then self:PublishPause() end
        end
        self:_log("authority prep released phase=%s", prep.phase)
        return true
    end
    local reason = PREP_REASON[phase]
    if not reason then return false, "bad_prep_phase" end
    if prep then
        if prep.key == key and prep.phase == phase then return true, "already_held" end
        return false, "prep_already_held"
    end
    local pause = self:EnablePause()
    if pause.locked then return false, "handover_locked" end
    local prior = { paused = pause.paused, owner = pause.owner, reason = pause.reason }
    local ok, why = pause:Set(self.identity.key, true, false, reason)
    if not ok then return false, why end
    self.authorityPrep = { key = key, phase = phase, reports = {}, prior = prior, heldWith = #self:_prepClients() }
    self:PublishPause(); self:PublishAuthorityPrep()
    self:_log("authority prep held phase=%s clients=%d", phase, #self:_prepClients())
    return true
end
-- {key, phase, waiting={slot...}, failed={slot, reason}|nil} for the held prep with this key, or nil.
function Host:AuthorityPrepStatus(key)
    local prep = self.authorityPrep
    if not prep or prep.key ~= key then return nil end
    local waiting, failed = self:_prepWaiting(prep)
    return { key = prep.key, phase = prep.phase, waiting = waiting, failed = failed }
end
function Host.handlers.AUTHORITY_PREP(self, peer, f)
    if not peer.key then return end
    reserved(self, "AUTHORITY_PREP")
    local prep = self.authorityPrep
    if not prep or f.key ~= prep.key or f.phase ~= prep.phase then
        self.stats.authority_prep_stale = (self.stats.authority_prep_stale or 0) + 1; return
    end
    local previous = prep.reports[peer.key]
    if previous and not previous.ok then return end -- a failure is sticky for this hold
    local reason = tostring(f.reason or ""):sub(1, PREP_REASON_BYTES)
    prep.reports[peer.key] = { ok = f.ok == true, reason = reason }
    if f.ok ~= true then self:_log("authority prep phase=%s failed peer=%s reason=%s", prep.phase, Identity.Mask(peer.key), reason) end
    self:PublishAuthorityPrep()
end

-- D43 (reconstructed by Coder A after an accidental revert; confirmed by Coder B): one host boss/unique actor's look
-- for one client's visual-only copy (ACTOR_INFO). False for an unbound key or an invalid look; nothing is sent then.
function Host:SendActorInfo(key, info)
    if not Messages.ValidateActorInfo(info) then return false end
    local fields = { epoch = info.epoch, id = info.id, kind = info.kind, mesh = info.mesh, scale = info.scale, name = info.name, maxHp = info.maxHp }
    for _, peer in pairs(self.peers) do if peer.key == key then return self:_send(peer, "ACTOR_INFO", fields) == true end end
    return false
end

-- Test 10 (S): the host's portal spots for one client (PORTAL_STATE, gmp_portal_mirror.lua). False for an unbound key
-- or an invalid state; nothing is sent then.
function Host:SendPortalState(key, f)
    if not Messages.ValidatePortalState(f) then return false end
    for _, peer in pairs(self.peers) do
        if peer.key == key then return self:_send(peer, "PORTAL_STATE", { epoch = f.epoch, island = f.island, spots = f.spots }) == true end
    end
    return false
end

------------------------------------------------------------------ presence (M3.1; inert unless EnablePresence was called)
-- Attribution comes from the peer's bound key, never from the packet. With presence off the message is counted and dropped.
function Host:EnablePause()
    if not self.sharedPause then self.sharedPause=require('gmp_pause').Host.new(function()
        local participants={};for _,player in ipairs(self.roster:Snapshot()) do if player.conn=='connected' then participants[player.key]=true end end
        return participants
    end) end
    return self.sharedPause
end
function Host:PublishPause()
    if not self.sharedPause or self.sharedPause.revision==0 then return false end
    local sent=true
    for _,peer in pairs(self.peers) do if peer.key then sent=self:_send(peer,'PAUSE_STATE',self.sharedPause:Snapshot()) and sent end end
    self.pauseQueuePending=not sent;return sent
end
function Host:RequestPause(key,paused)
    if not self.sharedPause then return false end
    if self.sharedPause.hostOnly and key~=self.identity.key then return false,'host_only' end
    if self.authorityPrep then return false,'authority_prep' end   -- S1: prep holds the pause until released
    local ok,why=self.sharedPause:Set(key,paused,false,'manual');if ok then self:PublishPause() end
    return ok,why
end
function Host:SetPauseHostOnly(value)
    if type(value)~='boolean' then return false,'invalid_policy' end
    local pause=self:EnablePause()
    if pause.locked then return false,'handover_locked' end
    local owner=pause.owner
    local ok,why=pause:Set(self.identity.key,pause.paused,false,'policy')
    if not ok then return false,why end
    if pause.paused then pause.owner=owner end
    pause.hostOnly=value;self:PublishPause();return true
end
function Host:PauseForHandover(key)
    if not self.sharedPause then return false end
    local ok,why=self.sharedPause:Set(key,true,true,'handover');if ok then self:PublishPause() end
    return ok,why
end
function Host.handlers.PAUSE_REQ(self,peer,f)
    if peer.key then self:RequestPause(peer.key,f.paused) end
end
function Host.handlers.PAUSE_ACK(self,peer,f)
    if peer.key and self.sharedPause then self.sharedPause:Acknowledge(peer.key,f.revision,f.paused) end
end

-- Opt-in authoritative enemy transport. The engine adapter must provide real
-- lifecycle events; these APIs never infer deaths or award gameplay rewards.
function Host:EnableEnemies()
    if not self.enemies then self.enemies=require('gmp_enemies').new() end
    return self.enemies
end
function Host:BeginEnemyIsland()
    if not self.enemies then return false,'enemies_off' end
    local epoch=self.enemies:BeginRun()
    self.enemyPackets=nil
    for _,peer in pairs(self.peers) do peer.enemyFrame=nil;peer.enemyRevision=nil end
    return epoch
end
function Host:ApplyEnemyEvents(events)
    if not self.enemies then return false,'enemies_off' end
    return self.enemies:Apply(events)
end
-- Enemy delta stream (dev, client rows mode; gmp_enemy_delta.lua): once enabled, BroadcastEnemies plans per client
-- (budget, priority by that client's presence position, adaptive rate from its link quality) and sends ENEMY_LIFE
-- (reliable) and ENEMY_MOTION (unreliable) instead of full snapshots. Once a second per client:
-- "HOSTENEMIES tx peer=<mask> hz=<rate> bytes_per_s=<n> sent=<rows> skipped=<rows> rtt_ms=<n|->".
function Host:EnableEnemyDelta(options)
    if not self.enemyDelta then
        self.enemyDelta = require('gmp_enemy_delta').Host.new(options)
        self.enemyDeltaPeers = {}
    end
    return self.enemyDelta
end
function Host:_enemyDeltaQuality(peer, state, now)
    local ok, P = pcall(require, 'gmp_presence')
    local Monitor = ok and type(P) == 'table' and P.LinkMonitor or nil
    if not Monitor then return { backlog = peer.link and peer.link:Pending() or 0 } end
    state.monitor = state.monitor or Monitor.new()
    pcall(state.monitor.Observe, state.monitor, { peer.link }, now)
    if not state.quality or now - (state.qualityAt or -1) >= 1 then
        local read, q = pcall(state.monitor.Quality, state.monitor)
        state.quality, state.qualityAt = read and type(q) == 'table' and q or {}, now
    end
    local q = state.quality
    return { rtt = q.rtt, loss = q.loss, backlog = peer.link and peer.link:Pending() or q.backlog or 0 }
end
function Host:_broadcastEnemyDelta()
    local delta, now, records = self.enemyDelta, self.clock(), self.enemies.records
    local sent = 0
    for _, peer in pairs(self.peers) do
        local rec = peer.key and self.roster:Get(peer.key)
        if rec and rec.conn == 'connected' then
            local state = self.enemyDeltaPeers[peer.key]
            if not state or state.peer ~= peer then
                -- a new connection (reconnect) starts the client over
                delta:Forget(peer.key)
                state = { peer = peer }; self.enemyDeltaPeers[peer.key] = state
            end
            local focus = self.presence and self.presence.entries and self.presence.entries[peer.key] or nil
            local quality = self:_enemyDeltaQuality(peer, state, now)
            local life, motion = delta:Plan(now, peer.key, records, focus, quality)
            for _, f in ipairs(life) do
                if self:_send(peer, 'ENEMY_LIFE', f) then sent = sent + 1 else delta:Revert(peer.key, f) end
            end
            for _, f in ipairs(motion) do if self:_send(peer, 'ENEMY_MOTION', f) then sent = sent + 1 end end
            if not state.loggedAt or now - state.loggedAt >= 1 then
                local s = delta:Stats(peer.key)
                if s and state.loggedAt then
                    self:_log('HOSTENEMIES tx peer=%s hz=%d bytes_per_s=%d sent=%d skipped=%d rtt_ms=%s', Identity.Mask(peer.key),
                        s.hz, s.bytesPerS, s.sent, s.skipped, s.rttMs and tostring(s.rttMs) or '-')
                end
                state.loggedAt = now
            end
        end
    end
    return sent
end
function Host:BroadcastEnemies()
    if not self.enemies or self.enemies.epoch==0 then return 0 end
    if self.enemyDelta then return self:_broadcastEnemyDelta() end
    local registry=self.enemies
    local frame=self.enemyPackets
    if not frame or frame.epoch~=registry.epoch or frame.revision~=registry.revision then
        local packets,why=require('gmp_enemy_stream').Packets(registry:Snapshot(),self.sid,2)
        if not packets then return 0,why end
        frame={epoch=registry.epoch,revision=registry.revision,packets=packets};self.enemyPackets=frame
    end
    local sent=0
    for _,peer in pairs(self.peers) do
        local rec=peer.key and self.roster:Get(peer.key)
        if rec and rec.conn=='connected' then
            local pending=peer.enemyFrame
            -- Finish an older revision before starting a newer one: otherwise
            -- continuously moving enemies could starve snapshot completion.
            if not pending and peer.enemyRevision~=frame.epoch..':'..frame.revision then
                pending={frame=frame,index=1};peer.enemyFrame=pending
            end
            if pending and self:_send(peer,'ENEMY_SNAPSHOT_V2',pending.frame.packets[pending.index]) then
                sent=sent+1;pending.index=pending.index+1
                if pending.index>#pending.frame.packets then
                    peer.enemyRevision=pending.frame.epoch..':'..pending.frame.revision;peer.enemyFrame=nil
                end
            end
        end
    end
    return sent
end

-- Only native-authorized captured outcomes enter this queue. Network application
-- receipts do not retire the native journal; its SDK-attributed witness is separate.
function Host:EnableOutcomes(adapter)
    if type(adapter)~='table' or type(adapter.authorize)~='function' or type(adapter.hold)~='function' or type(adapter.peerEpoch)~='function'then return false,'native_outcome_backend_missing'end
    self.outcomeAdapter=adapter;return true
end
function Host:PublishOutcome(batch)
    if not self.outcomeAdapter then return false,'native_outcome_backend_missing'end
    if self.outcomeFrame then return false,'outcome_backpressure'end
    if type(batch)~='table' or batch.term~=(self.authorityTerm or 1)then return false,'stale_outcome_authority'end
    local ok,authorized=pcall(self.outcomeAdapter.authorize,batch,self.sid)
    if not ok or authorized~=true then return false,'native_outcome_authorization_unavailable'end
    local packets,why=require('gmp_outcome_stream').Packets(batch,self.sid);if not packets then return false,why end
    local frame={sid=self.sid,context=batch.context,term=batch.term,worldEpoch=batch.worldEpoch,revision=batch.revision,journalSeq=batch.journalSeq,packets=packets,required={},acks={}}
    for _,peer in pairs(self.peers)do
        local rec=peer.key and self.roster:Get(peer.key)
        if rec and rec.conn=='connected' and peer.auth and peer.auth.state=='authenticated' and peer.authKey==peer.key then
            local called,current,authEpoch,providerGeneration=pcall(self.outcomeAdapter.peerEpoch,peer.key)
            if not called or current~=true or math.type(authEpoch)~='integer'or authEpoch<1 or math.type(providerGeneration)~='integer'or providerGeneration<1 then return false,'native_outcome_peer_epoch_unavailable'end
            frame.required[peer.key]={peer=peer,auth=peer.auth,link=peer.link,linkEpoch=peer.link.epoch,authEpoch=authEpoch,providerGeneration=providerGeneration}
        end
    end
    self.outcomeFrame=frame;for _,frozen in pairs(frame.required)do frozen.peer.outcomePending={frame=frame,cursor=1}end;return true
end
local function outcomePeerCurrent(self,key,frozen)
    local peer=frozen.peer;local rec=self.roster:Get(key)
    if self.peers[peer.peerId]~=peer or not rec or rec.conn~='connected' or peer.key~=key or peer.authKey~=key
        or peer.auth~=frozen.auth or peer.auth.state~='authenticated' or peer.link~=frozen.link or peer.link.epoch~=frozen.linkEpoch then return false end
    local ok,current,epoch,generation=pcall(self.outcomeAdapter.peerEpoch,key)
    return ok and current==true and epoch==frozen.authEpoch and generation==frozen.providerGeneration
end
function Host.handlers.OUTCOME_ACK(self,peer,f)
    local frame=self.outcomeFrame;local frozen=frame and peer.key and frame.required[peer.key]
    if not frozen or not outcomePeerCurrent(self,peer.key,frozen)then return end
    for _,k in ipairs{'term','worldEpoch','revision','journalSeq'}do if frame[k]~=f[k]then return end end
    if frame.sid~=self.sid or frame.term~=(self.authorityTerm or 1)then return end
    local ok,current=pcall(self.outcomeAdapter.authorize,frame,self.sid);if not ok or current~=true then return end
    frame.acks[peer.key]=true
end
function Host:OutcomeNetworkReceipt()
    local frame=self.outcomeFrame;if not frame then return nil end
    local ok,current=pcall(self.outcomeAdapter.authorize,frame,self.sid)
    if frame.sid~=self.sid or frame.term~=(self.authorityTerm or 1)or not ok or current~=true then return nil,'native_outcome_authority_withdrawn'end
    local r={term=frame.term,worldEpoch=frame.worldEpoch,revision=frame.revision,journalSeq=frame.journalSeq,applied={},complete=true}
    for key,frozen in pairs(frame.required)do if not outcomePeerCurrent(self,key,frozen)then return nil,'native_outcome_peer_epoch_changed'end;if frame.acks[key]then r.applied[#r.applied+1]=key else r.complete=false end end
    table.sort(r.applied);return r
end
function Host:RetireOutcomeNetworkFrame()
    local frame=self.outcomeFrame;if not frame then return false,'outcome_frame_missing'end
    local receipt,why=self:OutcomeNetworkReceipt();if not receipt or not receipt.complete then return false,why or 'outcome_application_pending'end
    -- The adapter must read the native SDK-attributed witness and retire its own
    -- exact journal token. A completed Lua/network barrier alone is insufficient.
    if type(self.outcomeAdapter.RetireOutcome)~='function'then return false,'native_outcome_retirement_unavailable',true end
    local ok,retired,reason=pcall(self.outcomeAdapter.RetireOutcome,frame,receipt)
    if not ok then return false,'native_outcome_retirement_exception',true end
    if retired~=true then return false,reason or 'native_outcome_retirement_pending'end
    for _,frozen in pairs(frame.required)do if frozen.peer.outcomePending and frozen.peer.outcomePending.frame==frame then frozen.peer.outcomePending=nil end end
    self.outcomeFrame=nil;return true
end

function Host:EnablePresence(pcfg)
    if self.presence then return self.presence end
    self.presence = require("gmp_presence").HostPresence.new({ cfg = pcfg, roster = self.roster, log = function(m) self:_log("%s", m) end })
    return self.presence
end

function Host.handlers.PLAYER_STATE(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    if not self.presence then self.stats.presence_off = (self.stats.presence_off or 0) + 1; return end
    self.presence:OnState(peer.key, f, self.clock())
end

function Host.handlers.PLAYER_STATE_VISUAL(self,peer,f)
    if not self.presence or not self.presence.cfg.animation then return end
    if not require('gmp_presentation').valid(f) then return end
    local state={seg=f.seg,x=f.x,y=f.y,z=f.z,dead=f.dead,pose=require('gmp_presentation').copy(f)}
    Host.handlers.PLAYER_STATE(self,peer,state)
end

function Host.handlers.PLAYER_AVATAR_STATE(self,peer,f)
    if not self.presence or not self.presence.cfg.appearance or math.type(f.model)~='integer' then return end
    Host.handlers.PLAYER_STATE_VISUAL(self,peer,f)
end

-- Sends each joined, connected peer the other players' latest states, cut to the packet budget. Sends nothing when there is nothing to say.
function Host:BroadcastPresence()
    local p = self.presence
    if not p then return 0 end
    local now = self.clock()
    local receivers, byKey = {}, {}
    for _, peer in pairs(self.peers) do
        if peer.key and p:_connected(peer.key) then receivers[#receivers + 1] = peer.key; byKey[peer.key] = peer end
    end
    table.sort(receivers)
    local plan = p:Plan(now, receivers, self.sid)
    local sent = 0
    for _, key in ipairs(receivers) do
        local list = plan[key]
        if list and #list > 0 and self:_send(byKey[key], p.cfg.appearance and "WORLD_AVATAR_STATE" or p.cfg.animation and "WORLD_STATE_VISUAL" or "WORLD_STATE", { players = list }) then sent = sent + 1 end
    end
    return sent
end

------------------------------------------------------------------ periodic work
function Host:Tick()
    self:_admitWaiting()
    for _,peer in pairs(self.peers)do
        local budget=4
        local selections=peer.acceptedSelections
        local selectionPending=selections and selections.cursor<=#selections.rows
        local outcome=peer.outcomePending
        local outcomePending=outcome and outcome.cursor<=#outcome.frame.packets
        if outcomePending then
            local ok,authorized=pcall(self.outcomeAdapter.authorize,outcome.frame,self.sid)
            if outcome.frame.sid~=self.sid or outcome.frame.term~=(self.authorityTerm or 1)or not ok or authorized~=true
                or not peer.key or not outcome.frame.required[peer.key] or not outcomePeerCurrent(self,peer.key,outcome.frame.required[peer.key])then
                outcomePending=false;self.outcomeError='native_outcome_authority_withdrawn';peer.outcomePending=nil
                local held,verified=pcall(self.outcomeAdapter.hold,self.outcomeError);self.outcomePhysicalHold=held and verified==true
            end
        end
        if peer.pendingPolicy and budget>0 and self:_send(peer,'SESSION_POLICY',peer.pendingPolicy)then peer.pendingPolicy=nil;budget=budget-1 end
        for _,kind in ipairs{'ROSTER','LOBBY_STATE'}do
            local pending=peer.snapshotPending and peer.snapshotPending[kind]
            while pending and budget>((selectionPending and 1 or 0)+(outcomePending and 1 or 0)) and pending.cursor<=#pending.pages do
                if not self:_send(peer,kind..'_PAGE',pending.pages[pending.cursor])then break end
                pending.cursor=pending.cursor+1;budget=budget-1
            end
            if pending and pending.cursor>#pending.pages then peer.snapshotPending[kind]=nil end
        end
        if selectionPending and budget>0 and self:_send(peer,'ACCEPTED_SELECTION',selections.rows[selections.cursor])then selections.cursor=selections.cursor+1;budget=budget-1 end
        if outcomePending and budget>0 and self:_send(peer,'OUTCOME_V1',outcome.frame.packets[outcome.cursor])then outcome.cursor=outcome.cursor+1;budget=budget-1 end
    end
    self:BroadcastDeparture()
    self:TickDeparture()
    self:TickForcedHandover()
    self:BroadcastHandoverStage()
    self:BroadcastCheckpoint()
    local now = self.clock()
    local list = {}
    for _, p in pairs(self.peers) do list[#list + 1] = p end
    for _, peer in ipairs(list) do
        if self.peers[peer.peerId] then
            local a = peer.auth
            self:_tickMutualAuth(peer)
            if peer.closeAt and now >= peer.closeAt then
                self:_dropPeer(peer, "closed_after_reject")
            elseif PENDING[a.state] and a.state ~= "verifying" and a.deadline and now > a.deadline then
                self:_authFail(peer, "auth_timeout")
            elseif a.state == "verifying" and now > a.verifyDeadline then
                self.verifying[a.claim] = nil
                self:_authFail(peer, "auth_timeout")
            elseif a.state == "authenticated" and a.deadline and not peer.key and not peer.waiting and now > a.deadline then
                self:_dropPeer(peer, "join_timeout")
            elseif now - peer.lastRx > self.cfg.PEER_TIMEOUT then
                self:_dropPeer(peer, "timeout")
            else
                if self.transport.PeerIdentity and peer.key and (not peer.authorityProofSent or peer.authorityProofRevision~=self.roster.rev
                    or not peer.authorityProofAt or now>=peer.authorityProofAt) then
                    self:_sendAuthorityProof(peer)
                end
                if now - peer.lastHb >= self.cfg.HEARTBEAT_INTERVAL then
                    peer.lastHb = now
                    self:_send(peer, "HEARTBEAT", { rosterRev = self.roster.rev })
                end
                local due, failed = peer.link:Due(now, self.cfg.RESEND_INTERVAL, self.cfg.MAX_RESENDS)
                for _, env in ipairs(due) do
                    local s = Codec.Encode(env)
                    if s then self.transport:Send(peer.peerId, s) end
                end
                if failed > 0 then self:_dropPeer(peer, "resend_exhausted") end
            end
        end
    end
end

------------------------------------------------------------------ host actions (local, authoritative)
function Host:StartRun() self.sessionPolicy.locked=true;self.sessionPolicy.revision=self.sessionPolicy.revision+1;self.roster:StartRun(); self:_log("run started"); self:_broadcastRoster() end
function Host:CheckpointComplete()
    local frame=self.checkpointFrame;if not frame then return true end
    for _,player in ipairs(self.roster:Snapshot()) do
        if player.conn=='connected' and (not self.checkpointAcks or self.checkpointAcks[player.key]~=frame.sequence) then return false end
    end
    return true
end
function Host:CheckpointReady()
    return self.checkpointFrame~=nil and self.checkpointPending==nil and self:CheckpointComplete()
end
function Host:EnableDeparture(options)
    if type(options)~='table' or type(options.paused)~='function' or type(options.ready)~='function' then
        return false,'departure_bindings_unavailable'
    end
    self.departureOptions=options;return true
end
function Host:BeginDeparture()
    if not self.departureOptions or not self:CheckpointReady() or self.handoverCommit
        or self.handoverRequest then return false,'departure_checkpoint_unavailable' end
    if self.departure and self.departure.phase~='canceled' then return false,'departure_in_progress' end
    local frame=self.checkpointFrame
    local coordinator,reason=require('gmp_departure_coordinator').new{checkpoint=frame.state,sid=self.sid,
        term=self.authorityTerm or 1,sequence=frame.sequence,digest=frame.digest,kind='graceful',coordinator=self.identity.key,
        paused=self.departureOptions.paused,ready=self.departureOptions.ready}
    if not coordinator then return false,reason end
    if not coordinator:_paused() then return false,'native_pause_unverified' end
    self.departure=coordinator;self.departureBroadcastAt=nil;return true
end
function Host:DepartureState() return self.departure and self.departure:Snapshot(self.identity.key) end
function Host:CancelDeparture()
    if not self.departure then return false,'no_departure' end
    local ok,why=self.departure:Cancel(self.identity.key)
    if ok then self.departureBroadcastAt=nil end;return ok,why
end
function Host:BroadcastDeparture()
    local departure=self.departure;if not departure then return end
    if self.departureBroadcastAt and self.clock()<self.departureBroadcastAt then return end
    self.departureBroadcastAt=self.clock()+.5
    for _,peer in pairs(self.peers) do
        local s=peer.key and departure:Snapshot(peer.key)
        if s then local receipt=s.receipt or {}
            self:_send(peer,'DEPARTURE_STATE',{term=s.term,revision=s.revision,sequence=departure.o.sequence,
                digest=departure.o.digest,coordinator=s.coordinator,eligible=s.eligible,active=s.active,paused=s.paused,
                winner=s.winner or '',request=receipt.request or '',accepted=receipt.accepted==true,
                reason=receipt.reason or '',phase=s.phase})
        end
    end
end
function Host.handlers.DEPARTURE_CLAIM(self,peer,f)
    if not peer.key or not self.departure then return end
    local p=self.roster:Get(peer.key);if not p or p.conn~='connected' then return end
    local ok,result=self.departure:Claim(peer.key,{sid=self.sid,term=f.term,revision=f.revision,key=peer.key,request=f.request})
    self.departureBroadcastAt=nil
    if ok then self:_log('Departure winner selected: %s term=%s; awaiting native application',peer.key,tostring(self.departure.commit.term)) end
    -- Election is not activation. Native transport integration consumes the
    -- selectedState/commit only after its own restoration and receipt barrier.
end
function Host:TickDeparture()
    local d=self.departure;local o=self.departureOptions
    if not d or d.phase~='selected' or self.handoverCommit or not o or o.allowGracefulRuntime~=true
        or type(o.prepare)~='function' then return end
    if not self.sharedPause or not self.sharedPause.paused then return end
    if not self.sharedPause.locked then self:PauseForHandover(self.identity.key);return end
    if not self.sharedPause:Ready() then return end
    local count=0;for _ in pairs(d.required) do count=count+1 end
    local production=self.cfg.MODE=='production' and self.cfg.AUTH_MODE=='steam' and o.productionNative==true
    if production then if count<2 or count>self.cfg.MAX_PLAYERS then return end
    elseif self.cfg.MODE~='dev' or count~=2 then return end
    local ok,ready=pcall(o.prepare,d.selectedState,d.commit)
    if not ok or ready~=true then
        d.phase='failed';self.departureBroadcastAt=nil;self:_log('Departure preparation refused; session held');return
    end
    self.handoverCommit=d.commit;self.handoverNonce=hex(self.rng,16);d.commit.nonce=self.handoverNonce
    self.handoverStageAcks={[self.identity.key]=true};self.handoverStageAt=nil
    self:_freezeHandoverStage(d.selectedState)
    self:_log('Normal departure staged term=%s host=%s',d.commit.term,d.commit.hostKey)
end
-- Only complete checkpoints matching the current authoritative roster qualify.
function Host:PublishCheckpoint(state)
    if self.departure and self.departure.phase~='canceled' then return false,'departure_in_progress' end
    if self.handoverRequest or (self.handoverArbiter and self.handoverArbiter.phase~='running') then
        return false,'handover_in_progress'
    end
    local ok,copy=require('gmp_handover').Validate(state);if not ok then return false,copy end
    local policy,policyWhy=self:LobbyAchievementPolicy()
    if not policy then return false,'session_policy_invalid:'..tostring(policyWhy) end
    copy.sessionPolicy=policy
    -- A checkpoint represents an active run even in isolated development fixtures.
    copy.sessionPolicy.locked=true
    if self.pickups then
        if self.pickups.epoch~=copy.manifest.epoch or self.pickups.island~=copy.manifest.island then return false,'pickup_generation_mismatch' end
        -- This registry belongs to host authority, never the capture caller.
        copy.world.pickups=self.pickups:Capture()
    end
    local found={}
    for _,player in ipairs(copy.players) do
        local current=self.roster:Get(player.key)
        if not current or current.slot~=player.slot or current.role~=player.role or current.conn~=player.conn then
            return false,'checkpoint_roster_mismatch'
        end
        found[player.key]=true
    end
    for _,player in ipairs(self.roster:Snapshot()) do
        if not found[player.key] then return false,'checkpoint_roster_incomplete' end
    end
    local term=self.authorityTerm or 1;local sequence=(self.checkpointSequence or 0)+1
    local packets,why=require('gmp_checkpoint_stream').Packets(copy,term,sequence,self.sid)
    if not packets then return false,why end
    if self.checkpointFrame and not self:CheckpointComplete() then
        -- Retain one newest pending capture. Replacing the in-flight frame on
        -- every capture tick would starve clients before their last fragment.
        self.checkpointPending=copy;return true,'queued'
    end
    self.checkpointPending=nil
    if self.handoverArbiter then
        local recorded,reason=self.handoverArbiter:Record(self.identity.key,term,sequence,copy)
        if not recorded then return false,reason end
    end
    self.checkpointSequence=sequence
    self.checkpointFrame={term=term,sequence=sequence,packets=packets,digest=packets[1].digest,state=copy}
    self.checkpointAcks={[self.identity.key]=sequence};return true
end
function Host:BroadcastCheckpoint()
    if self.checkpointPending and self:CheckpointComplete() then
        local pending=self.checkpointPending;self.checkpointPending=nil
        local ok,why=self:PublishCheckpoint(pending)
        if not ok then self:_log('Queued checkpoint discarded: %s',tostring(why)) end
    end
    local frame=self.checkpointFrame;if not frame then return 0 end
    local sent=0
    for _,peer in pairs(self.peers) do
        local rec=peer.key and self.roster:Get(peer.key)
        if rec and rec.conn=='connected' then
            if peer.checkpointSequence~=frame.sequence then
                peer.checkpointSequence=frame.sequence;peer.checkpointIndex=1;peer.checkpointRetryAt=nil
            end
            local index=peer.checkpointIndex
            if index>#frame.packets and self.checkpointAcks[peer.key]~=frame.sequence
                and peer.checkpointRetryAt and self.clock()>=peer.checkpointRetryAt then
                -- A client may have discarded an incomplete assembly after a
                -- stall even though the link accepted the individual packets.
                index=1;peer.checkpointIndex=1;peer.checkpointRetryAt=nil
            end
            if index<=#frame.packets and self:_send(peer,'CHECKPOINT_CHUNK',frame.packets[index]) then
                peer.checkpointIndex=index+1;sent=sent+1
                if index==#frame.packets then peer.checkpointRetryAt=self.clock()+2 end
            end
        end
    end
    return sent
end
function Host.handlers.CHECKPOINT_ACK(self,peer,f)
    local frame=self.checkpointFrame
    local player=peer.key and self.roster:Get(peer.key)
    if self.peers[peer.peerId]==peer and player and player.conn=='connected'
        and frame and f.term==frame.term and f.sequence==frame.sequence and f.digest==frame.digest then
        self.checkpointAcks[peer.key]=f.sequence
        if self.handoverArbiter then self.handoverArbiter:Acknowledge(peer.key,f.term,f.sequence) end
    end
end
function Host.handlers.PLAYER_STATE_CHUNK(self,peer,f)
    local player=peer.key and self.roster:Get(peer.key);local islands=self.islands
    if self.cfg.MODE~='dev' or self.peers[peer.peerId]~=peer or not player
        or player.conn~='connected' or not islands or islands.phase~='playing'
        or f.term~=(self.authorityTerm or 1) then return end
    local revision=self.sharedPause and self.sharedPause.revision or 0
    local context=tostring(islands.epoch)..':'..tostring(islands.island)..':'..tostring(f.term)..':'..tostring(revision)
    if peer.nativeContext~=context then
        peer.nativeContext=context
        peer.nativeStream=require('gmp_peer_native_state').Receiver(peer.key,islands.epoch,islands.island,f.term,revision)
    end
    local accepted,why=peer.nativeStream:Receive(f,self.clock())
    if accepted and why=='applied' then
        self:_log('PEERNATIVESTATE received player=%s sequence=%d island=%d pauseRevision=%d',
            peer.key,f.sequence,islands.island,revision)
    end
end
function Host.handlers.NATIVE_WORLD_READY(self,peer,f)
    local islands=self.islands
    if self.cfg.MODE~='dev' or self.peers[peer.peerId]~=peer or not peer.key
        or not islands or islands.phase~='playing' or f.term~=(self.authorityTerm or 1)
        or f.epoch~=islands.epoch or f.island~=islands.island then return end
    local player=self:GetPlayer(peer.key)
    if not player or player.conn~='connected' then return end
    self.nativeVisiblePeers=self.nativeVisiblePeers or {}
    self.nativeVisiblePeers[peer.key]=(self.sid or '')..':'..f.term..':'..f.epoch..':'..f.island
end
function Host.handlers.DEV_CYCLE_REPLACEMENT_ACK(self,peer,f)
    local islands=self.islands;local frame=self.checkpointFrame;local player=peer.key and self:GetPlayer(peer.key)
    if self.cfg.MODE~='dev' or not self.devCycleEnabled or self.peers[peer.peerId]~=peer
        or not player or player.conn~='connected' or not islands or not frame or not self.sharedPause or not self.sharedPause.paused
        or f.term~=(self.authorityTerm or 1) or f.epoch~=islands.epoch or f.island~=islands.island
        or f.revision~=self.sharedPause.revision or f.sequence~=frame.sequence or f.digest~=frame.digest then return end
    self.devCycleReplacementAcks=self.devCycleReplacementAcks or {}
    self.devCycleReplacementAcks[peer.key]=table.concat({f.term,f.epoch,f.island,f.revision,f.sequence,f.digest},':')
end
function Host.handlers.DEV_CYCLE_ABORT(self,peer,f)
    local islands=self.islands;local player=peer.key and self:GetPlayer(peer.key)
    if self.cfg.MODE~='dev' or not self.devCycleEnabled or self.peers[peer.peerId]~=peer
        or not player or player.conn~='connected' or not islands
        or f.term~=(self.authorityTerm or 1) or f.epoch~=islands.epoch or f.island~=islands.island then return end
    self.devCycleAbort=tostring(f.reason):sub(1,300)
    self:RequestPause(self.identity.key,true)
    for _,target in pairs(self.peers) do if target.key then self:_send(target,'DEV_CYCLE_ABORT',f) end end
end
function Host:PeerNativeState(key)
    local islands=self.islands;if not islands or islands.phase~='playing' then return nil end
    local context=tostring(islands.epoch)..':'..tostring(islands.island)..':'..tostring(self.authorityTerm or 1)
        ..':'..tostring(self.sharedPause and self.sharedPause.revision or 0)
    for _,peer in pairs(self.peers) do
        if peer.key==key and peer.nativeContext==context and peer.nativeStream then
            local player=self.roster:Get(key)
            if player and player.conn=='connected' then
                local state=peer.nativeStream:Snapshot();return state and state.native
            end
        end
    end
end
-- Source-only development wiring. Native adapters must attest readiness for
-- every participant; no options/default callback can imply restoration works.
function Host:EnableForcedHandover(options)
    if self.cfg.MODE~='dev' or not self.started or type(self.sid)~='string'
        or type(options)~='table' or type(options.ready)~='function'
        or self.handoverArbiter then return false,'runtime_not_ready' end
    local H=require('gmp_handover')
    local arbiter=H.new(self.identity.key,self.sid);arbiter.term=self.authorityTerm or 1
    arbiter.sequence=self.checkpointSequence or 0
    -- Enable before capture starts so ordered sequences have one shared owner.
    if self.checkpointFrame then return false,'checkpoint_already_started' end
    self.handoverOptions=options;self.handoverArbiter=arbiter;return true
end
function Host.handlers.HANDOVER_FORCE_REQ(self,peer,f)
    local frame=self.checkpointFrame;local arbiter=self.handoverArbiter
    local player=peer.key and self.roster:Get(peer.key)
    if self.cfg.MODE~='dev' or not arbiter or self.handoverRequest or arbiter.phase~='running'
        or self.peers[peer.peerId]~=peer or not player or player.conn~='connected'
        or player.role~='client' or not frame or not self:CheckpointReady()
        or f.term~=frame.term or f.sequence~=frame.sequence or f.digest~=frame.digest then return end
    -- Preflight without mutation. No peer changes role before every native
    -- adapter is available and the current checkpoint has reached everyone.
    for _,participant in ipairs(self.roster:Snapshot()) do
        if participant.conn=='connected' then
            local captured=false
            for _,record in ipairs(frame.state.players) do
                if record.key==participant.key and record.slot==participant.slot and record.conn=='connected' then captured=true end
            end
            if not captured then return end
            local ok,ready=pcall(self.handoverOptions.ready,participant.key,arbiter:Snapshot())
            if not ok or ready~=true then self:_log('Forced handover blocked: restore not ready for %s',participant.key);return end
        end
    end
    local paused=self:PauseForHandover(self.identity.key)
    if paused then self.handoverRequest={key=peer.key,term=f.term,sequence=f.sequence,digest=f.digest} end
end
function Host:TickForcedHandover()
    local request=self.handoverRequest;if not request then return end
    local arbiter=self.handoverArbiter
    local player=self.roster:Get(request.key)
    if not player or player.conn~='connected' then
        self.handoverRequest=nil;self.sharedPause:ReleaseHandover(self.identity.key);self:PublishPause();return
    end
    -- Game-thread acknowledgments, not reliable packet ACKs, form this barrier.
    if not self.sharedPause or not self.sharedPause:Ready() then return end
    local ok,commit=arbiter:ForceClaim(request.key,request.term,request.sequence)
    if not ok then self:_log('Forced handover claim blocked: %s',tostring(commit));return end
    assert(arbiter:BeginRestore(commit.hostKey,commit.term))
    commit.digest=self.checkpointFrame.digest
    self.handoverCommit=commit;self.handoverRequest=nil
    self.handoverNonce=hex(self.rng,16);commit.nonce=self.handoverNonce
    self.handoverStageAcks={[self.identity.key]=true}
    self:_freezeHandoverStage(arbiter:Snapshot())
    -- Runtime executor/commit delivery is the next integration stage. Keep
    -- shared pause locked until all transport/native application receipts.
    self:_log('Forced handover staged term=%d host=%s sequence=%d',commit.term,commit.hostKey,commit.sequence)
end
function Host:BroadcastHandoverStage()
    local commit=self.handoverCommit;if not commit then return end
    -- D52: the players waiting for the next game follow the session to the new host, in their order
    for rank,w in ipairs(self:WaitingPlayers()) do
        if w.peer.waiting.moveTerm~=commit.term
            and self:_send(w.peer,'WAIT_MOVE',{hostKey=commit.hostKey,term=commit.term,rank=rank}) then
            w.peer.waiting.moveTerm=commit.term
            self:_log('waiting player %s follows the host change to %s (rank %d)',Identity.Mask(w.key),Identity.Mask(commit.hostKey),rank)
        end
    end
    if self.handoverStageAt and self.clock()<self.handoverStageAt then return end
    self.handoverStageAt=self.clock()+.5
    for _,peer in pairs(self.peers) do
        if peer.key and self.handoverStageAcks[peer.key]==nil then
            self:_send(peer,commit.kind=='graceful' and 'DEPARTURE_STAGE' or 'HANDOVER_STAGE',{term=commit.term,sequence=commit.sequence,
                digest=self.checkpointFrame.digest,hostKey=commit.hostKey,formerHost=commit.formerHost,nonce=self.handoverNonce})
        end
    end
end
function Host.handlers.HANDOVER_STAGE_ACK(self,peer,f)
    local commit=self.handoverCommit;local player=peer.key and self.roster:Get(peer.key)
    if not commit or self.peers[peer.peerId]~=peer or not player or player.conn~='connected'
        or f.term~=commit.term or f.sequence~=commit.sequence or f.digest~=self.checkpointFrame.digest then return end
    if self.handoverStageAcks[peer.key]==nil then self.handoverStageAcks[peer.key]=f.ready end
    if not f.ready then self.handoverStageFailure='prepare_rejected:'..peer.key end
end
function Host:_freezeHandoverStage(state)
    self.handoverStageRequired={}
    for _,player in ipairs(state.players)do if player.conn=='connected'then self.handoverStageRequired[player.key]=true end end
end
function Host:HandoverStageReady()
    if not self.handoverCommit or self.handoverStageFailure then return false end
    if not self.handoverStageRequired then return false end
    for key in pairs(self.handoverStageRequired)do if self.handoverStageAcks[key]~=true then return false end end
    return true
end


-- Allow Auto Rejoin maps onto the EXISTING session policy cfg.ALLOW_AUTO_REJOIN (Roster:Rejoin already honours it).
function Host:SetAllowAutoRejoin(on)
    if type(on) ~= "boolean" then return nil, "bad_value" end
    if self.cfg.ALLOW_AUTO_REJOIN ~= on then self.cfg.ALLOW_AUTO_REJOIN = on; self.roster:_lbump(); self:_log("Allow Auto Rejoin -> %s", tostring(on)); self:_broadcastLobby() end
    return true
end

function Host:Chat(text) return self:_publishChat(self.identity.key, text) end
function Host:ColorAvailability() return self.roster:ColorAvailability() end
function Host:LobbyState() return self:_lobbyFields() end

function Host:SetHostColor(color)
    local rec, why = self.roster:SetColor(self.identity.key, color)
    if rec then self:_broadcastRoster() end
    return rec ~= nil, why
end

function Host:ReleaseReservation(key)
    local ok = self.roster:ReleaseReservation(key)
    if ok then self:_broadcastRoster() end
    return ok
end

function Host:Kick(key, reason)
    local target
    for _, p in pairs(self.peers) do if p.key == key then target = p end end
    local ok, why = self.roster:Kick(key)
    if not ok then return nil, why end
    if target then
        self:_send(target, "KICK", { reason = reason or "kicked" })
        target.key = nil
        target.closeAt = self.clock() + 1.5
    end
    self:_log("kicked %s", Identity.Mask(key))
    self:_broadcastRoster(); self:_broadcastLobby()
    return true
end

function Host:AuthStates()
    local out = {}
    for _, p in pairs(self.peers) do out[#out + 1] = { peerId = p.peerId, state = p.auth.state, authKey = p.authKey, order = p.order } end
    table.sort(out, function(x, y) return x.order < y.order end)
    return out
end

function Host:Permit(key) self.roster:Permit(key); return true end
function Host:CurrentPlayers() return self.roster:CurrentPlayers() end
function Host:Players() return self.roster:Snapshot() end
function Host:Display(opts) return Roster.DisplayOrder(self.roster:Snapshot(), opts) end
function Host:GetPlayer(key) return self.roster:Get(key) end

require('gmp_host_entry').Install(Host)
require('gmp_cheat_requests').Install(Host, nil)   -- D56 (Coder D): clients' F6/F7/F8 requests (CHEAT_REQ)
return Host
