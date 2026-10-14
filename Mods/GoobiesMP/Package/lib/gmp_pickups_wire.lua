-- D45 (Coder C): shared XP / pickup / reward-screen dev messages. Additive: gmp_messages.lua installs them with one
-- hook line (Wire.Install(Messages)); they are not in Types/ReservedTypes, so protocol pins are unchanged. All lane 1
-- (GAMEPLAY, reliable, low rate). Validators return a normalized copy or nil, reason.
--   PICKUP_DELTA    H2C {context, base, items={kind,id,x,y,z,n,v}}   clump/pickup upserts (n = 0: removed), host
--                   versions; base = the host's view epoch for this client (reliable messages are not ordered: a
--                   newer base means a complete resend from empty, so the client clears and drops older bases)
--   PICKUP_COLLECT  C2H {context, sequence, range, resync, ids={id}}   clumps/pickups this client touched
--   PICKUP_RESULT   H2C {context, sequence, accepted, refused, xp, reason}
--   PICKUP_GRANT    H2C {context, sequence, kind, value}       a per-player pickup effect (health: HP to add)
--   PICKUP_LOCAL_XP C2H {context, sequence, amount}            bounded report of a client's own local bonus orbs
--   XP_STATE        H2C {context, revision, level, current, target}   the host's (team) XP bar and level
--   REWARD_SCREEN   H2C {context, id, kind, phase, count, remainMs, rarity, text}   shared screen barrier (level-up,
--                   loot, roulette); rarity/text: the roulette's PresentRoulette arguments (-1 / '' = the defaults, D44)
--   REWARD_DONE     C2H {context, id, picked}   (id 0: the client's level report, picked = its Level)
--   XP_BONUS        C2H {context, revision, multiplier}   the client's own XP Multiplier (D46: shared on the host)
--   ENEMY_FX        H2C {context, sequence, fx, x, y, z, ex, ey, ez, radius, id}   a host-only enemy attack's look (dev
--                   flag ENEMY_FX, gmp_enemy_fx*.lua): the game's own effect at (x, y, z), its end point and radius; Amam
--                   shots (amam_shot / amam_end): ez = the projectile Speed, id = the shot (0: none); the Magmus laser
--                   (laser / laser_end): rx, ry, rz = the beam rotation (pitch, yaw, roll in 1/100 degree), sx, sy, sz = its
--                   scale (1/1000), radius = Gaia's indicator radius, ez = its lifetime in ms; 0 when unused
local Orbs = require('gmp_pickups_orbs')
local W = {}
W.MAX_COLLECT_IDS = 32
W.MAX_LOCAL_XP = 2000
W.CONTEXT_BYTES = 256
W.REASON_BYTES = 64
W.TEXT_BYTES = 96   -- a roulette title (DeathText)
W.KINDS = { levelup = true, loot = true, bush = true, reward = true, roulette = true, catchup = true }
W.PHASES = { open = true, deadline = true, closed = true }

local function F(name, t, of) return { name = name, type = t, of = of } end
W.Schema = {
    PICKUP_DELTA = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('base', 'int'),
        F('items', 'list', { F('kind', 'str'), F('id', 'str'), F('x', 'int'), F('y', 'int'), F('z', 'int'), F('n', 'int'), F('v', 'int') }) } },
    PICKUP_COLLECT = { dir = 'C2H', ch = 'R', fields = { F('context', 'str'), F('sequence', 'int'), F('range', 'int'), F('resync', 'bool'),
        F('ids', 'list', { F('id', 'str') }) } },
    PICKUP_RESULT = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('sequence', 'int'), F('accepted', 'int'), F('refused', 'int'),
        F('xp', 'int'), F('reason', 'str') } },
    PICKUP_GRANT = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('sequence', 'int'), F('kind', 'str'), F('value', 'str') } },
    PICKUP_LOCAL_XP = { dir = 'C2H', ch = 'R', fields = { F('context', 'str'), F('sequence', 'int'), F('amount', 'int') } },
    XP_STATE = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('revision', 'int'), F('level', 'int'), F('current', 'str'),
        F('target', 'str') } },
    REWARD_SCREEN = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('id', 'int'), F('kind', 'str'), F('phase', 'str'),
        F('count', 'int'), F('remainMs', 'int'), F('rarity', 'int'), F('text', 'str') } },
    REWARD_DONE = { dir = 'C2H', ch = 'R', fields = { F('context', 'str'), F('id', 'int'), F('picked', 'int') } },
    XP_BONUS = { dir = 'C2H', ch = 'R', fields = { F('context', 'str'), F('revision', 'int'), F('multiplier', 'str') } },
    ENEMY_FX = { dir = 'H2C', ch = 'R', fields = { F('context', 'str'), F('sequence', 'int'), F('fx', 'str'), F('x', 'int'), F('y', 'int'),
        F('z', 'int'), F('ex', 'int'), F('ey', 'int'), F('ez', 'int'), F('radius', 'int'), F('id', 'int'),
        F('rx', 'int'), F('ry', 'int'), F('rz', 'int'), F('sx', 'int'), F('sy', 'int'), F('sz', 'int') } },
}
W.ORDER = { 'PICKUP_DELTA', 'PICKUP_COLLECT', 'PICKUP_RESULT', 'PICKUP_GRANT', 'PICKUP_LOCAL_XP', 'XP_STATE', 'REWARD_SCREEN', 'REWARD_DONE',
    'XP_BONUS', 'ENEMY_FX' }
W.ENEMY_FX = { mortar = true, explosion = true, burst = true, heal = true, amam_shot = true, amam_end = true,
    danger = true, zigrid = true, ball_land = true, laser = true, laser_end = true }   -- gmp_enemy_fx.lua

-- Idempotent: adds missing schemas and appends missing names to Messages.DevTypes.
function W.Install(Messages)
    Messages.DevTypes = Messages.DevTypes or {}
    for _, name in ipairs(W.ORDER) do
        if not Messages.Schema[name] then Messages.Schema[name] = W.Schema[name] end
        local found = false
        for _, t in ipairs(Messages.DevTypes) do if t == name then found = true; break end end
        if not found then Messages.DevTypes[#Messages.DevTypes + 1] = name end
    end
    return true
end

local function int(v, lo, hi) return math.type(v) == 'integer' and v >= lo and v <= hi end
local function context(v) return type(v) == 'string' and #v >= 1 and #v <= W.CONTEXT_BYTES end
local function num(text, lo, hi)
    if type(text) ~= 'string' or #text < 1 or #text > 32 then return nil end
    local v = tonumber(text)
    if type(v) ~= 'number' or v ~= v or v < lo or v > hi then return nil end
    return v
end
local MAXI = 9007199254740991

W.Validate = {}
function W.Validate.PICKUP_DELTA(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.base, 1, MAXI) or type(f.items) ~= 'table' or #f.items > 256 then
        return nil, 'pickup_delta' end
    local items = {}
    for i, it in ipairs(f.items) do
        if not Orbs.ValidItem(it) then return nil, 'pickup_delta_item' end
        items[i] = { kind = it.kind, id = it.id, x = it.x, y = it.y, z = it.z, n = it.n, v = it.v }
    end
    return { context = f.context, base = f.base, items = items }
end
function W.Validate.PICKUP_COLLECT(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.sequence, 1, MAXI) or not int(f.range, 0, 1000000)
        or type(f.resync) ~= 'boolean' or type(f.ids) ~= 'table' or #f.ids > W.MAX_COLLECT_IDS then return nil, 'pickup_collect' end
    local ids = {}
    for i, rec in ipairs(f.ids) do
        local id = type(rec) == 'table' and rec.id or nil
        if type(id) ~= 'string' or #id < 1 or #id > Orbs.ID_BYTES then return nil, 'pickup_collect_id' end
        ids[i] = id
    end
    return { context = f.context, sequence = f.sequence, range = f.range, resync = f.resync, ids = ids }
end
function W.Validate.PICKUP_RESULT(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.sequence, 1, MAXI) or not int(f.accepted, 0, 1000)
        or not int(f.refused, 0, 1000) or not int(f.xp, 0, 100000000) or type(f.reason) ~= 'string' or #f.reason > W.REASON_BYTES then
        return nil, 'pickup_result' end
    return { context = f.context, sequence = f.sequence, accepted = f.accepted, refused = f.refused, xp = f.xp, reason = f.reason }
end
function W.Validate.PICKUP_GRANT(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.sequence, 1, MAXI) or not Orbs.KINDS[f.kind] then return nil, 'pickup_grant' end
    local value = num(f.value, -1e9, 1e9)
    if not value then return nil, 'pickup_grant_value' end
    return { context = f.context, sequence = f.sequence, kind = f.kind, value = value }
end
function W.Validate.PICKUP_LOCAL_XP(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.sequence, 1, MAXI) or not int(f.amount, 1, W.MAX_LOCAL_XP) then
        return nil, 'pickup_local_xp' end
    return { context = f.context, sequence = f.sequence, amount = f.amount }
end
function W.Validate.XP_STATE(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.revision, 1, MAXI) or not int(f.level, 0, 100000) then return nil, 'xp_state' end
    local current, target = num(f.current, 0, 1e7), num(f.target, 0, 1e7)
    if not current or not target or target <= 0 then return nil, 'xp_state_values' end
    return { context = f.context, revision = f.revision, level = f.level, current = current, target = target }
end
function W.Validate.REWARD_SCREEN(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.id, 1, MAXI) or not W.KINDS[f.kind] or not W.PHASES[f.phase]
        or not int(f.count, 0, 1000) or not int(f.remainMs, 0, 3600000) then return nil, 'reward_screen' end
    if not int(f.rarity, -1, 3) or type(f.text) ~= 'string' or #f.text > W.TEXT_BYTES or f.text:find('%c') then
        return nil, 'reward_screen_roulette' end
    return { context = f.context, id = f.id, kind = f.kind, phase = f.phase, count = f.count, remainMs = f.remainMs,
        rarity = f.rarity, text = f.text }
end
-- id 0 is the client's level report (picked = its own Level): the host opens a catch-up barrier when it is behind.
function W.Validate.REWARD_DONE(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.id, 0, MAXI) or not int(f.picked, 0, 100000) then return nil, 'reward_done' end
    return { context = f.context, id = f.id, picked = f.picked }
end

function W.Validate.XP_BONUS(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.revision, 1, MAXI) then return nil, 'xp_bonus' end
    local m = num(f.multiplier, 0.01, 1000)
    if not m then return nil, 'xp_bonus_value' end
    return { context = f.context, revision = f.revision, multiplier = m }
end
function W.Validate.ENEMY_FX(f)
    if type(f) ~= 'table' or not context(f.context) or not int(f.sequence, 1, MAXI) or not W.ENEMY_FX[f.fx] then return nil, 'enemy_fx' end
    for _, k in ipairs({ 'x', 'y', 'ex', 'ey' }) do if not int(f[k], -2000000, 2000000) then return nil, 'enemy_fx_position' end end
    for _, k in ipairs({ 'z', 'ez' }) do if not int(f[k], -200000, 200000) then return nil, 'enemy_fx_position' end end
    if not int(f.radius, 0, 100000) then return nil, 'enemy_fx_radius' end
    if not int(f.id, 0, MAXI) then return nil, 'enemy_fx_id' end
    local out = { context = f.context, sequence = f.sequence, fx = f.fx, x = f.x, y = f.y, z = f.z, ex = f.ex, ey = f.ey, ez = f.ez, radius = f.radius,
        id = f.id }
    for _, k in ipairs({ 'rx', 'ry', 'rz' }) do
        local v = f[k] == nil and 0 or f[k]
        if not int(v, -3600000, 3600000) then return nil, 'enemy_fx_rotation' end
        out[k] = v
    end
    for _, k in ipairs({ 'sx', 'sy', 'sz' }) do
        local v = f[k] == nil and 0 or f[k]
        if not int(v, 0, 10000000) then return nil, 'enemy_fx_scale' end
        out[k] = v
    end
    return out
end
-- Codec budget (gmp_codec.lua MAX_PACKET 1400) with a worst-case header (10-digit epoch, 12-digit seq/ack, 17-char
-- sid, magic/version/type/channel) plus the escaped context. Items carry no escaped characters except via kind/id
-- (validated to [%w:%-_]), so their wire length is exact.
W.PACKET = 1400
W.HEADER = 96
local function escLen(s) local n = #s; for _ in s:gmatch('[%%|,;%c]') do n = n + 2 end; return n end
local function itemLen(it)
    return #it.kind + #it.id + #tostring(it.x) + #tostring(it.y) + #tostring(it.z) + #tostring(it.n) + #tostring(it.v) + 7
end
function W.PackDelta(ctx, items, base)
    local packets = {}
    base = base or 1
    local head = W.HEADER + #'PICKUP_DELTA' + escLen(ctx) + #tostring(base) + 3
    local current, size = {}, head
    for _, it in ipairs(items) do
        local len = itemLen(it)
        if #current > 0 and size + len > W.PACKET then
            packets[#packets + 1] = { context = ctx, base = base, items = current }
            current, size = {}, head
        end
        current[#current + 1] = it; size = size + len
    end
    if #current > 0 then packets[#packets + 1] = { context = ctx, base = base, items = current } end
    return packets
end
return W
