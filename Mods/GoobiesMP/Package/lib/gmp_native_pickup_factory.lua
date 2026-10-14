-- Canonical controller XP template; own component lifecycle uses the audited
-- ordinary view engine routes. Native XP component is never modified.
local View=require('gmp_native_enemy_instances');local Pickup=require('gmp_native_pickup_instances')
local F={};F.__index=F
local retained={} -- Strong ownership published before any native component creation.
function F.new(world,options)
 return setmetatable({world=assert(world),o=assert(options),view=View.new(world,{cap=options.cap or 4096})},F)
end
function F:Bind(context)
 if self.started then return false,'pickup_factory_already_started' end
 self.started=true;retained[self]=true
 local ok,why=pcall(function()
  assert(self.o.authorize(context)==true,'pickup_factory_authority_unavailable')
  assert(self.view:Bind(context)==true,'pickup_factory_engine_schema_unavailable')
  local manager=self.view.manager;local source=manager.XPInstanceComponent
  assert(source and source:IsValid()==true,'pickup_template_missing')
  local owner=source:GetOwner();assert(owner and owner:IsValid()==true and owner:GetFullName()==self.view.managerName,'pickup_template_foreign_owner')
  local mesh=source.StaticMesh;assert(mesh and mesh:IsValid()==true,'pickup_template_mesh_missing')
  local material=source:GetMaterial(0);assert(material and material:IsValid()==true,'pickup_template_material_missing')
  assert(self.o.authorize(context)==true and self.view:_current()==true and self:_currentController(),'pickup_factory_context_changed')
  self.view.templates[0]={mesh=mesh,material=material,scale=1}
  local group=self.view:_group(0) -- Ownership recorded before native configuration.
  assert(group.component:GetInstanceCount()==0,'pickup_owned_component_not_empty')
  self.backend=Pickup.new{component=group.component,cap=self.view.cap,
   authorize=function()return self.o.authorize(context)==true end,
   owned=function()return self.view:_current() and group.ownerVerified and group.configured and not self.view.closing
    and self:_ownedComponent(group.component) end}
  self.context=context
 end)
 if not ok then
  self.failure=tostring(why)
  local clean,cleared=pcall(self.Clear,self)
  if not clean or cleared~=true then self.cleanupPending=true end
 end
 return ok,ok and self.backend or tostring(why)
end
function F:_currentController()
 local current=self.world:_enemyController()
 return current and current:IsValid()==true and current:GetFullName()==self.view.managerName
end
function F:_ownedComponent(component)
 local owner=component:GetOwner()
 return owner and owner:IsValid()==true and owner:GetFullName()==self.view.managerName
end
function F:Clear()
 -- Keep factory/view strongly owned until Clear returns true. Failed native
 -- destruction retains component identity and can be polled after withdrawal.
 local ok,why=self.view:Clear();if ok then self.backend=nil;self.context=nil;self.cleanupPending=false;retained[self]=nil end;return ok,why
end
function F.CleanupRetained()
 local failed=0
 for factory in pairs(retained)do
  if factory.failure then local ok,clean=pcall(factory.Clear,factory);if not ok or clean~=true then failed=failed+1 end end
 end
 return failed==0,failed
end
return F
