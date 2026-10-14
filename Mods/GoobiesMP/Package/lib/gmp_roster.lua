-- GoobiesMP production: HOST-AUTHORITATIVE player table (pure Lua; no messaging, no game access).
-- Records are keyed by identity key ("steam:<id>" / "dev:<name>"). Slot and colour are SEPARATE concepts and neither is identity.
--
-- RULES
--  * Slots are 1..maxPlayers, lowest free slot first. Colours are unique per session and come from the configured palette.
--  * Colour choice order: valid+free requested colour > colour this identity had before (colourMemory) > the slot's default
--    colour > first free colour. A requested colour that is taken is not an error at join time (host chooses another).
--  * Timed reservations (W8, D20; with a departure reason and RESERVATION_MINUTES 10-20): an ACCIDENTAL disconnect, in the
--    lobby or in a run, keeps the record as conn="disconnected" (slot AND colour reserved; a newcomer cannot take them)
--    for RESERVATION_MINUTES, then ExpireReservations frees it; a player whose reservation expired cannot rejoin that run
--    (reservation_expired, D24). A voluntary leave ("left:*") or a kick frees the slot at once.
--  * Legacy rule (no departure reason, or RESERVATION_MINUTES=0, dev only): the lobby frees at once; a run reserves
--    (RESERVE_ON_DISCONNECT) until ReleaseReservation / EndRun, with no expiry.
--  * W6 ReturnToLobby keeps reservations (with their timers); EndRun releases them.
--  * Kicked identities are refused until Permit(). Exactly one host record; the host never "disconnects" inside the roster.
--  * current_players = number of records with conn == "connected". Whether dead/disconnected players should count toward
--    current_players for XP scaling is an OPEN design question (see PHASE2.md); CurrentPlayers() is the single place to change it.
local Config = require("gmp_config")
local Identity = require('gmp_identity')

local Roster = {}
Roster.__index = Roster

function Roster.new(cfg, opts)
    opts = opts or {}
    local self = setmetatable({}, Roster)
    self.cfg = cfg
    self.maxPlayers = cfg.MAX_PLAYERS          -- fixed 4 slots (D12); the lobby has no player-count option
    self.phase = "lobby"
    self.rev = 0
    self.records = {}                          -- key -> record
    self.colorMemory = {}                      -- key -> last colour (colour is run state, not identity)
    self.kicked = {}                           -- key -> true
    self.expired = {}                          -- key -> true: reservation expired during this run (W8); cleared when the run ends
    self.lrev = 0                              -- lobby revision (ready/selection/settings/start); roster `rev` is for membership/slot/colour
    self.lobbyState = "open"                   -- open | handoff_pending (Start accepted; gameplay hand-off is NOT implemented)
    self.rng = opts.rng or math.random
    return self
end

local function hex(rng, nbytes)
    local t = {}
    for i = 1, nbytes do t[i] = string.format("%02x", math.floor(rng() * 256) % 256) end
    return table.concat(t)
end

function Roster:_bump() self.rev = self.rev + 1; self.lrev = self.lrev + 1; return self.rev end   -- membership/slot/colour changes also change the lobby view

function Roster:Get(key) return self.records[key] end
function Roster:ByPeer(peerId)
    if peerId == nil then return nil end
    for _, r in pairs(self.records) do if r.peerId == peerId then return r end end
end

-- Records that occupy a slot (connected, or disconnected-but-reserved).
function Roster:Count()
    local n = 0
    for _ in pairs(self.records) do n = n + 1 end
    return n
end

function Roster:CurrentPlayers()
    local n = 0
    for _, r in pairs(self.records) do if r.conn == "connected" then n = n + 1 end end
    return n
end

function Roster:FreeSlot()
    local used = {}
    for _, r in pairs(self.records) do used[r.slot] = true end
    for s = 1, self.maxPlayers do if not used[s] then return s end end
end

function Roster:ColorTaken(color)
    local k = color:lower()
    for _, r in pairs(self.records) do if r.color:lower() == k then return true end end
    return false
end

function Roster:_pickColor(key, slot, req)
    if req and req ~= "" then
        local c = Config.CanonicalColor(self.cfg, req)
        if c and not self:ColorTaken(c) then return c end
    end
    local mem = self.colorMemory[key]
    if mem and not self:ColorTaken(mem) then return mem end
    local def = Config.DefaultColorForSlot(self.cfg, slot)
    if def and not self:ColorTaken(def) then return def end
    for _, c in ipairs(Config.ColorList(self.cfg)) do if not self:ColorTaken(c) then return c end end
end

local function validName(cfg, name)
    return type(name) == "string" and #name >= 1 and #name <= Config.MAX_NAME_BYTES and not name:find("%c")
end

function Roster:_add(id, name, role, peerId, now, extra)
    local slot = self:FreeSlot()
    if not slot then return nil, "session_full" end
    local color = self:_pickColor(id.key, slot, extra and extra.reqColor)
    if not color then return nil, "no_color" end
    local rec = {
        key = id.key, kind = id.kind, value = id.value, isDev = id.isDev,
        name = name, slot = slot, color = color, role = role,
        conn = "connected", peerId = peerId, token = (role == "host") and "" or hex(self.rng, 8),
        joinedAt = now, lastSeen = now, disconnectedAt = nil, rejoinCount = 0,
        ready = false, class = "", artifacts = "",             -- lobby extras: they live and die with the record (so a pre-run leave frees them too)
        clientRosterRev = 0, modVer = extra and extra.modVer or "", gameVer = extra and extra.gameVer or "",
    }
    self.records[id.key] = rec
    self.colorMemory[id.key] = color
    self:_bump()
    return rec
end

function Roster:AddHost(id, name, now)
    if next(self.records) ~= nil then return nil, "host_exists" end
    if not validName(self.cfg, name) then return nil, "bad_name" end
    return self:_add(id, name, "host", nil, now)
end

-- Trusted checkpoint import; every remote member must authenticate again.
-- Slots/colours survive, while connection ids and reconnect tokens are fresh.
function Roster:ImportHandover(players,hostKey,now)
    if type(players)~='table' or #players<1 or #players>self.maxPlayers then return false,'invalid_roster' end
    local records,colors,slots={},{},{};local hostFound=false
    local policy=Identity.Policy.new(self.cfg.MODE)
    for _,player in ipairs(players) do
        local id=Identity.Parse(player.key)
        local name=player.name or (id and id.value)
        local color=Config.CanonicalColor(self.cfg,player.color)
        if not id or not policy:Check(id) or records[player.key] or not validName(self.cfg,name)
            or type(player.slot)~='number' or player.slot%1~=0 or player.slot<1 or player.slot>self.maxPlayers
            or slots[player.slot] or not color or colors[color] then return false,'invalid_roster' end
        local isHost=player.key==hostKey;hostFound=hostFound or isHost
        records[player.key]={key=id.key,kind=id.kind,value=id.value,isDev=id.isDev,name=name,
            slot=player.slot,color=color,role=isHost and 'host' or 'client',conn=isHost and 'connected' or 'disconnected',
            token=isHost and '' or hex(self.rng,8),joinedAt=now,lastSeen=now,disconnectedAt=isHost and nil or now,
            rejoinCount=0,ready=false,class=player.class or '',artifacts=player.artifacts or '',clientRosterRev=0,modVer='',gameVer=''}
        slots[player.slot]=true;colors[color]=true
    end
    if not hostFound then return false,'missing_host' end
    self.records=records;self.colorMemory={}
    for key,record in pairs(records) do self.colorMemory[key]=record.color end
    self.phase='run';self:_bump();return true
end

-- A new (non-rejoin) client join. Returns record | nil,reason.
function Roster:Join(id, name, peerId, now, extra)
    local key = id.key
    if self.kicked[key] then return nil, "kicked" end
    if not validName(self.cfg, name) then return nil, "bad_name" end
    if extra and extra.reqColor and extra.reqColor ~= "" and not Config.CanonicalColor(self.cfg, extra.reqColor) then
        return nil, "invalid_color"
    end
    local rec = self.records[key]
    if rec then
        if rec.conn == "connected" then return nil, "duplicate_identity" end
        return nil, "rejoin_required"          -- reserved by a disconnected player: must use REJOIN_REQ
    end
    if self.phase == "run" then return nil, "run_in_progress" end
    if self:Count() >= self.maxPlayers then return nil, "session_full" end
    return self:_add(id, name, "client", peerId, now, extra)
end

-- Reconnect of a reserved record. claims are verified against the host's own record; they never change it.
-- opts: { token=, claimSlot=, claimColor=, authenticated=bool }
function Roster:Rejoin(id, peerId, now, opts)
    local key = id.key
    if self.kicked[key] then return nil, "kicked" end
    local rec = self.records[key]
    if not rec then return nil, self.expired[key] and "reservation_expired" or "no_reservation" end
    if rec.conn == "connected" then return nil, "duplicate_identity" end
    if not self.cfg.ALLOW_AUTO_REJOIN then return nil, "approval_required" end   -- host-approval flow NOT built in M1
    if not opts.authenticated and (opts.token == nil or opts.token == "" or opts.token ~= rec.token) then return nil, "bad_token" end
    if opts.claimSlot and opts.claimSlot ~= 0 and opts.claimSlot ~= rec.slot then return nil, "slot_claim_invalid" end
    if opts.claimColor and opts.claimColor ~= "" and opts.claimColor:lower() ~= rec.color:lower() then return nil, "color_claim_invalid" end
    rec.conn, rec.peerId, rec.lastSeen, rec.disconnectedAt = "connected", peerId, now, nil
    rec.rejoinCount = rec.rejoinCount + 1
    self:_bump()
    return rec
end

-- A client left (LEAVE), timed out, or lost its link. `reason` is the host's departure reason ("left:<why>" for a
-- voluntary leave, "kicked", or a transport reason such as "timeout"/"transport_closed").
--  * Timed rule (W8, a reason given and RESERVATION_MINUTES>0): voluntary leave or kick -> freed at once; any other
--    (accidental) departure -> reserved, in the lobby as in a run, until ExpireReservations.
--  * Legacy rule (no reason, or RESERVATION_MINUTES=0): RUN phase (RESERVE_ON_DISCONNECT) -> reserved until
--    EndRun/ReleaseReservation; LOBBY phase -> record removed, slot+colour freed.
function Roster:Disconnect(key, now, reason)
    local rec = self.records[key]
    if not rec or rec.role == "host" then return nil, "no_such_client" end
    if reason ~= nil and (self.cfg.RESERVATION_MINUTES or 0) > 0 then
        local voluntary = tostring(reason):match("^left") ~= nil or reason == "kicked" or self.kicked[key] == true
        if not voluntary then
            rec.conn, rec.peerId, rec.disconnectedAt = "disconnected", nil, now
            self:_bump()
            return "reserved"
        end
        self.records[key] = nil
        self:_bump()
        return "freed"
    end
    if self.phase == "run" and self.cfg.RESERVE_ON_DISCONNECT then
        rec.conn, rec.peerId, rec.disconnectedAt = "disconnected", nil, now
        self:_bump()
        return "reserved"
    end
    self.records[key] = nil
    self:_bump()
    return "freed"
end

function Roster:ReleaseReservation(key)
    local rec = self.records[key]
    if rec and rec.conn == "disconnected" then self.records[key] = nil; self:_bump(); return true end
    return false
end

-- W8 (D20/D24): free every reservation older than RESERVATION_MINUTES at `now`. In a run the expired identity cannot
-- rejoin that run (Rejoin -> reservation_expired). RESERVATION_MINUTES=0 never expires. Returns the expired keys, sorted.
function Roster:ExpireReservations(now)
    local minutes = self.cfg.RESERVATION_MINUTES or 0
    local expired = {}
    if minutes <= 0 or type(now) ~= "number" then return expired end
    for key, rec in pairs(self.records) do
        if rec.conn == "disconnected" and type(rec.disconnectedAt) == "number" and now - rec.disconnectedAt >= minutes * 60 then
            expired[#expired + 1] = key
        end
    end
    table.sort(expired)
    for _, key in ipairs(expired) do
        self.records[key] = nil
        if self.phase == "run" then self.expired[key] = true end
    end
    if #expired > 0 then self:_bump() end
    return expired
end

function Roster:EndRun()
    for key, rec in pairs(self.records) do
        if rec.conn == "disconnected" then self.records[key] = nil else rec.ready = false end
    end
    self.expired = {}
    self.phase, self.lobbyState = "lobby", "open"
    self:_bump(); self:_lbump()
end

-- W6: the run returns to the lobby (the host reached the menu). Unlike EndRun, disconnected reservations are KEPT
-- (W8 times them out); everyone's Ready is cleared for the next run. Returns the number of reservations kept.
function Roster:ReturnToLobby()
    local kept = 0
    for _, rec in pairs(self.records) do
        if rec.conn == "disconnected" then kept = kept + 1 else rec.ready = false end
    end
    self.expired = {}   -- an expiry bars only that run
    self.phase, self.lobbyState = "lobby", "open"
    self:_bump(); self:_lbump()
    return kept
end

function Roster:StartRun() self.phase = "run"; self:_bump() end

function Roster:Kick(key)
    local rec = self.records[key]
    if not rec or rec.role == "host" then return nil, "no_such_client" end
    self.kicked[key] = true
    self.records[key] = nil
    self:_bump()
    return true
end
function Roster:Permit(key) self.kicked[key] = nil; return true end
function Roster:IsKicked(key) return self.kicked[key] == true end

-- Colour change: validated and decided here, never by the requester.
function Roster:SetColor(key, color)
    local rec = self.records[key]
    if not rec then return nil, "unknown_player" end
    local c = Config.CanonicalColor(self.cfg, color)
    if not c then return nil, "invalid_color" end
    if c:lower() == rec.color:lower() then return rec end
    if self:ColorTaken(c) then return nil, "color_taken" end
    rec.color = c
    self.colorMemory[key] = c
    self:_bump()
    return rec
end

------------------------------------------------------------------ lobby extras (host decides; every setter validates)
-- D37: the lobby stays open for Ready and selections during the host's start countdown (a change cancels it).
function Roster:LobbyOpen() return self.phase == "lobby" and (self.lobbyState == "open" or self.lobbyState == "countdown") end
function Roster:_lbump() self.lrev = self.lrev + 1; return self.lrev end

-- The host never needs to be Ready; it is the one who starts. A Ready flag only exists while the lobby is open.
function Roster:SetReady(key, ready)
    local rec = self.records[key]
    if not rec then return nil, "unknown_player" end
    if type(ready) ~= "boolean" then return nil, "bad_ready" end
    if rec.role == "host" then return nil, "host_is_always_ready" end
    if rec.conn ~= "connected" then return nil, "not_connected" end
    if not self:LobbyOpen() then return nil, "lobby_closed" end
    if rec.ready ~= ready then rec.ready = ready; self:_lbump() end
    return rec
end

local function token(s, max) return type(s) == "string" and #s <= max and s:match("^[%w_%- ]*$") ~= nil and not s:match("^%s") and not s:match("%s$") end

-- class: one token or "" (none). artifacts: ordered list of distinct tokens joined by ';'... the wire uses ' ' free text-safe form "a+b".
-- NO gameplay meaning yet: values are only validated as safe tokens (the real class/artifact catalogue is not known to the mod).
function Roster:SetSelection(key, class, artifacts)
    local rec = self.records[key]
    if not rec then return nil, "unknown_player" end
    if rec.conn ~= "connected" then return nil, "not_connected" end
    if not self:LobbyOpen() then return nil, "lobby_closed" end
    local L = Config.LOBBY
    if not token(class, L.MAX_TOKEN_BYTES) then return nil, "bad_class" end
    if type(artifacts) ~= "string" or #artifacts > 400 then return nil, "bad_artifacts" end
    local list, seen = {}, {}
    if artifacts ~= "" then
        for a in (artifacts .. "+"):gmatch("([^+]*)%+") do
            if a == "" or not token(a, L.MAX_TOKEN_BYTES) then return nil, "bad_artifacts" end
            if seen[a:lower()] then return nil, "duplicate_artifact" end
            seen[a:lower()] = true; list[#list + 1] = a
        end
        if #list > L.MAX_ARTIFACTS then return nil, "too_many_artifacts" end
    end
    local joined = table.concat(list, "+")
    if rec.class ~= class or rec.artifacts ~= joined then
        rec.class, rec.artifacts = class, joined
        -- Ready confirms this loadout. A changed choice requires confirmation again.
        if rec.role ~= "host" then rec.ready = false end
        self:_lbump()
    end
    return rec
end

-- Start requires every CONNECTED non-host player to be Ready. A disconnected reservation (a lobby disconnect, W8, or one
-- kept by the W6 return to the lobby) does not block Start; it stays reserved into the run until it expires or rejoins.
function Roster:AllReady()
    for _, r in pairs(self.records) do
        if r.role ~= "host" and r.conn == "connected" and not r.ready then return false end
    end
    return true
end

function Roster:Start()
    if self.phase ~= "lobby" or self.lobbyState ~= "open" then return nil, "already_started" end
    if not self:AllReady() then return nil, "players_not_ready" end
    self.phase, self.lobbyState = "run", "handoff_pending"
    self:_bump(); self:_lbump()
    return true
end

-- Colour availability, recomputed from the records on every call (selection updates it immediately).
function Roster:ColorAvailability()
    local owner = {}
    for _, r in pairs(self.records) do owner[r.color:lower()] = r.key end
    local out = {}
    for _, c in ipairs(Config.ColorList(self.cfg)) do out[#out + 1] = { color = c, owner = owner[c:lower()], free = owner[c:lower()] == nil } end
    return out
end

function Roster:LobbySnapshot()
    local list = {}
    for _, r in pairs(self.records) do list[#list + 1] = r end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    local out = {}
    for i, r in ipairs(list) do out[i] = { key = r.key, ready = (r.role == "host") or r.ready, class = r.class, artifacts = r.artifacts } end
    return out
end

function Roster:ReconnectEligible(key)
    local rec = self.records[key]
    return rec ~= nil and rec.conn == "disconnected" and not self.kicked[key] and self.cfg.ALLOW_AUTO_REJOIN
end

-- Public (serialisable) view, ordered by slot. Never includes peerId or token.
-- DISPLAY POSITION (derived, never stored, never sent as identity).
-- `slot` is the persistent session slot (reserved to one identity). Display position is only the visual order of ACTIVE
-- players in party UI: players sorted by persistent slot, then compacted. When B (slot 2) disconnects, C stays in slot 3 but
-- is shown at display position 2; when B returns, B is shown at 2 again and C at 3. Never use displayPos as identity or as a slot.
-- opts.includeDisconnected=true keeps disconnected players in the list (their displayPos is then their order among all listed).
function Roster.DisplayOrder(players, opts)
    local list = {}
    for _, p in ipairs(players) do
        if p.conn == "connected" or (opts and opts.includeDisconnected) then list[#list + 1] = p end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    local out = {}
    for i, p in ipairs(list) do out[i] = { displayPos = i, key = p.key, name = p.name, slot = p.slot, color = p.color, role = p.role, conn = p.conn } end
    return out
end

function Roster:Snapshot()
    local list = {}
    for _, r in pairs(self.records) do list[#list + 1] = r end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    local out = {}
    for i, r in ipairs(list) do out[i] = { key = r.key, name = r.name, slot = r.slot, color = r.color, role = r.role, conn = r.conn } end
    return out
end

return Roster
