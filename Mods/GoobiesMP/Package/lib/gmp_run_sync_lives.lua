-- SHARED_LIVES (D32; post-R1 dev flag, off by default; research/RESEARCH_GAMEPLAY.md section 11): the host-side policy
-- for a run's shared lives. Pure Lua, no game access; the host's run sync feeds it downs and positions and acts on its
-- events (revive: heal + invulnerability + explosion; ended: every player runs the game's own Death).
--   Lives.new{lives = 3, reviveSeconds = 4, reviveRange = 300, invulnerable = 1.5, reviveHp = 0.5}
--   lives:Down(key, now) -> true when the player became a ghost
--   lives:Tick(now, players) -> events: {kind='revive', key, slot, x, y} | {kind='ended'}
--     players: the players present in the run, {key, slot, x, y} (presence positions). A ghost revives when an ALIVE
--     teammate stays within reviveRange for reviveSeconds (progress resets when nobody alive is in range) and a life is
--     left; that uses one life. The run ends (once) when every present player is a ghost.
--   lives:Pause() -> while the shared pause holds (progress kept, paused time never counts)
--   lives:State() -> {lives, revision, ended, ghosts = {[key] = progress 0..1}}
local L = {}
L.__index = L
L.DEFAULTS = { lives = 3, reviveSeconds = 4, reviveRange = 300, invulnerable = 1.5, reviveHp = 0.5 }
L.MAX_LIVES = 99

local function finite(v) return type(v) == 'number' and v == v and v > -math.huge and v < math.huge end

function L.new(options)
    options = options or {}
    local o = {}
    for k, v in pairs(L.DEFAULTS) do o[k] = options[k] == nil and v or options[k] end
    assert(math.type(o.lives) == 'integer' and o.lives >= 0 and o.lives <= L.MAX_LIVES, 'lives_count')
    assert(finite(o.reviveSeconds) and o.reviveSeconds >= 1 and o.reviveSeconds <= 10, 'lives_revive_seconds')
    assert(finite(o.reviveRange) and o.reviveRange > 0 and o.reviveRange <= 5000, 'lives_revive_range')
    assert(finite(o.invulnerable) and o.invulnerable >= 0.5 and o.invulnerable <= 3, 'lives_invulnerable')
    assert(finite(o.reviveHp) and o.reviveHp > 0 and o.reviveHp <= 1, 'lives_revive_hp')
    return setmetatable({ options = o, lives = o.lives, ghosts = {}, ended = false, revision = 1 }, L)
end

function L:Down(key, now)
    if self.ended or type(key) ~= 'string' or key == '' or self.ghosts[key] then return false end
    self.ghosts[key] = { progress = 0, last = nil, since = now }
    self.revision = self.revision + 1
    return true
end

function L:Tick(now, players)
    if self.ended or not finite(now) or type(players) ~= 'table' then return {} end
    local present, alive = {}, {}
    for _, p in ipairs(players) do
        if type(p) == 'table' and type(p.key) == 'string' then
            present[#present + 1] = p
            if not self.ghosts[p.key] then alive[#alive + 1] = p end
        end
    end
    if #present == 0 then return {} end
    if #alive == 0 then
        self.ended = true; self.revision = self.revision + 1
        return { { kind = 'ended' } }
    end
    table.sort(present, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    local events, range2 = {}, self.options.reviveRange * self.options.reviveRange
    for _, p in ipairs(present) do
        local g = self.ghosts[p.key]
        if g then
            local near = false
            if self.lives > 0 and finite(p.x) and finite(p.y) then
                for _, a in ipairs(alive) do
                    if finite(a.x) and finite(a.y) and (a.x - p.x) ^ 2 + (a.y - p.y) ^ 2 <= range2 then near = true; break end
                end
            end
            if near then
                if g.last then g.progress = g.progress + math.max(0, now - g.last) end
                g.last = now
                if g.progress >= self.options.reviveSeconds then
                    self.ghosts[p.key] = nil
                    self.lives = self.lives - 1
                    self.revision = self.revision + 1
                    events[#events + 1] = { kind = 'revive', key = p.key, slot = p.slot, x = p.x, y = p.y }
                end
            else
                g.progress, g.last = 0, nil
            end
        end
    end
    return events
end

-- The shared pause: progress is kept, the time until the next Tick is not counted.
function L:Pause()
    for _, g in pairs(self.ghosts) do g.last = nil end
end

function L:State()
    local ghosts = {}
    for key, g in pairs(self.ghosts) do ghosts[key] = math.min(1, g.progress / self.options.reviveSeconds) end
    return { lives = self.lives, revision = self.revision, ended = self.ended, ghosts = ghosts }
end

return L
