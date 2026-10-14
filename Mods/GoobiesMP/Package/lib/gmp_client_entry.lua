-- Client world-entry mixin (PLAN_WORLD_ENTRY.md 3.2 item 5; Track W). Lobby start, session policy mirror, loadout
-- requests and the shared island lifecycle, moved unchanged out of gmp_client.lua and installed onto Client by
-- require('gmp_client_entry').Install(Client). Heartbeat, pause, enemies and outcomes stay in gmp_client.lua.
local Config = require("gmp_config")
local Messages = require("gmp_messages")

local Client = { handlers = {} }   -- mixin; every field is copied onto the real Client by Install

function Client:EnableIslands()
    if not self.islands then self.islands=require('gmp_islands').Client.new() end
    return self.islands
end
function Client:EnableTravelGate() self.travelGate=true end
function Client:LoadingWaiters() return self.loadingWaiting or {} end
function Client:TravelWaiters() return self.travelWaiting or {} end
function Client:UpdateTravelGate(blocked)
    local check=self.travelCheck
    if not check or self.state~='joined' then return false end
    if check.reported==blocked then return true end
    local sent=self:_send('TRAVEL_STATUS',{epoch=check.epoch,island=check.island,token=check.token,blocked=blocked})
    if sent then check.reported=blocked end
    return sent
end
function Client:RequestIslandResume()
    -- ODD_INTERACTIONS row 8 (Coder C): also while a resumed entry has not taken its settings (gmp_islands Refreshable)
    if self.state~='joined' or not self.islands or (self.islands.phase~='idle' and not self.islands:Refreshable()) then return false end
    if not self.islandResumeToken then
        self.islandResumeCounter=(self.islandResumeCounter or 0)+1
        self.islandResumeToken=self.islandResumeCounter
    end
    return self:_send('ISLAND_RESUME_REQ',{token=self.islandResumeToken})
end
function Client:RequestPortal()
    if self.state~='joined' or not self.islands or self.islands.phase~='playing' then return false end
    return self:_send('PORTAL_REQ',{epoch=self.islands.epoch,island=self.islands.island})
end
function Client:IslandGenerated(stamp)
    if self.state~='joined' or not self.islands or not self.islands.pending then return false end
    local ok=self.islands.phase=='ready' and stamp==require('gmp_islands').Stamp(self.islands.pending)
    if not ok then ok=self.islands:Generated(stamp) end
    if not ok then return false end
    return self:_send('ISLAND_READY',{epoch=self.islands.pending.epoch,island=self.islands.pending.island,stamp=stamp})
end
function Client:LobbyAchievementPolicy()
 local policy=self.sessionPolicy;if not policy then return nil end
 return Messages.CopyPolicy(policy)
end
function Client:RequestSelection(class, artifacts) if self.state ~= "joined" then return false end return self:_send("SELECT_REQ", { class = class or "", artifacts = artifacts or "" }) end
function Client:RequestReady(on) if self.state ~= "joined" then return false end return self:_send("READY_REQ", { ready = on and true or false, policyRevision=self.sessionPolicy and self.sessionPolicy.revision or 0 }) end
function Client.handlers.START(self, f)
    if self.state ~= "joined" then return end
    self.started = (f.state == "handoff_pending")
end
function Client.handlers.TRAVEL_CHECK(self,f)
    local state=self.islands
    if not self.travelGate or self.state~='joined' or not state or state.phase~='playing' then return end
    if f.epoch~=state.epoch or f.island~=state.island or f.token<1 or f.token>2147483647 then return end
    if self.travelCheck and f.token<=self.travelCheck.token then return end
    self.travelCheck={epoch=f.epoch,island=f.island,token=f.token}
end
function Client.handlers.ISLAND_WAIT(self,f)
    local state=self.islands;local pending=state and state.pending
    if self.state~='joined' or not pending or f.epoch~=pending.epoch or f.island~=pending.island then return end
    if #f.players>Config.MAX_PLAYERS_LIMIT then return end
    local slots,seen={},{}
    for _,row in ipairs(f.players) do
        if row.slot<1 or row.slot>Config.MAX_PLAYERS_LIMIT or row.slot%1~=0 or seen[row.slot] then return end
        seen[row.slot]=true;slots[#slots+1]=row.slot
    end
    table.sort(slots);self.loadingWaiting=slots
end
function Client.handlers.TRAVEL_WAIT(self,f)
    local check=self.travelCheck
    if not check or f.epoch~=check.epoch or f.island~=check.island or f.token~=check.token then return end
    if #f.players>Config.MAX_PLAYERS_LIMIT then return end
    local slots,seen={},{}
    for _,row in ipairs(f.players) do
        if row.slot<1 or row.slot>Config.MAX_PLAYERS_LIMIT or row.slot%1~=0 or seen[row.slot] then return end
        seen[row.slot]=true;slots[#slots+1]=row.slot
    end
    table.sort(slots);self.travelWaiting=slots
end
function Client.handlers.ISLAND_RESUME(self,f)
    if self.state~='joined' or not self.islands or (self.islands.phase~='idle' and not self.islands:Refreshable())
        or f.token~=self.islandResumeToken then return end   -- row 8 (Coder C)
    local manifest=require('gmp_islands').FromWire(f)
    if manifest and self.islands:Resume(manifest) then self.islandResumeToken=nil end
end
function Client.handlers.ISLAND_END(self,f)
    local state=self.islands
    if self.state~='joined' or not state or state.phase=='idle' or (f.epoch~=state.epoch and (not state.pending or f.epoch~=state.pending.epoch)) then return end
    state.phase='host_left';state.pending=nil;state.announced=nil
    self.travelCheck=nil;self.travelWaiting=nil;self.loadingWaiting=nil
end
function Client.handlers.ISLAND_BEGIN(self,f)
    if not self.islands or self.state~='joined' or self.islands.phase=='host_left' then return end
    local current=self.islands
    if current.pending then return end
    if (f.epoch==current.epoch and f.island==current.island+1) or (f.epoch>current.epoch and f.island==1) then
        self.travelCheck=nil;self.travelWaiting=nil
        current.announced={epoch=f.epoch,island=f.island};current.phase='transitioning'
    end
end
function Client.handlers.ISLAND_MANIFEST(self,f)
    if not self.islands or self.state~='joined' or self.islands.phase=='host_left' then return end
    local manifest=require('gmp_islands').FromWire(f)
    if manifest then self.islands:Prepare(manifest) end
end
function Client.handlers.ISLAND_COMMIT(self,f)
    if not self.islands or self.state~='joined' then return end
    if self.islands:Commit(f.epoch,f.island,f.stamp) then self.loadingWaiting=nil end
end
-- Host session policy mirror. Accepted only from the host over a joined session; stale revisions are ignored.
-- Protocol 9 carries no artifact rows yet (paged by W11), so the mirrored artifact lists start empty.
function Client.handlers.SESSION_POLICY(self,f)
 if self.state~='joined' or f.revision<1 or math.type(f.runGeneration)~='integer' or f.runGeneration<1 or f.runGeneration>9007199254740991 then return end
 if self.sessionPolicy and f.revision<self.sessionPolicy.revision then return end
 if self.sessionPolicy and f.revision==self.sessionPolicy.revision
  and (f.locked~=self.sessionPolicy.locked or f.runGeneration~=self.sessionPolicy.runGeneration) then return end
 if self.sessionPolicy and f.runGeneration<self.sessionPolicy.runGeneration then return end
 -- The same revision again (every LOBBY_STATE carries it): keep the lists already paged for it (W11), re-acknowledge.
 if self.sessionPolicy and f.revision==self.sessionPolicy.revision then self:_send('SESSION_POLICY_ACK',{revision=f.revision});return end
 local policy={revision=f.revision,locked=f.locked,runGeneration=f.runGeneration,artifacts={},hostUnlocked={}}
 if not Messages.ValidatePolicy(policy) then return end
 self.sessionPolicy=policy
 if self.lobby then self.lobby.sessionPolicy=self.sessionPolicy end
 self:_send('SESSION_POLICY_ACK',{revision=f.revision})
end

-- Receipt of the reserved (C0) types is recorded.
local function reserved(self, typ)
    self.reservedReceived = self.reservedReceived or {}
    self.reservedReceived[typ] = (self.reservedReceived[typ] or 0) + 1
end
-- W10 (D24): the host aborted the run (prep/generating timeout or host abort). Applied once per new run generation while
-- joined; the app leaves the run through the menu exit and the lobby shows the reason.
-- stuck_transition (D40): only this player leaves the run, at the current generation; the others play on.
local ABORT_REASONS = { prep_timeout = true, generating_timeout = true, host_abort = true, stuck_transition = true }
-- D42: the host's gameplay mod manifest (compared by the app; gmp_mod_manifest.lua).
function Client.handlers.MOD_MANIFEST(self, f)
    if self.state ~= "joined" or type(f.mods) ~= "string" then return end
    self.hostModManifest, self.hostModManifestSid = f.mods, self.sid
end
-- Test 10: this client's live HUD numbers from the host (the newest set; gmp_live_hud.lua shows only its own run's).
function Client.handlers.LIVE_STATS(self, f)
    if self.state ~= "joined" then return end
    local fields = require("gmp_messages").ValidateLiveStats(f)
    if fields then self.liveStats = fields end
end
-- D41: the host's player cheats; newer revisions only, bound to this session (sid).
function Client.handlers.CHEAT_STATE(self, f)
    if self.state ~= "joined" or math.type(f.revision) ~= "integer" or f.revision < 1 then return end
    local cur = self.hostCheats
    if cur and cur.sid == self.sid and f.revision <= cur.revision then return end
    self.hostCheats = { revision = f.revision, invulnerable = f.invulnerable == true, unlockClasses = f.unlockClasses == true, sid = self.sid }
end
function Client.handlers.RUN_ABORT(self, f)
    reserved(self, "RUN_ABORT")
    if self.state ~= "joined" or math.type(f.runGeneration) ~= "integer" or not ABORT_REASONS[f.reason] then return end
    if self.runAbort and f.runGeneration <= self.runAbort.runGeneration then return end
    if self.sessionPolicy and f.runGeneration < self.sessionPolicy.runGeneration then return end
    self.runAbort = { runGeneration = f.runGeneration, reason = f.reason }; self.started = false
    self:_log("run aborted runGeneration=%d reason=%s", f.runGeneration, f.reason)
end
-- W6: the host returned the run to the lobby. Applied once per new run generation while joined: the previous START
-- no longer counts, so the lobby can start the next run.
function Client.handlers.LOBBY_RETURN(self, f)
    reserved(self, "LOBBY_RETURN")
    if self.state ~= "joined" or math.type(f.runGeneration) ~= "integer" then return end
    if self.lobbyReturn and f.runGeneration <= self.lobbyReturn then return end
    if self.sessionPolicy and f.runGeneration < self.sessionPolicy.runGeneration then return end
    self.lobbyReturn = f.runGeneration; self.started = false
    self:_log("lobby return runGeneration=%d", f.runGeneration)
end
-- Reserved (C0) stub for W11: paged policy lists (gmp_messages.lua PolicyListReceive holds the reassembly rules).
-- W11: the host's paged policy lists (artifacts, hostUnlocked) for the mirrored revision (Messages.PolicyListReceive).
-- Receiving any page means this host pages its lists, so later revisions are complete only once both lists arrived.
function Client.handlers.POLICY_LIST(self, f)
    reserved(self, "POLICY_LIST")
    local policy = self.sessionPolicy
    if self.state ~= "joined" or not policy then return end
    self.policyListState = self.policyListState or {}
    local done, paths = Messages.PolicyListReceive(self.policyListState, f, policy.revision)
    if done == false then self:_log("policy list refused: %s", tostring(paths)); return end
    self.policyListsExpected = true
    if done == nil then return end
    local copy = {}; for i, path in ipairs(paths) do copy[i] = path end
    policy[f.list] = copy
    self.policyLists = self.policyLists or {}; self.policyLists[f.list] = policy.revision
end
-- True when the mirrored policy's lists are complete: either this host does not page lists, or both arrived for it.
function Client:PolicyListsComplete()
    if not self.policyListsExpected then return true end
    local policy, got = self.sessionPolicy, self.policyLists or {}
    return policy ~= nil and got.artifacts == policy.revision and got.hostUnlocked == policy.revision
end

local E = {}
function E.Install(target)
    assert(type(target) == "table" and type(target.handlers) == "table", "Client with a handlers table required")
    for name, fn in pairs(Client) do if name ~= "handlers" then target[name] = fn end end
    for name, fn in pairs(Client.handlers) do target.handlers[name] = fn end
    return target
end
return E
