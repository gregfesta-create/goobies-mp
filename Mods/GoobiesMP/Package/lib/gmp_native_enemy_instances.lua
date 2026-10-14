-- Host-driven ordinary enemy view. Components belong to this mod, not the
local Liveness=require('gmp_run_sync_liveness')   -- test 12: cached UObject handles are never trusted
-- game's native horde; hiding/removal never executes damage, death or rewards.
-- Runtime opt-in candidate: reflected signatures must match before creation.
local V={};V.__index=V
local function valid(o)return o and o:IsValid()==true end
local function safeName(o)
    local ok,name=pcall(function()assert(valid(o),'invalid_object');return o:GetFullName()end)
    if not ok or type(name)~='string' then return nil end
    return name:sub(1,1024)
end
local function finite(n,limit)return type(n)=='number' and n==n and math.abs(n)<=limit end
local function transform(row,scale)
    return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=row.x,Y=row.y,Z=row.z},Scale3D={X=scale,Y=scale,Z=scale}}
end
local signatures={
    ['/Script/Engine.Actor:AddComponentByClass']={'Class','bManualAttachment','RelativeTransform','bDeferredFinish','ReturnValue'},
    ['/Script/Engine.InstancedStaticMeshComponent:AddInstance']={'InstanceTransform','bWorldSpace','ReturnValue'},
    ['/Script/Engine.InstancedStaticMeshComponent:UpdateInstanceTransform']={'InstanceIndex','NewInstanceTransform','bWorldSpace','bMarkRenderStateDirty','bTeleport','ReturnValue'},
    ['/Script/Engine.InstancedStaticMeshComponent:GetInstanceTransform']={'InstanceIndex','OutInstanceTransform','bWorldSpace','ReturnValue'},
    ['/Script/Engine.SceneComponent:SetVisibility']={'bNewVisibility','bPropagateToChildren'},
    ['/Script/Engine.SceneComponent:IsVisible']={'ReturnValue'},
    -- Actual game bytecode calls K2_DestroyComponent(self). The non-reflected
    -- C++ DestroyComponent(bool) is a different interface, not a Lua UFunction.
    ['/Script/Engine.ActorComponent:K2_DestroyComponent']={'Object'},
    ['/Script/Engine.ActorComponent:IsBeingDestroyed']={'ReturnValue'},
    ['/Script/Engine.ActorComponent:GetOwner']={'ReturnValue'},
    ['/Script/Engine.Actor:K2_GetComponentsByClass']={'ComponentClass','ReturnValue'},
    ['/Script/Engine.PrimitiveComponent:SetCollisionEnabled']={'NewType'},
    ['/Script/Engine.SceneComponent:SetMobility']={'NewMobility'},
    ['/Script/Engine.StaticMeshComponent:SetStaticMesh']={'NewMesh','ReturnValue'},
    ['/Script/Engine.PrimitiveComponent:GetMaterial']={'ElementIndex','ReturnValue'},
    ['/Script/Engine.PrimitiveComponent:SetMaterial']={'ElementIndex','Material'},
    ['/Script/Engine.InstancedStaticMeshComponent:GetInstanceCount']={'ReturnValue'},
}
function V.new(world,options)
    options=options or {};local cap=options.cap or 4096
    assert(type(cap)=='number' and cap%1==0 and cap>=1 and cap<=4096,'invalid_instance_cap')
    return setmetatable({world=world,cap=cap,count=0,allocated=0,slots={},groups={},options=options},V)
end
function V:Bind(context)
    if self.context then return false,'already_bound' end
    local ok,why=pcall(function()
        assert(type(context)=='string' and context~='' and #context<=256,'invalid_view_context')
        -- Audit the complete dependency list before any template read/creation.
        -- Collect all refusals so one launch does not discover one missing API.
        local failures={};self.signatureAudit={}
        local paths={};for path in pairs(signatures)do paths[#paths+1]=path end;table.sort(paths)
        for _,path in ipairs(paths) do
            local names=signatures[path];local fn=self.world.G.StaticFindObject(path)
            local checked,detail=pcall(function()
                assert(valid(fn),'missing_instance_function:'..path)
                local actual={};local metadata={}
                fn:ForEachProperty(function(p)
                    assert(#actual<16,'instance_parameter_limit:'..path)
                    actual[#actual+1]=p:GetFName():ToString()
                    metadata[#metadata+1]=actual[#actual]..':'..p:GetClass():GetFName():ToString()..'@'..p:GetOffset_Internal()
                end)
                self.signatureAudit[#self.signatureAudit+1]=path..' '..table.concat(metadata,',')
                assert(#actual==#names,'instance_signature_count:'..path)
                for i,name in ipairs(names) do assert(actual[i]:lower()==name:lower(),'instance_signature_name:'..path)end
                if path=='/Script/Engine.ActorComponent:K2_DestroyComponent' then
                    local fields={};fn:ForEachProperty(function(p)fields[#fields+1]=p end)
                    assert(fields[1]:GetClass():GetFName():ToString()=='ObjectProperty'
                        and fields[1]:GetOffset_Internal()==0,'instance_destroy_object_signature')
                elseif path=='/Script/Engine.ActorComponent:GetOwner' then
                    assert((fn:GetFunctionFlags()&0x400)~=0,'instance_owner_not_native')
                    local fields={};fn:ForEachProperty(function(p)fields[#fields+1]=p end)
                    assert(fields[1]:GetClass():GetFName():ToString()=='ObjectProperty'
                        and fields[1]:GetOffset_Internal()==0,'instance_owner_signature')
                elseif path=='/Script/Engine.Actor:K2_GetComponentsByClass' then
                    assert((fn:GetFunctionFlags()&0x400)~=0,'instance_owner_components_not_native')
                    local fields={};fn:ForEachProperty(function(p)fields[#fields+1]=p end)
                    assert(fields[1]:GetClass():GetFName():ToString()=='ClassProperty'
                        and fields[1]:GetOffset_Internal()==0 and fields[2]:GetClass():GetFName():ToString()=='ArrayProperty'
                        and fields[2]:GetOffset_Internal()==8
                        and fields[2]:GetInner():GetClass():GetFName():ToString()=='ObjectProperty','instance_owner_components_signature')
                elseif path=='/Script/Engine.ActorComponent:IsBeingDestroyed' then
                    local fields={};fn:ForEachProperty(function(p)fields[#fields+1]=p end)
                    assert(fields[1]:GetClass():GetFName():ToString()=='BoolProperty'
                        and fields[1]:GetOffset_Internal()==0 and fields[1]:GetFieldSize()==1
                        and fields[1]:GetByteOffset()==0
                        and (fn:GetFunctionFlags() & 0x400)~=0,'instance_destroy_state_signature')
                end
            end)
            if not checked then failures[#failures+1]=tostring(detail) end
        end
        if self.options.log then for _,line in ipairs(self.signatureAudit)do self.options.log('SDKINSTANCE '..line)end end
        assert(#failures==0,table.concat(failures,' | '))
        local manager=self.world:_enemyController();assert(valid(manager),'missing_controller')
        local componentClass=self.world.G.StaticFindObject('/Script/Engine.InstancedStaticMeshComponent')
        assert(valid(componentClass),'missing_instance_component_class')
        self.context,self.manager,self.managerName,self.componentClass=context,manager,manager:GetFullName(),componentClass
        self.managerAddress=Liveness.Address(manager)
        self.templates={};self.originalComponents={};self.visibilityLedger={}
        self:_refreshTemplates()

    end)
    return ok,ok and nil or tostring(why)
end
-- Native mesh components can be created lazily. Catalog is always class-keyed;
-- a missing requested template refuses rendering rather than using another type.
-- D43 inventory, once per binding: the controller's AllEnemyTypes rows (S_Enemy: name, actor), so a run tells which
-- mesh-less classes are bosses, non-boss uniques or other actor enemies. Diagnostic only; failures are silent.
local S_ENEMY_NAME,S_ENEMY_ACTOR='name_2_D180B3A94E78E8FEDBD33490A48F79A6','actor_16_94DDBA63453991703C7E45A1738CBF3F'
function V:_listEnemyTypes(manager)
    local log=self.options.log
    if not log then return end
    pcall(function()
        local types=manager.AllEnemyTypes
        if not types or type(types.ForEach)~='function' then return end
        types:ForEach(function(index,element)
            local ok,row=pcall(function()return element:get()end)
            if not ok or type(row)~='table' and type(row)~='userdata' then return end
            local name,actor='-','-'
            pcall(function()local n=row[S_ENEMY_NAME];if n then name=n.ToString and n:ToString() or tostring(n) end end)
            pcall(function()
                local a=row[S_ENEMY_ACTOR]
                if a and a.IsValid and a:IsValid() then actor=tostring(a:GetFullName()):gsub('^%S+%s','') end
            end)
            log(string.format('ENEMYCLASS index=%d name=%s actor=%s',index-1,tostring(name),tostring(actor)))
        end)
    end)
end
function V:_refreshTemplates()
    assert(self:_current(),'changed_controller')
    local manager=self.manager;local components={};local seen={};local catalog={};local templates={}
    assert(#manager.AllInstanceComponents<=64 and #manager.enemyClasses<=64,'template_limit')
    manager.AllInstanceComponents:ForEach(function(index,element)
        assert(type(index)=='number' and index%1==0 and index>=1 and index<=64 and not seen[index],'invalid_component_index')
        seen[index]=true;local component=element:get();components[index]=component
        local isValid=valid(component);local mesh=isValid and component.StaticMesh or nil
        if self.options.log and not self.templatesLogged then self.options.log('SDKINSTANCE component='..index..' valid='..tostring(isValid)..' meshValid='..tostring(valid(mesh)))end
    end)
    manager.enemyClasses:ForEach(function(luaIndex,element)
        local classIndex=luaIndex-1 -- UE4SS ForEach passes i+1; native enemyType is zero-based.
        assert(type(classIndex)=='number' and classIndex%1==0 and classIndex>=0 and classIndex<64 and not catalog[classIndex],'invalid_class_index')
        local row=element:get();local index=row.meshIndex;local scale=row.Scale
        if self.options.log and not self.templatesLogged then self.options.log('SDKINSTANCE class='..classIndex..' meshIndex='..tostring(index)..' scale='..tostring(scale))end
        -- Keep unloaded/invalid mappings as unavailable catalog entries. Only a
        -- requested ordinary class requires a concrete matching local template.
        local radius;pcall(function()radius=row.Radius end)
        catalog[classIndex]={meshIndex=index,scale=scale,radius=finite(radius,100000) and radius or nil}
        -- Every class with a loaded mesh (R1 attempt 5: later waves bring class 26, SM_BlobMortar); mesh-less
        -- classes (actor bosses) have no template and are refused.
        if type(index)=='number' and index%1==0 and index>=0 and index<64
            and finite(scale,100) and scale>0 then
            local component=components[index+1]
            if valid(component) and valid(component.StaticMesh) then
                templates[classIndex]={mesh=component.StaticMesh,material=component:GetMaterial(0),scale=scale,meshIndex=index}
            end
        end
    end)
    assert(self:_current(),'changed_controller')
    self.catalog,self.templates=catalog,templates
    if not self.templatesLogged then self:_listEnemyTypes(manager) end
    self.templatesLogged=true;self.templatesAt=(self.options.clock or os.clock)()
    -- Add newly discovered original components to the restoration ledger's
    -- source set without replacing already owned visibility receipts.
    for _,component in pairs(components)do if valid(component) then
        local found=false;for _,known in ipairs(self.originalComponents)do if known==component then found=true;break end end
        if not found then self.originalComponents[#self.originalComponents+1]=component end
    end end
    if self.localSuppression then
        local hidden,why=self:SuppressLocalMeshes(true);assert(hidden,why)
    end
end
-- A missing class is re-scanned at most every RESCAN_SECONDS (test 6: a re-scan per refused row was a lag source).
V.RESCAN_SECONDS=5
function V:_mayRescan()
    local now=(self.options.clock or os.clock)()
    return not self.templatesAt or now-self.templatesAt>=V.RESCAN_SECONDS
end
-- Can rows of this class be drawn (a loaded mesh template)? Classes without one are not mirrored at all.
function V:HasTemplate(kind)
    if type(kind)~='number' or kind%1~=0 or kind<0 or kind>=64 then return false end
    if (not self.templates or not self.templates[kind]) and self:_mayRescan() then pcall(self._refreshTemplates,self) end
    return self.templates~=nil and self.templates[kind]~=nil
end
function V:AvailableOrdinaryType()
    local ok=pcall(self._refreshTemplates,self);if not ok then return nil end
    for kind=0,12 do if self.templates[kind] then return kind end end
end
-- Test 12 client crash (UE4SS read a freed object): the cached controller handle is never read here. The fresh
-- controller must have the bound one's name and address; its fresh handle is then adopted.
function V:_current()
    if self.frameCurrent~=nil then return self.frameCurrent end
    if not self.context then return false end
    local manager=self.world:_enemyController()
    if not valid(manager) or manager:GetFullName()~=self.managerName then return false end
    local address=Liveness.Address(manager)
    if address and self.managerAddress and address~=self.managerAddress then return false end
    self.manager=manager
    return true
end
-- One liveness proof for a whole batch of writes (the rows path calls these around each Apply): between BeginFrame
-- and EndFrame _current() reuses the result instead of scanning the world and controllers for every transform.
-- Test 9 (6.5 ms per apply): the proof (two object scans) is reused for FRAME_PROOF_SECONDS; the rows path re-checks
-- its context before every apply and an island/level change always changes that context.
V.FRAME_PROOF_SECONDS=0.25
function V:BeginFrame()
    local now=(self.options.clock or os.clock)()
    self.frameCurrent=nil
    if self.proofAt and self.proofOk and now-self.proofAt>=0 and now-self.proofAt<V.FRAME_PROOF_SECONDS then
        self.frameCurrent=true
    else
        self.frameCurrent=self:_current() and true or false
        self.proofAt,self.proofOk=now,self.frameCurrent
    end
    self.framePending={}
    return self.frameCurrent
end
-- Writes the frame's queued transforms: one BatchUpdateInstancesTransforms per class over the touched index range
-- (instances in between keep their stored transform), else per-row updates marking the render state dirty only on the
-- last one (the batch route's absence or failure is logged once and then not tried again).
function V:EndFrame()
    local pending=self.framePending
    self.frameCurrent,self.framePending=nil,nil
    if not pending then return end
    for group,indices in pairs(pending) do
        local list={}
        for index in pairs(indices) do list[#list+1]=index end
        table.sort(list)
        if #list>0 and valid(group.component) then
            local first,last=list[1],list[#list]
            local done=false
            -- test 10: a UE4SS UFunction is a callable userdata, not a Lua function; any callable value is tried
            local okBatch,batch=pcall(function()return group.component.BatchUpdateInstancesTransforms end)
            if not okBatch then batch=nil end
            if not self.batchBroken and batch~=nil then
                local transforms={}
                for i=first,last do transforms[#transforms+1]=group.transforms[i] or transform({x=0,y=0,z=0},0) end
                local called,result=pcall(batch,group.component,first,transforms,true,true,true)
                done=called and result~=false
                if done and not self.batchLogged then
                    self.batchLogged=true
                    if self.options.log then self.options.log('SDKINSTANCE batch ok first='..first..' n='..#transforms) end
                end
                if not done then
                    self.batchBroken=true
                    if self.options.log then self.options.log('SDKINSTANCE batch unavailable reason='..tostring(called and result or 'error')..' (per-row updates)') end
                end
            elseif not self.batchBroken then
                self.batchBroken=true
                if self.options.log then self.options.log('SDKINSTANCE batch unavailable reason=no_batch_route (per-row updates)') end
            end
            if not done then
                for n,index in ipairs(list) do
                    pcall(group.component.UpdateInstanceTransform,group.component,index,group.transforms[index],true,n==#list,true)
                end
            end
        end
    end
end
-- Reversible presentation suppression only. Native interception independently
-- blocks simulation; hiding meshes alone never claims authority coverage.
function V:SuppressLocalMeshes(enable)
    if type(enable)~='boolean' or not self:_current() then return false,'changed_controller' end
    local ok,why=pcall(function()
        if enable then
            for _,component in ipairs(self.originalComponents) do
                assert(valid(component),'lost_original_component')
                if self.visibilityLedger[component]==nil then
                    local visible=component:IsVisible();assert(type(visible)=='boolean','invalid_original_visibility')
                    self.visibilityLedger[component]=visible
                end
                component:SetVisibility(false,false)
                assert(component:IsVisible()==false,'original_hide_readback_failed')
            end
        else
            for component,visible in pairs(self.visibilityLedger) do
                assert(valid(component),'lost_original_component')
                component:SetVisibility(visible,false)
                assert(component:IsVisible()==visible,'original_restore_readback_failed')
                self.visibilityLedger[component]=nil
            end
        end
    end)
    if ok then self.localSuppression=enable end
    return ok,ok and nil or tostring(why)
end
function V:LocalMeshesSuppressed()
    if not self:_current() then return false end
    for _,component in ipairs(self.originalComponents or {}) do
        if not valid(component) or self.visibilityLedger[component]==nil or component:IsVisible()~=false then return false end
    end
    return true
end
function V:_group(kind)
    local group=self.groups[kind];if group then assert(valid(group.component) and group.configured and not group.failed,'lost_or_incomplete_owned_component');return group end
    if not self.templates[kind] and self:_mayRescan() then self:_refreshTemplates() end
    local template=self.templates[kind];assert(template,'requested_ordinary_template_unavailable')
    local component=self.manager:AddComponentByClass(self.componentClass,true,
        transform({x=0,y=0,z=0},1),false)
    assert(valid(component),'owned_component_creation_failed')
    group={component=component,free={},allocated=0,scale=template.scale};self.groups[kind]=group
    -- Record ownership before configuration so Clear handles partial creation.
    local owner=component:GetOwner()
    assert(valid(owner) and owner:GetFullName()==self.managerName,'owned_component_actor_mismatch')
    group.ownerVerified=true;group.componentName=component:GetFullName()
    component:SetCollisionEnabled(0);component:SetMobility(2)
    assert(component:SetStaticMesh(template.mesh)~=false,'owned_mesh_assignment_failed')
    component:SetMaterial(0,template.material)
    group.configured=true
    return group
end
function V:SetEnemy(id,row)
    local ok,why=pcall(function()
        assert(not self.closing and self:_current(),'changed_or_closing_controller')
        assert(type(id)=='string' and #id<=32 and id:match('^%d+:%d+$'),'invalid_host_lifetime')
        assert(type(row)=='table' and finite(row.x,2000000) and finite(row.y,2000000)
            and finite(row.z,100000) and type(row.enemyType)=='number' and row.enemyType%1==0
            and row.enemyType>=0 and row.enemyType<64,'invalid_instance_row')
        local binding=self.slots[id]
        if binding then assert(binding.kind==row.enemyType,'host_lifetime_type_changed') end
        local group=self:_group(row.enemyType)
        if not binding then
            assert(self.count<self.cap,'instance_capacity')
            local index=table.remove(group.free)
            if index==nil then
                assert(self.allocated<self.cap,'allocated_instance_capacity')
                group.failed=true
                index=group.component:AddInstance(transform(row,0),true)
                assert(type(index)=='number' and index%1==0 and index>=0 and index<self.cap,'owned_instance_add_failed')
                group.failed=false;group.allocated=group.allocated+1;self.allocated=self.allocated+1
            end
            binding={kind=row.enemyType,index=index};self.slots[id]=binding;self.count=self.count+1
        end
        local t=transform(row,group.scale)
        group.transforms=group.transforms or {}
        group.transforms[binding.index]=t
        if self.framePending then
            -- inside a frame: queued, written once per class at EndFrame
            self.framePending[group]=self.framePending[group] or {}
            self.framePending[group][binding.index]=true
        else
            assert(group.component:UpdateInstanceTransform(binding.index,t,true,true,true)==true,'owned_instance_update_failed')
        end
    end)
    return ok,ok and nil or tostring(why)
end
-- Cosmetic only (test 7): the client's rows path retires host deaths without any death route, and its own hits are
-- resolved by the host, so neither showed the game's feedback. Both spawn the game's own Niagara systems.
local function niagara(self)
    local lib=self.world.G.StaticFindObject('/Script/Niagara.Default__NiagaraFunctionLibrary')
    assert(valid(lib),'niagara_library_unavailable')
    return lib
end
-- The controller's own deathSystem at the host death position, at the class scale.
-- The host's ordinary death effect, exactly as its native kill (AEnemyController, exe 0x141aef020) plays it: the
-- NiagaraComponent at controller+0x2a8 is re-activated with Activate(true) and given User.pos (X, Y, 0), User.dir
-- (minus the row's dir), User.force (clamp(|HP| * 0.02, 0, 1)) and User.size (the row's Radius). Test 11: that field
-- is NS (enemyClasses @0x290, deathSystem @0x2a0 = the NS_EnemyDeathEffectMesh ASSET, NS @0x2a8); calling Activate on
-- deathSystem failed. Without a usable NS the deathSystem asset is spawned at the spot with the same parameters. The
-- client cannot see the host's overkill: force is DEATH_FORCE (test 12: 0.1 played the splash slowly; one-hit kills
-- reach the host's 1.0). User.dir is minus the drawn movement direction (dx, dy); the size the class Radius.
V.DEATH_FORCE=1
local function niagaraComponent(o)
    if not valid(o) then return false end
    local ok,name=pcall(function()return o:GetFullName()end)
    return ok and type(name)=='string' and name:find('^NiagaraComponent ')~=nil
end
function V:DeathEffect(kind,x,y,dx,dy)
    local ok,why=pcall(function()
        assert(not self.closing and self:_current(),'changed_or_closing_controller')
        assert(finite(x,2000000) and finite(y,2000000),'invalid_death_position')
        local component,route=self.manager.NS,'component'
        if not niagaraComponent(component) then
            local system=self.manager.deathSystem
            assert(valid(system),'no_death_system')
            component=niagara(self):SpawnSystemAtLocation(self.manager,system,{X=x,Y=y,Z=0},{Pitch=0,Yaw=0,Roll=0},{X=1,Y=1,Z=1},true,true,0,true)
            assert(valid(component),'death_system_spawn_failed')
            route='spawned'
        end
        if not self.deathRouteLogged and self.options.log then
            self.deathRouteLogged=true
            local name,asset='?','?'
            pcall(function()name=tostring(component:GetFullName()):gsub('^%S+%s','')end)
            pcall(function()asset=tostring(component.Asset:GetFullName()):gsub('^%S+%s','')end)
            self.options.log('SDKINSTANCE deathfx route='..route..' name='..name..' asset='..asset)
        end
        local FName=self.world.G and self.world.G.FName
        local function n(text) return FName and FName(text) or text end
        if route=='component' then component:Activate(true) end
        local pos={X=x,Y=y,Z=0}
        pcall(function()component:SetVariablePosition(n('User.pos'),pos)end)
        pcall(function()component:SetVariableVec3(n('User.pos'),pos)end)
        local ux,uy=0,0
        if finite(dx,2) and finite(dy,2) then ux,uy=-dx,-dy end
        pcall(function()component:SetVariableVec2(n('User.dir'),{X=ux,Y=uy})end)
        pcall(function()component:SetVariableFloat(n('User.force'),V.DEATH_FORCE)end)
        local class=self.catalog and self.catalog[kind]
        local radius=class and class.radius
        if finite(radius,100000) and radius>0 then pcall(function()component:SetVariableFloat(n('User.size'),radius)end) end
    end)
    return ok,ok and nil or tostring(why)
end
-- The game's damage number (NS_DamageNumbers, User.dmg) at a client hit, unless damage numbers are switched off.
V.DAMAGE_NUMBERS='/Game/FX/Test/NS_DamageNumbers.NS_DamageNumbers'
-- Test 13: the player's own setting, from the game's settings save (LoadGameFromSlot('settings', 0).ShowDamageNumbers?,
-- what the controller's BeginPlay copies into ShowDMGNumbers?; on clients that copy read false with the setting ON).
-- Read at most every SETTING_SECONDS and logged once; the controller copy is only the fallback without a save.
V.SETTING_SECONDS=5
function V:_damageNumbersOn()
    local now=(self.options.clock or os.clock)()
    if self.dmgSettingAt and now-self.dmgSettingAt<V.SETTING_SECONDS then return self.dmgSetting end
    self.dmgSettingAt=now
    local saved
    pcall(function()
        local statics=self.world.G.StaticFindObject('/Script/Engine.Default__GameplayStatics')
        local save=statics and statics:LoadGameFromSlot('settings',0)
        local v=save and save['ShowDamageNumbers?']
        if type(v)=='boolean' then saved=v end
    end)
    local copy;pcall(function()copy=self.manager['ShowDMGNumbers?']end)
    local on
    if saved~=nil then on=saved else on=copy~=false end
    if not self.dmgSettingLogged and self.options.log then
        self.dmgSettingLogged=true
        self.options.log('SDKINSTANCE damage numbers setting save='..tostring(saved)..' controller='..tostring(copy)..' on='..tostring(on))
    end
    self.dmgSetting=on
    return on
end
function V:HitNumber(x,y,damage)
    local ok,why=pcall(function()
        assert(not self.closing and self:_current(),'changed_or_closing_controller')
        assert(finite(x,2000000) and finite(y,2000000) and finite(damage,1e12) and damage>=0,'invalid_hit_number')
        assert(self:_damageNumbersOn(),'damage_numbers_off')
        local system=self.world.G.StaticFindObject(V.DAMAGE_NUMBERS)
        assert(valid(system),'damage_numbers_unavailable')
        local component=niagara(self):SpawnSystemAtLocation(self.manager,system,{X=x,Y=y,Z=0},{Pitch=0,Yaw=0,Roll=0},{X=1,Y=1,Z=1},true,true,0,true)
        assert(valid(component),'damage_number_spawn_failed')
        local FName=self.world.G.FName
        component:SetVariableInt(FName and FName('User.dmg') or 'User.dmg',math.floor(damage+0.5))
    end)
    return ok,ok and nil or tostring(why)
end
-- D43: visual-only copies of the host's boss/unique actors (research section 13). An owned StaticMeshComponent with the
-- host actor's mesh and scale (ACTOR_INFO), moved and yawed with the row, flashing (custom primitive data 3 = game time,
-- as the game's own hit flash) when the host HP drops; bosses also get the game's own boss bar (WBP_BossBar in the
-- HUD's BossBarDaddy, CurrentHP/MaxHP/BossName, UpdateBar). No actor, AI, attacks or rewards on this client.
V.ACTOR_COMPONENT='/Script/Engine.StaticMeshComponent'
V.BIG_DEATH='/Game/FX/Test/NS_EnemyDeathEffectBig.NS_EnemyDeathEffectBig'
-- The game's own boss bar, made exactly as BP_Boss AddBossBar does (Create, CurrentHP/MaxHP/BossName, the HUD's
-- BossBarDaddy). The Create call names its class literally: it is the button guard's one named construction
-- exemption (tools/button_guard.lua NAMED_CONSTRUCT, user-approved 2026-10-13, D43 boss bar); keep it on one line.
function V:_bossBar(info)
    local G=self.world.G
    local lib=G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary');assert(valid(lib),'widget_library_unavailable')
    local bar=lib:Create(self.manager,G.StaticFindObject('/Game/UI/WBP_BossBar.WBP_BossBar_C'),nil)
    assert(valid(bar),'boss_bar_create_failed')
    bar.CurrentHP=info.maxHp;bar.MaxHP=info.maxHp
    if G.FText then bar.BossName=G.FText(info.name) end
    local pawn=G.FindFirstOf and G.FindFirstOf('BP_Player_C')
    local hud=pawn and pawn.HUD
    if not (hud and valid(hud)) then pcall(function()bar:RemoveFromParent()end);error('no_hud') end
    hud.BossBarDaddy:AddChildToWrapBox(bar)
    return bar
end
-- Test 15: a non-boss unique (BP_MiniBoss and its children; a BP_Boss with IsMiniBoss?) shows the game's own 3D bar,
-- made as BP_MiniBoss's construction does (Create WBP_3D_Bar, CurrentHP/MaxHP, SetWidget on its 3D widget component
-- placed 2 x the mesh bounds' Z extent + 100 above). Here the widget component is owned by the controller and follows
-- the visual copy; screen space at its desired size. The Create call names its class literally: it is the button
-- guard's d57_miniboss_bar named construction exemption (tools/button_guard.lua, coordinator-approved 2026-10-13).
V.WIDGET_COMPONENT='/Script/UMG.WidgetComponent'
V.MINI_BAR_FALLBACK_Z=200
local function barHeight(mesh)
    local z
    pcall(function()
        local b=mesh:GetBounds()
        local e=b and b.BoxExtent and b.BoxExtent.Z
        if type(e)=='number' and e==e and e>=0 and e<100000 then z=e*2+100 end
    end)
    return z or V.MINI_BAR_FALLBACK_Z
end
function V:_miniBar(info,row,mesh)
    local G=self.world.G
    local lib=G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary');assert(valid(lib),'widget_library_unavailable')
    local class=G.StaticFindObject(V.WIDGET_COMPONENT);assert(valid(class),'widget_component_class_unavailable')
    local bar=lib:Create(self.manager,G.StaticFindObject('/Game/UI/WBP_3D_Bar.WBP_3D_Bar_C'),nil)
    assert(valid(bar),'miniboss_bar_create_failed')
    bar.CurrentHP=info.maxHp;bar.MaxHP=info.maxHp
    local z=barHeight(mesh)
    local ok,component=pcall(function()return self.manager:AddComponentByClass(class,true,transform({x=row.x,y=row.y,z=z},1),false)end)
    if not (ok and valid(component)) then pcall(function()bar:RemoveFromParent()end);error('miniboss_bar_component_failed') end
    pcall(function()component:SetCollisionEnabled(0)end)
    component:SetWidgetSpace(1)          -- screen space: faces the camera like the game's bar
    component:SetDrawAtDesiredSize(true)
    component:SetWidget(bar)
    return {bar=bar,component=component,z=z}
end
-- Test 15 crash (client ACCESS_VIOLATION at 0x0 about 1 s after the Magmus reward roulette opened): a UE4SS UObject
-- keeps a raw pointer and IsValid reads that same memory. The HUD boss bar belongs to the HUD (BossBarDaddy), not to
-- us: when the game removes it (the reward screen) it is collected and the cached handle dangles. Every bar is
-- re-found among the live widgets of its class right before use (Liveness.Listed); a bar that is gone is forgotten
-- and logged once. The owned components (mesh copy, 3D bar component) are touched only while their controller is
-- proved live (_current): they go with it and are never touched after.
V.BAR_CLASS={boss='WBP_BossBar_C',miniboss='WBP_3D_Bar_C'}
function V:_liveBar(bar,which)
    if bar==nil then return nil end
    local live=Liveness.Listed(self.world.G,bar,V.BAR_CLASS[which])
    if not live then
        self.barGone=self.barGone or {}
        if not self.barGone[which] and self.options.log then
            self.barGone[which]=true
            self.options.log('ACTORVISUAL '..which..' bar gone (removed by the game); never touched again')
        end
    end
    return live
end
-- One log line per refused bar step (create / update / remove); the mesh copy never depends on the bar.
function V:_barRefused(step,why,which)
    self.barRefusals=self.barRefusals or {}
    local key=(which or 'boss')..':'..step
    if self.barRefusals[key] or not self.options.log then return end
    self.barRefusals[key]=true
    self.options.log('ACTORVISUAL '..(which or 'boss')..' bar refused step='..step..' reason='..tostring(why))
end
function V:SetActorVisual(id,row,info)
    local ok,why=pcall(function()
        assert(not self.closing and self:_current(),'changed_or_closing_controller')
        assert(type(row)=='table' and finite(row.x,2000000) and finite(row.y,2000000),'invalid_actor_row')
        local G=self.world.G
        self.actors=self.actors or {}
        local a=self.actors[id]
        if not a then
            local class=G.StaticFindObject(V.ACTOR_COMPONENT);assert(valid(class),'actor_component_class_unavailable')
            local mesh=G.StaticFindObject(info.mesh)
            if not valid(mesh) and type(G.LoadAsset)=='function' then mesh=G.LoadAsset(info.mesh) end
            assert(valid(mesh),'actor_mesh_unavailable')
            local component=self.manager:AddComponentByClass(class,true,transform({x=row.x,y=row.y,z=0},info.scale),false)
            assert(valid(component),'actor_component_failed')
            component:SetCollisionEnabled(0);component:SetMobility(2)
            assert(component:SetStaticMesh(mesh)~=false,'actor_mesh_assignment_failed')
            a={component=component,x=row.x,y=row.y,hp=row.hp,yaw=0}
            self.actors[id]=a
            if info.kind=='boss' then
                local okBar,bar=pcall(self._bossBar,self,info)
                if okBar then a.bar=bar else self:_barRefused('create',bar) end
            else
                local okBar,mini=pcall(self._miniBar,self,info,row,mesh)
                if okBar then a.mini=mini else self:_barRefused('create',mini,'miniboss') end
            end
        end
        local dx,dy=row.x-a.x,row.y-a.y
        if dx*dx+dy*dy>1 then a.yaw=math.deg(math.atan(dy,dx)) end
        a.x,a.y=row.x,row.y
        a.component:K2_SetWorldLocationAndRotation({X=row.x,Y=row.y,Z=0},{Pitch=0,Yaw=a.yaw,Roll=0},false,{},false)
        if a.mini then
            local okMove,why=pcall(function()a.mini.component:K2_SetWorldLocation({X=row.x,Y=row.y,Z=a.mini.z},false,{},false)end)
            if not okMove then self:_barRefused('move',why,'miniboss') end
        end
        if type(row.hp)=='number' and type(a.hp)=='number' and row.hp<a.hp then
            pcall(function()
                local time=G.StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'):GetGameTimeInSeconds(self.manager)
                a.component:SetCustomPrimitiveDataFloat(3,time)
            end)
            if a.bar then
                local bar=self:_liveBar(a.bar,'boss')
                if not bar then a.bar=nil
                else
                    local okBar,why=pcall(function()bar:UpdateBar(row.hp)end)
                    if not okBar then self:_barRefused('update',why) end
                end
            end
        end
        -- the 3D bar shows the host HP on every change (a host heal too)
        if a.mini and type(row.hp)=='number' and type(a.hp)=='number' and row.hp~=a.hp then
            local bar=self:_liveBar(a.mini.bar,'miniboss')
            if not bar then a.mini.bar=nil
            else
                local okBar,why=pcall(function()bar:UpdateBar(row.hp)end)
                if not okBar then self:_barRefused('update',why,'miniboss') end
            end
        end
        if type(row.hp)=='number' then a.hp=row.hp end
    end)
    return ok,ok and nil or tostring(why)
end
function V:RemoveActorVisual(id,dead,x,y)
    local a=self.actors and self.actors[id]
    if not a then return true end
    self.actors[id]=nil
    -- removal is idempotent (forgotten first) and touches only what is proved live
    local bar=self:_liveBar(a.bar,'boss')
    if bar then
        local okBar,why=pcall(function()bar:RemoveFromParent()end)
        if not okBar then self:_barRefused('remove',why) end
    end
    local owned=not self.closing and self:_current()
    if a.mini then
        local mini=self:_liveBar(a.mini.bar,'miniboss')
        if mini then
            local okBar,why=pcall(function()mini:RemoveFromParent()end)
            if not okBar then self:_barRefused('remove',why,'miniboss') end
        end
        if owned then pcall(function()a.mini.component:K2_DestroyComponent(a.mini.component)end) end
    end
    if not owned then return true end   -- the controller is gone: its components went with it
    pcall(function()a.component:K2_DestroyComponent(a.component)end)
    if dead and finite(x,2000000) and finite(y,2000000) then
        pcall(function()
            local system=self.world.G.StaticFindObject(V.BIG_DEATH)
            niagara(self):SpawnSystemAtLocation(self.manager,system,{X=x,Y=y,Z=0},{Pitch=0,Yaw=0,Roll=0},{X=1,Y=1,Z=1},true,true,0,true)
        end)
    end
    return true
end
function V:VerifyEnemy(id,row)
    local ok,why=pcall(function()
        assert(self:_current(),'changed_controller')
        local binding=assert(self.slots[id],'missing_owned_lifetime')
        local group=assert(self.groups[binding.kind],'missing_owned_group')
        assert(binding.kind==row.enemyType and valid(group.component),'changed_owned_type')
        local out=transform({x=0,y=0,z=0},0)
        assert(group.component:GetInstanceTransform(binding.index,out,true)==true,'owned_instance_readback_failed')
        for _,axis in ipairs({'X','Y','Z'})do
            local wanted=axis=='X' and row.x or (axis=='Y' and row.y or row.z)
            assert(finite(out.Translation[axis],2000000) and math.abs(out.Translation[axis]-wanted)<=.001,'owned_instance_position_mismatch')
            assert(finite(out.Scale3D[axis],1000000) and math.abs(out.Scale3D[axis]-group.scale)<=.0001,'owned_instance_scale_mismatch')
        end
    end)
    return ok,ok and nil or tostring(why)
end
function V:RemoveEnemy(id)
    local binding=self.slots[id];if not binding then return true end
    local group=self.groups[binding.kind]
    local ok,why=pcall(function()
        assert(self:_current() and group and valid(group.component),'lost_owned_component')
        -- Do not RemoveInstance: swap/shift compaction varies by engine version.
        -- A zero-scale hidden slot remains ours and can be reused for a new ID.
        assert(group.component:UpdateInstanceTransform(binding.index,transform({x=0,y=0,z=0},0),true,true,true)==true,'owned_instance_hide_failed')
        local out=transform({x=0,y=0,z=0},1)
        assert(group.component:GetInstanceTransform(binding.index,out,true)==true,'owned_instance_hide_readback_failed')
        for _,axis in ipairs({'X','Y','Z'})do assert(out.Scale3D[axis]==0,'owned_instance_hide_mismatch')end
    end)
    if ok then
        self.slots[id]=nil;self.count=self.count-1;group.free[#group.free+1]=binding.index
        group.transforms=group.transforms or {};group.transforms[binding.index]=transform({x=0,y=0,z=0},0)
        if self.framePending and self.framePending[group] then self.framePending[group][binding.index]=nil end
    end
    return ok,ok and nil or tostring(why)
end
-- The level that held this presentation is gone (its components and the local horde meshes were freed with it):
-- drop every reference WITHOUT an engine call; the next Bind starts clean. Never use while the level is live.
function V:Forget()
    self.actors={}   -- the level is gone: its actor copies went with it (never touched)
    self.context,self.manager,self.managerName,self.closing=nil,nil,nil,nil
    self.groups,self.slots,self.count,self.allocated={},{},0,0
    self.visibilityLedger,self.localSuppression,self.originalComponents=nil,nil,nil
    self.templates,self.catalog,self.componentClass=nil,nil,nil
end
function V:Clear()
    -- D43: the visual copies of bosses/uniques go with the island (no death effect)
    for id in pairs(self.actors or {}) do self:RemoveActorVisual(id,false) end
    self.closing=true
    local clean=true;local pending=false
    if self.context and next(self.visibilityLedger or {}) then clean=self:SuppressLocalMeshes(false)==true end
    for _,group in pairs(self.groups) do
        if valid(group.component) then
            if not group.destroyRequested then
                group.destroyRequested=true
                local ownerOK,owner=pcall(group.component.GetOwner,group.component)
                if not ownerOK or safeName(owner)~=self.managerName then
                    group.destroyFailed=true
                end
                if self.options.log then
                    local outerOK,outer=pcall(function()return safeName(group.component:GetOuter())end)
                    self.options.log('SDKINSTANCE cleanup_component='..tostring(safeName(group.component) or 'unavailable')
                        ..' manager='..tostring(safeName(self.manager) or 'unavailable')
                        ..' outer='..tostring(outerOK and outer or 'unavailable'))
                end
                -- Owning actor supplies the Object authority argument. Do not
                -- pass bPromoteChildren: that belongs to the C++-only method.
                local ok,result=false,'unverified_owner'
                if not group.destroyFailed then ok,result=pcall(group.component.K2_DestroyComponent,group.component,owner)end
                if self.options.log then self.options.log('SDKINSTANCE destroy_call_ok='..tostring(ok)..' result='..tostring(result):sub(1,128))end
                if not ok then group.destroyFailed=true end
            end
            if group.destroyFailed then clean=false
            elseif valid(group.component) then
                -- UE4SS IsValid checks reachability, so a destroyed component
                -- can remain valid until GC while the world is paused. The
                -- destruction flag is diagnostic; exact native owner-list
                -- removal supplies the durable retirement proof below.
                local checked,destroyed=pcall(group.component.IsBeingDestroyed,group.component)
                if not group.destroyReadbackLogged and self.options.log then
                    group.destroyReadbackLogged=true
                    self.options.log('SDKINSTANCE destroy_readback_checked='..tostring(checked)
                        ..' value='..tostring(destroyed):sub(1,128)..' valid='..tostring(valid(group.component)))
                end
                if not checked or type(destroyed)~='boolean' then clean=false;group.destroyFailed=true
                else
                    -- Destruction-in-progress is not durable completion. The
                    -- known owner must have removed this exact component from
                    -- its bounded native component set after the destroy call.
                    local listedOK,listed=pcall(function()
                        local wanted=assert(safeName(group.component),'owned_component_name_missing')
                        local items=self.manager:K2_GetComponentsByClass(self.componentClass)
                        -- UFunction array returns use GetNonTrivialLocal:
                        -- SDK creates a dense 1-based Lua table. Its object
                        -- elements use GetParam remote wrappers (:get()),
                        -- unlike the property TArray's ForEach interface.
                        assert(type(items)=='table','owner_components_return_type')
                        local length=#items;assert(length<=8192,'owner_components_bound')
                        local count=0
                        for index in pairs(items) do
                            count=count+1
                            assert(count<=8192 and type(index)=='number' and index%1==0
                                and index>=1 and index<=length,'owner_components_return_key')
                        end
                        assert(count==length,'owner_components_return_sparse')
                        -- Detach every wrapper immediately, before any other
                        -- engine query or diagnostic can reuse return storage.
                        local objects={}
                        for index=1,length do
                            local parameter=items[index]
                            assert(parameter and type(parameter.get)=='function','owner_component_parameter_missing')
                            objects[index]=parameter:get()
                            assert(objects[index]~=nil,'owner_component_invalid')
                        end
                        local found=false
                        for index=1,length do
                            local object=objects[index];assert(valid(object),'owner_component_invalid')
                            local name=assert(safeName(object),'owner_component_name_missing')
                            if name==wanted then found=true end
                        end
                        if self.options.log and not group.ownerListLogged then
                            group.ownerListLogged=true
                            self.options.log('SDKINSTANCE owner_list_count='..length..' owned_present='..tostring(found))
                        end
                        return found
                    end)
                    if not listedOK then
                        clean=false;group.destroyFailed=true
                        if self.options.log then self.options.log('SDKINSTANCE cleanup_owner_list_error='..tostring(listed):sub(1,256))end
                    elseif listed then clean=false;pending=true end
                end
            end
        end
    end
    if clean then
        self.slots,self.groups,self.count,self.allocated={}, {},0,0
        self.context,self.manager,self.managerName,self.templates,self.componentClass=nil,nil,nil,nil,nil
        self.originalComponents,self.visibilityLedger={},{};self.closing=false
    end
    return clean,pending and 'component_cleanup_pending' or (not clean and 'component_cleanup_failed' or nil)
end
return V
