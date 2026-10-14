-- CLIENT_DAMAGE (post-R1 dev flag; research/RESEARCH_GAMEPLAY.md section 10): host-side contact between its enemy rows
-- and a remote client's presence position, following the game's own per-tick rule (BPC_CheckIfPlayerTakeDamage):
-- the damage is the sum of the Damage of every alive row within the query size (ActorScale3D.X * 100 = 100 at scale 1).
-- At most one hit per client per `interval` seconds (about the client's invincibility window; the client's own ChangeHP
-- still enforces its Invincible? gate). Pure Lua, no game access.
--   Contact.new{interval = 0.5, radius = 100}
--   contact:Hits(now, clients, enemies) -> { {peer, damage, enemies}, ... }  (in client order)
--     clients: { {key, x, y, dead}, ... }  (host presence, centimetres)   enemies: { {x, y, damage, dead}, ... }
local C = {}
C.__index = C
C.DEFAULTS = { interval = 0.5, radius = 100 }
local MAX_DAMAGE = 1000000

local function finite(v) return type(v) == 'number' and v == v and v > -math.huge and v < math.huge end

function C.new(options)
    options = options or {}
    local interval = options.interval or C.DEFAULTS.interval
    local radius = options.radius or C.DEFAULTS.radius
    assert(finite(interval) and interval > 0 and interval <= 60, 'contact_interval')
    assert(finite(radius) and radius > 0 and radius <= 10000, 'contact_radius')
    return setmetatable({ interval = interval, radius = radius, last = {} }, C)
end

function C:Hits(now, clients, enemies)
    local out = {}
    if not finite(now) or type(clients) ~= 'table' or type(enemies) ~= 'table' then return out end
    local r2 = self.radius * self.radius
    for _, c in ipairs(clients) do
        local last = self.last[c.key]
        if type(c) == 'table' and type(c.key) == 'string' and c.dead ~= true and finite(c.x) and finite(c.y)
            and (not last or now - last >= self.interval) then
            local damage, count = 0, 0
            for _, e in ipairs(enemies) do
                if type(e) == 'table' and e.dead ~= true and finite(e.x) and finite(e.y) and finite(e.damage) and e.damage > 0 then
                    local dx, dy = e.x - c.x, e.y - c.y
                    if dx * dx + dy * dy <= r2 then damage, count = damage + e.damage, count + 1 end
                end
            end
            if count > 0 and damage > 0 then
                self.last[c.key] = now
                out[#out + 1] = { peer = c.key, damage = math.min(damage, MAX_DAMAGE), enemies = count }
            end
        end
    end
    return out
end

return C
