-- Rejoin cover (user, after test 11): a player who rejoins a running run must not watch an empty island fill up.
-- Pure Lua over an injected island world (gmp_island_world: SetSharedPaused, SetPauseNotice); no widgets are made.
--   cover:Begin(now, why)              a client joined while the host's run is in progress (reconnect or menu rejoin)
--   cover:Tick(now, world, ready)      world: nil until the island plays; ready() -> ok, reason (RunSync:RejoinReady)
-- Once the island world exists the client's world is paused with the pause notice NOTICE; it is released when the
-- rows are ready (Coder B's RunSync:RejoinReady()) or CAP_SECONDS after the cover went up, whichever comes first.
-- Logs: "REJOINCOVER on (<why>)", "REJOINCOVER off reason=ready|timeout after <s>s (<ready reason>)".
local C = {}; C.__index = C
C.CAP_SECONDS = 5
C.NOTICE = 'Rejoining... loading the island'

function C.new(o) return setmetatable({ log = (o and o.log) or function() end, active = nil }, C) end
function C:Active() return self.active ~= nil end
function C:Begin(now, why)
    if self.active then return false end
    self.active = { why = why or 'rejoined', since = now }
    return true
end
-- The client left the session (or the run ended): drop the cover without touching the world.
function C:Cancel() self.active = nil end
local function call(world, name, ...)
    if type(world) == 'table' and type(world[name]) == 'function' then return pcall(world[name], world, ...) end
    return false
end
function C:Tick(now, world, ready)
    local a = self.active
    if not a or not world then return end
    if not a.applied then
        call(world, 'SetSharedPaused', true); call(world, 'SetPauseNotice', C.NOTICE)
        a.applied = now
        self.log(string.format('REJOINCOVER on (%s)', a.why))
    end
    local done, why = false, 'no_ready_signal'
    if type(ready) == 'function' then
        local ok, r, w = pcall(ready)
        if ok then done, why = r == true, w else why = 'rejoin_ready_error' end
    end
    if done or now - a.applied >= C.CAP_SECONDS then
        call(world, 'SetPauseNotice', nil); call(world, 'SetSharedPaused', false)
        self.log(string.format('REJOINCOVER off reason=%s after %.1fs (%s)', done and 'ready' or 'timeout', now - a.applied,
            tostring(why or (done and 'rows_ready' or 'not_ready'))))
        self.active = nil
    end
end
return C
