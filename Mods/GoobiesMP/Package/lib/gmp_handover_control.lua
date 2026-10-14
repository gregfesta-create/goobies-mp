-- Frozen-participant development barrier. Only the attributed coordinator may
-- command execution; every participant's receipts precede activation/release.
local C={};C.__index=C
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
function C.new(o)
 assert(o.mode=='dev' and type(o.send)=='function' and type(o.poll)=='function')
 assert(type(o.execute)=='function' and type(o.release)=='function')
 local self=setmetatable({o=o,phase='staged',localApplied=false,applied={},activated={},released={},done={}},C)
 self.key=o.key or (o.master and 'local_master' or 'local_peer');self.masterKey=o.masterKey or 'local_master'
 self.participants={};self.count=0
 for key,value in pairs(o.participants or {local_master=true,local_peer=true})do self.participants[key]=value end
 for key,value in pairs(self.participants)do assert(type(key)=='string' and value==true);self.count=self.count+1;if key~=self.key then self.other=key end end
 assert(self.participants[self.key] and self.participants[self.masterKey] and self.count>=2 and self.count<=Capacity)
 return self
end
function C:_all(receipts)for key in pairs(self.participants)do if not receipts[key]then return false end end;return true end
function C:_others(receipts)for key in pairs(self.participants)do if key~=self.key and not receipts[key]then return false end end;return true end
function C:_execute()
 if self.localApplied then return true end;if self.failed then return false end
 local ok,accepted,why=pcall(self.o.execute)
 if ok and accepted==false and why=='restore_pending' then return false end
 if not ok or accepted~=true then self.failed='execute_failed';self.failureReason=tostring(ok and why or accepted);return false end
 self.localApplied=true;self.applied[self.key]=true;self.phase='applied';return true
end
function C:_activate()
 if self.localActivated then return true end
 if self.failed or not self.localApplied then return false end
 local ok,accepted,why=pcall(self.o.activate)
 if ok and accepted==false and why=='activation_pending' then return false end
 if not ok or accepted~=true then self.failed='activate_failed';self.failureReason=tostring(ok and why or accepted);return false end
 self.localActivated=true;self.activated[self.key]=true;self.phase='activated';return true
end
function C:_release()
 if self.failed then return false end
 if self.phase=='released' or self.phase=='done' or self.phase=='finished' then return true end
 if not self.localApplied or self.o.activate and not self.localActivated then return false end
 local ok,accepted,why=pcall(self.o.release)
 if ok and accepted==false and why=='release_pending' then return false end
 if not ok or accepted~=true then self.failed='release_failed';self.failureReason=tostring(ok and why or accepted);return false end
 self.released[self.key]=true;self.phase='released';return true
end
function C:Abort(reason)self.failed=self.failed or 'aborted';self.failureReason=self.failureReason or tostring(reason);return true end
function C:Start()if not self.o.master or self.phase~='staged'then return false end;self.started=true;return self:_execute()end
function C:_send(message)
 local ok,accepted=pcall(self.o.send,message)
 if not ok then self:Abort('control_send_failed');return false end
 return accepted==true
end
function C:_event(row)
 if type(row)=='string'then if self.count~=2 or not self.o.allowAnonymousPair then return end;return self.other,row end
 if type(row)~='table' or not self.participants[row.sender] or row.sender==self.key then return end
 local context=self.o.context
 if not context or row.nonce~=context.nonce or row.sid~=context.session or row.term~=context.term
  or row.sequence~=context.sequence or row.digest~=context.digest then return end
 return row.sender,row.message
end
function C:Tick(now)
 if self.phase=='finished'then return end
 self.startedAt=self.startedAt or now
 if not self.failed and now-self.startedAt>=(self.o.timeout or 25)then self:Abort('participant_barrier_timeout')end
 local polled,events=pcall(self.o.poll)
 if not polled or type(events)~='table'then self:Abort('control_poll_failed');events={}end
 local attempted=false
 for i=1,math.min(#events,64)do
  local sender,message=self:_event(events[i]);local master=sender==self.masterKey
  if sender and message=='FAILED'then self.failed=self.failed or 'peer_failed';self.failureReason=self.failureReason or 'remote_restoration_or_activation_failed'
  elseif not self.o.master and master and message=='EXECUTE'then self.executeRequested=true;if not attempted then attempted=true;if self:_execute()then self.reply='APPLIED'end end
  elseif (self.o.master or self.o.allPeerReceipts) and message=='APPLIED' and (self.localApplied or self.o.allPeerReceipts) then self.applied[sender]=true
  elseif not self.o.master and master and message=='ACTIVATE' and self.localApplied and self.o.activate then self.activateRequested=true;if self:_activate()then self.reply='ACTIVATED'end
  elseif self.o.master and message=='ACTIVATED' and self.localActivated then self.activated[sender]=true
  elseif not self.o.master and master and message=='RELEASE' and self.localApplied and (not self.o.activate or self.localActivated)then self.releaseRequested=true;if self:_release()then self.reply='RELEASED'end
  elseif self.o.master and message=='RELEASED' and self.releaseSent then self.released[sender]=true
  elseif not self.failed and not self.o.master and master and message=='DONE' and self.released[self.key]then
   if self.o.participants then self.phase='done';self.reply='DONEACK'else self.phase='finished';self.reply=nil end
  elseif self.o.master and message=='DONEACK' and self.released[self.key]then self.done[sender]=true
  elseif not self.failed and not self.o.master and master and message=='FINALIZE' and self.phase=='done'then self.phase='finished';self.reply=nil end
 end
 if not attempted and not self.localApplied and (self.started or self.executeRequested)then if self:_execute()and not self.o.master then self.reply='APPLIED'end end
 if self.sendAt and now<self.sendAt then return end;self.sendAt=now+.25
 if self.failed then self:_send('FAILED');return end
 self.remoteApplied=self:_all(self.applied);self.remoteActivated=self:_all(self.activated);self.remoteReleased=self:_others(self.released)
 if self.o.master and self.started and self.localApplied then
  if not self.remoteApplied then self:_send('EXECUTE')
  elseif self.o.activate and not self.remoteActivated then
   self:_activate();if not self.failed then self:_send('ACTIVATE')end
  elseif not self.remoteReleased then self.releaseSent=true;self:_send('RELEASE')
  elseif self:_release()then
   self.done[self.key]=true
   if self.o.participants and not self:_all(self.done)then self:_send('DONE')
   else self.doneUntil=self.doneUntil or now+2;if now<self.doneUntil then self:_send(self.o.participants and 'FINALIZE' or 'DONE')else self.phase='finished';self.started=false end end
  end
 elseif self.reply then self:_send(self.reply)end
end
return C
