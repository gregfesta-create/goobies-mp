-- Enemy attack visuals on clients, part A (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 2, 5). Dev flag ENEMY_FX.
-- Host role only, never raises. The queen's mortar exists only in the host world (BPC_ShootingEnemie, one per queen
-- enemy, Type 1): 1.5 s after its Shoot timer it spawns NS_ShootingEnemyMortarBlobs at the row (SpawnedNS, HitLocation)
-- aimed at Player + Player velocity x a random lead. The host watches every queen component each tick; a new SpawnedNS
-- is one shot: ENEMY_FX mortar {from the row, to Player + LEAD x velocity} to every connected client, where
-- gmp_enemy_fx_client.lua plays the same effect without its callback (visual only; the host keeps the damage and the
-- blobs' new enemies, which reach clients as rows). Explosions, Tick bursts and healer pulses need no message: the client
-- derives them from the rows it already receives.
-- Boss attacks (follow-up): explicit hooks on the bosses' own Blueprint functions (the RegisterHook route used safely
-- across this mod; native function hooks are not used: Phase 0 recorded a native hook hang, and two routes would play
-- every effect twice) send the effect's exact parameters:
--   danger     BP_Logic_Gaia RedIndicator(Location, Lifetime, Radius)  -> NS_DangerIndicator (user.lifetime, user.radius)
--   burst      BP_Logic_Gaia 'Deal AOE DamageToPlayer'(Start, ...)     -> NS_BigExplosion at Start
--   zigrid     BP_Logic_Zigrid SpawnAttack(Location)                   -> NS_BossChamanAttack
--   ball_land  BP_Logic_Magmus_Balls ReceiveParticleData (a landing)   -> NS_MagmusEruption, boss -> landing (User.EndPos,
--              User.Radius = the ball size); the client's eruption starts as the host's ball lands (late by its flight)
-- and the Magmus laser (a mesh beam, not an effect) is polled while visible and streamed about 10 times a second (laser:
-- its world transform and end point; laser_end once when it goes off). Mumsa has no effect of its own (movement
-- timelines only); Amam is gmp_enemy_amam_host.lua.
--   H.new{game=<adapter>, log=fn, G}; h:Tick(ctx, session, now); h:Deactivate()   session: roster, identity, SendPickups
local Wire = require('gmp_pickups_wire')
local Live = require('gmp_pickups_pawncache').Live
local FX = require('gmp_enemy_fx')
local H = {}; H.__index = H
H.LEAD = 0.5   -- the game's lead is velocity x RandomFloat(0..1); the mean
H.LASER_SECONDS = 0.1

function H.new(options)
    options = options or {}
    local self = setmetatable({ game = options.game or H.Game.new({ G = options.G }), log = options.log, last = {}, sequence = 0, logged = {},
        beams = {}, beamSeq = 0 }, H)
    self.boss = H.BossHooks.new({ G = options.G, active = function() return self.active == true end })
    return self
end
function H:Deactivate() self.active = false end
function H:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
local function round(v) return math.floor((v or 0) + 0.5) end
function H:_send(ctx, session, f)
    self.sequence = FX.NextSequence()
    f.context, f.sequence, f.id = ctx.key, self.sequence, f.id or 0
    f.ex, f.ey = f.ex or f.x, f.ey or f.y
    for _, k in ipairs({ 'z', 'ez', 'radius', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz' }) do f[k] = f[k] or 0 end
    if not Wire.Validate.ENEMY_FX(f) then return end
    local ok, players = pcall(function() return session.roster:Snapshot() end)
    if not ok or type(players) ~= 'table' then return end
    local me = type(session.identity) == 'table' and session.identity.key or nil
    for _, p in ipairs(players) do
        if p.key ~= me and p.conn == 'connected' then pcall(session.SendPickups, session, p.key, 'ENEMY_FX', f) end
    end
end
function H:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if ctx.key ~= self.contextKey then self.contextKey, self.last, self.beams = ctx.key, {}, {}; self.boss:Take() end   -- a new run drops old boss events
        self.active = true
        self.boss:Install()
        for _, e in ipairs(self.boss:Take()) do self:_send(ctx, session, e) end
        self:_lasers(ctx, session, now)
        local okQ, queens, why = pcall(self.game.Queens, self.game, ctx, now)
        if not okQ then return self:_once('queens:' .. tostring(queens), 'ENEMYFX host queens unreadable %s', tostring(queens):sub(1, 160)) end
        if type(queens) ~= 'table' then return self:_once('queens:' .. tostring(why), 'ENEMYFX host queens unavailable %s', tostring(why)) end
        local present = {}
        for _, q in ipairs(queens) do
            present[q.key] = true
            local before = self.last[q.key]
            if before == nil then
                self.last[q.key] = q.ns or false            -- first sight: an effect already there is not a new shot
            elseif q.ns and q.ns ~= before then
                self.last[q.key] = q.ns
                if q.type == 1 and q.from and q.target then
                    local t = q.target
                    self:_send(ctx, session, { fx = 'mortar', x = round(q.from.x), y = round(q.from.y), z = 0,
                        ex = round(t.x + H.LEAD * (t.vx or 0)), ey = round(t.y + H.LEAD * (t.vy or 0)), ez = round(t.z or 0), radius = 0 })
                end
            elseif not q.ns then
                self.last[q.key] = false
            end
        end
        for key in pairs(self.last) do if not present[key] then self.last[key] = nil end end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'ENEMYFX host tick error %s', tostring(err):sub(1, 200)) end
end

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= 2000000 end
function H:_lasers(ctx, session, now)
    if type(self.game.Lasers) ~= 'function' then return end
    local ok, list = pcall(self.game.Lasers, self.game, ctx, now)
    if not ok or type(list) ~= 'table' then return end
    local present = {}
    for _, b in ipairs(list) do
        if b.key and finite(b.x) and finite(b.y) then
            present[b.key] = true
            local st = self.beams[b.key]
            if not st then self.beamSeq = self.beamSeq + 1; st = { id = self.beamSeq }; self.beams[b.key] = st end
            if not st.at or now - st.at >= H.LASER_SECONDS then
                st.at = now
                self:_send(ctx, session, { fx = 'laser', x = round(b.x), y = round(b.y), z = round(b.z), ex = round(b.ex), ey = round(b.ey), ez = round(b.z),
                    radius = 0, id = st.id, rx = round((b.pitch or 0) * 100), ry = round((b.yaw or 0) * 100), rz = round((b.roll or 0) * 100),
                    sx = round(math.max(0, b.sx or 0) * 1000), sy = round(math.max(0, b.sy or 0) * 1000), sz = round(math.max(0, b.sz or 0) * 1000) })
            end
        end
    end
    for key, st in pairs(self.beams) do
        if not present[key] then self.beams[key] = nil; self:_send(ctx, session, { fx = 'laser_end', x = 0, y = 0, id = st.id }) end
    end
end

------------------------------------------------------------------ boss attack hooks (BP functions, process-wide)
local Boss = {}; Boss.__index = Boss; H.BossHooks = Boss
local BOSSES = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/'
Boss.PATHS = {
    danger = BOSSES .. 'BP_Logic_Gaia.BP_Logic_Gaia_C:RedIndicator',
    burst = BOSSES .. 'BP_Logic_Gaia.BP_Logic_Gaia_C:Deal AOE DamageToPlayer',
    zigrid = BOSSES .. 'BP_Logic_Zigrid.BP_Logic_Zigrid_C:SpawnAttack',
    ball_land = BOSSES .. 'BP_Logic_Magmus_Balls.BP_Logic_Magmus_Balls_C:ReceiveParticleData',
}
Boss.QUEUE_MAX = 64
local BOSS_STATES = setmetatable({}, { __mode = 'k' })
local BOSS_LOCAL = {}
local function bossState(G)
    local key = G or BOSS_LOCAL
    local st = BOSS_STATES[key]
    if not st then st = { done = {}, queue = {}, active = function() return false end }; BOSS_STATES[key] = st end
    return st
end
function Boss.new(options)
    options = options or {}
    local self = setmetatable({ G = options.G, active = options.active or function() return true end }, Boss)
    self.state = bossState(self.G)
    return self
end
local function pget(p) if p == nil then return nil end; local ok, v = pcall(function() return p:get() end); return ok and v or nil end
local function vec(v) if type(v) ~= 'table' and type(v) ~= 'userdata' then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and finite(x) and finite(y) then return x, y, finite(z) and z or 0 end
end
local function bossCallback(st, kind)
    return function(context, a, b, c)
        pcall(function()
            if st.active() ~= true or #st.queue >= Boss.QUEUE_MAX then return end
            if kind == 'ball_land' then
                -- the game reads Data[0] only (one landing per callback): the eruption from the boss to that spot
                local arr = pget(a)
                if arr == nil then return end
                local first
                arr:ForEach(function(_, elem) if first == nil then first = pget(elem) or false end end)
                local ex, ey, ez = vec(first and first.Position)
                if not ex then return end
                local size = first.Size
                local x, y, z = ex, ey, ez
                local okAt, at = pcall(function() return pget(context):K2_GetActorLocation() end)
                if okAt then local bx, by, bz = vec(at); if bx then x, y, z = bx, by, bz end end
                st.queue[#st.queue + 1] = { fx = 'ball_land', x = round(x), y = round(y), z = round(z), ex = round(ex), ey = round(ey), ez = 0,
                    radius = finite(size) and round(math.max(0, size)) or 0 }
                return
            end
            local x, y, z = vec(pget(a))
            if not x then return end
            local e = { fx = kind, x = round(x), y = round(y), z = round(z) }
            if kind == 'danger' then
                local lifetime, radius = pget(b), pget(c)
                e.ez = finite(lifetime) and round(lifetime * 1000) or 0
                e.radius = finite(radius) and round(radius) or 0
            end
            st.queue[#st.queue + 1] = e
        end)
    end
end
function Boss:Install()
    local G = self.G or {}
    self.state.active = self.active
    if type(G.RegisterHook) ~= 'function' or type(G.StaticFindObject) ~= 'function' then return false end
    for kind, path in pairs(Boss.PATHS) do
        if not self.state.done[kind] then
            local okFind, fn = pcall(G.StaticFindObject, path)
            if okFind and fn ~= nil and pcall(G.RegisterHook, path, bossCallback(self.state, kind)) then self.state.done[kind] = true end
        end
    end
    return true
end
function Boss:Take()
    local out = self.state.queue
    self.state.queue = {}
    return out
end

------------------------------------------------------------------ the real host objects
local Game = {}; Game.__index = Game; H.Game = Game
Game.HANDLER_PATH = '/Game/Blueprints/EnemyController/EnemyActors/BP_ShootingEnemy.BP_ShootingEnemy_C'
Game.COMPONENT_PATH = '/Game/Blueprints/EnemyController/EnemyActors/BPC_ShootingEnemie.BPC_ShootingEnemie_C'
Game.HANDLER_SECONDS = 2
Game.LASER_PATH = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Logic_Magmus_Laser.BP_Logic_Magmus_Laser_C'
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
local function list(arr)
    if arr == nil then return {} end
    if type(arr) == 'table' and type(arr.GetArrayNum) ~= 'function' then return arr end
    local out = {}
    pcall(function() for i = 1, arr:GetArrayNum() do out[i] = arr[i] end end)
    return out
end
function Game:_find(path)
    local G = self.options.G or {}
    local find = G.StaticFindObject or (type(_G.StaticFindObject) == 'function' and _G.StaticFindObject) or nil
    local o = find and find(path)
    return Live(o) and o or nil
end
-- The queen handler actors of the local world (GameplayStatics:GetAllActorsOfClass, never FindAllOf; test 12).
function Game:_handlers(ctx, now)
    if self.handlers and self.handlersAt and (now or 0) - self.handlersAt < Game.HANDLER_SECONDS then
        local all = true
        for _, h in ipairs(self.handlers) do if not Live(h) then all = false end end
        if all then return self.handlers end
    end
    local world, _, library = ctx.islandWorld:LocalWorldPawn()
    if not world or not library then return {} end
    local class = self:_find(Game.HANDLER_PATH)
    if not class then return {} end
    local out = {}
    local ret = library:GetAllActorsOfClass(world, class, out)
    local found = (type(ret) == 'table' and #ret > 0) and ret or out
    self.handlers, self.handlersAt = {}, now or 0
    for _, a in ipairs(found) do if Live(a) then self.handlers[#self.handlers + 1] = a end end
    return self.handlers
end
local function name(o) local ok, n = pcall(function() return o:GetFullName() end); return ok and n or nil end
function Game:Queens(ctx, now)
    local island = ctx.islandWorld
    if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil, 'no_island_world' end
    local compClass = self:_find(Game.COMPONENT_PATH)
    if not compClass then return {} end
    local out = {}
    for _, handler in ipairs(self:_handlers(ctx, now)) do
        for _, comp in ipairs(list(handler:K2_GetComponentsByClass(compClass))) do
            if Live(comp) then
                local key = name(comp)
                local ns = comp.SpawnedNS
                local hit, player = comp.HitLocation, comp.Player
                local target
                if Live(player) then
                    local at, vel = player:K2_GetActorLocation(), player:GetVelocity()
                    target = { x = at.X, y = at.Y, z = at.Z, vx = vel and vel.X or 0, vy = vel and vel.Y or 0 }
                end
                if key then
                    out[#out + 1] = { key = key, ns = Live(ns) and name(ns) or nil, type = comp.Type,
                        from = hit and { x = hit.X, y = hit.Y } or nil, target = target }
                end
            end
        end
    end
    return out
end
-- Visible Magmus laser beams: {key, x, y, z, pitch, yaw, roll, sx, sy, sz, ex, ey} (GetAllActorsOfClass, 1 s cache).
function Game:Lasers(ctx, now)
    if not self.laserList or not self.laserAt or (now or 0) - self.laserAt >= 1 then
        self.laserAt, self.laserList = now or 0, {}
        local world, _, library = ctx.islandWorld:LocalWorldPawn()
        local class = self:_find(Game.LASER_PATH)
        if world and library and class then
            local out = {}
            local ret = library:GetAllActorsOfClass(world, class, out)
            for _, a in ipairs((type(ret) == 'table' and #ret > 0) and ret or out) do if Live(a) then self.laserList[#self.laserList + 1] = a end end
        end
    end
    local beams = {}
    for _, logic in ipairs(self.laserList) do
        local laser = Live(logic) and logic.Laser or nil
        if Live(laser) and laser:IsVisible() == true then
            local at, rot, sc, fwd = laser:K2_GetComponentLocation(), laser:K2_GetComponentRotation(), laser:K2_GetComponentScale(), laser:GetForwardVector()
            local len = (logic.LaserScaleX or 0) * 100
            if at and rot and sc and fwd then
                beams[#beams + 1] = { key = name(logic), x = at.X, y = at.Y, z = at.Z, pitch = rot.Pitch, yaw = rot.Yaw, roll = rot.Roll,
                    sx = sc.X, sy = sc.Y, sz = sc.Z, ex = at.X + fwd.X * len, ey = at.Y + fwd.Y * len }
            end
        end
    end
    return beams
end
return H
