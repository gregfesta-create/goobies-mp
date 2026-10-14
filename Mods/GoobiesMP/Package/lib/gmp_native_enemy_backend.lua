-- Native horde binding for the pinned UE4SS Lua out-table ABI.
-- Source: UE4SS 5e627997 LuaUObject.cpp call_ufunction_from_lua; game call
-- signature: tools/phase2_static/dumps/BP_EnemyController.txt, offset1948.
-- Actor bosses are rejected before Reset until their reconstruction is covered.
local B={};B.__index=B
local spawnPath='/Script/Shooter.EnemyController:AddInstanceClassType'
local bakePath='/Game/Blueprints/EnemyController/BP_NewFlowField.BP_NewFlowField_C:BakeFlowField'
local function valid(o) return o and o:IsValid()==true end
local function finite(v,limit) return type(v)=='number' and v==v and math.abs(v)<=limit end
function B.new(world,capture,options)
    return setmetatable({world=world,capture=capture,options=options or {}},B)
end
function B:_manager() return self.world:_enemyController() end
-- Explicit, bounded development concession: drop unclaimed ordinary XP mesh
-- transients during reset without awarding XP or changing progression state.
-- This is never enabled by the normal factory/profile and is not full coverage.
function B:_xpLoss()
    local budget=self.options.xpTransientLossBudget
    if budget==nil then return nil end
    assert(type(budget)=='number' and budget%1==0 and budget>=0 and budget<=64,'invalid_xp_loss_budget')
    assert(type(self.options.log)=='function','missing_xp_loss_audit')
    local manager=self:_manager();local mesh=manager.XPInstanceComponent
    assert(valid(mesh),'missing_xp_component')
    local count=mesh:GetInstanceCount()
    assert(type(count)=='number' and count%1==0 and count>=0 and count<=budget,'xp_loss_budget_exceeded')
    -- Until nonzero native observations establish what XPP contains, ambiguous
    -- stale/pending records cannot be treated as disposable mesh instances.
    assert(manager.XPP and #manager.XPP==count,'xp_loss_ambiguous_records')
    return {version=1,kind='ordinary_xp_instances',budget=budget,count=count}
end
function B:ValidateSnapshot(snapshot)
    self.expectedXpTransientLoss=nil
    local policy=type(snapshot)=='table' and snapshot.xpTransientLoss
    if self.options.xpTransientLossBudget==nil then
        return policy==nil,policy~=nil and 'xp_loss_policy_disabled' or nil
    end
    if type(policy)~='table' or policy.version~=1 or policy.kind~='ordinary_xp_instances'
        or policy.budget~=self.options.xpTransientLossBudget or type(policy.count)~='number'
        or policy.count%1~=0 or policy.count<0 or policy.count>policy.budget then return false,'invalid_xp_loss_policy' end
    self.expectedXpTransientLoss={count=policy.count,budget=policy.budget}
    return true
end
function B:Context()
    local manager=self:_manager();local token=self.options.token and self.options.token()
    if not valid(manager) or type(token)~='string' or token=='' then return nil end
    return manager:GetFullName()..'|'..token
end
function B:Paused()
    local world=self.world:_world();local statics=self.world:_statics()
    if not world or not statics then return false end
    local ok,v=pcall(statics.GetGlobalTimeDilation,statics,world)
    return ok and finite(v,1) and v>0 and v<=.001
end
-- .001 world dilation is a presentation pause, not a simulation barrier.
-- ReceiveTick calls UpdateInstances; suspend that verified actor tick until
-- the complete cross-domain transaction has passed readback and is released.
function B:SuspendSimulation()
    assert(self:Paused(),'restore_not_paused')
    local manager=self:_manager();assert(valid(manager),'missing_controller')
    if self.simulationHold then
        self:VerifySimulationHold()
        return true
    end
    local tick=manager:IsActorTickEnabled();assert(type(tick)=='boolean','invalid_enemy_tick_state')
    local address=manager:GetAddress();assert(type(address)=='number' and address>0,'invalid_controller_address')
    self.simulationHold={manager=manager,address=address,context=self:Context(),tick=tick}
    manager:SetActorTickEnabled(false)
    assert(manager:IsActorTickEnabled()==false,'enemy_tick_suspend_failed')
    return true
end
function B:VerifySimulationHold()
    local hold=self.simulationHold
    local current=self:_manager()
    assert(hold and valid(hold.manager) and valid(current) and current:GetAddress()==hold.address
        and self:Context()==hold.context,'suspended_controller_changed')
    assert(hold.manager:IsActorTickEnabled()==false,'enemy_tick_reenabled')
    return true
end
function B:RetainSimulation()
    local hold=self.simulationHold
    local current=self:_manager()
    assert(hold and valid(hold.manager) and valid(current) and current:GetAddress()==hold.address
        and self:Context()==hold.context,'suspended_controller_changed')
    hold.manager:SetActorTickEnabled(false)
    assert(hold.manager:IsActorTickEnabled()==false,'enemy_tick_hold_failed')
    return true
end
function B:ReleaseSimulation()
    if not self.simulationHold then return true end
    self:VerifySimulationHold()
    local hold=self.simulationHold
    hold.manager:SetActorTickEnabled(hold.tick)
    assert(hold.manager:IsActorTickEnabled()==hold.tick,'enemy_tick_release_failed')
    self.simulationHold=nil
    return true
end
function B:AbilityActors()
    local manager=self:_manager();local out={}
    assert(#manager.AllEnemyActors<=64,'enemy_handler_limit')
    if #manager.AllEnemyActors==0 then return out end
    assert(manager.AllEnemyTypes and #manager.AllEnemyTypes<=64,'missing_enemy_type_table')
    local known={}
    manager.AllEnemyTypes:ForEach(function(_,element)
        local row=element:get();local class=row.actor_16_94DDBA63453991703C7E45A1738CBF3F
        if valid(class) then known[class:GetFullName()]=true end
    end)
    local lib=self.world:_statics();assert(lib,'missing_statics');local seen={}
    manager.AllEnemyActors:ForEach(function(_,element)
        local actor=element:get();assert(valid(actor),'missing_enemy_handler')
        local class=lib:GetObjectClass(actor);assert(valid(class),'missing_handler_class')
        local kind=class:GetFullName();local name=actor:GetFullName()
        assert(known[kind],'unrecognized_enemy_actor class='..tostring(kind):sub(1,320))
        -- SetEnemyTypes spawns a handler for each data row. Several rows may
        -- share an actor class; only duplicate actor identities are invalid.
        assert(not seen[name],'duplicate_enemy_handler')
        seen[name]=true;out[#out+1]=name
    end)
    table.sort(out);return out
end
function B:Preflight(spawnOnly)
    local ok,why=pcall(function()
        assert(self:Context() and self:Paused(),'missing_paused_context')
        local fn=self.world.G.StaticFindObject(spawnPath);assert(valid(fn),'missing_spawn_function')
        local names={}
        fn:ForEachProperty(function(p)
            local name=p:GetFName():ToString();if name~='ReturnValue' then names[#names+1]=name end
        end)
        assert(#names==8 and names[4]:lower()=='enemiesindex' and names[5]:lower()=='spawnedenemy'
            and names[6]:lower()=='damageoverride' and names[7]:lower()=='hpoverride','unsupported_spawn_signature')
        self.outputName=names[5]
        local manager=self:_manager()
        -- Appending one horde instance does not reset or reconstruct existing
        -- actors. Keep actor exclusion on the destructive rebuild path only.
        if not spawnOnly then
            local bake=self.world.G.StaticFindObject(bakePath);assert(valid(bake),'missing_flowfield_bake')
            local parameters=0
            bake:ForEachProperty(function(p) if p:GetFName():ToString()~='ReturnValue' then parameters=parameters+1 end end)
            assert(parameters==0,'unsupported_flowfield_bake_signature')
            self:AbilityActors()
            assert(#manager.AllMiniBosses==0,'actor_enemies_not_supported:count='..#manager.AllMiniBosses)
            -- BP Reset also clears XP instances; refuse until those are part of
            -- the restoration plan instead of silently discarding pickups.
            if self.options.xpTransientLossBudget~=nil then self:_xpLoss()
            else
                assert(manager.XPP and #manager.XPP==0,'xp_pickups_not_supported:xpp='..tostring(manager.XPP and #manager.XPP))
                if manager.XPInstanceComponent~=nil then
                    assert(valid(manager.XPInstanceComponent),'missing_xp_component')
                    local count=manager.XPInstanceComponent:GetInstanceCount()
                    assert(count==0,'xp_pickups_not_supported:instances='..tostring(count))
                end
            end
            -- Reset clears consumable instance meshes and destroys reward/XP
            -- actors. Their presence must block reconstruction until captured.
            assert(manager.AllConsumableInstances and #manager.AllConsumableInstances<=64,'missing_consumable_components')
            manager.AllConsumableInstances:ForEach(function(_,element)
                local component=element:get();assert(valid(component),'missing_consumable_component')
                local count=component:GetInstanceCount()
                assert(count==0,'consumable_pickups_not_supported:instances='..tostring(count))
            end)
            for _,kind in ipairs({'BP_RewardItem_C','BP_XPConsumable_C'}) do
                for _,actor in ipairs(self.world.G.FindAllOf(kind) or {}) do
                    assert(not valid(actor) or not actor:GetFullName():find(self.world.map,1,true),'reward_pickups_not_supported')
                end
            end
            for _,boss in ipairs(self.world.G.FindAllOf('BP_Boss_C') or {}) do
                assert(not valid(boss) or not boss:GetFullName():find(self.world.map,1,true),'actor_boss_not_supported')
            end
        end
        assert(#manager.InstanceStruct<=4096 and #manager.enemyClasses<=64,'native_record_limit')
    end)
    return ok,ok and nil or tostring(why)
end
function B:Reset()
    local ok,why=self:Preflight();assert(ok,why)
    local manager=self:_manager();self.boundContext=self:Context();local handlers=self:AbilityActors()
    local xpLoss=self:_xpLoss()
    if xpLoss then
        assert(self.expectedXpTransientLoss,'missing_captured_xp_loss_policy')
        assert(self.expectedXpTransientLoss.budget==xpLoss.budget,'xp_loss_policy_changed')
    end
    self.previousFlowFields={}
    for _,actor in ipairs(self.world.G.FindAllOf('BP_NewFlowField_C') or {}) do
        if valid(actor) and actor:GetFullName():find(self.world.map,1,true) then self.previousFlowFields[actor:GetFullName()]=true end
    end
    manager:Reset()
    assert(self:Context()==self.boundContext and #manager.InstanceStruct==0,'reset_readback_failed')
    if xpLoss then
        assert(#manager.XPP==0 and manager.XPInstanceComponent:GetInstanceCount()==0,'xp_loss_reset_readback_failed')
        self.lastXpTransientLoss={count=xpLoss.count,capturedCount=self.expectedXpTransientLoss.count,budget=xpLoss.budget}
        self.options.log('XP transient loss count='..xpLoss.count..' captured='..self.expectedXpTransientLoss.count
            ..' budget='..xpLoss.budget..' progression_unchanged=true complete=false')
    end
    local retained=self:AbilityActors();assert(#retained==#handlers,'enemy_handlers_changed')
    for i,name in ipairs(handlers) do assert(retained[i]==name,'enemy_handlers_changed') end
    return true
end
function B:BindSpawnOnly()
    local ok,why=self:Preflight(true);if not ok then return false,why end
    self.boundContext=self:Context();return true
end
function B:InitializeSimulation()
    assert(self:Paused() and self.boundContext==self:Context(),'restore_context_changed')
    local fields={};local observed={}
    for _,actor in ipairs(self.world.G.FindAllOf('BP_NewFlowField_C') or {}) do
        if valid(actor) then
            local name=actor:GetFullName();observed[#observed+1]=name
            if name:find(self.world.map,1,true) and not (self.previousFlowFields or {})[name] then fields[#fields+1]=actor end
        end
    end
    assert(#fields==1,'missing_or_ambiguous_flowfield new='..#fields..' observed='..table.concat(observed,';'):sub(1,650))
    local field=fields[1];field:BakeFlowField()
    local manager=self:_manager()
    assert(valid(field.EnemyController) and field.EnemyController:GetFullName()==manager:GetFullName(),'flowfield_controller_mismatch')
    assert(manager['Walkable Cells'] and #manager['Walkable Cells']>0,'flowfield_walkability_missing')
    assert(field:IsActorTickEnabled()==true,'flowfield_tick_disabled')
    return true
end
function B:_damageFor(row)
    assert(type(row)=='table' and finite(row.x,2000000) and finite(row.y,2000000)
        and finite(row.hp,1e12) and row.hp>0 and row.z==0,'invalid_horde_row')
    local damage
    self:_manager().enemyClasses:ForEach(function(_,element)
        local class=element:get()
        if class.meshIndex==row.enemyType then
            assert(damage==nil,'ambiguous_enemy_class');damage=class.Damage
        end
    end)
    assert(finite(damage,1e12) and damage>=0,'missing_enemy_class_damage')
    if row.damage~=nil then
        assert(finite(row.damage,1e12) and row.damage>=0,'invalid_enemy_damage')
        return row.damage
    end
    return damage
end
function B:ValidateRows(rows)
    local ok,why=pcall(function()
        local supported,reason=self:Preflight();assert(supported,reason)
        assert(type(rows)=='table' and #rows<=4096,'invalid_restore_rows')
        for _,row in ipairs(rows) do self:_damageFor(row) end
    end)
    return ok,ok and nil or tostring(why)
end
function B:Spawn(row)
    assert(self:Paused() and self.boundContext==self:Context(),'restore_context_changed')
    local manager=self:_manager();local damage=self:_damageFor(row)
    local indices,spawned={},{}
    manager:AddInstanceClassType(1,{X=row.x,Y=row.y},row.enemyType,indices,spawned,damage,row.hp,0)
    assert(spawned[self.outputName]==true and #indices==1,'native_spawn_rejected')
    local slot=indices[1]
    -- Pinned UE4SS array output elements use GetParam, which returns a
    -- RemoteUnrealParam wrapper rather than the scalar itself.
    if type(slot)=='userdata' or type(slot)=='table' then
        local ok,value=pcall(function() return slot:get() end)
        assert(ok,'unreadable_spawn_slot');slot=value
    end
    assert(type(slot)=='number' and slot%1==0 and slot>=0 and slot<4096,'invalid_spawn_slot')
    return slot
end
function B:ReadRows()
    assert(self:Paused() and self.boundContext==self:Context(),'restore_context_changed')
    return self.capture:_rows(self:_manager())
end
function B:CaptureSnapshot()
    local capture=self.capture
    if self.options.sourceCapture then capture=self.options.sourceCapture() end
    if not self:Paused() or not self:Context() or not capture or not capture.observer
        or not capture.observer.bootstrapped then return nil,'missing_paused_enemy_capture' end
    local manager=self:_manager()
    if capture.managerName~=manager:GetFullName() or capture.token~=self.options.token() then
        return nil,'stale_enemy_capture_context'
    end
    local state=capture.observer.registry:Snapshot()
    local registry=require('gmp_enemies').new();local ok,why=registry:Restore(state)
    if not ok then return nil,why end
    local bindings={}
    for _,row in ipairs(state.enemies) do
        if not row.dead then bindings[#bindings+1]={id=row.id,slot=row.slot} end
    end
    local accepted,reason=require('gmp_enemy_observer').new(registry):Adopt(bindings,capture:_rows(manager))
    if not accepted then return nil,reason end
    local snapshot=registry:Snapshot()
    if self.options.xpTransientLossBudget~=nil then
        local safe,why=self:Preflight();if not safe then return nil,why end
        snapshot.xpTransientLoss=self:_xpLoss()
    end
    return snapshot
end
function B:Adopt(registry,bindings,context)
    assert(self:Paused() and self:Context()==context and context==self.boundContext,'restore_context_changed')
    assert(type(self.options.import)=='function','missing_registry_import')
    -- Import is explicit, supplied by the replacement host session; never use a
    -- registry from the previous role or a stale module-local session closure.
    assert(self.options.import(registry)==true,'registry_import_failed')
    return self.capture:AdoptRestored(self:_manager(),self.options.token(),registry,bindings)
end
function B:BindAuthority(capture,registry,bindings,context,import)
    if not self:Paused() or self:Context()~=context or context~=self.boundContext then
        return false,'restore_context_changed'
    end
    if not capture or type(capture.AdoptRestored)~='function' or type(import)~='function' then
        return false,'missing_authority_capture'
    end
    local ok,why=capture:AdoptRestored(self:_manager(),self.options.token(),registry,bindings)
    if ok~=true then return false,why end
    self.capture=capture;self.options.import=import;return true
end
return B
