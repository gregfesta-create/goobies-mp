-- D45 (Coder C; research/RESEARCH_PICKUPS.md 4-6): the client side of shared XP orbs. Client role only, never raises.
-- Draws the host's orb clumps (PICKUP_DELTA -> gmp_pickups_orbs Client model -> gmp_pickups_view) and reports the
-- clumps its own player touches (within the game's pickup radius 650 + its AdditionalPickUpRange) as PICKUP_COLLECT;
-- a reported clump is hidden until the host removes it, and shown (and reportable) again after PENDING_SECONDS if the
-- host did not. It never awards XP: the host removes the orbs and awards them on its own pawn (the team level).
-- On entering a context it clears its view and asks the host for a full resend (resync).
--   C.new{view=<renderer>, player=function(ctx) -> {x, y, range} | nil, log=fn, G}
--   c:Tick(ctx, session, now)   session: EnablePickups/DrainPickups/SendPickups(typ, f)
local Orbs = require('gmp_pickups_orbs')
local Wire = require('gmp_pickups_wire')
local C = {}; C.__index = C
C.PENDING_SECONDS = 3
C.COLLECT_SECONDS = 0.25
C.BIND_RETRY_SECONDS = 2
C.SUMMARY_SECONDS = 5
C.CONSUMABLE_REACH = 150   -- the game's consumable trace (125) plus a little
C.ACTOR_REACH = 200
C.HEALTH_DEFAULT = '/Game/Blueprints/Consumables/BPC_Health.Default__BPC_Health_C'

-- A health grant on the own pawn, as BPC_Health does it: ChangeHP(HpAddAmount, true). value <= 0: the game's default.
function C.Heal(ctx, value, G)
    local ok, done = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return false end
        local _, pawn = island:LocalWorldPawn()
        if not pawn or pawn:IsValid() ~= true then return false end
        local amount = value
        if type(amount) ~= 'number' or amount <= 0 then
            local find = G and G.StaticFindObject or (type(StaticFindObject) == 'function' and StaticFindObject) or nil
            local cdo = find and find(C.HEALTH_DEFAULT)
            amount = cdo and cdo:IsValid() == true and cdo.HpAddAmount or nil
        end
        if type(amount) ~= 'number' or amount <= 0 then return false end
        pawn:ChangeHP(amount, true)
        return true
    end)
    return ok and done == true
end

-- The local player's position and pickup range from the game objects, or nil.
function C.Player(ctx)
    local ok, result = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil end
        local _, pawn = island:LocalWorldPawn()
        if not pawn or pawn:IsValid() ~= true then return nil end
        local at = pawn:K2_GetActorLocation()
        local range = 0
        local checker = pawn.BPC_CheckingForXP
        if checker then
            local r = checker.AdditionalPickUpRange
            if type(r) == 'number' and r == r and r > 0 then range = r end
        end
        return { x = at.X, y = at.Y, z = at.Z, range = range }
    end)
    if ok and type(result) == 'table' and type(result.x) == 'number' and type(result.y) == 'number' then return result end
    return nil
end

function C.new(options)
    options = options or {}
    local view = options.view or require('gmp_pickups_view').new({ G = options.G, log = options.log })
    return setmetatable({ view = view, player = options.player or C.Player, log = options.log, G = options.G,
        heal = options.heal or function(ctx, value) return C.Heal(ctx, value, options.G) end, grantSequence = 0, model = Orbs.Client.new({
        pendingSeconds = C.PENDING_SECONDS }), sequence = 0, logged = {}, stats = { sent = 0, accepted = 0, refused = 0, xp = 0 } }, C)
end
function C:_log(fmt, ...)
    if not self.log then return end
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function C:_once(key, fmt, ...)
    if self.logged[key] then return end
    self.logged[key] = true; self:_log(fmt, ...)
end
function C:_send(session, ctx, ids, resync, range)
    local f = { context = ctx.key, sequence = self.sequence + 1, range = math.floor(range or 0), resync = resync == true, ids = {} }
    for i, id in ipairs(ids) do f.ids[i] = { id = id } end
    if not Wire.Validate.PICKUP_COLLECT(f) then return false end
    local ok, sent = pcall(session.SendPickups, session, 'PICKUP_COLLECT', f)
    if ok and sent == true then self.sequence = f.sequence; self.stats.sent = self.stats.sent + 1; return true end
    return false
end
function C:_enter(ctx)
    self.contextKey = ctx.key
    self.model:Reset(ctx.key)
    pcall(self.view.Clear, self.view)
    self.bound, self.bindAt, self.resyncWanted, self.collectAt, self.base, self.grantSequence = false, nil, true, nil, 0, 0
end
function C:_bind(ctx, now)
    if self.bound then return true end
    if self.bindAt and now - self.bindAt < C.BIND_RETRY_SECONDS then return false end
    self.bindAt = now
    local ok, bound, why = pcall(self.view.Bind, self.view, ctx)
    if ok and bound == true then
        self.bound = true
        self.model:Each(function(id, it) self.view:Set(id, it.x, it.y, it.z, it.n, self.model.pending[id] ~= nil, it.kind) end)
        return true
    end
    self:_once('bind:' .. tostring(ok and why or bound), 'PICKUPS client orb view unavailable reason=%s', tostring(ok and why or bound))
    return false
end
function C:_apply(changes)
    if not self.bound then return end
    for _, ch in ipairs(changes) do
        if ch.op == 'remove' then self.view:Remove(ch.id)
        else self.view:Set(ch.id, ch.x, ch.y, ch.z, ch.n, ch.hidden, ch.kind) end
    end
end
function C:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if type(session.EnablePickups) ~= 'function' then return self:_once('nosession', 'PICKUPS client session has no pickup intake') end
        if ctx.key ~= self.contextKey then self:_enter(ctx) end
        session:EnablePickups()
        self:_bind(ctx, now)
        for _, item in ipairs(session:DrainPickups() or {}) do
            if item.type == 'PICKUP_DELTA' then
                local m = Wire.Validate.PICKUP_DELTA(item.f)
                if m and m.context == ctx.key then
                    if m.base > self.base then
                        -- a complete resend from empty (reliable messages are not ordered): drop the old view
                        if self.bound then self.model:Each(function(id) self.view:Remove(id) end) end
                        self.model:Reset(ctx.key); self.base = m.base
                    end
                    if m.base == self.base then self:_apply(self.model:Apply(m.items)) end
                end
            elseif item.type == 'PICKUP_GRANT' then
                local m = Wire.Validate.PICKUP_GRANT(item.f)
                if m and m.context == ctx.key and m.sequence > self.grantSequence then
                    self.grantSequence = m.sequence
                    if m.kind == 'h' then
                        local healed = self.heal(ctx, m.value)
                        self:_log('PICKUPS client health granted value=%s ok=%s', tostring(m.value), tostring(healed == true))
                    end
                end
            elseif item.type == 'PICKUP_RESULT' then
                local m = Wire.Validate.PICKUP_RESULT(item.f)
                if m and m.context == ctx.key then
                    self.stats.accepted, self.stats.refused = self.stats.accepted + m.accepted, self.stats.refused + m.refused
                    self.stats.xp = self.stats.xp + m.xp
                    if m.reason ~= '' then self:_once('refused:' .. m.reason, 'PICKUPS client claim refused reason=%s', m.reason) end
                end
            end
        end
        local player = self.player(ctx)
        if self.resyncWanted then
            if self:_send(session, ctx, {}, true, player and player.range) then self.resyncWanted = false end
        end
        if self.bound then
            for _, id in ipairs(self.model:Expire(now)) do self.view:Hide(id, false) end
        end
        if player and (not self.collectAt or now - self.collectAt >= C.COLLECT_SECONDS) then
            local orbReach = Orbs.BASE_RANGE + (player.range or 0)
            local ids = self.model:Near(player.x, player.y, function(kind)
                if kind == 'o' then return orbReach elseif kind == 'x' or kind == 'r' then return C.ACTOR_REACH end
                return C.CONSUMABLE_REACH
            end, now, Wire.MAX_COLLECT_IDS)
            if #ids > 0 then
                self.collectAt = now
                if self:_send(session, ctx, ids, false, player.range) then
                    if self.bound then for _, id in ipairs(ids) do self.view:Hide(id, true) end end
                else
                    for _, id in ipairs(ids) do self.model.pending[id] = nil end
                end
            end
        end
        if not self.summaryAt or now - self.summaryAt >= C.SUMMARY_SECONDS then
            self.summaryAt = now
            local n = 0; self.model:Each(function() n = n + 1 end)
            self:_log('PICKUPS client clumps=%d sent=%d accepted=%d refused=%d xp=%d bound=%s', n, self.stats.sent,
                self.stats.accepted, self.stats.refused, self.stats.xp, tostring(self.bound))
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'PICKUPS client tick error %s', tostring(err):sub(1, 200)) end
end
function C:Clear() self.contextKey = nil; return pcall(self.view.Clear, self.view) end
return C
