-- D57 (user, 2026-10-14): using mods disables achievements, and that belongs to Mod Menu. The native ModMenuGuard
-- (native/mm_guard, a UE4SS C++ mod inside Win64) denies every stats-changing SteamCorePro function (achievements,
-- stats, leaderboard score uploads) and registers into this Lua state:
--   MM_AchievementGuard() -> ready, reason, denied, found, late, unclassified, proven
--   MM_AchievementGuardBlocks() -> '<Class>:<Function>=<calls>;...' (blocked calls after its self-proof)
-- This module reads it. Logs: 'MMGUARD READY denied=<n> found=<n>' or 'MMGUARD UNAVAILABLE <reason>' once at start,
-- and 'MMGUARD BLOCK <Class>:<Function> calls=<n>' whenever a function's blocked-call count grows (tick).
-- When the guard cannot be confirmed, Mod Menu shows NOTICE on the main menu and play stays allowed (user, D57: warn
-- and allow; nothing is disabled). A status that is missing, raises, is malformed or contradicts itself is never ready.
local Guard={}
Guard.__index=Guard
Guard.NOTICE='Achievement protection could not be confirmed; achievements may unlock while modded'

function Guard.new(env,log)
    return setmetatable({env=env or _G,log=log or function() end,counts={}},Guard)
end
local function integer(v) return math.type(v)=='integer' and v>=0 end
function Guard:_read()
    local fn=self.env.MM_AchievementGuard
    if type(fn)~='function' then return {ready=false,reason='guard_not_loaded'} end
    local ok,ready,reason,denied,found,late,unclassified,proven=pcall(fn)
    if not ok then return {ready=false,reason='status_error:'..tostring(ready):gsub('%s','_'):sub(1,120)} end
    if type(ready)~='boolean' or type(reason)~='string' or not integer(denied) or not integer(found)
        or type(late)~='boolean' then
        return {ready=false,reason='status_malformed'}
    end
    if ready and (reason~='ready' or late or proven~=true) then return {ready=false,reason='status_contradictory'} end
    return {ready=ready,reason=reason,denied=denied,found=found,late=late,unclassified=unclassified,proven=proven}
end
function Guard:start()
    if self.status then return self.status end
    self.status=self:_read()
    if self.status.ready then
        self.log(string.format('MMGUARD READY denied=%d found=%d',self.status.denied,self.status.found))
    else
        self.log('MMGUARD UNAVAILABLE '..self.status.reason)
    end
    return self.status
end
function Guard:ready() return self:start().ready==true end
function Guard:notice() if self:ready() then return nil end return Guard.NOTICE end
function Guard:allowsPlay() return true end   -- D57: warn and allow
-- Poll the blocked-call counts (cheap; a few times a minute is enough) and log each growth once.
function Guard:tick()
    local fn=self.env.MM_AchievementGuardBlocks
    if type(fn)~='function' then return end
    local ok,text=pcall(fn)
    if not ok or type(text)~='string' then return end
    for name,n in text:gmatch('([%w_]+:[%w_]+)=(%d+);') do
        local calls=tonumber(n)
        if calls and calls>(self.counts[name] or 0) then
            self.counts[name]=calls
            self.log(string.format('MMGUARD BLOCK %s calls=%d',name,calls))
        end
    end
end
return Guard
