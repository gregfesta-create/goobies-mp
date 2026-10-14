-- Authenticated claims refer only to host lifetimes. The bound engine backend
-- removes an orb without invoking client/local collection or reward branches.
local R={};R.__index=R
function R.new(ledger,backend)
 for _,name in ipairs({'Context','Ready','Eligible','Remove','Publish'}) do
  assert(type(backend[name])=='function','missing_pickup_backend:'..name)
 end
 return setmetatable({ledger=ledger,backend=backend,pending={},held=false},R)
end
function R:Resolve(peer,id,context)
 local b,l=self.backend,self.ledger
 if self.held then return false,'pickup_mutation_uncertain' end
 if type(peer)~='string' or #peer==0 or #peer>128 or type(id)~='string' or #id>32
  or type(context)~='string' or #context==0 or #context>256 then return false,'invalid_claim' end
 if b:Context()~=context or b:Ready(context)~=true then return false,'pickup_binding_unverified' end
 local epoch,island=l.epoch,l.island
 local row=l.records[id]
 if not row then return false,'unknown_pickup' end
 local pending=self.pending[id]
 if pending then
  if pending.context~=context then return false,'stale_pickup_delivery' end
  return self:_publish(id,pending)
 end
 if row.claimed then return false,'claimed_without_world_receipt' end
 local ok,eligible=pcall(b.Eligible,b,context,peer,id)
 if not ok or eligible~=true then return false,'ineligible' end
 if b:Context()~=context or b:Ready(context)~=true or l.epoch~=epoch or l.island~=island
  or l.records[id]~=row then return false,'context_changed' end
 -- Ledger claim reserves the lifetime before any engine mutation. Neither an
 -- exception nor a lost readback can permit the removal/award path to replay.
 local claimed,delta,snapshot=l:Claim(epoch,island,id,peer,true)
 if not claimed then return false,delta end
 pending={context=context,delta=delta,snapshot=snapshot,removed=false}
 self.pending[id]=pending
 ok,eligible=pcall(b.Remove,b,context,id)
 if not ok or eligible~=true or b:Context()~=context then
  self.held=true;return false,'pickup_removal_uncertain'
 end
 pending.removed=true
 return self:_publish(id,pending)
end
function R:_publish(id,pending)
 if not pending.removed then self.held=true;return false,'pickup_removal_uncertain' end
 -- Publication is an idempotent revision projection, never AddExperience(delta).
 local s=pending.snapshot
 local projection={epoch=s.epoch,island=s.island,total=s.total,revision=s.revision}
 local ok,result=pcall(self.backend.Publish,self.backend,pending.context,projection)
 if not ok or result~=true then return false,'pickup_delivery_pending' end
 if self.backend:Context()~=pending.context then self.held=true;return false,'context_changed' end
 if not self.ledger:Retire(id) then self.held=true;return false,'pickup_retirement_failed' end
 self.pending[id]=nil;return true,pending.delta,pending.snapshot
end
return R
