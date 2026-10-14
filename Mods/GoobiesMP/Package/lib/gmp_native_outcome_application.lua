-- Native transform readback proves presentation, not native HP. Commit must bind
-- the host HP/death cache receipt to the same actual authority/controller context.
local A={};A.__index=A
local function dense(rows)
 if type(rows)~='table' or #rows>128 then return false end
 local count=0;for k in pairs(rows)do if type(k)~='number' or k%1~=0 or k<1 or k>#rows then return false end;count=count+1 end
 return count==#rows
end
function A.new(options)return setmetatable({o=assert(options)},A)end
function A:BindPickupFactory(factory,context)
 if self.failed or self.o.pickups or self.pickupFactory then return false,'outcome_pickup_already_bound' end
 -- Retain the factory before Bind may create native components.
 self.pickupFactory=assert(factory)
 local ok,backend=factory:Bind(context)
 if not ok then self.failed=tostring(backend);return false,self.failed end
 self.o.pickups=backend;return true
end
function A:CleanupPickups()
 if not self.pickupFactory then return true end
 local ok,why=self.pickupFactory:Clear()
 if ok then self.o.pickups=nil;self.pickupFactory=nil end
 return ok,why
end
function A:_proof(batch)
 assert(self.o.authorize(batch)==true,'native_client_host_receipt_unavailable')
 assert(self.o.suppression(batch)==true,'native_client_simulation_not_suppressed')
end
function A:ApplyOutcome(batch)
 if self.failed then return false,self.failed end
 local wrote=false
 local ok,why=pcall(function()
  assert(type(batch)=='table' and dense(batch.enemies) and dense(batch.pickups)
   and #batch.enemies+#batch.pickups<=128,'invalid_native_outcome')
  self:_proof(batch)
  assert(type(self.o.enemies)=='table' and type(self.o.enemies.VerifyEnemy)=='function','native_enemy_readback_unavailable')
  -- Preflight every domain before any native mutation.
  assert(self.o.preflight(batch)==true,'native_outcome_schema_unavailable')
  if #batch.pickups>0 then
   assert(type(self.o.pickups)=='table' and type(self.o.pickups.ApplyPickup)=='function'
    and type(self.o.pickups.VerifyPickup)=='function','native_pickup_application_unavailable')
  end
  for _,row in ipairs(batch.enemies)do
   self:_proof(batch);wrote=true
   local applied,detail
   if row.dead then applied,detail=self.o.enemies:RemoveEnemy(row.id)
   else applied,detail=self.o.enemies:SetEnemy(row.id,row)end
   assert(applied==true,detail or 'native_enemy_apply_failed')
   if not row.dead then local checked,reason=self.o.enemies:VerifyEnemy(row.id,row);assert(checked==true,reason)end
  end
  for _,row in ipairs(batch.pickups)do
   self:_proof(batch);wrote=true
   local applied,detail=self.o.pickups:ApplyPickup(row);assert(applied==true,detail or 'native_pickup_apply_failed')
   local checked,reason=self.o.pickups:VerifyPickup(row);assert(checked==true,reason or 'native_pickup_readback_failed')
  end
  self:_proof(batch)
  local receipt=self.o.commit(batch)
  assert(type(receipt)=='table' and receipt.context==batch.context and receipt.term==batch.term
   and receipt.worldEpoch==batch.worldEpoch and receipt.revision==batch.revision
   and receipt.journalSeq==batch.journalSeq,'native_outcome_commit_failed')
  self:_proof(batch)
  assert(self.o.verifyCommit(batch,receipt)==true,'native_host_state_receipt_unproven')
 end)
 if not ok then
  local reason=tostring(why)
  if wrote then self.failed=reason;if self.o.hold then pcall(self.o.hold,reason,batch)end end
  return false,reason
 end
 return true
end
return A
