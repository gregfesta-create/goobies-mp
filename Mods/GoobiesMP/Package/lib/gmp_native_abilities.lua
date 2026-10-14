-- Retained weapon timer-component parameters. Blueprint latent Delay actions
-- remain attached to their existing owners: never replay ResetTimer/ShootItem.
-- Projectile actors and recreation of lost latent actions remain unsupported.
local A={};A.__index=A
A.CompleteCapture=false;A.CompleteRestore=false
A.TimerClass='BlueprintGeneratedClass /Game/Blueprints/Abilities/NewStuff/Modules/BPC_TimerComponent.BPC_TimerComponent_C'
A.Fields={'Player Attack Speed Multi','AdditionalMultiplier','AddedMultiplier','AS Frenzy',
    'SpinkyBonusAS','RateOfFire','ActualROF ForStats'}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=1e12 end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end;return true
end
function A.new(world) return setmetatable({world=world},A) end
function A:_actors()
    local w=self.world:_world();local p=w and self.world:_pawn(w)
    assert(p and p.PlayerIsDead==false,'missing_live_pawn')
    local lib=self.world:_statics();assert(lib,'missing_statics')
    assert(#p.PlayerItemsActors<=256,'ability_limit')
    local actors={};local seen={}
    p.PlayerItemsActors:ForEach(function(_,element)
        local actor=element:get();assert(actor and actor:IsValid(),'missing_ability_actor')
        local name=actor:GetFullName();assert(type(name)=='string' and #name<=4096 and not seen[name],'invalid_ability_identity')
        seen[name]=true;actors[#actors+1]=actor
    end)
    return p,actors,lib,w
end
function A:_read(actor,lib)
    local class=lib:GetObjectClass(actor);assert(class and class:IsValid(),'missing_ability_class')
    local row={actor=actor:GetFullName(),class=class:GetFullName()}
    local fields={};local count=0
    class:ForEachProperty(function(property)
        count=count+1;assert(count<=1024,'ability_property_limit')
        fields[property:GetFName():ToString()]=true
    end)
    local ready,value=pcall(function() return actor['IsReady?'] end)
    if fields['IsReady?'] then assert(ready and type(value)=='boolean','invalid_ability_ready');row.ready=value end
    local exists,timer=pcall(function() return actor.BPC_TimerComponent end)
    if fields.BPC_TimerComponent then
        assert(exists and timer,'missing_timer_component')
        assert(timer:IsValid(),'missing_timer_component')
        local kind=lib:GetObjectClass(timer)
        assert(kind and kind:IsValid() and kind:GetFullName()==A.TimerClass,'unsupported_timer_component')
        row.timer=timer:GetFullName();row.values={}
        for _,field in ipairs(A.Fields) do
            local value=timer[field];assert(finite(value),'invalid_ability_parameter:'..field);row.values[field]=value
        end
    end
    return row
end
function A:Capture()
    local ok,result=pcall(function()
        local pawn,actors,lib,w=self:_actors();local out={version=1,pawn=pawn:GetFullName(),items={}}
        for _,actor in ipairs(actors) do out.items[#out.items+1]=self:_read(actor,lib) end
        local current=self.world:_pawn(w);assert(current and current:GetFullName()==out.pawn,'ability_pawn_changed')
        return out
    end)
    if not ok then return nil,'ability_capture:'..tostring(result):sub(1,700) end
    return result
end
function A:ValidateRestore(state)
    local current=self:Capture()
    if not current or type(state)~='table' or state.version~=1 or state.pawn~=current.pawn
        or type(state.items)~='table' or #state.items~=#current.items then return false,'ability_context_changed' end
    for i,row in ipairs(current.items) do
        local saved=state.items[i]
        if type(saved)~='table' or row.actor~=saved.actor or row.class~=saved.class
            or row.timer~=saved.timer or row.ready~=saved.ready then return false,'ability_continuity_changed' end
        if row.values then
            if type(saved.values)~='table' then return false,'missing_ability_parameters' end
            for _,field in ipairs(A.Fields) do if not finite(saved.values[field]) then return false,'invalid_ability_parameters' end end
        elseif saved.values~=nil then return false,'unexpected_ability_parameters' end
    end
    return true
end
function A:RestoreStep(state)
    if self.failed then return false,self.failed end
    local target=self.pending and self.pending.target or state
    local valid,why=self:ValidateRestore(target)
    if not valid then
        if self.pending then self.failed=why;self.pending=nil end
        return false,why
    end
    local pawn,actors,lib,w=self:_actors()
    local ok,d=pcall(lib.GetGlobalTimeDilation,lib,w)
    if not ok or not finite(d) or d<=0 or d>.001 then
        if self.pending then self.failed='not_paused';self.pending=nil end
        return false,'not_paused'
    end
    if not self.pending then
        -- Capture a detached target, not the caller's mutable table.
        local target={version=1,pawn=state.pawn,items={}}
        for i,row in ipairs(state.items) do
            target.items[i]={actor=row.actor,class=row.class,timer=row.timer,ready=row.ready}
            if row.values then target.items[i].values={};for _,f in ipairs(A.Fields) do target.items[i].values[f]=row.values[f] end end
        end
        self.pending={target=target,cursor=1}
    end
    local pending=self.pending;local row=pending.target.items[pending.cursor]
    if not row then self.pending=nil;return true end
    local actor=actors[pending.cursor];local before=self:_read(actor,lib)
    local function write(value)
        if value.values then
            local timer=actor.BPC_TimerComponent
            assert(timer and timer:IsValid() and timer:GetFullName()==value.timer,'ability_timer_changed')
            for _,field in ipairs(A.Fields) do timer[field]=value.values[field] end
        end
        assert(same(self:_read(actor,lib),value),'ability_readback_failed')
    end
    local applied,problem=pcall(write,row)
    if not applied then
        self.failure=tostring(problem);self.rollbackSucceeded=pcall(write,before)
        self.failed='native_ability_write_failed';self.pending=nil;return false,self.failed
    end
    pending.cursor=pending.cursor+1
    if pending.cursor>#pending.target.items then self.pending=nil;return true end
    return nil,'restore_pending'
end
function A:Restore(state) return self:RestoreStep(state) end
return A
