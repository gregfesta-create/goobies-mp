-- Single fixed survivor coordinator; all frozen survivors must acknowledge.
-- A partition never elects another coordinator or removes a missing voter.
local Checkpoint=require('gmp_handover');local Departure=require('gmp_departure_coordinator');local L={};L.__index=L
local function atom(s,n)return type(s)=='string' and #s>0 and #s<=n and s:match('^[%w_:%-]+$')end
local function nonce(rng)local out={};for i=1,32 do out[i]=string.format('%x',rng(0,15))end;return table.concat(out)end
function L.new(o)
 if not o.mesh or type(o.paused)~='function' or type(o.hold)~='function' or type(o.current)~='function'
  or type(o.restore)~='function' or type(o.activate)~='function' or type(o.release)~='function'
  or not atom(o.sid,64) or not atom(o.digest,64) then return nil,'invalid_loss_runtime' end
 local policy=o.checkpoint and o.checkpoint.sessionPolicy
 if not require('gmp_messages').ValidatePolicy(policy) or policy.locked~=true then return nil,'locked_session_policy_missing' end
 local coordinator,slot,host
 for _,p in ipairs(o.checkpoint.players or {})do
  if p.role=='host' then host=p.key
  elseif p.conn=='connected' and (not slot or p.slot<slot) then coordinator=p.key;slot=p.slot end
 end
 local d,why=Departure.new{checkpoint=o.checkpoint,sid=o.sid,term=o.term,sequence=o.sequence,digest=o.digest,
  kind='loss',coordinator=coordinator,paused=o.paused,ready=o.ready}
 if not d or not d.required[o.key] then return nil,why or 'not_survivor' end
 local self=setmetatable({o=o,d=d,coordinator=coordinator,formerHost=host,phase='waiting',hello={},restored={},activated={},released={},started=o.clock()},L)
 if o.key==coordinator then self.nonce=nonce(o.rng or math.random)end
 if o.hold(true)~=true or o.paused()~=true then return nil,'physical_loss_hold_unverified' end
 return self
end
function L:_all(receipts)for key in pairs(self.d.required)do if not receipts[key]then return false end end;return true end
function L:_fail(reason)
 self.failed=self.failed or reason;self.phase='failed';self.o.hold(true)
end
function L:_selected()
 local ok,state=Checkpoint.Validate(self.d.state);assert(ok)
 for _,p in ipairs(state.players)do p.role=p.key==self.winner and 'host' or 'client';if p.key==self.formerHost then p.conn='disconnected'end end
 self.selectedState=state
end
function L:_packet(kind,request)
 return table.concat({kind,self.o.sid,self.o.term,self.o.sequence,self.o.digest,self.winner or '-',request or self.commit and self.commit.request or '-',self.nonce or '-'},'|')
end
function L:_send(kind,request,target)
 local packet=self:_packet(kind,request)
 if target then return self.o.mesh:Send(target,packet)end
 for key in pairs(self.d.required)do if key~=self.o.key then self.o.mesh:Send(key,packet)end end
end
function L:Claim(request)
 if self.phase~='offered' or not atom(request,64) then return false,'loss_offer_unavailable' end
 self.request=request;return true -- queued; role never changes here.
end
function L:_claim(sender,request)
 local ok,commit=self.d:Claim(sender,{key=sender,sid=self.o.sid,term=self.o.term,revision=1,request=request})
 if ok then self.commit=commit;commit.nonce=self.nonce;commit.request=request;self.winner=commit.hostKey;self.phase='restoring';self:_selected() end
 return ok
end
function L:_receive(event)
 if not self.d.required[event.sender] or type(event.data)~='string' then return end
 local kind,sid,term,sequence,digest,winner,request,attempt=event.data:match('^([A-Z]+)|([%w_%-]+)|(%d+)|(%d+)|([%w_:%-]+)|([%w_:%-]+)|([%w_:%-]+)|([%w_:%-]+)$')
 if sid~=self.o.sid or tonumber(term)~=self.o.term or tonumber(sequence)~=self.o.sequence or digest~=self.o.digest then return end
 if kind~='HELLO' then
  if not attempt or #attempt~=32 or not attempt:match('^[0-9a-f]+$')then return end
  if self.nonce and self.nonce~=attempt then return end
  if not self.nonce then if kind~='OFFER' or event.sender~=self.coordinator then return end;self.nonce=attempt end
 end
 if self.commit and kind~='CLAIM' and kind~='HELLO' and request~=self.commit.request then return end
 if kind=='FAILED' then return self:_fail('survivor_failed:'..event.sender)end
 if kind=='HELLO' and self.o.key==self.coordinator and self.phase=='waiting' then self.hello[event.sender]=true
 elseif kind=='OFFER' and event.sender==self.coordinator and self.phase=='waiting' then self.phase='offered'
 elseif kind=='CLAIM' and self.o.key==self.coordinator and self.phase=='offered' and atom(request,64) then self:_claim(event.sender,request)
 elseif kind=='SELECT' and event.sender==self.coordinator and self.d.eligible[winner] then
  if self.winner and self.winner~=winner then return self:_fail('conflicting_selected_host')end
  if not self.winner then
   self.winner=winner;self.commit={session=sid,term=self.o.term+1,sequence=self.o.sequence,digest=digest,hostKey=winner,formerHost=self.formerHost,forced=false,kind='loss',nonce=attempt,request=request}
   self.phase='restoring';self:_selected()
  end
 elseif kind=='RESTORED' and self.o.key==self.coordinator and winner==self.winner then self.restored[event.sender]=true
 elseif kind=='ACTIVATE' and event.sender==self.coordinator and winner==self.winner and self.localRestored then self.activateRequested=true
 elseif kind=='ACTIVATED' and self.o.key==self.coordinator and winner==self.winner then self.activated[event.sender]=true
 elseif kind=='RELEASE' and event.sender==self.coordinator and winner==self.winner and self.localActivated then self.releaseRequested=true
 elseif kind=='RELEASED' and self.o.key==self.coordinator and winner==self.winner then self.released[event.sender]=true
 elseif kind=='DONE' and event.sender==self.coordinator and self.localReleased then self.phase='finished';self:_send('DONEACK',nil,self.coordinator)
 elseif kind=='DONEACK' and self.o.key==self.coordinator and self.localReleased then self.done=self.done or {};self.done[event.sender]=true end
end
function L:SelectedCommit(commit)
 return type(commit)=='table' and not self.failed and self.commit and self.o.current()==true
  and self.o.mesh:Ready()==true and commit.session==self.commit.session and commit.term==self.commit.term
  and commit.hostKey==self.commit.hostKey and commit.formerHost==self.commit.formerHost
  and commit.sequence==self.commit.sequence and commit.digest==self.commit.digest and commit.nonce==self.commit.nonce and commit.request==self.commit.request
end
function L:TrustedCommit(commit)
 return type(commit)=='table' and not self.failed and self.activateRequested==true and self.localRestored==true and self.commit
  and commit.session==self.commit.session and commit.term==self.commit.term and commit.hostKey==self.commit.hostKey
  and commit.formerHost==self.commit.formerHost and commit.sequence==self.commit.sequence and commit.digest==self.commit.digest and commit.nonce==self.commit.nonce and commit.request==self.commit.request
end
function L:Tick()
 if self.phase=='finished' then for _,event in ipairs(self.o.mesh:Tick())do self:_receive(event)end;return end
 if self.o.current()~=true then self:_fail('loss_context_changed')end
 if self.lastPhase~=self.phase then self.lastPhase=self.phase;self.started=self.o.clock()end
 if self.phase~='failed' and self.o.clock()-self.started>=25 then self:_fail('loss_transaction_timeout')end
 if self.phase~='failed' and not self.localReleased and self.o.paused()~=true then self:_fail('loss_hold_changed')end
 for _,event in ipairs(self.o.mesh:Tick())do self:_receive(event)end
 if self.failed then self:_send('FAILED');return end
 if not self.o.mesh:Ready() then return end
 if self.phase=='waiting' then
  self.hello[self.o.key]=true
  if self.o.key==self.coordinator and self:_all(self.hello)then self.phase='offered'else self:_send('HELLO',nil,self.coordinator)end
 end
 if self.phase=='offered' then
  if self.o.key==self.coordinator then self:_send('OFFER');if self.request then self:_claim(self.o.key,self.request)end
  elseif self.request then self:_send('CLAIM',self.request,self.coordinator)end
 end
 if self.winner then
  if self.o.key==self.coordinator then self:_send('SELECT')end
  if not self.nativePrepared and type(self.o.prepare)=='function' then
   local ok,why=self.o.prepare(self.commit)
   if ok==false then return self:_fail('prepare:'..tostring(why))end
   if ok~=true then return end;self.nativePrepared=true
  end
  if not self.localRestored then
   local ok,why=self.o.restore(self.commit,self.selectedState)
   if ok==false then return self:_fail('restore:'..tostring(why))end
   if ok==true then self.localRestored=true;self.restored[self.o.key]=true end
  end
  if self.localRestored then
   if self.o.key==self.coordinator then if self:_all(self.restored)then self.activateRequested=true;self:_send('ACTIVATE')end
   end
   self:_send('RESTORED')
  end
  if self.activateRequested and not self.localActivated then
   local ok,why=self.o.activate(self.commit,self.selectedState)
   if ok==false then return self:_fail('activate:'..tostring(why))end
   if ok==true then self.localActivated=true;self.activated[self.o.key]=true;self.phase='activating' end
  end
  if self.localActivated then
   if self.o.key==self.coordinator then if self:_all(self.activated)then self.releaseRequested=true;self:_send('RELEASE')end
   end
   self:_send('ACTIVATED')
  end
  if self.releaseRequested and not self.localReleased then
   local ok,why=self.o.release(self.commit)
   if ok==false then return self:_fail('release:'..tostring(why))end
   if ok==true then self.localReleased=true;self.released[self.o.key]=true;self.phase='releasing' end
  end
  if self.localReleased then
   if self.o.key==self.coordinator then if self:_all(self.released)then self.done=self.done or {};self.done[self.o.key]=true;self:_send('DONE');if self:_all(self.done)then self.phase='finished'end end
   end
   self:_send('RELEASED')
  end
 end
end
return L
