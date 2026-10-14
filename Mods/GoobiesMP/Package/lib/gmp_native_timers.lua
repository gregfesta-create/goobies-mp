-- Ordinary controller spawn timers only. Latent boss delays are excluded.
-- Native writes require exact reflected signatures and an actual global pause.
local T={};T.__index=T
T.CompleteCapture=false;T.CompleteRestore=false
local timers={{field='SpawnTimer',callback='SpawnEnemies'},
    {field='SeperateWaveTimer',callback='SpawnRandomWave'}}
local signatures={
    K2_GetTimerRemainingTimeHandle={'WorldContextObject','Handle'},
    K2_GetTimerElapsedTimeHandle={'WorldContextObject','Handle'},
    K2_IsTimerActiveHandle={'WorldContextObject','Handle'},
    K2_IsTimerPausedHandle={'WorldContextObject','Handle'},
    K2_ClearTimerHandle={'WorldContextObject','Handle'},
    K2_PauseTimerHandle={'WorldContextObject','Handle'},
    K2_SetTimer={'Object','FunctionName','Time','bLooping','InitialStartDelay','InitialStartDelayVariance'}}
T.Signatures=signatures
local function number(v) return type(v)=='number' and v==v and math.abs(v)<=1e12 end
local function valid(s)
    if type(s)~='table' or s.version~=1 or type(s.timers)~='table' or #s.timers~=#timers then return false end
    for i,expected in ipairs(timers) do
        local row=s.timers[i]
        if type(row)~='table' or row.field~=expected.field or row.callback~=expected.callback
            or not number(row.remaining) or not number(row.rate)
            or type(row.active)~='boolean' or type(row.paused)~='boolean' then return false end
        if row.active or row.paused then
            if row.rate<=0 or row.remaining<0 or row.remaining>row.rate+.01 then return false end
        elseif row.remaining~=-1 or row.rate~=-1 then return false end
    end
    return true
end
function T.new(world) return setmetatable({world=world,cursor=1},T) end
function T:_bindings(writes)
    local lib=self.world.G.StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    assert(lib and lib:IsValid(),'missing_timer_library')
    for name,expected in pairs(signatures) do
        if writes or name:find('GetTimer',1,true) or name:find('IsTimer',1,true) then
            local fn=self.world.G.StaticFindObject('/Script/Engine.KismetSystemLibrary:'..name)
            assert(fn and fn:IsValid(),'missing_timer_binding:'..name)
            local names={};fn:ForEachProperty(function(p)
                local n=p:GetFName():ToString();if n~='ReturnValue' then names[#names+1]=n end
            end)
            assert(#names==#expected,'timer_signature:'..name)
            for i,n in ipairs(expected) do assert(names[i]==n,'timer_signature:'..name) end
        end
    end
    return lib
end
function T:_paused()
    local w=self.world:_world();local lib=self.world:_statics()
    if not w or not lib then return false end
    local ok,d=pcall(lib.GetGlobalTimeDilation,lib,w)
    return ok and number(d) and d>0 and d<=.001
end
function T:Capture()
    local ok,state=pcall(function()
        local lib=self:_bindings(false);local m=self.world:_enemyController();assert(m,'missing_controller')
        local name=m:GetFullName();local out={version=1,timers={}}
        for _,timer in ipairs(timers) do
            local handle=m[timer.field]
            local remaining=lib:K2_GetTimerRemainingTimeHandle(m,handle)
            local elapsed=lib:K2_GetTimerElapsedTimeHandle(m,handle)
            local active=lib:K2_IsTimerActiveHandle(m,handle)
            local paused=lib:K2_IsTimerPausedHandle(m,handle)
            assert(number(remaining) and number(elapsed),'invalid_timer_clock')
            -- Cleared native handles can expose zero clocks rather than -1.
            -- Normalize only the observed stopped zero representation. A
            -- pending handle with a positive rate is still refused, and active
            -- or paused zero timers retain the strict invalid-state guard.
            if active==false and paused==false and remaining==0 and elapsed==0 then
                remaining=-1;elapsed=-1
            end
            -- FTimerManager elapsed is Rate - remaining. Kismet exposes
            -- elapsed/remaining, but no GetTimerRateHandle in this game.
            local rate=(remaining==-1 and elapsed==-1) and -1 or remaining+elapsed
            out.timers[#out.timers+1]={field=timer.field,callback=timer.callback,
                remaining=remaining,rate=rate,
                active=active,paused=paused}
        end
        assert(self.world:_enemyController():GetFullName()==name,'controller_changed')
        local detail={}
        for _,row in ipairs(out.timers) do
            detail[#detail+1]=row.field..':rate='..tostring(row.rate)..',remaining='..tostring(row.remaining)
                ..',active='..tostring(row.active)..',paused='..tostring(row.paused)
        end
        assert(valid(out),'invalid_timer_state:'..table.concat(detail,';'));return out
    end)
    if not ok then return nil,'timer_capture:'..tostring(state):sub(1,700) end
    return state
end
function T:ValidateRestore(state)
    if not valid(state) then return false,'invalid_timer_state' end
    for _,row in ipairs(state.timers) do
        if (row.active or row.paused) and row.remaining<=0 then return false,'zero_timer_delay_not_supported' end
    end
    local ok,why=pcall(function() self:_bindings(true);assert(self.world:_enemyController(),'missing_controller') end)
    return ok,ok and nil or tostring(why)
end
function T:Begin(state)
    if self.pending then return false,'timer_restore_busy' end
    local ok,why=self:ValidateRestore(state);if not ok then return false,why end
    if not self:_paused() then return false,'not_paused' end
    local before,err=self:Capture();if not before then return false,err end
    local rollbackReady,rollbackReason=self:ValidateRestore(before)
    if not rollbackReady then return false,'rollback_not_ready:'..tostring(rollbackReason) end
    local copy={version=1,timers={}}
    for i,row in ipairs(state.timers) do copy.timers[i]={};for k,v in pairs(row) do copy.timers[i][k]=v end end
    self.pending={state=copy,before=before,context=self.world:_enemyController():GetFullName(),cursor=1}
    self.failed=nil;return true
end
function T:_write(m,lib,row)
    assert(not (row.active or row.paused) or row.remaining>0,'zero_timer_delay_not_supported')
    self.writeStarted=true
    lib:K2_ClearTimerHandle(m,m[row.field])
    if row.active or row.paused then
        -- This game's Kismet setter adds InitialStartDelay to Time. The
        -- controller itself uses -8 with its roughly 10-second spawn interval.
        -- Supply an offset so the first countdown equals captured remaining.
        assert(row.remaining>0,'zero_timer_delay_not_supported')
        local handle=lib:K2_SetTimer(m,row.callback,row.rate,true,row.remaining-row.rate,0)
        assert(handle~=nil,'missing_new_timer_handle');m[row.field]=handle
        if row.paused then lib:K2_PauseTimerHandle(m,handle) end
    end
end
function T:_verify(row)
    local captured,why=self:Capture();assert(captured,why)
    for _,read in ipairs(captured.timers) do
        if read.field==row.field then
            local detail=' field='..row.field..' expected(rate='..tostring(row.rate)..',remaining='..tostring(row.remaining)
                ..',active='..tostring(row.active)..',paused='..tostring(row.paused)..') actual(rate='..tostring(read.rate)
                ..',remaining='..tostring(read.remaining)..',active='..tostring(read.active)..',paused='..tostring(read.paused)..')'
            assert(read.active==row.active and read.paused==row.paused,'timer_flag_readback'..detail)
            assert(math.abs(read.rate-row.rate)<=.01 and math.abs(read.remaining-row.remaining)<=.01,'timer_time_readback'..detail)
        end
    end
end
-- TimerManager advances slightly under the diagnostic's small global dilation.
-- Preserve strict flags/signatures while allowing the same bounded countdown
-- tolerance used by native write readback, including the final batch check.
function T:MatchesCapture(expected,current)
    if not valid(expected) or not valid(current) then return false end
    for i,row in ipairs(expected.timers) do
        local read=current.timers[i]
        if read.active~=row.active or read.paused~=row.paused
            or math.abs(read.rate-row.rate)>.01
            or math.abs(read.remaining-row.remaining)>.01 then return false end
    end
    return true
end
function T:Step()
    if self.failed then return false,self.failed end
    local p=self.pending;if not p then return false,'timer_restore_not_started' end
    self.writeStarted=false
    local ok,why=pcall(function()
        assert(self:_paused(),'not_paused');local m=self.world:_enemyController()
        assert(m and m:GetFullName()==p.context,'controller_changed')
        local lib=self:_bindings(true);local row=p.state.timers[p.cursor]
        assert(not (row.active or row.paused) or row.remaining>0,'zero_timer_delay_not_supported')
        if p.verify then
            self:_verify(row)
        else
            self:_write(m,lib,row);p.wrote=true
        end
    end)
    if not ok then
        -- Roll back only the current timer and only in the same paused context.
        self.rollbackSucceeded=false
        local m=self.world:_enemyController()
        if (self.writeStarted or p.wrote) and self:_paused() and m and m:GetFullName()==p.context then
            -- A successful setter does not prove immediate readback: new timers
            -- may remain pending until the next native frame. Keep the failure
            -- hold and report rollback invocation separately from verification.
            self.rollbackInvoked=pcall(function() self:_write(m,self:_bindings(true),p.before.timers[p.cursor]) end)
        end
        self.failed='timer_restore:'..tostring(why);self.pending=nil;return false,self.failed
    end
    if not p.verify then p.verify=true;return nil,'restore_pending' end
    p.verify=false;p.wrote=false;p.cursor=p.cursor+1
    if p.cursor<=#timers then return nil,'restore_pending' end
    self.pending=nil;return true
end
function T:RestoreStep(state)
    if self.failed then return false,self.failed end
    if not self.pending then
        local ok,why=self:Begin(state);if not ok then return false,why end
    end
    return self:Step()
end
function T:Restore(state)
    local ok,why=self:Begin(state);if not ok then return false,why end
    -- Verification must occur on a later native frame, even for this entry
    -- point. GameState uses RestoreStep to continue the staged operation.
    return self:Step()
end
return T
