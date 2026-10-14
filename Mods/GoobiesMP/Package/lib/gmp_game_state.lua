-- Capture/restore orchestration for independently implemented game domains.
-- Missing domains block handover. No inferred completeness, engine globals or IO.
local H=require('gmp_handover')
local G={};G.__index=G
local names={'players','enemies','progression','rewards','world','random'}
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function G.new(domains,options) return setmetatable({domains=domains or {},paused=false,options=options or {}},G) end
function G:_scope(state)
    local profile=self.options.profile
    if not profile then return not state or state.scope==nil end
    if profile.name~='retained_ordinary' or type(profile.validate)~='function'
        or type(profile.domains)~='table' or (state and state.scope~=profile.name) then return false end
    local ok,accepted,reason=pcall(profile.validate,state)
    self.scopeReason=ok and reason or tostring(accepted)
    return ok and accepted==true
end
function G:_covered(name,kind)
    local adapter=self.domains[name]
    if adapter and adapter[kind]==true then return true end
    local profile=self.options.profile
    return profile and profile.domains[name]==true and self:_scope() or false
end
function G:Readiness()
    local scoped=self.options.profile and self:_scope()
    local result={ready=self:_scope(),domains={},scope=self.options.profile and self.options.profile.name,reason=self.scopeReason}
    for _,name in ipairs(names) do
        local adapter=self.domains[name]
        local row={capture=adapter~=nil and type(adapter.Capture)=='function',
            restore=adapter~=nil and type(adapter.ValidateRestore)=='function' and type(adapter.Restore)=='function',
            completeCapture=adapter~=nil and (adapter.CompleteCapture==true or scoped and self.options.profile.domains[name]==true) or false,
            completeRestore=adapter~=nil and (adapter.CompleteRestore==true or scoped and self.options.profile.domains[name]==true) or false,
            productionCapture=adapter~=nil and adapter.CompleteCapture==true,
            productionRestore=adapter~=nil and adapter.CompleteRestore==true}
        result.domains[name]=row
        if not row.capture or not row.restore or not row.completeCapture or not row.completeRestore then result.ready=false end
    end
    return result
end
function G:BindEnemyAuthority(capture,registry,import)
    local adapter=self.domains.enemies
    if not self.paused or not self.restored or self.failed or not adapter
        or type(adapter.BindAuthority)~='function' then return false,'enemy_authority_not_ready' end
    return adapter:BindAuthority(capture,registry,import)
end
function G:SetPaused(value)
    if value==false and self.failed then return false,'restore_incomplete' end
    if value==false and self.prepared and (self.restoreCursor or self.verifyCursor) then
        return false,'restore_in_progress'
    end
    local world=self.domains.world
    if type(value)~='boolean' or not world or type(world.SetPaused)~='function' then return false,'missing_pause' end
    local enemy=self.domains.enemies
    local ok,accepted=pcall(world.SetPaused,world,value)
    if not ok or accepted~=true then return false,'pause_rejected' end
    if value==false and self.restored and enemy and type(enemy.ReleaseSimulation)=='function' then
        local released,accepted=pcall(enemy.ReleaseSimulation,enemy)
        if not released or accepted~=true then
            -- Both operations are synchronous on the game thread. Re-hold the
            -- world before the next frame if releasing native tick is refused.
            pcall(world.SetPaused,world,true)
            if type(enemy.RetainSimulation)=='function' then pcall(enemy.RetainSimulation,enemy) end
            self.failed=true
            return false,'enemy_simulation_release_rejected'
        end
    end
    self.paused=value;return true
end
function G:BeginCapture(manifest,context)
    if not self:_scope() then return false,'capture_scope_unavailable' end
    if not self.paused then return false,'not_paused' end
    if self.capturePending then return false,'capture_busy' end
    if type(context)~='string' or context=='' then return false,'missing_capture_context' end
    -- Detach caller data before a multi-tick capture can outlive its source.
    local ok,copy=pcall(function()
        local out={};for k,v in pairs(manifest) do
            if type(v)=='table' then local t={};for i,x in pairs(v) do t[i]=x end;out[k]=t else out[k]=v end
        end;return out
    end)
    if not ok then return false,'invalid_manifest' end
    self.failureDetail=nil
    self.capturePending={context=context,cursor=1,state={manifest=copy,coverage={},scope=self.options.profile and self.options.profile.name}};return true
end
function G:CancelCapture() self.capturePending=nil end
function G:CaptureStep(context)
    local pending=self.capturePending
    if not pending then return false,'no_capture' end
    if not self.paused or context~=pending.context or not self:_scope(pending.state) then self.capturePending=nil;return false,'capture_canceled' end
    local name=names[pending.cursor];local adapter=self.domains[name]
    if not adapter or type(adapter.Capture)~='function' or not self:_covered(name,'CompleteCapture') then
        self.capturePending=nil;return false,'incomplete_capture:'..name
    end
    local method=adapter.CaptureStep or adapter.Capture
    local ok,value,reason=pcall(method,adapter)
    if ok and value==nil and adapter.CaptureStep then return nil,'capture_pending' end
    if not ok or type(value)~='table' then
        self.failureDetail=tostring(ok and reason or value):sub(1,650)
        self.capturePending=nil;return false,'capture_failed:'..name
    end
    -- Domain state must already be detached. Freeze each result now rather than
    -- allowing later domain reads to mutate an earlier captured table.
    local function detach(v,depth,seen,budget)
        budget.n=budget.n+1;assert(depth<=20 and budget.n<=100000,'capture_limit')
        local kind=type(v)
        if kind=='table' then
            assert(not getmetatable(v) and not seen[v],'invalid_capture_table');seen[v]=true
            local out={};for k,x in pairs(v) do
                assert(type(k)=='string' or type(k)=='number','invalid_capture_key')
                out[k]=detach(x,depth+1,seen,budget)
            end;seen[v]=nil;return out
        end
        assert(kind=='string' or kind=='number' or kind=='boolean' or kind=='nil','invalid_capture_value')
        if kind=='string' then assert(#v<=4096,'capture_string_limit') end
        if kind=='number' then assert(v==v and math.abs(v)<math.huge,'capture_nonfinite') end
        return v
    end
    local copied,detached=pcall(detach,value,0,{},{n=0})
    if not copied then self.capturePending=nil;return false,'capture_failed:'..name end
    pending.state[name]=detached;pending.state.coverage[name]=true;pending.cursor=pending.cursor+1
    if pending.cursor<=#names then return nil,'capture_pending' end
    self.capturePending=nil;return H.Validate(pending.state)
end
function G:Capture(manifest)
    if not self.paused then return false,'not_paused' end
    if not self:_scope() then return false,'capture_scope_unavailable' end
    local state={manifest=manifest,coverage={},scope=self.options.profile and self.options.profile.name}
    for _,name in ipairs(names) do
        local adapter=self.domains[name]
        if not adapter or type(adapter.Capture)~='function' then return false,'missing_capture:'..name end
        if not self:_covered(name,'CompleteCapture') then return false,'incomplete_capture:'..name end
        local ok,value=pcall(adapter.Capture,adapter)
        if not ok or type(value)~='table' then return false,'capture_failed:'..name end
        state[name]=value;state.coverage[name]=true
    end
    return H.Validate(state)
end
function G:Prepare(checkpoint)
    if self.prepared and (self.restoreCursor or self.verifyCursor) then return false,'restore_busy' end
    self.prepared=nil;self.restoreCursor=nil;self.verifyCursor=nil;self.restored=nil;self.failureDetail=nil
    local ok,state=H.Validate(checkpoint);if not ok then return false,state end
    if not self:_scope(state) then return false,'restore_scope_unavailable' end
    for _,name in ipairs(names) do
        local adapter=self.domains[name]
        if not adapter or type(adapter.ValidateRestore)~='function' or type(adapter.Restore)~='function' then return false,'missing_restore:'..name end
        if type(adapter.VerifyRestore)~='function' and type(adapter.Capture)~='function' then return false,'missing_readback:'..name end
        if not self:_covered(name,'CompleteRestore') then return false,'incomplete_restore:'..name end
        local success,accepted,reason=pcall(adapter.ValidateRestore,adapter,state[name],state.manifest)
        if not success or accepted~=true then
            self.failureDetail=tostring(success and reason or accepted):sub(1,650)
            return false,'restore_rejected:'..name
        end
    end
    for _,name in ipairs(names) do
        local adapter=self.domains[name]
        if type(adapter.PrepareRestore)=='function' then
            local success,accepted=pcall(adapter.PrepareRestore,adapter,state[name],state.manifest)
            if not success or accepted~=true then return false,'restore_prepare_rejected:'..name end
        end
    end
    self.prepared=state;return true
end
function G:RestoreStep()
    if not self.paused then return false,'not_paused' end
    if not self.prepared then return false,'not_prepared' end
    if not self:_scope(self.prepared) then
        self.failureDetail=('scope='..tostring(self.scopeReason)..';restoreCursor='..tostring(self.restoreCursor)
            ..';verifyCursor='..tostring(self.verifyCursor)):sub(1,650)
        self.failed='scope';self.prepared=nil;return false,'restore_scope_changed'
    end
    if self.verifyCursor then
        local name=names[self.verifyCursor];local adapter=self.domains[name]
        local ok,accepted=pcall(function()
            if type(adapter.VerifyRestore)=='function' then
                return adapter:VerifyRestore(self.prepared[name],self.prepared.manifest)==true
            end
            local captured=adapter:Capture()
            if type(adapter.MatchesCapture)=='function' then
                return adapter:MatchesCapture(self.prepared[name],captured)==true
            end
            return type(captured)=='table' and equal(captured,self.prepared[name])
        end)
        if not ok or accepted~=true then
            self.failed=name;self.prepared=nil;return false,'restore_readback_failed:'..name
        end
        self.verifyCursor=self.verifyCursor+1
        if self.verifyCursor<=#names then return nil,'verification_pending' end
        self.restored=self.prepared;self.prepared=nil;self.failed=nil;return true
    end
    self.restoreCursor=self.restoreCursor or 1
    local name=names[self.restoreCursor];local adapter=self.domains[name]
    local method=adapter.RestoreStep or adapter.Restore
    local ok,accepted,reason=pcall(method,adapter,self.prepared[name],self.prepared.manifest)
    if ok and accepted==nil and adapter.RestoreStep then return nil,'restore_pending' end
    if not ok or accepted~=true then
        self.failureDetail=tostring(adapter.failureDetail or (ok and reason or accepted)):sub(1,650)
        self.failed=name;self.prepared=nil;return false,'restore_failed:'..name
    end
    self.restoreCursor=self.restoreCursor+1
    if self.restoreCursor<=#names then return nil,'restore_pending' end
    -- Later restores may change an earlier domain. Keep the gameplay hold
    -- until the complete batch is read back, one domain per game-thread tick.
    self.verifyCursor=1;return nil,'verification_pending'
end
function G:Restore()
    -- Synchronous compatibility caller; migration runtime uses RestoreStep.
    for _=1,2*#names do
        local accepted,why=self:RestoreStep()
        if accepted~=nil then return accepted,why end
    end
    return nil,'restore_pending'
end
return G
