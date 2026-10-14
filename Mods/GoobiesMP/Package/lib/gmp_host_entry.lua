-- Host world-entry mixin (PLAN_WORLD_ENTRY.md 3.2 item 5; Track W). Lobby start/end, session policy, loadout
-- selection and the shared island lifecycle, moved unchanged out of gmp_host.lua and installed onto Host by
-- require('gmp_host_entry').Install(Host). Heartbeat, pause, enemies, outcomes and peer drop stay in gmp_host.lua.
local Codec = require("gmp_codec")
local Messages = require("gmp_messages")

local Host = { handlers = {} }   -- mixin; every field is copied onto the real Host by Install

-- Lobby Start (host only). Ends in "handoff_pending": the roster enters the run phase (so later departures are RESERVED, the approved
-- in-run semantics) but NO gameplay is started or synchronised -- that hand-off is a later milestone.
function Host:LobbyStart()
    local ok, why = self.roster:Start()
    if not ok then self:_log("start refused: %s", tostring(why)); return nil, why end
    self.sessionPolicy.locked=true;self.sessionPolicy.revision=self.sessionPolicy.revision+1
    self:_log("lobby start accepted: players=%d state=handoff_pending (gameplay hand-off not implemented)", self.roster:CurrentPlayers())
    for _, peer in pairs(self.peers) do if peer.key then self:_send(peer, "START", { state = self.roster.lobbyState, lrev = self.roster.lrev }) end end
    self:_broadcastRoster(); self:_broadcastLobby()
    return true
end
-- D37: the host's Ready starts a countdown (lobby state "countdown", sent in LOBBY_STATE like every lobby state; no new
-- message). It is canceled by the host, by a player no longer Ready, or by any membership change. When it is due the
-- lobby is open again and the caller runs the normal gated start (gmp_lobby_screen 'host_start').
function Host:BeginStartCountdown(seconds)
    local r = self.roster
    if r.phase ~= "lobby" or r.lobbyState ~= "open" then return false, "lobby_closed" end
    if not r:AllReady() then return false, "players_not_ready" end
    seconds = seconds or 5
    r.lobbyState = "countdown"; r:_lbump()
    self.startCountdown = { endsAt = self.clock() + seconds, seconds = seconds, rosterRev = r.rev }
    self:_log("start countdown %ds", seconds)
    self:_broadcastLobby()
    return true
end
function Host:CancelStartCountdown(reason)
    if not self.startCountdown then return false, "no_countdown" end
    self.startCountdown = nil; self.startCountdownCanceled = tostring(reason or "canceled")
    if self.roster.lobbyState == "countdown" then self.roster.lobbyState = "open"; self.roster:_lbump() end
    self:_log("start countdown canceled: %s", self.startCountdownCanceled)
    self:_broadcastLobby()
    return true
end
function Host:StartCountdownRemaining()
    local c = self.startCountdown
    return c and math.max(0, math.ceil(c.endsAt - self.clock() - 1e-9)) or nil
end
-- Returns "due" once the countdown reached 0 with every gate this module can see still passing (lobby open again).
function Host:TickStartCountdown()
    local c, r = self.startCountdown, self.roster
    if not c then return nil end
    if r.phase ~= "lobby" or r.lobbyState ~= "countdown" then self.startCountdown = nil; return nil end
    if not r:AllReady() then self:CancelStartCountdown("player_unready"); return nil end
    if r.rev ~= c.rosterRev then self:CancelStartCountdown("players_changed"); return nil end
    if self.clock() < c.endsAt then return nil end
    self.startCountdown = nil; r.lobbyState = "open"; r:_lbump()
    return "due"
end
-- S8 (moved to Track W; D23): host-credited stats. One end-screen row per player slot (host included) from the
-- attribution source {[key]={kills, damage, weapons={[type]={damage, kills}}}} (runSync:Status().attribution, set by
-- gmp_app.lua as host.runStatsSource). Counts are floored non-negative integers; a row keeps its 16 highest-damage
-- weapons whose type the wire can carry. Display only: nothing here is saved (D19/D23).
local function counted(v) if math.type(v) == "integer" then return v >= 0 and v or 0 end
    if type(v) == "number" and v == v and v >= 0 and v < 2^53 then return math.floor(v) end; return 0 end
local function wireType(v) return type(v) == "string" and #v >= 1 and #v <= Messages.RunStats.MAX_TYPE_BYTES and not v:find("[^ -~]") and not v:find("[%%|,;]") end
function Host.RunStatsRows(players, attribution)
    local rows = {}
    for _, player in ipairs(players) do
        local a = type(attribution) == "table" and attribution[player.key] or nil
        local row = { slot = player.slot, kills = 0, damage = 0, weapons = {} }
        if type(a) == "table" then
            row.kills, row.damage = counted(a.kills), counted(a.damage)
            if type(a.weapons) == "table" then
                for kind, w in pairs(a.weapons) do
                    if wireType(kind) and type(w) == "table" then row.weapons[#row.weapons + 1] = { type = kind, damage = counted(w.damage), kills = counted(w.kills) } end
                end
                table.sort(row.weapons, function(x, y) if x.damage ~= y.damage then return x.damage > y.damage end; return x.type < y.type end)
                for i = #row.weapons, Messages.RunStats.MAX_WEAPONS + 1, -1 do row.weapons[i] = nil end
            end
        end
        rows[#rows + 1] = row
    end
    table.sort(rows, function(x, y) return x.slot < y.slot end)
    return rows
end
-- Page the set to every client with the run's own generation. Called at run end before the generation moves on.
function Host:PublishRunStats()
    if self.roster.phase ~= "run" then return false, "not_in_run" end
    if type(self.runStatsSource) ~= "function" then self:_log("run stats unavailable: no attribution source"); return false, "no_source" end
    local ok, attribution = pcall(self.runStatsSource)
    if not ok then self:_log("run stats unavailable: %s", tostring(attribution):sub(1, 200)); return false, "source_failed" end
    local players = {}
    for _, rec in ipairs(self.roster:Snapshot()) do players[#players + 1] = { key = rec.key, slot = rec.slot } end
    local generation = self.sessionPolicy.runGeneration or 1
    local parts, why = Messages.RunStatsParts({ runGeneration = generation, rows = Host.RunStatsRows(players, attribution) })
    if not parts then self:_log("run stats refused: %s", tostring(why)); return false, why end
    for _, peer in pairs(self.peers) do
        if peer.key then for _, part in ipairs(parts) do self:_send(peer, "RUN_STATS", part) end end
    end
    self:_log("run stats sent runGeneration=%d rows=%d parts=%d", generation, #players, #parts)
    return true
end
function Host:EndRun() self:PublishRunStats(); self.sessionPolicy.runGeneration=(self.sessionPolicy.runGeneration or 1)+1;self.sessionPolicy.locked=false;self.sessionPolicy.revision=self.sessionPolicy.revision+1;self.roster:EndRun(); self:_log("run ended; reservations released"); self:_broadcastRoster(); self:_broadcastLobby() end
-- W6: return the run to the lobby when the host reaches the menu. The next run generation's policy is unlocked,
-- reservations are kept, and every client is told with LOBBY_RETURN{runGeneration}. Refused outside a run.
function Host:ReturnToLobby()
    if self.roster.phase ~= "run" then return false, "not_in_run" end
    self:PublishRunStats()   -- S8: the end screen set, with this run's generation
    local generation = (self.sessionPolicy.runGeneration or 1) + 1
    self.sessionPolicy.runGeneration = generation; self.sessionPolicy.locked = false
    self.sessionPolicy.revision = self.sessionPolicy.revision + 1
    local kept = self.roster:ReturnToLobby()
    self:_log("lobby return runGeneration=%d reservations=%d", generation, kept)
    for _, peer in pairs(self.peers) do if peer.key then self:_send(peer, "LOBBY_RETURN", { runGeneration = generation }) end end
    self:_broadcastRoster(); self:_broadcastLobby()
    return true, generation
end
-- W10 (D24): abort a run. Like ReturnToLobby (next generation, unlocked policy, reservations kept), but every client is
-- told RUN_ABORT{runGeneration, reason} and the host records runAborted for its own menu exit and lobby message.
Host.ABORT_REASONS = { prep_timeout = true, generating_timeout = true, host_abort = true }
function Host:AbortRun(reason)
    if not Host.ABORT_REASONS[reason] then return false, "bad_abort_reason" end
    if self.roster.phase ~= "run" then return false, "not_in_run" end
    local generation = (self.sessionPolicy.runGeneration or 1) + 1
    self.sessionPolicy.runGeneration = generation; self.sessionPolicy.locked = false
    self.sessionPolicy.revision = self.sessionPolicy.revision + 1
    local kept = self.roster:ReturnToLobby()
    self.runAborted = { runGeneration = generation, reason = reason }; self.stuckPhase = nil
    self:_log("run aborted runGeneration=%d reason=%s reservations=%d", generation, reason, kept)
    for _, peer in pairs(self.peers) do if peer.key then self:_send(peer, "RUN_ABORT", { runGeneration = generation, reason = reason }) end end
    self:_broadcastRoster(); self:_broadcastLobby()
    return true, generation
end
-- D55: the host types this lobby's max players (Host lobby box). 2..Config.MAX_PLAYERS_LIMIT, never below the players
-- in the lobby, lobby phase only; it lives on the roster (this lobby only, never saved: a new lobby starts from
-- cfg.MAX_PLAYERS). Joins beyond it are session_full (Roster:Join).
function Host:SetLobbyMaxPlayers(n)
    local Config = require("gmp_config")
    if math.type(n) ~= "integer" then
        if type(n) == "number" and n == math.floor(n) then n = math.tointeger(n) else return false, "max_players_invalid" end
    end
    if not n or n < 2 or n > Config.MAX_PLAYERS_LIMIT then return false, "max_players_invalid" end
    if self.roster.phase ~= "lobby" then return false, "max_players_lobby_only" end
    if n < self.roster:Count() then return false, "max_players_below_players" end
    if self.roster.maxPlayers ~= n then
        -- A Steam lobby follows (self.lobbyLimit, set by the app: GMP_Lob_Limit). A native refusal keeps the old size;
        -- a provider without the export (nil, 'unavailable') leaves the roster limit alone authoritative.
        if self.lobbyLimit then
            local called, ok, why = pcall(self.lobbyLimit, n)
            if not called then return false, "max_players_steam_error" end
            if ok == false then return false, "max_players_steam_" .. tostring(why or "refused") end
            if ok == nil then self:_log("lobby max players: the Steam lobby keeps its limit (%s)", tostring(why)) end
        end
        self.roster.maxPlayers = n; self.roster:_bump(); self.roster:_lbump()
        self:_log("lobby max players -> %d", n)
        self:_broadcastRoster(); self:_broadcastLobby()
    end
    return true
end
Host.RETRY_SECONDS = 20
-- W10: a run is stuck in prep while the S1 prep pause is held (authorityPrep), or in generating while the islands are not
-- playing during a run. A phase lasting PREP_TIMEOUT_SECONDS / GENERATING_TIMEOUT_SECONDS aborts the run; any change of
-- phase, island or prep key restarts the timer. Driven every host tick by App:Tick. Returns the abort reason when it fired.
function Host:TickStuckPhases()
    local now = self.clock()
    if self.roster.phase ~= "run" then self.stuckPhase = nil; return nil end
    -- Test 14 (D40): a prep held for clients that have all left (disconnected or reserved) completes for the host
    -- alone, at once; departed clients never count in the wait (Host:_prepClients is the connected players).
    local held = self.authorityPrep
    if type(held) == "table" and (held.heldWith or 0) > 0 and #self:_prepClients() == 0 then
        self:_log("authority prep: no client left in it (phase=%s); released for the host alone", tostring(held.phase))
        self:PauseForAuthorityPrep(held.key, false)
        self.stuckPhase = nil
        return "prep_released"
    end
    local islands = self.islands
    local phase, limit, token
    if type(self.authorityPrep) == "table" then
        phase, limit = "prep", self.cfg.PREP_TIMEOUT_SECONDS
        token = "prep:" .. tostring(self.authorityPrep.key) .. ":" .. tostring(self.authorityPrep.phase)
    elseif not islands or islands.phase ~= "playing" then
        phase, limit = "generating", self.cfg.GENERATING_TIMEOUT_SECONDS
        token = "generating:" .. tostring(islands and islands.phase) .. ":" .. tostring(islands and islands.epoch) .. ":" .. tostring(islands and islands.island)
    end
    if not phase then self.stuckPhase = nil; return nil end
    if not self.stuckPhase or self.stuckPhase.token ~= token then self.stuckPhase = { token = token, since = now }; return nil end
    -- D40: after the retry the second wait is RETRY_SECONDS (a stuck player costs limit + 20 s, not two limits).
    if type(limit) == "number" and self.stuckPhase.retried then limit = math.min(limit, Host.RETRY_SECONDS) end
    if type(limit) ~= "number" or now - self.stuckPhase.since < limit then return nil end
    local reason = phase .. "_timeout"
    -- D40: when the stuck ones are clients, retry once, then leave them behind; only a stuck host ends the run.
    local stuck = self:_stuckClients(phase)
    if stuck and #stuck > 0 then
        self.stuckRetries = self.stuckRetries or {}
        self.stuckPhase.since = now
        local left = 0
        for _, rec in ipairs(stuck) do
            local tries = self.stuckRetries[rec.key] or 0
            if tries < 1 then
                self.stuckRetries[rec.key] = tries + 1
                self.stuckPhase.retried = true
                self:_retryTransition(rec.key, phase)
            elseif self:LeaveBehind(rec.key, phase) then
                left = left + 1
            end
        end
        return left > 0 and "stuck_transition" or "retry"
    end
    if self:AbortRun(reason) then return reason end
    return nil
end
-- D40: the connected clients the current phase waits for, or nil when the host itself is the one stuck (no manifest
-- yet, its own island not ready, its own prep not released with nobody waiting).
function Host:_stuckClients(phase)
    local out = {}
    if phase == "prep" then
        local prep = self.authorityPrep
        prep.reports = prep.reports or {}
        local waiting = self:_prepWaiting(prep)
        local bySlot = {}
        for _, rec in ipairs(self.roster:Snapshot()) do bySlot[rec.slot] = rec end
        for _, slot in ipairs(waiting) do
            local rec = bySlot[slot]
            if rec and rec.key ~= self.identity.key and rec.conn == "connected" then out[#out + 1] = rec end
        end
        return #out > 0 and out or nil
    end
    local islands = self.islands
    if not islands or islands.phase ~= "generating" or type(islands.required) ~= "table" then return nil end
    if islands.required[self.identity.key] and not islands.ready[self.identity.key] then return nil end
    for _, rec in ipairs(self.roster:Snapshot()) do
        if rec.key ~= self.identity.key and rec.conn == "connected" and islands.required[rec.key] and not islands.ready[rec.key] then
            out[#out + 1] = rec
        end
    end
    return #out > 0 and out or nil
end
function Host:_peerByKey(key)
    for _, peer in pairs(self.peers) do if peer.key == key then return peer end end
    return nil
end
-- D40 retry: send the stuck player the current transition again (the island manifest it should be loading, or the
-- prep state and the island commit it should be acting on); it gets one more timeout to make it.
function Host:_retryTransition(key, phase)
    local peer = self:_peerByKey(key)
    self:_log("stuck transition retry phase=%s player=%s", phase, require("gmp_identity").Mask(key))
    if not peer then return false end
    if phase == "prep" then
        self:PublishAuthorityPrep()
        if self.islandCommit then self:_send(peer, "ISLAND_COMMIT", self.islandCommit) end
    elseif self.islands and self.islands.pending then
        local wire = require("gmp_islands").ToWire(self.islands.pending)
        if wire then self:_send(peer, "ISLAND_MANIFEST", wire) end
    end
    return true
end
-- D40: only this player leaves the run: it is told RUN_ABORT{current generation, stuck_transition} (main menu, rejoin
-- offered) and dropped once the message had time to arrive; its slot stays reserved (D20) and the waits release.
Host.LEAVE_BEHIND_SECONDS = 1.5
function Host:LeaveBehind(key, phase)
    local peer = self:_peerByKey(key)
    if not peer or peer.leftBehind then return false end
    peer.leftBehind = true
    self:_send(peer, "RUN_ABORT", { runGeneration = self.sessionPolicy.runGeneration or 1, reason = "stuck_transition" })
    peer.closeAt = self.clock() + Host.LEAVE_BEHIND_SECONDS
    self:_log("stuck transition: player %s left behind (phase=%s); the run goes on", require("gmp_identity").Mask(key), tostring(phase))
    return true
end
-- W8 (D20/D24): expire reservations older than RESERVATION_MINUTES on the host clock; the freed slots are broadcast.
-- Driven every host tick by App:Tick. Returns the expired keys.
function Host:TickReservations()
    local expired = self.roster:ExpireReservations(self.clock())
    if #expired == 0 then return expired end
    for _, key in ipairs(expired) do
        self:_log("reservation expired %s after %d min", require("gmp_identity").Mask(key), self.cfg.RESERVATION_MINUTES)
    end
    self:_broadcastRoster(); self:_broadcastLobby()
    return expired
end
-- D41: the host's player cheats (Invulnerable, Unlock all classes). A change raises the revision; TickCheatState sends
-- the current state to every joined peer that does not have it yet (also a peer that joins later).
function Host:SetCheatState(state)
    if type(state) ~= "table" then return false end
    local inv, unlock = state.invulnerable == true, state.unlockClasses == true
    local cur = self.cheatState
    if cur and cur.invulnerable == inv and cur.unlockClasses == unlock then return true end
    self.cheatState = { revision = (cur and cur.revision or 0) + 1, invulnerable = inv, unlockClasses = unlock }
    self:_log("cheat state revision=%d invulnerable=%s unlockClasses=%s", self.cheatState.revision, tostring(inv), tostring(unlock))
    return true
end
function Host:TickCheatState()
    local c = self.cheatState
    if not c then return 0 end
    local sent = 0
    for _, peer in pairs(self.peers) do
        if peer.key and peer.cheatRevision ~= c.revision then
            if self:_send(peer, "CHEAT_STATE", { revision = c.revision, invulnerable = c.invulnerable, unlockClasses = c.unlockClasses }) then
                peer.cheatRevision = c.revision; sent = sent + 1
            end
        end
    end
    return sent
end
-- D42: the host's gameplay mod manifest, sent once to every joined peer (also one that joins later).
function Host:SetModManifest(manifest)
    if type(manifest) ~= "string" or #manifest > 1000 then return false end
    if self.modManifest ~= manifest then
        self.modManifest = manifest
        for _, peer in pairs(self.peers) do peer.modManifestSent = nil end
    end
    return true
end
function Host:TickModManifest()
    if not self.modManifest then return 0 end
    local sent = 0
    for _, peer in pairs(self.peers) do
        if peer.key and not peer.modManifestSent and self:_send(peer, "MOD_MANIFEST", { mods = self.modManifest }) then
            peer.modManifestSent = true; sent = sent + 1
        end
    end
    return sent
end
-- Test 10: one client's live HUD numbers (gmp_live_hud.lua). False for an unbound key or invalid fields.
function Host:SendLiveStats(key, f)
    local fields = Messages.ValidateLiveStats(f)
    if not fields then return false end
    for _, peer in pairs(self.peers) do if peer.key == key then return self:_send(peer, "LIVE_STATS", fields) == true end end
    return false
end
-- Test 12: island changes wait only for players in the world. A player that asks for an island resume (a restarted
-- or reconnected client that is not in the world, loading the island) is "joining" (islandJoining[key]): out of the
-- transitions until its island readiness arrives (ISLAND_READY), so it never blocks the others.
function Host:EnableIslands()
    if not self.islands then
        self.islandJoining=self.islandJoining or {}
        self.islands=require('gmp_islands').Host.new(function()
            local participants={}
            for _,player in ipairs(self.roster:Snapshot()) do
                if player.conn=='connected' and not self.islandJoining[player.key] then participants[player.key]=true end
            end
            return participants
        end)
    end
    return self.islands
end
function Host:_islandJoining(key)
    local state=self.islands
    self.islandJoining[key]=true
    if state.required then state.required[key]=nil end
    if state.ready then state.ready[key]=nil end
    if self.travelCheck and self.travelCheck.required then self.travelCheck.required[key]=nil end
end
function Host:_broadcastIsland(typ,fields)
    local sent=true
    for _,peer in pairs(self.peers) do
        if peer.key and self.islands.required[peer.key] then sent=self:_send(peer,typ,fields) and sent end
    end
    return sent
end
function Host:EndIslandRun()
    if not self.islands or self.islands.phase=='idle' then return false end
    return self:_broadcastIsland('ISLAND_END',{epoch=self.islands.epoch})
end
function Host:BeginIslandRun()
    if not self.islands then return false,'islands_off' end
    self.travelCheck=nil
    local epoch=self.islands:BeginRun()
    return self:_broadcastIsland('ISLAND_BEGIN',{epoch=epoch,island=1})
end
function Host:EnableTravelGate() self.travelGate=true end
function Host:LoadingWaiters()
    local state=self.islands;local slots={}
    if not state or state.phase~='generating' then return slots end
    for key in pairs(state.required) do
        if not state.ready[key] then local player=self:GetPlayer(key);if player then slots[#slots+1]=player.slot end end
    end
    table.sort(slots);return slots
end
function Host:UpdateLoadingNotice()
    local state=self.islands
    if not state or state.phase~='generating' or not state.pending then self.loadingSignature=nil;return end
    local slots=self:LoadingWaiters();local signature=state.pending.epoch..':'..state.pending.island..':'..table.concat(slots,',')
    if signature==self.loadingSignature then return end
    local players={};for _,slot in ipairs(slots) do players[#players+1]={slot=slot} end
    if self:_broadcastIsland('ISLAND_WAIT',{epoch=state.pending.epoch,island=state.pending.island,players=players}) then self.loadingSignature=signature end
end
function Host:TravelWaiters()
    local check=self.travelCheck;local slots={}
    if not check then return slots end
    for key in pairs(check.required) do
        local blocked=key==self.identity.key and self.travelHostBlocked or check.blocked[key]
        -- Explicit false is ready; absent status is still waiting.
        if key==self.identity.key then blocked=self.travelHostBlocked end
        if blocked~=false then local player=self:GetPlayer(key);if player then slots[#slots+1]=player.slot end end
    end
    table.sort(slots);return slots
end
function Host:UpdateTravelGate(blocked)
    local check=self.travelCheck
    if not check then return false end
    self.travelHostBlocked=blocked
    local players=self:TravelWaiters()
    local signature=table.concat(players,',')
    if signature~=check.waitSignature then
        local wire={};for _,slot in ipairs(players) do wire[#wire+1]={slot=slot} end
        if self:_broadcastIsland('TRAVEL_WAIT',{epoch=check.epoch,island=check.island,token=check.token,players=wire}) then check.waitSignature=signature end
    end
    if check.retry then
        check.retry=not self:_broadcastIsland('TRAVEL_CHECK',{epoch=check.epoch,island=check.island,token=check.token})
    end
    if blocked or check.retry then return false end
    for key in pairs(check.required) do
        if key~=self.identity.key and check.blocked[key]~=false then return false end
    end
    local ok,why=self.islands:Request(self.identity.key,check.epoch,check.island)
    if ok and why=='end_island' then
        self.travelCheck=nil
        self:_broadcastIsland('ISLAND_BEGIN',{epoch=check.epoch,island=check.island+1})
        return true
    end
    return false
end
function Host:RequestIslandTransition(key,epoch,island)
    if not self.islands then return false,'islands_off' end
    if self.travelGate then
        if epoch~=self.islands.epoch or island~=self.islands.island then return false,'stale_island' end
        local participants=self.islands:_participants()
        if not participants[key] then return false,'not_participant' end
        if self.travelCheck then return true,'already_requested' end
        if self.islands.phase~='playing' then return false,'transition_pending' end
        -- Replacement hosts retain an already committed island without a
        -- generation barrier. Refresh recipients from authenticated membership
        -- before broadcasting the next travel check.
        self.islands.required=participants
        self.travelToken=(self.travelToken or 0)+1
        assert(self.travelToken<=2147483647,'Travel token exhausted')
        self.travelCheck={epoch=epoch,island=island,token=self.travelToken,required=participants,blocked={}}
        self.travelCheck.retry=not self:_broadcastIsland('TRAVEL_CHECK',{epoch=epoch,island=island,token=self.travelToken})
        return true,'waiting_for_rewards'
    end
    local ok,why=self.islands:Request(key,epoch,island)
    if ok and why=='end_island' then self:_broadcastIsland('ISLAND_BEGIN',{epoch=epoch,island=island+1}) end
    return ok,why
end
function Host:PublishIsland(manifest)
    if not self.islands then return false,'islands_off' end
    local I=require('gmp_islands');local wire=I.ToWire(manifest)
    if not wire then return false,'invalid_manifest' end
    -- Budget real wire framing at the largest link counters before mutating state.
    local encoded=Codec.Encode({type='ISLAND_MANIFEST',ch='R',sid=self.sid,ep=2147483647,seq=9007199254740991,ack=9007199254740991,f=wire})
    local commit=Codec.Encode({type='ISLAND_COMMIT',ch='R',sid=self.sid,ep=2147483647,seq=9007199254740991,ack=9007199254740991,
        f={epoch=manifest.epoch,island=manifest.island,stamp=I.Stamp(manifest)}})
    if not encoded or not commit or #encoded>1380 or #commit>1380 then return false,'manifest_too_large' end
    local ok,why=self.islands:Prepare(manifest);if not ok then return false,why end
    return self:_broadcastIsland('ISLAND_MANIFEST',wire)
end
function Host:HostIslandReady(stamp)
    if not self.islands or not self.islands.pending then return false end
    return self.islands:Ready(self.identity.key,self.islands.epoch,self.islands.pending.island,stamp)
end
function Host:CommitIsland()
    if not self.islands then return false,'islands_off' end
    local ok,manifest=self.islands:Commit();if not ok then return false,manifest end
    -- Native Play can enter through island handoff rather than lobby Start.
    -- Keep disconnection reservations tied to the actual committed run.
    if self.roster.phase~='run' then self.roster:StartRun();self:_broadcastRoster() end
    local fields={epoch=manifest.epoch,island=manifest.island,stamp=require('gmp_islands').Stamp(manifest)}
    self.islandCommit=fields -- retained so queue pressure can be retried explicitly
    return self:_broadcastIsland('ISLAND_COMMIT',fields)
end
function Host:ResendIslandCommit()
    return self.islands and self.islandCommit and self:_broadcastIsland('ISLAND_COMMIT',self.islandCommit) or false
end
-- The session policy (gmp_messages.lua schema). Achievements are always blocked in multiplayer (D16), so the
-- policy has no achievement setting; an invalid host policy (for example a reserved `lives` value) is refused and
-- logged once per reason, returning nil, reason. It is never thrown: LobbyState() runs every lobby tick, and a
-- missing policy already fails world entry closed (gmp_lobby_achievement_binding: achievement_policy_missing).
function Host:LobbyAchievementPolicy()
 local valid,why=Messages.ValidatePolicy(self.sessionPolicy)
 if not valid then
  why=tostring(why)
  if self.policyRefusalLogged~=why then self.policyRefusalLogged=why;self:_log('session policy refused: %s',why) end
  return nil,why
 end
 self.policyRefusalLogged=nil
 return Messages.CopyPolicy(self.sessionPolicy)
end
-- Local host loadout follows the same validation as client selections.
function Host:SetHostSelection(class, artifacts)
    local rec, why = self.roster:SetSelection(self.identity.key, class, artifacts)
    if rec then self:_broadcastLobby() end
    return rec ~= nil, why
end
function Host.handlers.PORTAL_REQ(self,peer,f)
    if not peer.key or not self.islands then return end
    self:RequestIslandTransition(peer.key,f.epoch,f.island)
end
function Host.handlers.ISLAND_RESUME_REQ(self,peer,f)
    if not peer.key or not self.islands then return end
    local state=self.islands
    -- Only once the run has a committed island: at the run's first island everyone entered together (D40 handles a
    -- client that cannot make it); later a resume means the player is not in the world.
    if peer.key~=self.identity.key and state.island>0 then self:_islandJoining(peer.key) end
    local manifest=state.phase=='playing' and state.current or state.phase=='generating' and state.pending
    if not manifest then return end
    if type(f.token)~='number' or f.token%1~=0 or f.token<1 or f.token>2147483647 then return end
    local wire=require('gmp_islands').ToWire(manifest);wire.token=f.token
    if self:_send(peer,'ISLAND_RESUME',wire) then peer.islandResumeStamp=require('gmp_islands').Stamp(manifest) end
end
function Host.handlers.ISLAND_READY(self,peer,f)
    if not peer.key or not self.islands then return end
    local I=require('gmp_islands')
    if self.islands.phase=='playing' and self.islands.current and
        f.epoch==self.islands.epoch and f.island==self.islands.island and f.stamp==I.Stamp(self.islands.current) then
        self.islandJoining[peer.key]=nil   -- a resumed player is in the world again
        self:_send(peer,'ISLAND_COMMIT',{epoch=f.epoch,island=f.island,stamp=f.stamp})
        if self.travelCheck then
            local check=self.travelCheck
            self:_send(peer,'TRAVEL_CHECK',{epoch=check.epoch,island=check.island,token=check.token})
        end
        return
    end
    local state=self.islands
    -- A joining player ready for the island being prepared takes part at once (it is ready, so it waits for nobody).
    if state.phase=='generating' and state.pending and f.epoch==state.epoch and f.island==state.pending.island
        and f.stamp==I.Stamp(state.pending) then
        self.islandJoining[peer.key]=nil
        if state.required and not state.required[peer.key] then state.required[peer.key]=true end
    end
    state:Ready(peer.key,f.epoch,f.island,f.stamp)
end
function Host.handlers.TRAVEL_STATUS(self,peer,f)
    local check=self.travelCheck
    if not self.travelGate or not peer.key or not check or not check.required[peer.key] then return end
    if f.epoch~=check.epoch or f.island~=check.island or f.token~=check.token or type(f.blocked)~='boolean' then return end
    check.blocked[peer.key]=f.blocked
end
function Host.handlers.SESSION_POLICY_ACK(self,peer,f)
 if peer.key and f.revision==self.sessionPolicy.revision then
  peer.achievementPolicyRev=f.revision
  -- W11: with host artifacts, both policy lists follow every acknowledged revision (even when empty, so the client
  -- knows its lists are complete).
  if self.hostArtifacts and peer.policyListsSent~=f.revision then
   local policy=Messages.CopyPolicy(self.sessionPolicy)
   for _,list in ipairs({'artifacts','hostUnlocked'}) do
    for _,page in ipairs(Messages.PolicyListPages(policy,list) or {}) do self:_send(peer,'POLICY_LIST',page) end
   end
   peer.policyListsSent=f.revision
  end
 end
end
-- W11 (D25/D28/D29/D34): the host's artifact set and its normal-save unlocks, as actor paths ("/Game/...X_C"), never a
-- grid index. Only with host artifacts on (App sets host.hostArtifacts from HOST_ARTIFACTS) and while the lobby is
-- open; a revision clears every client's Ready (the clients must confirm the new policy).
function Host:_setPolicyList(list,paths)
 if not self.hostArtifacts then return false,'host_artifacts_off' end
 if self.roster.phase~='lobby' or self.roster.lobbyState~='open' or self.sessionPolicy.locked then return false,'lobby_closed' end
 if type(paths)~='table' then return false,'policy_'..(list=='artifacts' and 'artifacts' or 'host_unlocked') end
 local candidate=Messages.CopyPolicy(self.sessionPolicy);local copy={}
 for i,path in ipairs(paths) do copy[i]=path end
 candidate[list]=copy
 local valid,why=Messages.ValidatePolicy(candidate)
 if not valid then return false,why end
 self.sessionPolicy[list]=copy;self.sessionPolicy.revision=self.sessionPolicy.revision+1
 for _,rec in ipairs(self.roster:Snapshot()) do
  if rec.key~=self.identity.key and self.roster:Get(rec.key).ready then self.roster:SetReady(rec.key,false) end
 end
 self:_log('session policy %s=%d revision=%d',list,#copy,self.sessionPolicy.revision)
 self:_broadcastRoster();self:_broadcastLobby()
 return true
end
function Host:SetPolicyArtifacts(paths) return self:_setPolicyList('artifacts',paths) end
function Host:SetHostUnlocked(paths) return self:_setPolicyList('hostUnlocked',paths) end
function Host.handlers.SELECT_REQ(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    -- W11-min: the session uses the host default artifact set (an empty policy.artifacts until W11); a client never
    -- chooses artifacts, so a SELECT_REQ carrying any is refused and the old selection is kept.
    if f.artifacts ~= "" then return self:_send(peer, "REQ_DENIED", { ofType = "SELECT_REQ", reason = "artifacts_host_policy" }) end
    local rec, why = self.roster:SetSelection(peer.key, f.class, f.artifacts)
    if not rec then return self:_send(peer, "REQ_DENIED", { ofType = "SELECT_REQ", reason = why }) end
    self:_broadcastLobby()
end
function Host.handlers.READY_REQ(self, peer, f)
    if not peer.key then self.stats.unbound_peer = self.stats.unbound_peer + 1; return end
    if f.ready and (peer.achievementPolicyRev~=self.sessionPolicy.revision or f.policyRevision~=self.sessionPolicy.revision) then return self:_send(peer,'REQ_DENIED',{ofType='READY_REQ',reason='session_policy_not_confirmed'})end
    local rec, why = self.roster:SetReady(peer.key, f.ready)
    if not rec then return self:_send(peer, "REQ_DENIED", { ofType = "READY_REQ", reason = why }) end
    self:_broadcastLobby()
end

-- Reserved (C0): run abort / lobby return (RUN_ABORT, LOBBY_RETURN) are host-to-client messages implemented by W10;
-- the client stubs live in gmp_client_entry.lua. A rejoin after an expired reservation (D20/D24, W8) is refused
-- with this stable code.
local E = { RESERVATION_EXPIRED = Messages.Refusal.RESERVATION_EXPIRED, RunStatsRows = Host.RunStatsRows }
function E.Install(target)
    assert(type(target) == "table" and type(target.handlers) == "table", "Host with a handlers table required")
    for name, fn in pairs(Host) do if name ~= "handlers" then target[name] = fn end end
    for name, fn in pairs(Host.handlers) do target.handlers[name] = fn end
    return target
end
return E
