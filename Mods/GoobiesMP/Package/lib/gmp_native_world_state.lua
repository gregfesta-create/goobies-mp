-- World domain: native wave values and staged spawn timers share one ordered
-- restoration group. Enemy-derived counters are verified by enemy readback.
local Group=require('gmp_native_slice_group');local W={};W.__index=W
W.CompleteCapture=false;W.CompleteRestore=false
function W.new(world,pauseWorld,context)
    assert(pauseWorld and type(pauseWorld.SetSharedPaused)=='function' and type(context)=='function','missing_world_binding')
    local group=Group.new({{name='wave',adapter=require('gmp_native_wave').new(world)},
        {name='timers',adapter=require('gmp_native_timers').new(world)}})
    return setmetatable({world=world,pauseWorld=pauseWorld,context=context,group=group},W)
end
function W:SetPaused(value) return self.pauseWorld:SetSharedPaused(value) end
function W:Capture()
    local context=self.context();if type(context)~='string' or context=='' then return nil,'missing_world_context' end
    local native,why=self.group:Capture();if not native then return nil,why end
    return {version=1,context=context,native=native}
end
function W:ValidateRestore(state)
    if type(state)~='table' or state.version~=1 or state.context~=self.context() then return false,'world_context_changed' end
    return self.group:ValidateRestore(state.native)
end
function W:RestoreStep(state)
    if self.failed then return false,self.failed end
    if type(state)~='table' or state.context~=self.context() then
        if self.restoreStarted then self.failed='world_context_changed' end
        return false,'world_context_changed'
    end
    self.restoreStarted=true
    local accepted,why=self.group:RestoreStep(state.native)
    if accepted==false then self.failureDetail=self.group.failureDetail end
    return accepted,why
end
function W:Restore(state) return self:RestoreStep(state) end
function W:VerifyRestore(state)
    if type(state)~='table' or state.context~=self.context() then return false,'world_context_changed' end
    return self.group:VerifyRestore(state.native)
end
return W
