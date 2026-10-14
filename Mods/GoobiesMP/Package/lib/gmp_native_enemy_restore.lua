-- Incremental reconstruction executor. A native backend must supply verified
-- reset/spawn/readback operations; this module does not guess UE out parameters.
-- Actor bosses, waves, timers and rewards are not yet complete native coverage.
local E=require('gmp_enemies')
local R={};R.__index=R
R.CompleteCapture=false;R.CompleteRestore=false
local required={'Context','Paused','ValidateRows','Reset','Spawn','ReadRows','Adopt'}
function R.new(backend) return setmetatable({backend=backend or {},phase='idle'},R) end
function R:Capture()
    if type(self.backend.CaptureSnapshot)~='function' then return nil,'missing_enemy_capture' end
    return self.backend:CaptureSnapshot()
end
function R:ValidateRestore(snapshot)
    for _,name in ipairs(required) do
        if type(self.backend[name])~='function' then return false,'missing_backend:'..name end
    end
    local registry=E.new();local ok,why=registry:Restore(snapshot)
    if not ok then return false,why end
    if type(self.backend.ValidateSnapshot)=='function' then
        local accepted,reason=self.backend:ValidateSnapshot(snapshot)
        if accepted~=true then return false,reason end
    end
    return true
end
function R:_fail(why)
    self.phase='failed';self.reason=why;return false,why
end
function R:Begin(snapshot)
    if self.phase~='idle' and self.phase~='complete' then return false,'restore_busy' end
    local ok,why=self:ValidateRestore(snapshot);if not ok then return false,why end
    local context=self.backend:Context()
    if type(context)~='string' or context=='' or self.backend:Paused()~=true then return false,'not_paused_or_no_context' end
    local registry=E.new();assert(registry:Restore(snapshot))
    self.registry=registry;self.context=context;self.bindings={};self.slots={};self.cursor=1;self.alive={}
    for _,row in ipairs(registry:Snapshot().enemies) do
        if not row.dead then self.alive[#self.alive+1]=row end
    end
    local checked,supported,reason=pcall(self.backend.ValidateRows,self.backend,self.alive)
    if not checked or supported~=true then return self:_fail('restore_preflight:'..tostring(checked and reason or supported)) end
    if self.backend:Context()~=context or self.backend:Paused()~=true then return self:_fail('restore_context_changed') end
    self.phase='reset';return true
end
function R:Step()
    if self.phase=='failed' then return false,self.reason end
    if self.phase=='complete' then return true end
    if self.phase=='idle' then return false,'not_started' end
    local ok,result,why=pcall(function()
        if self.backend:Paused()~=true or self.backend:Context()~=self.context then return self:_fail('restore_context_changed') end
        if self.phase~='reset' and type(self.backend.VerifySimulationHold)=='function' then
            if self.backend:VerifySimulationHold()~=true then return self:_fail('simulation_hold_lost') end
        end
        if self.phase=='reset' then
            local supported,reason=self.backend:ValidateRows(self.alive)
            if supported~=true then return self:_fail('restore_preflight:'..tostring(reason)) end
            if type(self.backend.SuspendSimulation)=='function' and self.backend:SuspendSimulation()~=true then
                return self:_fail('simulation_suspend_failed')
            end
            if self.backend:Reset()~=true then return self:_fail('reset_failed') end
            self.phase=type(self.backend.InitializeSimulation)=='function' and 'initialize' or 'spawn';return nil,'restore_pending'
        elseif self.phase=='initialize' then
            if self.backend:InitializeSimulation()~=true then return self:_fail('simulation_initialization_failed') end
            self.phase='spawn';return nil,'restore_pending'
        elseif self.phase=='spawn' then
            local row=self.alive[self.cursor]
            if not row then self.phase='verify';return nil,'restore_pending' end
            -- One successful native spawn per tick, retaining host ID separately.
            local request={};for k,v in pairs(row) do request[k]=v end
            local slot=self.backend:Spawn(request)
            if type(slot)~='number' or slot%1~=0 or slot<0 or slot>=E.MAX_SLOTS or self.slots[slot] then return self:_fail('spawn_failed') end
            self.slots[slot]=true;self.bindings[#self.bindings+1]={id=row.id,slot=slot};self.cursor=self.cursor+1
            return nil,'restore_pending'
        elseif self.phase=='verify' then
            local observer=require('gmp_enemy_observer').new(self.registry)
            local adopted,err=observer:Adopt(self.bindings,self.backend:ReadRows())
            if not adopted then return self:_fail(err) end
            self.phase='adopt';return nil,'restore_pending'
        elseif self.phase=='adopt' then
            if self.backend:Adopt(self.registry,self.bindings,self.context)~=true then return self:_fail('capture_adoption_failed') end
            self.phase='complete';return true
        end
        return self:_fail('invalid_phase')
    end)
    if not ok then return self:_fail('backend_exception:'..tostring(result)) end
    return result,why
end
-- Game-state orchestration calls this once per tick. Begin retains a detached
-- registry, so later caller edits cannot change an in-flight reconstruction.
function R:RestoreStep(snapshot)
    if self.phase=='idle' then
        local ok,why=self:Begin(snapshot);if not ok then return false,why end
        return nil,'restore_pending'
    end
    if self.phase=='complete' then return self:VerifyRestore(snapshot) end
    return self:Step()
end
-- Called once after every domain has passed preflight, before a new transaction.
-- Final readback never calls this hook, preserving the completed bindings.
function R:PrepareRestore(snapshot)
    if self.phase~='idle' and self.phase~='complete' then return false,'restore_busy' end
    local ok,why=self:ValidateRestore(snapshot);if not ok then return false,why end
    self.phase='idle';self.reason=nil
    return true
end
function R:Restore(snapshot) return self:RestoreStep(snapshot) end
function R:VerifyRestore(snapshot)
    if self.phase~='complete' or self.backend:Paused()~=true or self.backend:Context()~=self.context then
        return false,'restore_not_complete'
    end
    if type(self.backend.VerifySimulationHold)=='function' then
        local ok,why=pcall(self.backend.VerifySimulationHold,self.backend)
        if not ok or why~=true then return false,'simulation_hold_lost:'..tostring(why) end
    end
    local registry=E.new();local ok,why=registry:Restore(snapshot)
    if not ok then return false,why end
    return require('gmp_enemy_observer').new(registry):Adopt(self.bindings,self.backend:ReadRows())
end
function R:ReleaseSimulation()
    if self.phase~='complete' then return false,'enemy_restore_not_complete' end
    if type(self.backend.ReleaseSimulation)~='function' then return true end
    return self.backend:ReleaseSimulation()
end
function R:RetainSimulation()
    if type(self.backend.RetainSimulation)~='function' then return true end
    return self.backend:RetainSimulation()
end
function R:BindAuthority(capture,registry,import)
    if self.phase~='complete' or type(self.backend.BindAuthority)~='function' then
        return false,'enemy_restore_not_bound'
    end
    local ok,why=self:VerifyRestore(registry:Snapshot());if not ok then return false,why end
    ok,why=self.backend:BindAuthority(capture,registry,self.bindings,self.context,import)
    if ok==true then self.registry=registry end
    return ok,why
end
return R
