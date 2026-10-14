-- Enemy attacks part C1 (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 1, 3; D50 3). Dev flag ENEMY_ATTACKS. Host role
-- only, never raises. Queens and bosses aim at the NEAREST player, host-chosen per shot or attack: pre-hooks on the
-- game's shot/attack functions re-point the game's own target reference to the nearest player's pawn, the host pawn or
-- that client's stand-in (Coder B's StandIn(key): follows the client, invincible, hidden, no collision, EnemyController
-- set), so the game's own aiming, range checks and attack placement follow that player:
--   queen   BPC_ShootingEnemie Shoot      -> component.Player        (nearest to the queen row: session.enemies slot)
--   bosses  Gaia DoGaiaStuff / Clap, Zigrid Attack, Magmus StartLaser, Amam Attack, Mumsa InitiateMovement
--                                          -> owner.Daddy['As BP Player'] (nearest to the boss)
--   BP_Boss BossDeath                      -> back to the host pawn, so BossDefeated (roulette, Magnet, portal) stays on
--                                             the host (and on Deactivate, for every boss touched)
-- Damage the game then deals to a stand-in (BP_Player ChangeHP pre-hook, self = a stand-in, not a heal) is queued for
-- that client (hit(key, amount, 'boss')), except while an attack whose damage gmp_enemy_attacks_host.lua computes for
-- every player is running (Tg.Computed): there the game's trace/overlap only ever hits the host and would misroute it.
-- Without stand-ins nothing is re-pointed (targets stay on the host).
--   Tg.new{G, hit, standIn, log}; t:Tick(ctx, session, now); t:Deactivate(); Tg.Nearest(players, x, y); Tg.Computed(on)
local Live = require('gmp_pickups_pawncache').Live
local Tg = {}; Tg.__index = Tg
local B = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/'
Tg.PATHS = {
    queen_shoot = '/Game/Blueprints/EnemyController/EnemyActors/BPC_ShootingEnemie.BPC_ShootingEnemie_C:Shoot',
    gaia_attack = B .. 'BP_Logic_Gaia.BP_Logic_Gaia_C:DoGaiaStuff',
    gaia_clap = B .. 'BP_Logic_Gaia.BP_Logic_Gaia_C:Clap',
    zigrid_attack = B .. 'BP_Logic_Zigrid.BP_Logic_Zigrid_C:Attack',
    magmus_laser = B .. 'BP_Logic_Magmus_Laser.BP_Logic_Magmus_Laser_C:StartLaser',
    amam_attack = B .. 'BP_Logic_Amam.BP_Logic_Amam_C:Attack',
    mumsa_move = B .. 'BP_Logic_Mumsa.BP_Logic_Mumsa_C:InitiateMovement',
    boss_death = B .. 'BP_Boss.BP_Boss_C:BossDeath',
    change_hp = '/Game/Blueprints/BP_Player.BP_Player_C:ChangeHP',
}
Tg.BOSS_ATTACKS = { gaia_attack = true, gaia_clap = true, zigrid_attack = true, magmus_laser = true, amam_attack = true, mumsa_move = true }
Tg.QUEUE_MAX = 64
local TARGET = 'As BP Player'

-- Computed attacks in progress (gmp_enemy_attacks_host.lua's pre-hooks; a post-hook ends it early when UE4SS calls
-- one): the game's ChangeHP inside such an attack runs in the same call, so a short CPU-time window is enough and can
-- never stay stuck. Process-wide.
Tg.COMPUTED_WINDOW = 0.02
local computedAt = -math.huge
function Tg.Computed(on)
    if on then computedAt = os.clock() else computedAt = -math.huge end
end
local function inComputed() return os.clock() - computedAt < Tg.COMPUTED_WINDOW end
Tg.InComputed = inComputed

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= 2000000 end
local function get(p) if p == nil then return nil end; local ok, v = pcall(function() return p:get() end); return ok and v or nil end
local function name(o) local ok, n = pcall(function() return o:GetFullName() end); return ok and n or nil end

function Tg.Nearest(players, x, y)
    local best, bestD
    for _, p in ipairs(players or {}) do
        if p.dead ~= true and finite(p.x) and finite(p.y) and p.pawn ~= nil then
            local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    return best
end

-- One hook state per Lua state (G): the hooks live as long as the process and call the newest Targets object.
local STATES = setmetatable({}, { __mode = 'k' })
local LOCAL = {}
local function state(G)
    local key = G or LOCAL
    local st = STATES[key]
    if not st then st = { done = {} }; STATES[key] = st end
    return st
end

function Tg.new(options)
    options = options or {}
    local self = setmetatable({ G = options.G, hit = options.hit, standIn = options.standIn, log = options.log, players = {},
        bySlot = {}, standIns = {}, bosses = setmetatable({}, { __mode = 'k' }), queue = {}, logged = {} }, Tg)
    self.state = state(self.G)
    return self
end
function Tg:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function Tg:_install()
    local G = self.G or {}
    if type(G.RegisterHook) ~= 'function' or type(G.StaticFindObject) ~= 'function' then return end
    local st = self.state
    for kind, path in pairs(Tg.PATHS) do
        if not st.done[kind] then
            local okFind, fn = pcall(G.StaticFindObject, path)
            if okFind and fn ~= nil then
                local cb = function(...)
                    local args = { ... }
                    pcall(function()
                        local t = st.current
                        if t and t.active then t:_hook(kind, args) end
                    end)
                end
                if pcall(G.RegisterHook, path, cb) then st.done[kind] = true end
            end
        end
    end
end
function Tg:_aim(target, field, x, y)
    if not finite(x) or not finite(y) then return end
    local p = Tg.Nearest(self.players, x, y)
    if p and p.pawn and target[field] ~= p.pawn then target[field] = p.pawn end
end
function Tg:_hook(kind, args)
    if kind == 'queen_shoot' then
        local comp = get(args[1])
        if comp == nil then return end
        local row = self.bySlot[comp.EnemyIndex]
        if row then self:_aim(comp, 'Player', row.x, row.y) end
    elseif Tg.BOSS_ATTACKS[kind] then
        local owner = get(args[1])
        local daddy = owner and owner.Daddy
        if not Live(daddy) then return end
        local at = daddy:K2_GetActorLocation()
        self.bosses[daddy] = true
        self:_aim(daddy, TARGET, at.X, at.Y)
    elseif kind == 'boss_death' then
        local daddy = get(args[1])
        if daddy ~= nil and self.hostPawn then daddy[TARGET] = self.hostPawn end
    elseif kind == 'change_hp' then
        local pawn = get(args[1])
        local key = pawn and self.standIns[name(pawn)]
        if not key then return end
        local amount, add = get(args[2]), get(args[3])
        if add == true or not finite(amount) or amount <= 0 or inComputed() then return end
        if #self.queue < Tg.QUEUE_MAX then self.queue[#self.queue + 1] = { key = key, amount = amount } end
    end
end
function Tg:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(session) ~= 'table' then return end
        self:_install()
        self.state.current, self.active = self, true
        local hostKey = type(session.identity) == 'table' and session.identity.key or nil
        local _, pawn = ctx.islandWorld:LocalWorldPawn()
        self.hostPawn = Live(pawn) and pawn or nil
        local players, standIns = {}, {}
        if self.hostPawn then
            local at = self.hostPawn:K2_GetActorLocation()
            players[#players + 1] = { key = hostKey, x = at.X, y = at.Y, pawn = self.hostPawn, host = true }
        end
        local connected = {}
        local okR, roster = pcall(function() return session.roster:Snapshot() end)
        if okR and type(roster) == 'table' then for _, p in ipairs(roster) do if p.conn == 'connected' then connected[p.key] = true end end end
        local presence = session.presence
        local okP, list = false, nil
        if type(presence) == 'table' and type(presence.Visible) == 'function' then okP, list = pcall(presence.Visible, presence, now) end
        if okP and type(list) == 'table' then
            for _, v in ipairs(list) do
                if v.key ~= hostKey and connected[v.key] then
                    local stand = type(self.standIn) == 'function' and self.standIn(v.key) or nil
                    if not Live(stand) then stand = nil end
                    if stand then standIns[name(stand) or ''] = v.key end
                    players[#players + 1] = { key = v.key, x = v.x, y = v.y, pawn = stand, dead = v.dead }
                end
            end
        end
        self.players, self.standIns = players, standIns
        local bySlot = {}
        local registry = session.enemies
        if type(registry) == 'table' and type(registry.records) == 'table' then
            for _, r in pairs(registry.records) do if r.dead ~= true and r.slot ~= nil then bySlot[r.slot] = r end end
        end
        self.bySlot = bySlot
        local queue = self.queue
        self.queue = {}
        if type(session.sharedPause) == 'table' and session.sharedPause.paused == true then return end
        for _, q in ipairs(queue) do
            if type(self.hit) == 'function' then
                local okHit, queued = pcall(self.hit, q.key, q.amount, 'boss')
                if not okHit or queued == false then self:_once('hit', 'ENEMYATTACK boss hit not queued reason=%s', tostring(queued)) end
            end
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'ENEMYATTACK targets tick error %s', tostring(err):sub(1, 200)) end
end
-- Run end, role change or flag off: nothing is re-pointed any more and every boss touched aims at the host again.
function Tg:Deactivate()
    self.active = false
    if self.state.current == self then self.state.current = nil end
    for daddy in pairs(self.bosses) do
        if Live(daddy) and self.hostPawn then pcall(function() daddy[TARGET] = self.hostPawn end) end
    end
end
return Tg
