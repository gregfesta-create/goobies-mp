-- Host-only HitInformation preparation. Intent packets supply no damage,
-- position, crit decision, item identity or native struct fields.
local H={}
local function finite(v,b)return type(v)=='number' and v==v and math.abs(v)<=b end
local function integer(v,lo,hi)return finite(v,hi) and v%1==0 and v>=lo end
function H.Build(context,pawn,enemy,weapon)
 if type(context)~='string' or #context==0 or #context>256 or type(pawn)~='table'
  or type(enemy)~='table' or type(weapon)~='table' then return nil,'invalid_host_hit_context' end
 if pawn.context~=context or enemy.context~=context or weapon.context~=context
  or pawn.identity~=weapon.pawnIdentity or weapon.inventoryVerified~=true
  or weapon.nativeWeaponSnapshotVerified~=true or type(weapon.weaponIdentity)~='string'
  or #weapon.weaponIdentity==0 or not integer(weapon.inventoryRevision,1,9007199254740991)
  or not integer(weapon.critRevision,1,9007199254740991) then return nil,'host_weapon_evidence_missing' end
 local info=weapon.hitInformation
 if type(info)~='table' or not finite(weapon.damage,1e12) or weapon.damage<=0
  or not finite(info.knockback,1e6) or info.knockback<0
  or not finite(info.lifetime,3600) or info.lifetime<0
  or not integer(info.itemTypeIndex,-1,2147483647) or not integer(info.Value,0,2147483647)
  or not finite(info.HitChance,1e6) or info.HitChance<0
  or type(info.sendHitEvent)~='boolean' or type(info.wasCrit)~='boolean'
  or type(info.wasMegaCrit)~='boolean' or (info.wasMegaCrit and not info.wasCrit)
  or not integer(weapon.radius,0,100000) then return nil,'host_hit_fields_unverified' end
 local a,b=pawn.position,enemy.position
 if type(a)~='table' or type(b)~='table' or not finite(a.x,2000000) or not finite(a.y,2000000)
  or not finite(b.x,2000000) or not finite(b.y,2000000) or enemy.dead~=false
  or not finite(enemy.hp,1e12) or enemy.hp<=0 then return nil,'host_hit_lifetime_stale' end
 local x,y=b.x-a.x,b.y-a.y;local length=math.sqrt(x*x+y*y)
 local dx,dy=0,0;if length>0 then dx,dy=x/length,y/length end
 return {Damage=weapon.damage,knockback=info.knockback,HitLocation={X=b.x,Y=b.y},Direction={X=dx,Y=dy},
  lifetime=info.lifetime,itemTypeIndex=info.itemTypeIndex,sendHitEvent=info.sendHitEvent,
  HitChance=info.HitChance,Value=info.Value,wasCrit=info.wasCrit,wasMegaCrit=info.wasMegaCrit},weapon.radius
end
return H
