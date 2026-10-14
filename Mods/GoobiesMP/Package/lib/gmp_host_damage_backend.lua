-- Resolver adapter for real host-owned bindings. No client damage, native
-- address, item identity or HP is accepted here; intent authentication remains
-- in the host session. Uncertain native writes hold the context until rebound.
local Hit=require('gmp_host_hit_information')
local B={};B.__index=B
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function position(p)return type(p)=='table' and finite(p.x) and finite(p.y) and finite(p.z) end
local function copy(t)
 if type(t)~='table' then return t end
 local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
function B.new(authority,pawns,inventory,enemies,native)
 for _,spec in ipairs({{authority,{'Context','Role'}},{pawns,{'Get'}},
   {inventory,{'Verified','Attack'}},{enemies,{'Get','Verified'}},{native,{'Bound','ApplyHostHit'}}}) do
  local source,names=spec[1],spec[2]
  assert(type(source)=='table','missing_host_damage_binding')
  for _,name in ipairs(names)do assert(type(source[name])=='function','missing_host_damage_method:'..name)end
 end
 return setmetatable({authority=authority,pawns=pawns,inventory=inventory,enemies=enemies,native=native,holds={}},B)
end
function B:Context()return self.authority:Context()end
function B:Ready(context)
 return type(context)=='string' and self:Context()==context and self.authority:Role()=='host'
  and not self.holds[context] and self.inventory:Verified(context)==true
  and self.enemies:Verified(context)==true and self.native:Bound(context)==true
end
function B:PeerPawn(peer,context)
 if not self:Ready(context)then return nil end
 return copy(self.pawns:Get(peer,context))
end
function B:AttackState(peer,attack,context)
 if not self:Ready(context)then return nil end
 return copy(self.inventory:Attack(peer,attack,context))
end
function B:Enemy(id,context)
 if not self:Ready(context)then return nil end
 return copy(self.enemies:Get(id,context))
end
function B:ApplyHit(context,pawn,enemy,weapon,sequence)
 if not self:Ready(context)then return false end
 -- Compare again with the actual host providers after resolver reads. The
 -- native binding is obtained here from the lifetime ledger, never a packet.
 local currentPawn=self.pawns:Get(pawn.peer,context)
 local currentEnemy=self.enemies:Get(enemy.id,context)
 local currentWeapon=self.inventory:Attack(pawn.peer,weapon.attack,context)
 if type(currentPawn)~='table' or currentPawn.context~=context or currentPawn.peer~=pawn.peer
  or currentPawn.identity~=pawn.identity
  or type(currentEnemy)~='table' or currentEnemy.context~=context or currentEnemy.dead~=false
  or currentEnemy.id~=enemy.id or currentEnemy.nativeLifetime~=enemy.nativeLifetime
  or type(currentEnemy.nativeLifetime)~='string' or currentEnemy.nativeLifetime==''
  or type(currentWeapon)~='table' or currentWeapon.context~=context
  or currentWeapon.peer~=pawn.peer or currentWeapon.attack~=weapon.attack
  or currentWeapon.weaponIdentity~=weapon.weaponIdentity
  or currentWeapon.inventoryRevision~=weapon.inventoryRevision
  or currentWeapon.critRevision~=weapon.critRevision
  or currentWeapon.pawnIdentity~=currentPawn.identity
  or currentWeapon.cooldown~=weapon.cooldown then return false end
 -- Resolver snapshots may have moved during provider reads. Check the fresh
 -- host positions and range before building the native hit, preserving the
 -- resolver's reserved cooldown rather than accepting a changed cooldown.
 if not position(currentPawn.position) or not position(currentEnemy.position)
  or not finite(currentWeapon.range) or currentWeapon.range<0 or currentWeapon.range>1e7
  then return false end
 local dx=currentPawn.position.x-currentEnemy.position.x
 local dy=currentPawn.position.y-currentEnemy.position.y
 local dz=currentPawn.position.z-currentEnemy.position.z
 if dx*dx+dy*dy+dz*dz>currentWeapon.range*currentWeapon.range then return false end
 local info,radius=Hit.Build(context,currentPawn,currentEnemy,currentWeapon)
 if not info or not self:Ready(context)then return false end
 local ok,result=pcall(self.native.ApplyHostHit,self.native,context,currentEnemy.nativeLifetime,
  info,radius,currentWeapon.weaponIdentity,currentWeapon.inventoryRevision,sequence)
 if not ok or result~=true then self.holds[context]=true;return false end
 return true
end
return B
