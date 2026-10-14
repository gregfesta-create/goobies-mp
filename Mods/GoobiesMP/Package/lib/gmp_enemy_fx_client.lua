-- Enemy attack visuals on clients, part A (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 2, 5). Dev flag ENEMY_FX.
-- Client role only, never raises. Visual only: the game's own effects, never a callback (gmp_enemy_fx.lua).
--   * From the host enemy rows the client already receives (session.enemyDelta, gmp_enemy_delta.lua; read only):
--       class 3 (exploding enemy) dies  -> its blast NS_ExplodingEnemyDeath (User.Radius = the game's ExplosionRadius)
--       class 2 / 10 (Tick / EliteTick) dies -> the burst NS_BigExplosion
--       class 7 (healer) alive -> a heal pulse FX_HealingEnemy once a second (HealingTickRate 1) at its newest position
--     Rows already dead when first seen (a late join) play nothing.
--   * Host-sent ENEMY_FX events (gmp_enemy_fx_host.lua: the queen mortar, Gaia's danger indicator and AOE burst,
--     Zigrid's attack, the Magmus eruption) are played as they come, once per sequence (reliable messages are not
--     ordered: a sequence is played once even when it arrives after a newer one). Magmus laser updates (laser, about
--     10 a second) go to the beam view (gmp_enemy_fx_beam.lua), the newest per laser; laser_end removes it.
--   C.new{spawner, beam, log, G, explosionRadius=fn}; c:Tick(ctx, session, now, inbox); c:Clear()
local FX = require('gmp_enemy_fx')
local Wire = require('gmp_pickups_wire')
local C = {}; C.__index = C
C.EXPLOSIVE, C.HEALER = 3, 7
C.TICKS = { [2] = true, [10] = true }
C.HEAL_SECONDS = 1
C.COPY_SECONDS = 9         -- an Amam projectile ends itself after 8 s
C.COPY_MAX = 64
C.SEEN_WINDOW = 512        -- sequences older than the newest minus this are dropped (and forgotten)
C.EXPLOSION_RADIUS = 300   -- used when the game's own ExplosionRadius cannot be read
C.EXPLOSIVE_DEFAULT = '/Game/Blueprints/EnemyController/EnemyActors/BP_ExplosiveEnemy.Default__BP_ExplosiveEnemy_C'

function C.new(options)
    options = options or {}
    local self = setmetatable({ spawner = options.spawner or FX.Spawner.new({ G = options.G, log = options.log }),
        log = options.log, G = options.G, seen = {}, healAt = {}, sequence = 0, copies = {}, played = {}, lasers = {} }, C)
    self.beam = options.beam or require('gmp_enemy_fx_beam').new({ G = options.G, log = options.log })
    self.explosionRadius = options.explosionRadius or function() return self:_explosionRadius() end
    return self
end
function C:_explosionRadius()
    if self.radius then return self.radius end
    local ok, r = pcall(function()
        local find = self.G and self.G.StaticFindObject
        local cdo = find and find(C.EXPLOSIVE_DEFAULT)
        return cdo and cdo:IsValid() == true and cdo.ExplosionRadius or nil
    end)
    self.radius = ok and type(r) == 'number' and r > 0 and r or C.EXPLOSION_RADIUS
    return self.radius
end
local function newest(e)
    local s = type(e.samples) == 'table' and e.samples[#e.samples]
    if s and type(s.x) == 'number' and type(s.y) == 'number' then return s.x, s.y end
    if type(e.base) == 'table' and type(e.base.x) == 'number' then return e.base.x, e.base.y end
    return nil
end
function C:_rows(ctx, session, now)
    local delta = session.enemyDelta
    if type(delta) ~= 'table' or type(delta.enemies) ~= 'table' then return end
    local ids = {}
    for id in pairs(delta.enemies) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(ids) do
        local e = delta.enemies[id]
        local known = self.seen[id]
        if known == nil then
            self.seen[id] = e.dead == true and 'dead' or 'alive'
        elseif known == 'alive' and e.dead == true then
            self.seen[id] = 'dead'
            local x, y = newest(e)
            if x then
                if e.enemyType == C.EXPLOSIVE then
                    self.spawner:Play(ctx, 'explosion', { x = x, y = y, z = 0, radius = self.explosionRadius() }, now)
                elseif C.TICKS[e.enemyType] then
                    self.spawner:Play(ctx, 'burst', { x = x, y = y, z = 0 }, now)
                end
            end
        end
        if e.enemyType == C.HEALER and e.dead ~= true and (not self.healAt[id] or now - self.healAt[id] >= C.HEAL_SECONDS) then
            local x, y = newest(e)
            if x then self.healAt[id] = now; self.spawner:Play(ctx, 'heal', { x = x, y = y, z = 0 }, now) end
        end
    end
    -- forget rows the stream dropped
    for id in pairs(self.seen) do if not delta.enemies[id] then self.seen[id], self.healAt[id] = nil, nil end end
end
function C:Tick(ctx, session, now, inbox)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if ctx.key ~= self.contextKey then
            if self.contextKey then pcall(self.beam.Clear, self.beam) end
            self.contextKey, self.seen, self.healAt, self.sequence, self.copies, self.played, self.lasers = ctx.key, {}, {}, 0, {}, {}, {}
        end
        for _, item in ipairs(inbox or {}) do
            if item.type == 'ENEMY_FX' then
                local m = Wire.Validate.ENEMY_FX(item.f)
                if m and m.context == ctx.key and not self.played[m.sequence] and m.sequence > self.sequence - C.SEEN_WINDOW then
                    self.played[m.sequence] = true
                    if m.sequence > self.sequence then self.sequence = m.sequence end
                    if m.fx == 'laser' then
                        if m.id > 0 and m.sequence > (self.lasers[m.id] or 0) then
                            self.lasers[m.id] = m.sequence
                            pcall(self.beam.Update, self.beam, ctx, m, now)
                        end
                    elseif m.fx == 'laser_end' then
                        self.lasers[m.id] = math.huge
                        pcall(self.beam.End, self.beam, m.id)
                    elseif m.fx == 'amam_shot' then
                        local n = 0; for _ in pairs(self.copies) do n = n + 1 end
                        if n < C.COPY_MAX and m.id > 0 and not self.copies[m.id] and type(self.spawner.Actor) == 'function' then
                            local actor = self.spawner:Actor(ctx, 'amam_shot', m, now)
                            if actor then self.copies[m.id] = { actor = actor, at = now } end
                        end
                    elseif m.fx == 'amam_end' then
                        local copy = self.copies[m.id]
                        if copy then self.copies[m.id] = nil; pcall(self.spawner.Destroy, self.spawner, copy.actor) end
                    else
                        self.spawner:Play(ctx, m.fx, m, now)
                    end
                end
            end
        end
        for s in pairs(self.played) do if s <= self.sequence - C.SEEN_WINDOW then self.played[s] = nil end end
        pcall(self.beam.Tick, self.beam, now)
        self:_rows(ctx, session, now)
        for id, copy in pairs(self.copies) do if now - copy.at >= C.COPY_SECONDS then self.copies[id] = nil end end
    end)
    if not ok and self.log and not self.errorLogged then self.errorLogged = true; pcall(self.log, 'ENEMYFX client tick error ' .. tostring(err):sub(1, 200)) end
end
-- Run end / sync stop: the drawn lasers go (one-off effects end themselves).
function C:Clear()
    self.lasers = {}
    local ok, clean = pcall(self.beam.Clear, self.beam)
    return ok and clean ~= false
end
return C
