-- Test 15 stutters (Coder B): an opt-in switch for the Lua collector, ready for the case where slow collision-map
-- refreshes turn out to be a Lua collection finishing inside the call (ROWS slow map refresh ... cause=around).
-- Config keys (all optional; without LUA_GC_MODE and LUA_GC_TICK_STEP_KB nothing changes and nothing is logged):
--   LUA_GC_MODE=incremental|generational
--   LUA_GC_PAUSE, LUA_GC_STEPMUL, LUA_GC_STEPSIZE    incremental tuning (0 = keep the current value)
--   LUA_GC_MINOR, LUA_GC_MAJOR                         generational tuning (0 = keep the current value)
--   LUA_GC_TICK_STEP_KB=<n>                            clients only: collectgarbage('step', n) every app tick, so the
--                                                      collector's work is spread over ticks instead of one big step
-- The mode is applied once at boot. GoobiesMP runs as a Mod Menu managed package, so it shares the mod_menu Lua state:
-- the mode applies to that whole state (Mod Menu and every managed package); Lua has one collector per state.
--   GC.Parse(configText) -> settings | nil, problem      GC.new(settings, {collect, log, problem}); g:Apply(); g:Tick(role)
local GC = {}
GC.__index = GC
local LIMITS = { LUA_GC_PAUSE = 1000, LUA_GC_STEPMUL = 1000, LUA_GC_STEPSIZE = 30, LUA_GC_MINOR = 100, LUA_GC_MAJOR = 1000,
    LUA_GC_TICK_STEP_KB = 4096 }
function GC.Parse(text)
    local values = {}
    for line in ((text or '') .. '\n'):gmatch('([^\r\n]*)[\r\n]') do
        line = line:gsub('#.*$', ''):gsub('^%s+', ''):gsub('%s+$', '')
        local k, v = line:match('^(LUA_GC_[%w_]+)%s*=%s*(.-)$')
        if k then values[k] = v end
    end
    if next(values) == nil then return nil end
    local s = { mode = values.LUA_GC_MODE }
    if s.mode ~= nil and s.mode ~= 'incremental' and s.mode ~= 'generational' then return nil, 'LUA_GC_MODE must be incremental or generational' end
    for key, limit in pairs(LIMITS) do
        local raw = values[key]
        if raw ~= nil then
            local n = tonumber(raw)
            if not n or n % 1 ~= 0 or n < 0 or n > limit then return nil, key .. ' must be a whole number 0..' .. limit end
            s[key] = n
        end
    end
    if not s.mode and not s.LUA_GC_TICK_STEP_KB then return nil, 'LUA_GC_MODE or LUA_GC_TICK_STEP_KB is needed' end
    return s
end
function GC.new(settings, options)
    options = options or {}
    return setmetatable({ s = settings, collect = options.collect or collectgarbage, log = options.log or function() end,
        problem = options.problem }, GC)
end
function GC:Apply()
    if self.applied then return end
    self.applied = true
    if not self.s then
        if self.problem then pcall(self.log, 'LUAGC refused: ' .. tostring(self.problem) .. ' (the collector is left as it is)') end
        return
    end
    local s = self.s
    local step = s.LUA_GC_TICK_STEP_KB or 0
    local line
    if s.mode == 'incremental' then
        pcall(self.collect, 'incremental', s.LUA_GC_PAUSE or 0, s.LUA_GC_STEPMUL or 0, s.LUA_GC_STEPSIZE or 0)
        line = string.format('LUAGC mode=incremental pause=%d stepmul=%d stepsize=%d tick_step_kb=%d', s.LUA_GC_PAUSE or 0,
            s.LUA_GC_STEPMUL or 0, s.LUA_GC_STEPSIZE or 0, step)
    elseif s.mode == 'generational' then
        pcall(self.collect, 'generational', s.LUA_GC_MINOR or 0, s.LUA_GC_MAJOR or 0)
        line = string.format('LUAGC mode=generational minor=%d major=%d tick_step_kb=%d', s.LUA_GC_MINOR or 0, s.LUA_GC_MAJOR or 0, step)
    else
        line = string.format('LUAGC mode=unchanged tick_step_kb=%d', step)
    end
    pcall(self.log, line .. ' (applies to the whole mod_menu Lua state: Mod Menu and every managed package)')
end
-- Every app tick: on clients, one bounded collector step.
function GC:Tick(role)
    local s = self.s
    if not s or not s.LUA_GC_TICK_STEP_KB or s.LUA_GC_TICK_STEP_KB <= 0 or role ~= 'client' then return end
    pcall(self.collect, 'step', s.LUA_GC_TICK_STEP_KB)
end
return GC
