-- Host-side attribution of remote hits (PLAN_WORLD_ENTRY.md 4, S7b; D21/D23). Pure Lua, no game access.
-- Only native-proven hits are recorded (gmp_native_host_damage.lua Hit -> {damage, killed, weapon}); the host never
-- credits a client's own report.
--   A.new() -> attribution
--   attribution:Record(peerKey, weaponType, damage, killed) -> true | false, reason
--   attribution:Snapshot() -> {[peerKey] = {kills, damage, weapons = {[weaponType] = {damage, kills}}}}   (a copy;
--                             the RunSync:Status().attribution shape)
-- S8 builds the RUN_STATS rows from this raw shape (Host.RunStatsRows, gmp_host_entry.lua); any top-N / "Other"
-- grouping is display-time (P1).
-- Bounds (D54: no fixed player count): peers up to Config.MAX_PLAYERS_LIMIT (an untrusted-row sanity cap, not a
-- session size), 64 weapon types per peer; types are wire-safe (printable ASCII without % | , ;) <= 64 bytes.
local A = {}
A.__index = A
A.MAX_PEERS, A.MAX_WEAPON_TYPES = require('gmp_config').MAX_PLAYERS_LIMIT, 64

local function key(v) return type(v) == 'string' and #v > 0 and #v <= 64 end
local function wireType(v)
    return type(v) == 'string' and #v >= 1 and #v <= 64 and not v:find('[^ -~]') and not v:find('[%%|,;]')
end
local function amount(v) return type(v) == 'number' and v == v and v >= 0 and v <= 1e12 end

function A.new() return setmetatable({ peers = {}, count = 0 }, A) end

function A:Record(peer, weapon, damage, killed)
    if not key(peer) or not wireType(weapon) or not amount(damage) or type(killed) ~= 'boolean' then
        return false, 'attribution_invalid'
    end
    local row = self.peers[peer]
    if not row then
        if self.count >= A.MAX_PEERS then return false, 'attribution_peer_capacity' end
        row = { kills = 0, damage = 0, weapons = {}, types = 0 }
        self.peers[peer] = row; self.count = self.count + 1
    end
    local w = row.weapons[weapon]
    if not w then
        if row.types >= A.MAX_WEAPON_TYPES then return false, 'attribution_weapon_capacity' end
        w = { damage = 0, kills = 0 }; row.weapons[weapon] = w; row.types = row.types + 1
    end
    local kill = killed and 1 or 0
    w.damage, w.kills = w.damage + damage, w.kills + kill
    row.damage, row.kills = row.damage + damage, row.kills + kill
    return true
end

function A:Snapshot()
    local out = {}
    for peer, row in pairs(self.peers) do
        local weapons = {}
        for name, w in pairs(row.weapons) do weapons[name] = { damage = w.damage, kills = w.kills } end
        out[peer] = { kills = row.kills, damage = row.damage, weapons = weapons }
    end
    return out
end

return A
