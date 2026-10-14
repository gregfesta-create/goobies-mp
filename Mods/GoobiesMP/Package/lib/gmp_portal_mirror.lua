-- Portals on clients (test 10). A client's boss is a visual copy, so the game never spawns the boss portal there. The
-- host sends its portals' positions (PORTAL_STATE, gmp_run_sync.lua); each client spawns the game's own BP_Portal_C at
-- every host spot (the island world gates it on BeginPlay like any portal: overlap off, proximity sends PORTAL_REQ)
-- and destroys the ones it spawned when the host's portal goes. Island travel destroys every portal anyway
-- (gmp_island_world.lua ConsumePortals / Transition); a new island context forgets the spawned list.
--   Mirror.HostSpots(G)            -> { {x, y, z, yaw}, ... } game-world BP_Portal_C positions and yaw, at most MAX
--   Mirror.Encode(spots)           -> "x,y,z,yaw;..." (one decimal)
--   Mirror.new{G, log}:Tick(ctx, state)   state = { epoch, island, spots } (Messages.ValidatePortalState)
local Messages = require('gmp_messages')
local Mirror = {}
Mirror.__index = Mirror
Mirror.MAX = Messages.PORTAL_MAX
Mirror.PORTAL_CLASS = '/Game/Blueprints/BP_Portal.BP_Portal_C'
Mirror.NEAR = 200   -- cm: a portal already standing this close to a host spot is that portal (never doubled)
local function valid(o) local ok, v = pcall(function() return o and o:IsValid() end); return ok and v == true end
-- game-world BP_Portal_C actors, and what the scan saw: {raw = FindAllOf count (-1: the call failed), game, sample}
local function gamePortals(G)
    local out, seen = {}, { raw = 0, game = 0, sample = nil }
    if type(G) ~= 'table' or type(G.FindAllOf) ~= 'function' then return out, seen end
    local ok, list = pcall(G.FindAllOf, 'BP_Portal_C')
    if not ok then seen.raw = -1; return out, seen end
    if type(list) ~= 'table' then return out, seen end
    seen.raw = #list
    for _, actor in ipairs(list) do
        local okName, name = pcall(function() return actor:GetFullName() end)
        if valid(actor) and okName and type(name) == 'string' and name:find('/Game/Maps/Game.', 1, true) then
            out[#out + 1] = actor
            seen.sample = seen.sample or name:gsub('^%S+%s', '')
        end
    end
    seen.game = #out
    return out, seen
end
local function locationOf(actor)
    local ok, l = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or type(l) ~= 'table' and type(l) ~= 'userdata' then return nil end
    local x, y, z = tonumber(l.X), tonumber(l.Y), tonumber(l.Z)
    if not (x and y and z) then return nil end
    local yaw = 0
    pcall(function() yaw = tonumber(actor:K2_GetActorRotation().Yaw) or 0 end)
    return { x = x, y = y, z = z, yaw = yaw }
end
function Mirror.HostSpots(G)
    local spots = {}
    local actors, seen = gamePortals(G)
    for _, actor in ipairs(actors) do
        if #spots >= Mirror.MAX then break end
        local spot = locationOf(actor)
        if spot then spots[#spots + 1] = spot end
    end
    return spots, seen
end
function Mirror.Encode(spots)
    local parts = {}
    for i, s in ipairs(spots or {}) do
        if i > Mirror.MAX then break end
        parts[#parts + 1] = string.format('%.1f,%.1f,%.1f,%.1f', s.x, s.y, s.z, s.yaw or 0)
    end
    return table.concat(parts, ';')
end
-- Test 12 client crash (UE4SS read a freed object): the client scans the game's portals only while the host has a
-- spot that no portal of ours covers, at most every SCAN_SECONDS, and keeps only the ADDRESS of a portal it spawned:
-- that portal is touched again only after it is found among the live portals (gmp_run_sync_liveness.lua rule).
Mirror.SCAN_SECONDS = 1
local Liveness = require('gmp_run_sync_liveness')
function Mirror.new(options)
    return setmetatable({ options = options or {}, spawned = {}, key = nil, scanAt = nil }, Mirror)
end
function Mirror:_log(line) if self.options.log then pcall(self.options.log, line) end end
local function near(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy <= Mirror.NEAR * Mirror.NEAR end
-- the live portal that is `mine` (by address; an offline double without addresses by identity), or nil
local function liveOf(live, mine)
    for _, actor in ipairs(live) do
        if mine.address then
            if Liveness.Address(actor) == mine.address then return actor end
        elseif actor == mine.actor then return actor end
    end
    return nil
end
function Mirror:Tick(ctx, state)
    if type(ctx) ~= 'table' then return end
    -- a new island context: the old portals went with the old island; never touched again
    if self.key ~= ctx.key then self.key, self.spawned, self.scanAt = ctx.key, {}, nil end
    local spots = {}
    if type(state) == 'table' and state.epoch == ctx.epoch and state.island == ctx.island and type(state.spots) == 'table' then
        spots = state.spots
    end
    local stale, missing = {}, {}
    for i, mine in ipairs(self.spawned) do
        local kept = false
        for _, s in ipairs(spots) do if near(mine.spot, s) then kept = true end end
        if not kept then stale[#stale + 1] = i end
    end
    for _, s in ipairs(spots) do
        local covered = false
        for _, mine in ipairs(self.spawned) do if near(mine.spot, s) then covered = true end end
        if not covered then missing[#missing + 1] = s end
    end
    if #stale == 0 and #missing == 0 then return end
    local okNow, now = pcall(self.options.clock or os.clock)
    now = okNow and now or 0
    if #missing > 0 and #stale == 0 and self.scanAt and now - self.scanAt < Mirror.SCAN_SECONDS then return end
    self.scanAt = now
    local live = gamePortals(self.options.G)
    -- ours that the host no longer has: destroyed through a fresh handle, or simply forgotten when already gone
    for k = #stale, 1, -1 do
        local mine = table.remove(self.spawned, stale[k])
        local actor = liveOf(live, mine)
        if actor then pcall(function() actor:K2_DestroyActor() end) end
        self:_log(string.format('PORTAL removed x=%.0f y=%.0f live=%s', mine.spot.x, mine.spot.y, tostring(actor ~= nil)))
    end
    if #missing == 0 then return end
    local standing = {}
    for _, actor in ipairs(live) do
        local spot = locationOf(actor)
        if spot then standing[#standing + 1] = spot end
    end
    for _, s in ipairs(missing) do
        local present = false
        for _, at in ipairs(standing) do if near(at, s) then present = true end end
        if not present and #self.spawned < Mirror.MAX then
            local ok, actor = pcall(function()
                local cls = self.options.G.StaticFindObject(Mirror.PORTAL_CLASS)
                assert(valid(cls), 'portal_class_unavailable')
                local world = ctx.world and ctx.world:_world()
                assert(valid(world), 'no_world')
                local a = world:SpawnActor(cls, { X = s.x, Y = s.y, Z = s.z }, { Pitch = 0, Yaw = s.yaw or 0, Roll = 0 })
                assert(valid(a), 'portal_spawn_failed')
                return a
            end)
            -- a refusal is logged once per reason (retried at most every SCAN_SECONDS)
            local why = ok and '' or tostring(actor)
            if ok or self.refused ~= why then
                if not ok then self.refused = why end
                self:_log(string.format('PORTAL shown x=%.0f y=%.0f ok=%s%s', s.x, s.y, tostring(ok), ok and '' or ' reason=' .. why))
            end
            if ok then
                local address = Liveness.Address(actor)
                self.spawned[#self.spawned + 1] = { address = address, actor = not address and actor or nil, spot = s }
                standing[#standing + 1] = s
            end
        elseif present then
            -- the client's own portal (or one already standing): adopt the spot so it is not scanned again
            self.spawned[#self.spawned + 1] = { spot = s, own = true }
        end
    end
end
return Mirror
