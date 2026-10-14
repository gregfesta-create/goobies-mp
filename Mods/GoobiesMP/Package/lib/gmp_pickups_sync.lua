-- D45 (Coder C; research/RESEARCH_PICKUPS.md): the one entry point for shared XP and pickups, ticked by the run sync
-- when the dev flag SHARED_XP is set (gmp_run_sync.lua "-- D45 hook (Coder C)"). Never raises.
--   host:   gmp_pickups_host.lua (orb clumps out, collects in, awards on the host pawn = the team level), then
--           gmp_xp_host.lua      (XP_STATE, level-up barriers under the shared pause, catch-up, local XP credit)
--   client: gmp_pickups_client.lua (draws clumps, reports touches), then
--           gmp_xp_client.lua      (fence, guard, host XP bar, one real level-up per team level, done, auto-pick)
-- The session's pickup intake is drained once per tick and split by message type.
-- Flags (options.flags, the run sync's): shared XP and pickups run when flags.sharedXp (or when no flags are given:
-- the original SHARED_XP hook); the enemy attack visuals (gmp_enemy_fx_host/_client.lua) when flags.enemyFx (ENEMY_FX);
-- the host-decided enemy attack damage to clients (gmp_enemy_attacks_host.lua, D50) when flags.enemyAttacks
-- (ENEMY_ATTACKS), through options.hit(key, damage, source) (Coder B's RunSync:QueueClientHit), and the nearest-player
-- aiming of queens and bosses (gmp_enemy_targets_host.lua, D50 3) through options.standIn(key) (Coder B's StandIn).
-- Requiring it installs the additive dev message schemas (gmp_pickups_wire.lua Install; idempotent, also done by the
-- one-line hook in gmp_messages.lua).
local Wire = require('gmp_pickups_wire')
local PawnCache = require('gmp_pickups_pawncache')
Wire.Install(require('gmp_messages'))
local S = {}; S.__index = S
S.ROUTE = {
    host = { PICKUP_COLLECT = 'pickups', REWARD_DONE = 'xp', PICKUP_LOCAL_XP = 'xp', XP_BONUS = 'xp' },
    client = { PICKUP_DELTA = 'pickups', PICKUP_RESULT = 'pickups', PICKUP_GRANT = 'pickups', XP_STATE = 'xp', REWARD_SCREEN = 'xp',
        ENEMY_FX = 'fx' },
}

function S.new(options)
    options = options or {}
    return setmetatable({ options = options, log = options.log, pawns = PawnCache.new() }, S)
end
function S:_options(part)
    local o = {}
    for k, v in pairs(self.options[part] or {}) do o[k] = v end
    o.log = o.log or self.log
    o.G = o.G or self.options.G
    if part == 'xpHost' or part == 'xpClient' then o.autoPickOther = o.autoPickOther or self.autoPickOther or self.options.autoPickOther end
    return o
end
-- D44 plug-in point (Coder B's gmp_roulette_auto): fn(pawn) -> true when it clicked a roulette step. Applies to the XP
-- modules already created and to later ones.
function S:SetAutoPickOther(fn)
    self.autoPickOther = fn
    for _, part in ipairs({ 'xpHost', 'xpClient' }) do
        local m = self[part]
        if m and m.game and type(m.game.options) == 'table' then m.game.options.autoPickOther = fn end
    end
end
-- The session as the pickup modules see it: their already drained share of the intake.
local function share(session, items)
    local p = setmetatable({}, { __index = session })
    p.EnablePickups = function() return true end
    p.DrainPickups = function() return items end
    p.SendPickups = function(_, ...) return session:SendPickups(...) end
    return p
end
function S:Tick(ctx, session, now)
    if type(ctx) ~= 'table' or type(session) ~= 'table' then return end
    local route = S.ROUTE[ctx.role]
    if not route then return end
    -- crash hardening (test 12): one liveness-checked local pawn lookup serves every adapter of this tick
    if type(ctx.islandWorld) == 'table' then ctx = self.pawns:Wrap(ctx, now) end
    local split = { pickups = {}, xp = {}, fx = {} }
    local flags = self.options.flags
    local shared = flags == nil or flags.sharedXp == true
    local fx = type(flags) == 'table' and flags.enemyFx == true
    local attacks = type(flags) == 'table' and flags.enemyAttacks == true
    -- the game hooks outlive roles (F6 handover): they only queue while this process is the host with the flag on
    self.attacksActive = attacks and ctx.role == 'host'
    if self.attacksActive then
        if not self.attacks then
            local o = self:_options('attacks')
            o.hit = o.hit or self.options.hit
            o.capture = o.capture or require('gmp_enemy_attacks_host').Capture.new({ G = o.G, active = function() return self.attacksActive == true end })
            self.attacks = require('gmp_enemy_attacks_host').new(o)
            if type(o.hit) ~= 'function' and self.log then pcall(self.log, 'ENEMYATTACK no hit queue (Coder B QueueClientHit not wired): clients take no attack damage') end
        end
        self.attacks:Tick(ctx, session, now)
        -- C1: queens and bosses aim at the nearest player (stand-ins: options.standIn, Coder B's RunSync:StandIn)
        if not self.targets then
            local o = self:_options('targets')
            o.hit, o.standIn = o.hit or self.options.hit, o.standIn or self.options.standIn
            self.targets = require('gmp_enemy_targets_host').new(o)
            if type(o.standIn) ~= 'function' and self.log then pcall(self.log, 'ENEMYATTACK no stand-ins (Coder B StandIn not wired): enemies keep aiming at the host') end
        end
        self.targets:Tick(ctx, session, now)
        -- C2: Amam's aimed shots split over the players, every projectile host-checked against the clients
        if not self.amam then
            local o = self:_options('amam')
            o.hit = o.hit or self.options.hit
            self.amam = require('gmp_enemy_amam_host').new(o)
        end
        self.amam:Tick(ctx, session, now)
    elseif self.targets and self.targets.active then
        self.targets:Deactivate()
    end
    if type(session.EnablePickups) == 'function' and type(session.DrainPickups) == 'function' then
        local ok = pcall(session.EnablePickups, session)
        local drained, items = pcall(session.DrainPickups, session)
        if ok and drained and type(items) == 'table' then
            for _, item in ipairs(items) do
                local to = type(item) == 'table' and route[item.type]
                if to then split[to][#split[to] + 1] = item end
            end
        end
    end
    if ctx.role == 'host' and fx then
        self.fxHost = self.fxHost or require('gmp_enemy_fx_host').new(self:_options('fxHost'))
        self.fxHost:Tick(ctx, session, now)
    elseif ctx.role == 'client' and fx then
        self.fxClient = self.fxClient or require('gmp_enemy_fx_client').new(self:_options('fxClient'))
        self.fxClient:Tick(ctx, session, now, split.fx)
    end
    if not fx and self.fxHost and type(self.fxHost.Deactivate) == 'function' then pcall(self.fxHost.Deactivate, self.fxHost) end
    if not shared then return end
    if ctx.role == 'host' then
        self.host = self.host or require('gmp_pickups_host').new(self:_options('host'))
        self.xpHost = self.xpHost or require('gmp_xp_host').new(self:_options('xpHost'))
        self.host:Tick(ctx, share(session, split.pickups), now)
        self.xpHost:Tick(ctx, session, now, split.xp)
        -- D46: loot, bush and reward items collected this tick give every player their own screen
        if type(self.host.TakeRewards) == 'function' then
            for _, event in ipairs(self.host:TakeRewards()) do self.xpHost:Reward(ctx, session, now, event) end
        end
    else
        self.client = self.client or require('gmp_pickups_client').new(self:_options('client'))
        self.xpClient = self.xpClient or require('gmp_xp_client').new(self:_options('xpClient'))
        self.client:Tick(ctx, share(session, split.pickups), now)
        self.xpClient:Tick(ctx, session, now, split.xp)
    end
end
-- Run end / sync stop: the client's owned orb drawing goes with it, and the host releases a reward pause it holds.
function S:Stop()
    self.attacksActive = false
    if self.targets then pcall(self.targets.Deactivate, self.targets) end
    if self.fxHost and type(self.fxHost.Deactivate) == 'function' then pcall(self.fxHost.Deactivate, self.fxHost) end
    if self.fxClient and type(self.fxClient.Clear) == 'function' then pcall(self.fxClient.Clear, self.fxClient) end
    if self.client then pcall(self.client.Clear, self.client) end
    if self.xpHost then pcall(self.xpHost.Release, self.xpHost) end
end
function S:Status()
    return { host = self.host and self.host:Status() or nil, client = self.client and self.client.stats or nil,
        xp = self.xpHost and self.xpHost:Status() or nil }
end
return S
