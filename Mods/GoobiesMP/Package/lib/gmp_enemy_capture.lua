-- Opt-in read-only native spawn observation. Never changes the controller.
local Observer=require('gmp_enemy_observer')
local C={};C.__index=C
C.SPAWN='/Script/Shooter.EnemyController:AddInstanceClassType'
C.BOSS='/Script/Shooter.EnemyController:SpawnBossOfType'
local function valid(object) return object and object:IsValid()==true end
-- Test 10: a capture that stopped mid-island never came back, and the frozen registry was streamed to every later
-- island. A stop now logs its traceback and the capture restarts after a backoff (1, 2, 4 ... s) with a fresh epoch
-- (BeginEnemyIsland + Bootstrap from the native rows: clients resync), at most RESTARTS_PER_ISLAND times per island.
-- A spawn hook that fires while the capture itself is reading the native rows (a re-entrant game call) is queued and
-- applied after the read, which is then repeated, so no registry change ever lands inside a running read or poll.
C.RESTARTS_PER_ISLAND=5
function C.new(G,options)
    return setmetatable({G=G,options=options,failed=false,installed=false,spawnCallbacks=0,nextPoll=0,hooks={},slotParams={},
        restarts=0,deferredQueue={},deferred=0},C)
end
local function oneLine(text) return (tostring(text):gsub('\r?\n%s*',' | '):sub(1,1200)) end
function C:_fail(why,trace)
    self.busy=false
    if not self.failed then
        self.options.log('Host enemy capture stopped: '..oneLine(trace or why))
        self.retryAt=(self.clockNow or 0)+math.min(2^self.restarts,8);self.failToken=self.token
    end
    self.failed=true;self.reason=tostring(why)
end
function C:_guard(fn,...)
    if self.failed then return end
    local trace
    local ok,why=xpcall(fn,function(e)
        trace=debug and debug.traceback and debug.traceback(tostring(e),2) or tostring(e);return e
    end,self,...)
    if not ok then self:_fail(why,trace) end
end
function C:_maybeRestart(now)
    local ok,token=pcall(self.options.token)
    if ok and token~=nil and token~=self.failToken then self.restarts=0;self.retryAt=math.min(self.retryAt or now,now) end
    if self.restarts>=C.RESTARTS_PER_ISLAND or not self.retryAt or now<self.retryAt then return end
    self.restarts=self.restarts+1
    self.options.log(string.format('Host enemy capture restarted attempt=%d after=%s',self.restarts,oneLine(self.reason)))
    self.failed,self.reason,self.retryAt,self.busy=false,nil,nil,false
    self.observer,self.manager,self.managerName,self.token,self.deferredQueue=nil,nil,nil,nil,{}
end
-- Applies the spawns queued during a read; true when any was applied (the read is then repeated).
function C:_drainDeferred()
    local queue=self.deferredQueue
    if #queue==0 then return false end
    self.deferredQueue={}
    for _,item in ipairs(queue) do assert(self.observer:Spawn(item.slots,item.rows)) end
    return true
end
function C:_rows(manager,selected)
    local array=manager.InstanceStruct
    assert(#array<=4096,'Native enemy record limit exceeded')
    local rows={}
    array:ForEach(function(_,element)
        local record=element:get();local slot=record.Index
        if not selected or selected[slot] then
            rows[#rows+1]={index=slot,enemyType=record.enemyType,hp=record.HP,
                x=record.Location.X,y=record.Location.Y,z=0,damage=record.Damage}
        end
    end)
    return rows
end
function C:_ensure(manager)
    if not self.options.active() or not valid(manager)
        or not manager:GetFullName():find('/Game/Maps/Game.',1,true) then return false end
    local token=self.options.token();if not token then return false end
    if self.observer and self.observer.registry~=self.options.registry() then
        self:_fail('registry_changed_without_adoption');return false
    end
    local name=manager:GetFullName()
    if self.manager and not valid(self.manager) then self.manager=nil end
    if not self.manager or self.managerName~=name or self.token~=token then
        self.options.begin()
        self.observer=Observer.new(self.options.registry())
        assert(self.observer:Bootstrap(self:_rows(manager)))
        self.manager,self.managerName,self.token=manager,name,token
        self.options.log('Host enemy capture began: '..token)
    end
    return true
end
-- Called by a completed native reconstruction while the game is paused.
-- Never BeginRun here: imported host identities must survive role reversal.
function C:AdoptRestored(manager,token,registry,bindings)
    if self.failed then return false,self.reason end
    if type(token)~='string' or token=='' or not registry then return false,'invalid_restore_context' end
    local ok,result,why=pcall(function()
        if not valid(manager) or not manager:GetFullName():find('/Game/Maps/Game.',1,true) then return false,'invalid_controller' end
        if self.options.registry()~=registry or self.options.token()~=token then return false,'stale_restore_context' end
        local observer=Observer.new(registry)
        local adopted,err=observer:Adopt(bindings,self:_rows(manager))
        if not adopted then return false,err end
        self.observer=observer;self.manager=manager;self.managerName=manager:GetFullName();self.token=token
        return true
    end)
    if not ok then return false,tostring(result) end
    return result,why
end
-- Role activation creates a fresh session registry. Existing hooks and native
-- slots survive, but the observer must stop writing into the previous session.
-- Keep imported host IDs and reconstructed local slot bindings; never Bootstrap
-- here, which would assign new lifetimes to already restored enemies.
function C:RetargetRegistry(registry)
    if self.failed then return false,self.reason end
    if not self.observer or not self.observer.bootstrapped or not self.manager then
        return false,'missing_restored_observer'
    end
    if not registry or self.options.registry()~=registry or self.options.token()~=self.token
        or not valid(self.manager) or self.manager:GetFullName()~=self.managerName then
        return false,'stale_registry_activation'
    end
    local prior=self.observer.registry:Snapshot()
    if registry.epoch~=prior.epoch then return false,'enemy_epoch_mismatch' end
    local bindings={}
    for _,row in ipairs(prior.enemies) do
        if not row.dead then bindings[#bindings+1]={id=row.id,slot=row.slot} end
    end
    return self:AdoptRestored(self.manager,self.token,registry,bindings)
end
-- Test 15 rejoin stall (Coder B): the hooks live as long as the process and fire for every native spawn, also while a
-- level loads and after this window stopped hosting. Before touching the call's context: this window must host a
-- playing island (options.active), and until the capture has bound this island it must also be visible
-- (options.visible, when given). Once bound, a reward screen or fade never drops a spawn (that would restart it).
function C:_live()
    if not self.options.active() then return false end
    local visible=self.options.visible
    if visible==nil or (self.observer and self.manager and self.token~=nil and self.token==self.options.token()) then return true end
    return visible()==true
end
function C:_before(context)
    if not self:_live() then return end
    self:_ensure(context:get())
end
function C:_after(path,context,...)
    if not self:_live() then return end
    local manager=context:get();if not self:_ensure(manager) then return end
    local params={...};local output=assert(params[self.slotParams[path]],'Native spawn output parameter missing'):get()
    local slots,selected={},{}
    if path==C.BOSS then
        assert(type(output)=='number' and output%1==0 and output>=0 and output<4096,'Invalid native boss slot')
        slots[1]=output;selected[output]=true
    else
        assert(#output<=256,'Native spawn batch limit exceeded')
        output:ForEach(function(_,element)
            local slot=element:get();slots[#slots+1]=slot;selected[slot]=true
        end)
    end
    if #slots==0 then return end
    self.spawnCallbacks=self.spawnCallbacks+1
    if self.busy then
        -- re-entrant: the capture is reading the native rows right now; apply after that read
        self.deferredQueue[#self.deferredQueue+1]={slots=slots,rows=self:_rows(manager,selected)}
        self.deferred=self.deferred+1
        return
    end
    assert(self.observer:Spawn(slots,self:_rows(manager,selected)))
end
function C:Install()
    if self.installed or self.failed then return self.installed end
    for _,path in ipairs({C.SPAWN,C.BOSS}) do
        if not self.hooks[path] then
            local fn=self.G.StaticFindObject(path)
            if valid(fn) then
                local index=0
                fn:ForEachProperty(function(property)
                    local name=property:GetFName():ToString()
                    if name~='ReturnValue' then
                        index=index+1
                        if name:lower()=='enemiesindex' then self.slotParams[path]=index end
                    end
                end)
                assert(self.slotParams[path],'Native spawn output reflection did not expose enemiesIndex: '..path)
                self.G.RegisterHook(path,function(context) self:_guard(C._before,context) end,
                    function(context,...) self:_guard(C._after,path,context,...) end)
                self.hooks[path]=true;self.options.log('Host enemy spawn observation installed: '..path)
            end
        end
    end
    self.installed=self.hooks[C.SPAWN] and self.hooks[C.BOSS] or false
    return self.installed
end
function C:Tick(now)
    self.clockNow=now
    if self.failed then self:_maybeRestart(now);if self.failed then return end end
    self:_guard(function()
        self:Install()
        if not self.installed or now<self.nextPoll then return end
        self.nextPoll=now+0.1
        local manager=self.options.manager()
        if self:_ensure(manager) then
            local rows
            for _=1,3 do
                self.busy=true
                local read=self:_rows(manager)
                self.busy=false
                if not self:_drainDeferred() then rows=read;break end
            end
            if rows then assert(self.observer:Poll(rows)) end
        end
    end)
end
return C
