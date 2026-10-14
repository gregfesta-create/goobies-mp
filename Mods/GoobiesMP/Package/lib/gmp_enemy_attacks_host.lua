-- Enemy attacks part B1 (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 2, 4; D50 1-2). Dev flag ENEMY_ATTACKS. Host role
-- only, never raises. The host decides damage to clients with the game's own formulas, from each client's reported
-- (presence) position, and every player in range is hit (D50). The host itself keeps the game's native damage (its own
-- pawn is the game's target), so only connected clients are computed here. Hits go to Coder B's queue:
-- hit(key, damage, source) -> CLIENT_HIT with B's sequence and the CLIENT_DAMAGE / PLAYER_DOWN / shared-lives path.
--   mortar landing   BPC_ShootingEnemie ReceiveParticleData: per blob SphereOverlapActors(Position, Size, BP_Player)
--                    -> ChangeHP(EnemyDamageScale x 0.75); here: once per client per volley, any blob within Size +
--                    PLAYER_RADIUS
--   exploding enemy  BP_ExplosiveEnemy ReceiveParticleData: within ExplosionRadius -> (1 - d / R) x 3.5
--   Magmus balls     BP_Logic_Magmus_Balls ReceiveParticleData: per ball overlap -> ChangeHP(BallDamage); once per client
--   Gaia AOE         BP_Logic_Gaia 'Deal AOE DamageToPlayer'(Start, Radius, DamageMulti): pawn trace at Start/Radius ->
--                    ChangeHP(DamageMulti x Daddy.Damage)
--   Zigrid blast     BP_Logic_Zigrid ReceiveParticleData: within 300 of the blast -> ChangeHP(Daddy.Damage x 3)
--   Magmus laser     BP_Logic_Magmus_Laser: its own 30 cm trace only damages a hit actor equal to the target, which a
--                    stand-in (no collision) never is; polled here (A.Game.Lasers): every player within 30 + player radius
--                    of the visible beam -> LaserDamage, at most every LASER_SECONDS per player
-- C1 (targets re-pointed to stand-ins, gmp_enemy_targets_host.lua): these attacks' own trace/overlap only ever finds the
-- host, and their ChangeHP goes to the game's current target. Each hook opens the computed-attack window
-- (Targets.Computed) so damage the game routes to a stand-in is dropped, and when the game's target is NOT the host
-- pawn the host is computed here too (hit(hostKey, ...)); when it is the host, the host keeps the game's own damage.
-- The hook callbacks (Capture) only copy the event's numbers into a bounded queue; the damage is decided in Tick.
--   A.new{hit=fn, capture=<Capture>, log=fn}; a:Tick(ctx, session, now)
--   A.Capture.new{G, active=fn}; c:Install() (until the classes are loaded; once per process); c:Take() -> events
local Targets = require('gmp_enemy_targets_host')
local A = {}; A.__index = A
A.ZIGRID_RADIUS, A.ZIGRID_FACTOR = 300, 3
A.LASER_RADIUS, A.LASER_SECONDS = 30, 0.5
A.PLAYER_RADIUS = 50       -- BP_Player's collision radius (approximate)
A.MORTAR_FACTOR = 0.75
A.EXPLOSION_FACTOR = 3.5
A.MAX_DAMAGE = 100000
-- Boss mutations (Coder B, 2026-10-14; research/BOSS_LOGIC_STATIC.md): the game's own numbers
A.FIRETRAIL_RADIUS_FACTOR, A.FIRETRAIL_FACTOR = 0.5, 0.5
A.SPEW_FACTOR = 1.3
A.SWEEP_RADIUS, A.SWEEP_LENGTH, A.SWEEP_FACTOR = 80, 5000, 2
A.DEATHAURA_TICK_FACTOR = 0.1

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= 2000000 end

function A.new(options)
    options = options or {}
    return setmetatable({ hit = options.hit, capture = options.capture or A.Capture.new({ G = options.G }), log = options.log,
        game = options.game or A.Game.new({ G = options.G }), laserAt = {}, logged = {}, stats = { hits = 0, events = 0 } }, A)
end
function A:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
-- Connected clients (never the host) with a reported position, not dead.
local function clients(session, now)
    local out = {}
    local me = type(session.identity) == 'table' and session.identity.key or nil
    local okR, players = pcall(function() return session.roster:Snapshot() end)
    local connected = {}
    if okR and type(players) == 'table' then for _, p in ipairs(players) do if p.conn == 'connected' then connected[p.key] = true end end end
    local presence = session.presence
    if type(presence) ~= 'table' or type(presence.Visible) ~= 'function' then return out end
    local ok, list = pcall(presence.Visible, presence, now)
    if not ok or type(list) ~= 'table' then return out end
    for _, v in ipairs(list) do
        if v.key ~= me and connected[v.key] and v.dead ~= true and finite(v.x) and finite(v.y) then out[#out + 1] = v end
    end
    return out
end
local function anyWithin(particles, x, y, extra)
    for _, p in ipairs(particles) do
        local r = (p.size or 0) + extra
        if (p.x - x) ^ 2 + (p.y - y) ^ 2 <= r * r then return true end
    end
    return false
end
-- The damage of one event for a player at (x, y), or nil.
function A.Damage(event, x, y)
    local ps = event.particles
    if type(ps) ~= 'table' or #ps == 0 then return nil end
    for _, p in ipairs(ps) do if not finite(p.x) or not finite(p.y) or not (finite(p.size or 0) and (p.size or 0) >= 0) then return nil end end
    if event.kind == 'mortar' then
        if not finite(event.damageScale) or event.damageScale <= 0 then return nil end
        if anyWithin(ps, x, y, A.PLAYER_RADIUS) then return event.damageScale * A.MORTAR_FACTOR end
    elseif event.kind == 'explosion' then
        local r = event.radius
        if not finite(r) or r <= 0 then return nil end
        local p = ps[1]
        local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
        if d <= r then return (1 - math.min(1, d / r)) * A.EXPLOSION_FACTOR end
    elseif event.kind == 'magmus_balls' then
        if not finite(event.damage) or event.damage <= 0 then return nil end
        if anyWithin(ps, x, y, A.PLAYER_RADIUS) then return event.damage end
    elseif event.kind == 'gaia_aoe' then
        if not finite(event.damage) or event.damage <= 0 then return nil end
        if anyWithin(ps, x, y, A.PLAYER_RADIUS) then return event.damage end
    elseif event.kind == 'zigrid' then
        if not finite(event.damage) or event.damage <= 0 then return nil end
        local p = ps[1]
        if (p.x - x) ^ 2 + (p.y - y) ^ 2 < A.ZIGRID_RADIUS ^ 2 then return event.damage end
    -- boss mutations (Coder B): see the header
    elseif event.kind == 'firetrail' then
        if not finite(event.damage) or event.damage <= 0 then return nil end
        if anyWithin(ps, x, y, A.PLAYER_RADIUS) then return event.damage end   -- the game's loop stops at the first hit
    elseif event.kind == 'spew' then
        if not finite(event.damageScale) or event.damageScale <= 0 then return nil end
        local n = 0
        for _, p in ipairs(ps) do
            local r = (p.size or 0) + A.PLAYER_RADIUS
            if (p.x - x) ^ 2 + (p.y - y) ^ 2 <= r * r then n = n + 1 end
        end
        if n > 0 then return event.damageScale * A.SPEW_FACTOR * n end
    elseif event.kind == 'sweep' then
        if not finite(event.damage) or event.damage <= 0 then return nil end
        local n = 0
        for _, p in ipairs(ps) do
            if finite(p.vx) and finite(p.vy) and (p.vx ~= 0 or p.vy ~= 0) then
                -- the game's trace runs from Position - Velocity x 5000 to Position + Velocity x 5000
                local ax, ay = p.x - p.vx * A.SWEEP_LENGTH, p.y - p.vy * A.SWEEP_LENGTH
                local dx, dy = 2 * p.vx * A.SWEEP_LENGTH, 2 * p.vy * A.SWEEP_LENGTH
                local t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                local px, py = ax + dx * t, ay + dy * t
                local r = (p.size or A.SWEEP_RADIUS) + A.PLAYER_RADIUS
                if (x - px) ^ 2 + (y - py) ^ 2 <= r * r then n = n + 1 end
            end
        end
        if n > 0 then return event.damage * n end
    elseif event.kind == 'deathaura_bomb' or event.kind == 'deathaura_tick' then
        local r = event.radius
        if not finite(event.damage) or event.damage <= 0 or not finite(r) or r <= 0 then return nil end
        local p = ps[1]
        if (p.x - x) ^ 2 + (p.y - y) ^ 2 < r * r then return event.damage end   -- the game: distance to the player < radius
    end
    return nil
end
function A:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(session) ~= 'table' then return end
        if type(self.capture.Install) == 'function' then self.capture:Install() end
        local events = self.capture:Take()
        local okL, lasers = pcall(self.game.Lasers, self.game, ctx, now)
        if not okL or type(lasers) ~= 'table' then lasers = {} end
        if #events == 0 and #lasers == 0 then return end
        if type(session.sharedPause) == 'table' and session.sharedPause.paused == true then return end
        local targets = clients(session, now)
        local hostKey = type(session.identity) == 'table' and session.identity.key or nil
        local hostAt, hostName
        local okP, _, pawn = pcall(function() return ctx.islandWorld:LocalWorldPawn() end)
        if okP and pawn ~= nil then
            local okA, at = pcall(function() return pawn:K2_GetActorLocation() end)
            if okA and at then hostAt = { key = hostKey, x = at.X, y = at.Y } end
            local okN, n = pcall(function() return pawn:GetFullName() end)
            hostName = okN and n or nil
        end
        for _, l in ipairs(lasers) do self:_laser(l, targets, hostAt, hostName, now) end
        for _, event in ipairs(events) do
            self.stats.events = self.stats.events + 1
            local all = targets
            -- the game's own damage went to a stand-in (and was dropped): the host is computed here too
            if hostAt and event.target ~= nil and event.target ~= hostName then
                all = {}
                for _, c in ipairs(targets) do all[#all + 1] = c end
                all[#all + 1] = hostAt
            end
            for _, c in ipairs(all) do
                local dmg = A.Damage(event, c.x, c.y)
                if dmg and dmg > 0 and dmg <= A.MAX_DAMAGE and type(self.hit) == 'function' then
                    local okHit, queued = pcall(self.hit, c.key, dmg, event.kind)
                    if okHit and queued ~= false then self.stats.hits = self.stats.hits + 1
                    else self:_once('hit:' .. tostring(queued), 'ENEMYATTACK hit not queued reason=%s', tostring(queued)) end
                end
            end
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'ENEMYATTACK host tick error %s', tostring(err):sub(1, 200)) end
end

local function segmentDistance(l, x, y)
    local t = (x - l.x) * l.dx + (y - l.y) * l.dy
    if t < 0 then t = 0 elseif t > l.length then t = l.length end
    local px, py = l.x + l.dx * t, l.y + l.dy * t
    return math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
end
function A:_laser(l, targets, hostAt, hostName, now)
    if not (finite(l.x) and finite(l.y) and finite(l.dx) and finite(l.dy) and finite(l.length) and finite(l.damage)) or l.damage <= 0 then return end
    local all = {}
    for _, c in ipairs(targets) do all[#all + 1] = c end
    if hostAt and l.target ~= nil and l.target ~= hostName then all[#all + 1] = hostAt end
    for _, c in ipairs(all) do
        if segmentDistance(l, c.x, c.y) <= A.LASER_RADIUS + A.PLAYER_RADIUS
            and (not self.laserAt[c.key] or now - self.laserAt[c.key] >= A.LASER_SECONDS) and type(self.hit) == 'function' then
            self.laserAt[c.key] = now
            local okHit, queued = pcall(self.hit, c.key, l.damage, 'magmus_laser')
            if okHit and queued ~= false then self.stats.hits = self.stats.hits + 1 end
        end
    end
end

------------------------------------------------------------------ the real host objects (polled sources)
local Game = {}; Game.__index = Game; A.Game = Game
Game.LASER_PATH = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Logic_Magmus_Laser.BP_Logic_Magmus_Laser_C'
Game.LOOKUP_SECONDS = 1
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
local Live = require('gmp_pickups_pawncache').Live
local function fullNameOf(o) if o == nil then return nil end; local ok, n = pcall(function() return o:GetFullName() end); return ok and n or nil end
-- Visible Magmus lasers: {x, y, dx, dy, length, damage, target}. Logic actors from GetAllActorsOfClass (never
-- FindAllOf; test 12), looked up at most once a second.
function Game:Lasers(ctx, now)
    if not self.list or not self.at or (now or 0) - self.at >= Game.LOOKUP_SECONDS then
        self.at, self.list = now or 0, {}
        local okW, world, _, library = pcall(function() return ctx.islandWorld:LocalWorldPawn() end)
        local G = self.options.G or {}
        local find = G.StaticFindObject or (type(_G.StaticFindObject) == 'function' and _G.StaticFindObject) or nil
        local class = find and find(Game.LASER_PATH)
        if okW and world and library and Live(class) then
            local out = {}
            local ret = library:GetAllActorsOfClass(world, class, out)
            local found = (type(ret) == 'table' and #ret > 0) and ret or out
            for _, a in ipairs(found) do if Live(a) then self.list[#self.list + 1] = a end end
        end
    end
    local out = {}
    for _, logic in ipairs(self.list) do
        if Live(logic) then
            local laser = logic.Laser
            if Live(laser) and laser:IsVisible() == true then
                local at, dir = laser:K2_GetComponentLocation(), laser:GetForwardVector()
                local len = (logic.LaserScaleX or 0) * 100
                if at and dir and len > 0 then
                    out[#out + 1] = { x = at.X, y = at.Y, dx = dir.X, dy = dir.Y, length = len, damage = logic.LaserDamage,
                        target = fullNameOf(logic.Daddy and logic.Daddy['As BP Player']) }
                end
            end
        end
    end
    return out
end

------------------------------------------------------------------ hook capture (UE4SS RegisterHook)
local Capture = {}; Capture.__index = Capture; A.Capture = Capture
Capture.QUEUE_MAX = 64
Capture.PARTICLES_MAX = 64
Capture.PATHS = {
    mortar = '/Game/Blueprints/EnemyController/EnemyActors/BPC_ShootingEnemie.BPC_ShootingEnemie_C:ReceiveParticleData',
    explosion = '/Game/Blueprints/EnemyController/EnemyActors/BP_ExplosiveEnemy.BP_ExplosiveEnemy_C:ReceiveParticleData',
    magmus_balls = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Logic_Magmus_Balls.BP_Logic_Magmus_Balls_C:ReceiveParticleData',
    gaia_aoe = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Logic_Gaia.BP_Logic_Gaia_C:Deal AOE DamageToPlayer',
    zigrid = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Logic_Zigrid.BP_Logic_Zigrid_C:ReceiveParticleData',
    -- boss mutations (Coder B, 2026-10-14)
    firetrail = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/Mutations/BP_Mutation_FireTrail.BP_Mutation_FireTrail_C:ReceiveParticleData',
    spew = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/Mutations/BP_Mutation_Spew.BP_Mutation_Spew_C:ReceiveParticleData',
    sweep = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/Mutations/BP_Mutation_Sweep.BP_Mutation_Sweep_C:ReceiveParticleData',
    deathaura_bomb = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/Mutations/BP_Mutation_DeathAura.BP_Mutation_DeathAura_C:ReceiveParticleData',
    deathaura_tick = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/Mutations/BP_Mutation_DeathAura.BP_Mutation_DeathAura_C:DeathTick',
}
-- the kinds whose game damage may be misrouted to a stand-in (see the header)
Capture.COMPUTED = { mortar = true, magmus_balls = true, gaia_aoe = true, zigrid = true,
    firetrail = true, spew = true, sweep = true, deathaura_bomb = true, deathaura_tick = true }
-- The hooks live as long as the process: one state per Lua state (G) with the registered kinds, ONE shared queue and the
-- newest capture's activity check, so a later run (a new Capture) never registers twice and still receives the events.
local STATES = setmetatable({}, { __mode = 'k' })
local LOCAL = {}
local function state(G)
    local key = G or LOCAL
    local st = STATES[key]
    if not st then st = { done = {}, queue = {}, active = function() return false end }; STATES[key] = st end
    return st
end
function Capture.new(options)
    options = options or {}
    local self = setmetatable({ G = options.G, active = options.active or function() return true end }, Capture)
    self.state = state(self.G)
    self.state.active = self.active
    return self
end
local function get(p) if p == nil then return nil end; local ok, v = pcall(function() return p:get() end); return ok and v or nil end
local function particleList(param)
    local arr, out = get(param), {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, elem)
            if #out >= Capture.PARTICLES_MAX then return end
            local d = get(elem)
            local pos = d and d.Position
            if pos and finite(pos.X) and finite(pos.Y) then
                local row = { x = pos.X, y = pos.Y, size = d.Size or 0 }
                local v = d.Velocity
                if v and finite(v.X) and finite(v.Y) then row.vx, row.vy = v.X, v.Y end
                out[#out + 1] = row
            end
        end)
    end)
    return out
end
local function fullName(o) if o == nil then return nil end; local ok, n = pcall(function() return o:GetFullName() end); return ok and n or nil end
local function callback(st, kind)
    return function(context, data, radius, multi)
        pcall(function()
            if st.active() ~= true then return end
            if Capture.COMPUTED[kind] then Targets.Computed(true) end
            if #st.queue >= Capture.QUEUE_MAX then return end
            local owner = get(context)
            if owner == nil then return end
            local event = { kind = kind }
            local daddyOf = owner.Daddy
            if kind == 'deathaura_tick' then
                -- DeathTick: no particles; around the mutation (it sits on its boss)
                local okL, at = pcall(function() return owner:K2_GetActorLocation() end)
                if not okL or not at or not finite(at.X) or not finite(at.Y) or not daddyOf then return end
                event.particles = { { x = at.X, y = at.Y, size = 0 } }
                event.radius = owner.DeathAuraRadius
                event.damage = (daddyOf.Damage or 0) * A.DEATHAURA_TICK_FACTOR
                event.target = fullName(daddyOf['As BP Player'])
            elseif kind == 'gaia_aoe' then
                local start, r, m = get(data), get(radius), get(multi)
                local daddy = owner.Daddy
                if not start or not finite(start.X) or not finite(r) or not finite(m) or not daddy then return end
                event.particles = { { x = start.X, y = start.Y, size = r } }
                event.damage = m * (daddy.Damage or 0)
                event.target = fullName(daddy['As BP Player'])
            else
                event.particles = particleList(data)
                if #event.particles == 0 then return end
                if kind == 'mortar' then
                    local player = owner.Player
                    local controller = player and player.EnemyController
                    event.damageScale = controller and controller.EnemyDamageScale
                    event.target = fullName(player)
                elseif kind == 'explosion' then event.radius = owner.ExplosionRadius
                elseif kind == 'magmus_balls' then
                    event.damage = owner.BallDamage
                    event.target = fullName(owner.Daddy and owner.Daddy['As BP Player'])
                elseif kind == 'zigrid' then
                    local daddy = owner.Daddy
                    event.damage = daddy and (daddy.Damage or 0) * A.ZIGRID_FACTOR
                    event.target = fullName(daddy and daddy['As BP Player'])
                    event.particles = { event.particles[1] }
                elseif kind == 'firetrail' then
                    if not daddyOf then return end
                    for _, p in ipairs(event.particles) do p.size = (p.size or 0) * A.FIRETRAIL_RADIUS_FACTOR end
                    event.damage = (daddyOf.Damage or 0) * A.FIRETRAIL_FACTOR
                    event.target = fullName(daddyOf['As BP Player'])
                elseif kind == 'spew' then
                    local player = daddyOf and daddyOf['As BP Player']
                    local controller = player and player.EnemyController
                    event.damageScale = controller and controller.EnemyDamageScale
                    event.target = fullName(player)
                elseif kind == 'sweep' then
                    if not daddyOf then return end
                    for _, p in ipairs(event.particles) do p.size = A.SWEEP_RADIUS end
                    event.damage = (daddyOf.Damage or 0) * A.SWEEP_FACTOR
                    event.target = fullName(daddyOf['As BP Player'])
                elseif kind == 'deathaura_bomb' then
                    if not daddyOf then return end
                    event.particles = { event.particles[1] }
                    event.radius = owner.ExplosionRadius
                    event.damage = (daddyOf.Damage or 0) * (owner.Damage or 0)
                    event.target = fullName(daddyOf['As BP Player'])
                end
            end
            st.queue[#st.queue + 1] = event
        end)
    end
end
local function after() pcall(Targets.Computed, false) end
function Capture:Install()
    local G = self.G or {}
    self.state.active = self.active
    if type(G.RegisterHook) ~= 'function' or type(G.StaticFindObject) ~= 'function' then return false end
    for kind, path in pairs(Capture.PATHS) do
        if not self.state.done[kind] then
            local okFind, fn = pcall(G.StaticFindObject, path)
            if okFind and fn ~= nil then
                local post = Capture.COMPUTED[kind] and after or nil
                if pcall(G.RegisterHook, path, callback(self.state, kind), post) then self.state.done[kind] = true end
            end
        end
    end
    return true
end
function Capture:Take()
    local out = self.state.queue
    self.state.queue = {}
    return out
end
return A
