-- Ordinary-enemy cosmetic renderer candidate. Uses the same evidenced
-- StaticMeshActor operations as gmp_world's runtime-tested remote avatars.
-- Diagnostic cap only: per-enemy actors are not the final 4096-horde renderer.
-- No native enemy records, damage, collision, rewards, timers or AI are written.
local V={};V.__index=V
local function valid(o)return o and o:IsValid()==true end
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
function V.new(world,options)
    options=options or {};local cap=options.cap or 32
    assert(type(cap)=='number' and cap%1==0 and cap>=1 and cap<=128,'invalid_visual_cap')
    return setmetatable({world=world,cap=cap,actors={},count=0},V)
end
function V:Bind(context)
    if self.context then return false,'already_bound' end
    local ok,why=pcall(function()
        assert(type(context)=='string' and context~='','invalid_context')
        local manager=self.world:_enemyController();assert(valid(manager),'missing_controller')
        local components={};assert(#manager.AllInstanceComponents<=64,'component_limit')
        manager.AllInstanceComponents:ForEach(function(_,element)components[#components+1]=element:get()end)
        local templates={};assert(#manager.enemyClasses<=64,'class_limit')
        manager.enemyClasses:ForEach(function(luaIndex,element)
            local classIndex=luaIndex-1 -- actual UE4SS callback ordinal, not native enemyType.
            local row=element:get();local index=row.meshIndex
            assert(type(index)=='number' and index%1==0 and index>=0 and index<64,'invalid_mesh_index')
            if classIndex>=0 and classIndex<=12 then
                local component=components[index+1]
                assert(valid(component) and valid(component.StaticMesh),'missing_class_mesh')
                assert(finite(row.Scale) and row.Scale>0 and row.Scale<=100,'invalid_mesh_scale')
                assert(not templates[classIndex],'duplicate_class_index')
                templates[classIndex]={component=component,mesh=component.StaticMesh,scale=row.Scale}
            end
        end)
        assert(next(templates),'no_ordinary_templates')
        self.templates,self.managerName,self.context=templates,manager:GetFullName(),context
    end)
    return ok,ok and nil or tostring(why)
end
function V:_current()
    local manager=self.world:_enemyController()
    return self.context and valid(manager) and manager:GetFullName()==self.managerName
end
function V:SetEnemy(id,row)
    local ok,why=pcall(function()
        assert(self:_current(),'changed_controller')
        assert(type(id)=='string' and #id<=32 and id:match('^%d+:%d+$'),'invalid_visual_id')
        assert(type(row)=='table' and finite(row.x) and math.abs(row.x)<=2000000
            and finite(row.y) and math.abs(row.y)<=2000000 and finite(row.z) and math.abs(row.z)<=100000,'invalid_visual_position')
        local template=self.templates[row.enemyType];assert(template,'unsupported_actor_enemy')
        local actor=self.actors[id]
        if not valid(actor) then
            if actor then self.actors[id]=nil;self.count=self.count-1 end
            assert(self.count<self.cap,'visual_capacity')
            local world=self.world:_world();assert(valid(world),'missing_world')
            actor=world:SpawnActor(self.world.G.StaticFindObject('/Script/Engine.StaticMeshActor'),
                {X=row.x,Y=row.y,Z=row.z},{Pitch=0,Yaw=0,Roll=0})
            assert(valid(actor),'spawn_failed')
            -- Record before setup so RemoveEnemy disposes partially created actors.
            self.actors[id]=actor;self.count=self.count+1
            local component=actor.StaticMeshComponent
            component:SetCollisionEnabled(0);component:SetMobility(2)
            assert(component:SetStaticMesh(template.mesh)~=false,'mesh_assignment_failed')
            component:SetMaterial(0,template.component:GetMaterial(0))
            actor:SetActorScale3D({X=template.scale,Y=template.scale,Z=template.scale})
        end
        actor:K2_SetActorLocation({X=row.x,Y=row.y,Z=row.z},false,{},true)
    end)
    self.lastError=ok and nil or tostring(why):sub(1,500)
    return ok,self.lastError
end
function V:RemoveEnemy(id)
    local actor=self.actors[id];if not actor then return true end
    if valid(actor) then
        local ok=pcall(actor.K2_DestroyActor,actor)
        if not ok then return false end
    end
    self.actors[id]=nil;self.count=self.count-1;return true
end
function V:Clear()
    local ids={};for id in pairs(self.actors)do ids[#ids+1]=id end
    for _,id in ipairs(ids)do if not self:RemoveEnemy(id)then return false end end
    self.context,self.templates,self.managerName=nil,nil,nil;return true
end
return V
