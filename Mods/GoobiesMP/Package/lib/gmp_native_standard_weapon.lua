-- Read actual host-owned standard weapon fields. This is not an inventory
-- grant, crit decision, client attack handler or permission to apply damage.
local W={}
W.ClassPath='/Game/Blueprints/Abilities/NewStuff/AllPassives/Actives/BP_StandardActive.BP_StandardActive_C'
local function valid(o)return o and o:IsValid()==true end
local function same(a,b)return valid(a) and valid(b) and a:GetFullName()==b:GetFullName()end
local function finite(n,b)return type(n)=='number' and n==n and math.abs(n)<=b end
local function path(o)
 local name=o:GetFullName();assert(type(name)=='string' and #name<=1024,'weapon_name_bound')
 return assert(name:match('^%S+ (.+)$'),'weapon_canonical_name_missing')
end
local function field(statics,object,name,kind)
 local class=statics:GetObjectClass(object);local seen={};local depth,count=0,0;local found;local nearby={}
 while valid(class) do
  depth=depth+1;assert(depth<=32 and not seen[class:GetFullName()],'weapon_class_cycle')
  seen[class:GetFullName()]=true
  class:ForEachProperty(function(p)
   count=count+1;assert(count<=512,'weapon_property_bound')
   local actualName=p:GetFName():ToString()
   if #nearby<8 and actualName:lower():find('component',1,true) then
    nearby[#nearby+1]=actualName:sub(1,64)..'/'..p:GetClass():GetFName():ToString()
   end
   if not found and p:GetFName():ToString()==name then found=p end
  end)
  if found then break end
  class=class:GetSuperStruct()
 end
 local actual=found and found:GetClass():GetFName():ToString() or 'missing'
 assert(found and actual==kind,'weapon_field_signature:'..name..':expected='..kind..':actual='..actual
  ..':value='..tostring(found and object[name]):sub(1,64)..':nearby='..table.concat(nearby,','))
 return object[name]
end
function W.Capture(world,authority,peer,ordinal,context)
 local ok,result=pcall(function()
  assert(type(context)=='string' and #context>0 and #context<=256,'weapon_context')
  assert(type(peer)=='string' and #peer>0 and #peer<=64,'weapon_peer')
  assert(authority:Role()=='host' and authority:Context()==context
   and authority:LocalPeer()==peer,'weapon_host_local_peer_required')
  assert(type(ordinal)=='number' and ordinal%1==0 and ordinal>=1 and ordinal<=64,'weapon_ordinal')
  local currentWorld=world:_world();local pawn=currentWorld and world:_pawn(currentWorld)
  assert(valid(currentWorld),'weapon_world_missing')
  assert(valid(pawn) and pawn.PlayerIsDead==false,'weapon_pawn_dead_or_missing')
  local items=pawn.PlayerItemsActors;assert(items and #items<=64,'weapon_inventory_bound')
  local actor
  items:ForEach(function(index,entry)if index==ordinal then actor=entry:get()end end)
  assert(valid(actor),'weapon_inventory_actor_missing')
  local statics=world:_statics();assert(valid(statics),'weapon_statics_missing')
  local class=statics:GetObjectClass(actor)
  assert(valid(class) and path(class)==W.ClassPath,'unsupported_weapon_class')
  local actorPath=path(actor);local pawnName=pawn:GetFullName()
  assert(same(field(statics,actor,'As BP Player','ObjectProperty'),pawn),'weapon_pawn_ownership')
  local component=field(statics,actor,'BPC_DamageComponent','ObjectProperty')
  assert(valid(component) and path(component):sub(1,#actorPath+1)==actorPath..'.','weapon_component_ownership')
  -- Decoded ShootNormal@1188 and ShootDir@293 use this sum. Actor.Damage
  -- is only the initialization source and can be stale after upgrades.
  local damage=field(statics,component,'Damage','DoubleProperty')
  local bonus=field(statics,pawn,'ProjectileBonusDamage','DoubleProperty')
  local radius=field(statics,actor,'ProjectileRadius','IntProperty')
  local knockback=field(statics,actor,'ProjectileKnockback','IntProperty')
  local lifetime=field(statics,actor,'ProjectileLifetime','FloatProperty')
  local componentIndex=field(statics,actor,'ComponentIndex','IntProperty')
  assert(finite(damage,1e12) and finite(bonus,1e12) and finite(damage+bonus,1e12)
   and damage+bonus>0,'weapon_damage_bound')
  assert(finite(radius,100000) and radius%1==0 and radius>=0,'weapon_radius_bound')
  assert(finite(knockback,1e6) and knockback%1==0 and knockback>=0,'weapon_knockback_bound')
  assert(finite(lifetime,3600) and lifetime>=0,'weapon_lifetime_bound')
  assert(finite(componentIndex,4095) and componentIndex%1==0 and componentIndex>=0,'weapon_component_index_bound')
  local current=world:_pawn(world:_world());local selected
  assert(valid(current) and same(current,pawn) and current.PlayerIsDead==false,'weapon_pawn_changed')
  assert(same(world:_world(),currentWorld) and authority:Role()=='host'
   and authority:Context()==context and authority:LocalPeer()==peer,'weapon_context_changed')
  current.PlayerItemsActors:ForEach(function(index,entry)if index==ordinal then selected=entry:get()end end)
  assert(same(selected,actor) and valid(actor) and valid(component),'weapon_inventory_changed')
  assert(same(actor['As BP Player'],pawn) and same(actor.BPC_DamageComponent,component)
   and component.Damage==damage and pawn.ProjectileBonusDamage==bonus
   and actor.ProjectileRadius==radius and actor.ProjectileKnockback==knockback
   and actor.ProjectileLifetime==lifetime and actor.ComponentIndex==componentIndex,'weapon_fields_changed')
  return {context=context,peer=peer,pawnIdentity=pawnName,weaponIdentity=actor:GetFullName(),
   damageComponent=component:GetFullName(),componentIndex=componentIndex,ordinal=ordinal,
   damage=damage+bonus,componentDamage=damage,bonusDamage=bonus,radius=radius,
   knockback=knockback,lifetime=lifetime,mode='ShootNormal',HitChance=1,Value=0,
   itemTypeIndex=0,sendHitEvent=true,nativeFieldsCaptured=true,
   inventoryVerified=false,critVerified=false,runtimeReady=false}
 end)
 if not ok then return nil,tostring(result):sub(1,512) end
 return result
end
return W
