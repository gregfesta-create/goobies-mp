-- Enemy attacks part C2 (Coder C; research/RESEARCH_ENEMY_ATTACKS.md 2; D50 4 and the coordinator's ring decision).
-- Dev flag ENEMY_ATTACKS. Host role only, never raises. Amam's attack (BP_Logic_Amam, every 5 s) fires BP_Amam_Projectile02
-- actors that fly straight (forward x Speed) for 8 s and only damage their cached GetPlayerPawn(0), the host, on overlap:
--   * aimed shots (Speed 20, 2 per attack): dealt round-robin to the connected players (sorted by key) and turned toward
--     their player on first sight (D50: the attack's shots are split evenly, each share at a different player);
--   * the ring (Speed 7, 6 per volley): left alone; it already goes every way;
--   * every projectile is swept against the clients each tick (segment from its last to its current position, so a fast
--     shot cannot tunnel): a client within PROJECTILE_RADIUS + PLAYER_RADIUS takes its Damage once (hit(key, Damage,
--     'amam')) and the projectile is destroyed, as the game does on the host; the host keeps the game's own overlap hit;
--   * each shot and its end go to clients as ENEMY_FX amam_shot {x, y, z, end point along its direction, ez = Speed, id}
--     / amam_end {id} for gmp_enemy_fx_client.lua's visual copy.
--   M.new{game, hit, log, G}; m:Tick(ctx, session, now)
local Wire = require('gmp_pickups_wire')
local Live = require('gmp_pickups_pawncache').Live
local M = {}; M.__index = M
M.AIMED_SPEED = 10          -- above: an aimed shot (20); below: the ring (7)
M.PROJECTILE_RADIUS, M.PLAYER_RADIUS = 60, 50
M.END_DISTANCE = 10000

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= 2000000 end
local function round(v) return math.floor((v or 0) + 0.5) end

function M.new(options)
    options = options or {}
    return setmetatable({ game = options.game or M.Game.new({ G = options.G }), hit = options.hit, log = options.log,
        known = {}, seq = 0, sequence = 0, rr = 0, logged = {} }, M)
end
function M:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function M:_send(ctx, session, f)
    self.sequence = require('gmp_enemy_fx').NextSequence()
    f.context, f.sequence = ctx.key, self.sequence
    f.z, f.ex, f.ey, f.ez, f.radius, f.id = f.z or 0, f.ex or 0, f.ey or 0, f.ez or 0, f.radius or 0, f.id or 0
    for _, k in ipairs({ 'rx', 'ry', 'rz', 'sx', 'sy', 'sz' }) do f[k] = f[k] or 0 end
    if not Wire.Validate.ENEMY_FX(f) then return end
    local me = type(session.identity) == 'table' and session.identity.key or nil
    local ok, players = pcall(function() return session.roster:Snapshot() end)
    if not ok or type(players) ~= 'table' then return end
    for _, p in ipairs(players) do
        if p.key ~= me and p.conn == 'connected' then pcall(session.SendPickups, session, p.key, 'ENEMY_FX', f) end
    end
end
local function players(ctx, session, now)
    local out = {}
    local me = type(session.identity) == 'table' and session.identity.key or nil
    local okP, _, pawn = pcall(function() return ctx.islandWorld:LocalWorldPawn() end)
    if okP and pawn ~= nil then
        local okA, at = pcall(function() return pawn:K2_GetActorLocation() end)
        if okA and at then out[#out + 1] = { key = me, x = at.X, y = at.Y, host = true } end
    end
    local connected = {}
    local okR, roster = pcall(function() return session.roster:Snapshot() end)
    if okR and type(roster) == 'table' then for _, p in ipairs(roster) do if p.conn == 'connected' then connected[p.key] = true end end end
    local presence = session.presence
    local okV, list = false, nil
    if type(presence) == 'table' and type(presence.Visible) == 'function' then okV, list = pcall(presence.Visible, presence, now) end
    if okV and type(list) == 'table' then
        for _, v in ipairs(list) do
            if v.key ~= me and connected[v.key] and v.dead ~= true and finite(v.x) and finite(v.y) then
                out[#out + 1] = { key = v.key, x = v.x, y = v.y }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return out
end
local function segmentDistance(ax, ay, bx, by, x, y)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and ((x - ax) * dx + (y - ay) * dy) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return math.sqrt((x - (ax + dx * t)) ^ 2 + (y - (ay + dy * t)) ^ 2)
end
function M:Tick(ctx, session, now)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if ctx.key ~= self.contextKey then self.contextKey, self.known = ctx.key, {} end
        local okL, list = pcall(self.game.Projectiles, self.game, ctx, now)
        if not okL or type(list) ~= 'table' then
            return self:_once('list:' .. tostring(list), 'ENEMYATTACK amam projectiles unreadable %s', tostring(list):sub(1, 160))
        end
        local paused = type(session.sharedPause) == 'table' and session.sharedPause.paused == true
        local everyone = players(ctx, session, now)
        local present = {}
        for _, p in ipairs(list) do
            if finite(p.x) and finite(p.y) and p.id ~= nil then
                present[p.id] = true
                local k = self.known[p.id]
                if not k then
                    self.seq = self.seq + 1
                    local yaw = p.yaw or 0
                    if (p.speed or 0) > M.AIMED_SPEED and #everyone > 0 then
                        local target = everyone[(self.rr % #everyone) + 1]
                        self.rr = self.rr + 1
                        yaw = math.deg(math.atan(target.y - p.y, target.x - p.x))
                        pcall(self.game.Turn, self.game, ctx, p, yaw)
                    end
                    k = { num = self.seq, x = p.x, y = p.y }
                    self.known[p.id] = k
                    local r = math.rad(yaw)
                    self:_send(ctx, session, { fx = 'amam_shot', x = round(p.x), y = round(p.y), z = round(p.z),
                        ex = round(p.x + math.cos(r) * M.END_DISTANCE), ey = round(p.y + math.sin(r) * M.END_DISTANCE), ez = round(p.speed), id = k.num })
                elseif not k.ended then
                    if not paused then
                        for _, c in ipairs(everyone) do
                            if not c.host and segmentDistance(k.x, k.y, p.x, p.y, c.x, c.y) <= M.PROJECTILE_RADIUS + M.PLAYER_RADIUS then
                                if type(self.hit) == 'function' and finite(p.damage) and p.damage > 0 then pcall(self.hit, c.key, p.damage, 'amam') end
                                pcall(self.game.Destroy, self.game, ctx, p)
                                k.ended = true
                                self:_send(ctx, session, { fx = 'amam_end', x = round(p.x), y = round(p.y), id = k.num })
                                break
                            end
                        end
                    end
                    k.x, k.y = p.x, p.y
                end
            end
        end
        for id, k in pairs(self.known) do
            if not present[id] then
                if not k.ended then self:_send(ctx, session, { fx = 'amam_end', x = round(k.x), y = round(k.y), id = k.num }) end
                self.known[id] = nil
            end
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'ENEMYATTACK amam tick error %s', tostring(err):sub(1, 200)) end
end

------------------------------------------------------------------ the real host objects
local Game = {}; Game.__index = Game; M.Game = Game
Game.CLASS_PATH = '/Game/Blueprints/EnemyController/EnemyActors/Bosses/BP_Amam_Projectile02.BP_Amam_Projectile02_C'
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
local function name(o) local ok, n = pcall(function() return o:GetFullName() end); return ok and n or nil end
-- The live Amam projectiles of the local world (GetAllActorsOfClass, never FindAllOf; test 12).
function Game:Projectiles(ctx)
    local world, _, library = ctx.islandWorld:LocalWorldPawn()
    if not world or not library then return {} end
    local G = self.options.G or {}
    local find = G.StaticFindObject or (type(_G.StaticFindObject) == 'function' and _G.StaticFindObject) or nil
    local class = find and find(Game.CLASS_PATH)
    if not Live(class) then return {} end
    local out = {}
    local ret = library:GetAllActorsOfClass(world, class, out)
    local found = (type(ret) == 'table' and #ret > 0) and ret or out
    local list = {}
    for _, a in ipairs(found) do
        if Live(a) then
            local at, rot = a:K2_GetActorLocation(), a:K2_GetActorRotation()
            list[#list + 1] = { id = name(a), actor = a, x = at.X, y = at.Y, z = at.Z, yaw = rot and rot.Yaw or 0, speed = a.Speed, damage = a.Damage }
        end
    end
    return list
end
function Game:Turn(_, p, yaw)
    if not Live(p.actor) then return false end
    p.actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    return true
end
function Game:Destroy(_, p)
    if not Live(p.actor) then return false end
    p.actor:K2_DestroyActor()
    return true
end
return M
