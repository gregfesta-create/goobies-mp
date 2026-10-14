-- Enemy attack visuals on clients, part A (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 5). Dev flag ENEMY_FX.
-- The catalog of the game's own Niagara effects for host-only enemy attacks, and the spawner that plays one at a spot
-- with its user parameters, through the same NiagaraFunctionLibrary:SpawnSystemAtLocation route the enemy view uses
-- (gmp_native_enemy_instances.lua, verified in test 11), with the local enemy controller as world context. It never sets
-- the effect's callback object, so on a client nothing runs the game's damage or spawn code: visual only.
--   FX.CATALOG[kind] = {path, endParam?, radiusParam?, floats?={{name, field, factor}}}
--   FX.Spawner.new{G, log, perSecond=30}; s:Play(ctx, kind, {x, y, z, ex, ey, ez, radius}, now) -> ok, why
local FX = {}
FX.CATALOG = {
    -- BPC_ShootingEnemie (queen) mortar: spawned at the row, user.endpos = the target (its callback lands the blobs)
    mortar = { path = '/Game/FX/Test/NS_ShootingEnemyMortarBlobs.NS_ShootingEnemyMortarBlobs', endParam = 'user.endpos' },
    -- BP_ExplosiveEnemy death (class 3): User.Radius = ExplosionRadius
    explosion = { path = '/Game/FX/Test/NS_ExplodingEnemyDeath.NS_ExplodingEnemyDeath', radiusParam = 'User.Radius' },
    -- BP_SpreadingEnemy death (Tick 2 / EliteTick 10)
    burst = { path = '/Game/FX/Test/NS_BigExplosion.NS_BigExplosion' },
    -- BP_HealingEnemy (class 7) heal pulse
    heal = { path = '/Game/FX/Test/Consumables/FX_HealingEnemy.FX_HealingEnemy' },
    -- boss attacks (gmp_enemy_fx_host.lua BossHooks):
    -- Gaia RedIndicator: user.lifetime (s) = ez / 1000, user.radius = radius (floats, as the Blueprint sets them)
    danger = { path = '/Game/FX/Test/BossChaman/NS_DangerIndicator.NS_DangerIndicator',
        floats = { { 'user.lifetime', 'ez', 0.001 }, { 'user.radius', 'radius', 1 } } },
    -- Zigrid SpawnAttack (the game also sets User.CallBack, which spawns its damage: never set here)
    zigrid = { path = '/Game/FX/Test/BossChaman/NS_BossChamanAttack.NS_BossChamanAttack' },
    -- Magmus balls: the eruption from the boss (x, y, z) to the landing (User.EndPos), User.Radius = the ball size
    ball_land = { path = '/Game/FX/Test/BossMagmus/NS_MagmusEruption.NS_MagmusEruption', endParam = 'User.EndPos', radiusParam = 'User.Radius' },
}
FX.LIBRARY = '/Script/Niagara.Default__NiagaraFunctionLibrary'
FX.STATICS = '/Script/Engine.Default__GameplayStatics'
-- C2: visual copies of host projectile actors (spawned harmless: Damage 0 before BeginPlay, collision off after)
FX.ACTORS = {
    amam_shot = { path = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Amam_Projectile02.BP_Amam_Projectile02_C' },
}
FX.PER_SECOND = 30
-- One ENEMY_FX sequence for every host sender (boss visuals, mortar, Amam): the client plays each sequence once.
local fxSequence = 0
function FX.NextSequence() fxSequence = fxSequence + 1; return fxSequence end
FX.LIMIT = 2000000

local function valid(o)
    if o == nil then return false end
    local ok, live = pcall(function() return o:IsValid() == true end)
    return ok and live == true
end
local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= FX.LIMIT end

local Spawner = {}; Spawner.__index = Spawner; FX.Spawner = Spawner
function Spawner.new(options)
    options = options or {}
    return setmetatable({ G = options.G, log = options.log, perSecond = options.perSecond or FX.PER_SECOND,
        window = { start = -math.huge, n = 0 }, logged = {}, systems = {} }, Spawner)
end
function Spawner:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function Spawner:_system(path)
    local cached = self.systems[path]
    if valid(cached) then return cached end
    local find = self.G and self.G.StaticFindObject
    local system = find and find(path)
    if not valid(system) then return nil end
    self.systems[path] = system
    return system
end
function Spawner:Play(ctx, kind, p, now)
    local entry = FX.CATALOG[kind]
    if not entry or type(p) ~= 'table' or not finite(p.x) or not finite(p.y) then return false, 'enemy_fx_invalid' end
    local w = self.window
    if now - w.start >= 1 then w.start, w.n = now, 0 end
    if w.n >= self.perSecond then return false, 'enemy_fx_rate' end
    local ok, result, why = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return false, 'no_island_world' end
        local _, pawn = island:LocalWorldPawn()
        if not valid(pawn) then return false, 'no_pawn' end
        local context = pawn.EnemyController
        if not valid(context) then context = pawn end
        local find = self.G and self.G.StaticFindObject
        local lib = find and find(FX.LIBRARY)
        if not valid(lib) then return false, 'no_niagara_library' end
        local system = self:_system(entry.path)
        if not valid(system) then return false, 'no_effect_asset:' .. kind end
        local component = lib:SpawnSystemAtLocation(context, system, { X = p.x, Y = p.y, Z = finite(p.z) and p.z or 0 },
            { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, true, true, 0, true)
        if not valid(component) then return false, 'effect_spawn_failed' end
        local FName = self.G and self.G.FName
        local function n(text) return FName and FName(text) or text end
        if entry.endParam and finite(p.ex) and finite(p.ey) then
            local endpos = { X = p.ex, Y = p.ey, Z = finite(p.ez) and p.ez or 0 }
            pcall(function() component:SetVariableVec3(n(entry.endParam), endpos) end)
        end
        if entry.radiusParam and finite(p.radius) and p.radius > 0 then
            pcall(function() component:SetVariableInt(n(entry.radiusParam), math.floor(p.radius + 0.5)) end)
        end
        for _, spec in ipairs(entry.floats or {}) do
            local v = p[spec[2]]
            if finite(v) then pcall(function() component:SetVariableFloat(n(spec[1]), v * spec[3]) end) end
        end
        return true
    end)
    if not ok then result, why = false, 'exception:' .. tostring(result):sub(1, 120) end
    if result == true then w.n = w.n + 1; return true end
    self:_once(kind .. ':' .. tostring(why), 'ENEMYFX %s not played reason=%s', kind, tostring(why))
    return false, why
end
-- A harmless copy of a host projectile actor: spawned deferred at (x, y, z) facing its end point (ex, ey), Speed = ez,
-- Damage 0 before its BeginPlay, collision off after; it flies and ends itself (the Amam projectile after 8 s).
function Spawner:Actor(ctx, kind, p, now)
    local entry = FX.ACTORS[kind]
    if not entry or type(p) ~= 'table' or not finite(p.x) or not finite(p.y) then return nil, 'enemy_fx_invalid' end
    local w = self.window
    if now - w.start >= 1 then w.start, w.n = now, 0 end
    if w.n >= self.perSecond then return nil, 'enemy_fx_rate' end
    local ok, actor, why = pcall(function()
        local _, pawn = ctx.islandWorld:LocalWorldPawn()
        if not valid(pawn) then return nil, 'no_pawn' end
        local find = self.G and self.G.StaticFindObject
        local gs = find and find(FX.STATICS)
        local class = self:_system(entry.path)
        if not valid(gs) or not valid(class) then return nil, 'no_actor_class:' .. kind end
        local yaw = (finite(p.ex) and finite(p.ey)) and math.deg(math.atan(p.ey - p.y, p.ex - p.x)) or 0
        local transform = { Translation = { X = p.x, Y = p.y, Z = finite(p.z) and p.z or 0 }, Rotation = { Pitch = 0, Yaw = yaw, Roll = 0 },
            Scale3D = { X = 1, Y = 1, Z = 1 } }
        local a = gs:BeginDeferredActorSpawnFromClass(pawn, class, transform, 1, nil)
        if not valid(a) then return nil, 'actor_spawn_failed' end
        a.Damage = 0
        if finite(p.ez) and p.ez > 0 then a.Speed = p.ez end
        gs:FinishSpawningActor(a, transform)
        pcall(function() a:SetActorEnableCollision(false) end)
        return a
    end)
    if not ok then actor, why = nil, 'exception:' .. tostring(actor):sub(1, 120) end
    if actor then w.n = w.n + 1; return actor end
    self:_once(kind .. ':' .. tostring(why), 'ENEMYFX %s copy not spawned reason=%s', kind, tostring(why))
    return nil, why
end
function Spawner:Destroy(actor)
    if not valid(actor) then return false end
    local ok = pcall(function() actor:K2_DestroyActor() end)
    return ok
end
return FX
