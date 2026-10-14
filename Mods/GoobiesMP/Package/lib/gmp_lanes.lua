-- Traffic lanes (dev protocol, additive; the one lane map). Pure Lua, no game or transport calls.
--   0 PRESENCE      highest priority, unreliable, latest wins (PLAYER_STATE / WORLD_STATE and their visual/avatar forms)
--   1 GAMEPLAY      reliable gameplay and control (ATTACK_INTENT, ATTACK_AOE, PLAYER_*, LIVES, prep, pause, policy, ...),
--                   plus the heartbeat; the default for any other type
--   2 ENEMY_LIFE    reliable enemy spawns/deaths/damage (ENEMY_LIFE, ENEMY_SNAPSHOT): apart, so a spawn wave cannot
--                   delay hits on lane 1
--   3 ENEMY_MOTION  lowest, unreliable, droppable when older than ~150 ms (ENEMY_MOTION)
-- Ordering: a lane-3 motion row for an id whose lane-2 spawn has not arrived is refused (gmp_enemy_delta Client:Motion,
-- counted as unknownRows).
-- The qa_four transport marks a message frame with its lane (frame kind Lanes.KIND); the dev sidecar queues per lane.
-- Real Steam needs ConfigureConnectionLanes and a per-message lane index in the native transport (not here).
local Lanes = {}
Lanes.COUNT = 4
Lanes.NAMES = { [0] = 'presence', 'gameplay', 'enemy_life', 'enemy_motion' }
Lanes.KIND = { [0] = 'P', 'M', 'L', 'N' }          -- qa_four frame kind per lane ('M' was the only message kind)
Lanes.FROM_KIND = { P = 0, M = 1, L = 2, N = 3 }
local BY_TYPE = {
    PLAYER_STATE = 0, WORLD_STATE = 0, PLAYER_STATE_VISUAL = 0, WORLD_STATE_VISUAL = 0,
    PLAYER_AVATAR_STATE = 0, WORLD_AVATAR_STATE = 0,
    ENEMY_LIFE = 2, ENEMY_SNAPSHOT = 2,
    ENEMY_MOTION = 3,
}
function Lanes.ForType(t) return BY_TYPE[t] or 1 end
-- The lane of an encoded message (gmp_codec: MAGIC|version|TYPE|...).
function Lanes.ForData(data)
    if type(data) ~= 'string' then return 1 end
    local t = data:match('^[^|]*|[^|]*|([A-Z0-9_]+)|')
    return Lanes.ForType(t)
end

-- Per-lane tx counts for the once-a-second LANES line.
local Counter = {}; Counter.__index = Counter; Lanes.Counter = Counter
function Counter.new(now) return setmetatable({ start = now or 0, msgs = { [0] = 0, 0, 0, 0 }, bytes = { [0] = 0, 0, 0, 0 } }, Counter) end
function Counter:Add(lane, bytes) self.msgs[lane] = self.msgs[lane] + 1; self.bytes[lane] = self.bytes[lane] + (bytes or 0) end
-- "LANES tx p0=<msgs>/<bytes> p1=... p2=... p3=..." once a full second has passed (then the counts restart), else nil.
function Counter:Line(now, suffix)
    if now - self.start < 1 then return nil end
    local parts = {}
    for lane = 0, Lanes.COUNT - 1 do parts[#parts + 1] = string.format('p%d=%d/%d', lane, self.msgs[lane], self.bytes[lane]) end
    self.start, self.msgs, self.bytes = now, { [0] = 0, 0, 0, 0 }, { [0] = 0, 0, 0, 0 }
    return 'LANES tx ' .. table.concat(parts, ' ') .. (suffix or '')
end
return Lanes
