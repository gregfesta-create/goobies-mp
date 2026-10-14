-- Owned XP presentation only: never native XPP, ConsumeXP or AddExperience.
local P={};P.__index=P
local function t(r,scale)return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=r.x,Y=r.y,Z=r.z},Scale3D={X=scale,Y=scale,Z=scale}}end
function P.new(options)return setmetatable({o=assert(options),slots={},free={},allocated=0,retired={},retiredCount=0},P)end
function P:_bound()
 assert(self.o.authorize()==true and self.o.owned()==true,'pickup_native_ownership_changed')
 assert(self.o.component:IsValid()==true,'pickup_component_invalid')
 assert(self.o.component:GetInstanceCount()==self.allocated,'pickup_native_count_changed')
end
function P:ApplyPickup(row)
 if self.failed then return false,self.failed end
 local write=false;local ok,why=pcall(function()
  self:_bound();assert(type(row.amount)=='number' and row.amount%1==0 and row.amount>=1 and row.amount<=1000000000,'pickup_amount_invalid')
  for _,k in ipairs({'x','y','z'})do assert(type(row[k])=='number' and row[k]==row[k] and math.abs(row[k])<=(k=='z' and 100000 or 2000000),'pickup_position_invalid')end
  assert(row.kind=='xp' and type(row.id)=='string' and row.id:match('^%d+:%d+$'),'pickup_identity_invalid')
  local epoch=row.id:match('^(%d+):');self.epoch=self.epoch or epoch;assert(epoch==self.epoch,'pickup_epoch_changed')
  local slot=self.slots[row.id]
  if row.state=='retired' then
   if slot then assert(slot.amount==row.amount,'pickup_amount_changed')end
   if not self.retired[row.id] then assert(self.retiredCount<65536,'pickup_retirement_capacity');self.retired[row.id]=row.amount;self.retiredCount=self.retiredCount+1
   else assert(self.retired[row.id]==row.amount,'pickup_retired_amount_changed')end
   if not slot then return end
   assert(slot.amount==row.amount,'pickup_amount_changed');write=true
   assert(self.o.component:UpdateInstanceTransform(slot.index,t(row,0),true,true,true)==true,'pickup_hide_failed')
   local out=t(row,1);assert(self.o.component:GetInstanceTransform(slot.index,out,true)==true,'pickup_hide_unreadable')
   for _,a in ipairs({'X','Y','Z'})do assert(out.Scale3D[a]==0,'pickup_hide_mismatch')end
   self:_bound();self.slots[row.id]=nil;self.free[#self.free+1]=slot.index
  else
   assert(row.state=='born','pickup_state_invalid');assert(not self.retired[row.id],'pickup_lifetime_retired')
   if slot then assert(slot.amount==row.amount,'pickup_amount_changed')else
    local index=table.remove(self.free)
    if not index then
     assert(self.allocated<(self.o.cap or 8192),'pickup_capacity');write=true
     index=self.o.component:AddInstance(t(row,0),true)
     assert(type(index)=='number' and index%1==0 and index>=0 and index<(self.o.cap or 8192),'pickup_add_failed')
     assert(index==self.allocated and self.o.component:GetInstanceCount()==self.allocated+1,'pickup_add_not_append')
     for _,other in pairs(self.slots)do assert(other.index~=index,'pickup_add_alias')end
     self.allocated=self.allocated+1
    end
    slot={index=index,amount=row.amount};self.slots[row.id]=slot
   end
   write=true;assert(self.o.component:UpdateInstanceTransform(slot.index,t(row,1),true,true,true)==true,'pickup_update_failed')
  end
  self:_bound()
 end)
 if not ok then if write then self.failed=tostring(why)end;return false,tostring(why)end
 return true
end
function P:VerifyPickup(row)
 local ok,why=pcall(function()
  self:_bound();local slot=self.slots[row.id]
  if row.state=='retired' then assert(not slot,'pickup_still_present');return end
  assert(slot and slot.amount==row.amount,'pickup_lifetime_missing')
  local out=t(row,0);assert(self.o.component:GetInstanceTransform(slot.index,out,true)==true,'pickup_readback_failed')
  for _,a in ipairs({'X','Y','Z'})do
   local expected=a=='X' and row.x or (a=='Y' and row.y or row.z)
   assert(type(out.Translation[a])=='number' and math.abs(out.Translation[a]-expected)<=.001,'pickup_position_mismatch')
   assert(out.Scale3D[a]==1,'pickup_scale_mismatch')
  end
  self:_bound()
 end)
 return ok,ok and nil or tostring(why)
end
return P
