-- Atomic host outcomes. Receipt of fragments never acknowledges native application.
local Codec=require('gmp_codec')
local S={};S.__index=S;S.ROWS=4;S.MAX_ROWS=128
local function int(v,a,b)return type(v)=='number' and v%1==0 and v>=a and v<=b end
local function token(v,n)return type(v)=='string' and #v>=1 and #v<=n and not v:find('[%c]')end
local function id(v)
 if not token(v,32)then return false end
 local epoch,serial=v:match('^([1-9]%d*):([1-9]%d*)$')
 return epoch and int(tonumber(epoch),1,2147483647)and int(tonumber(serial),1,2147483647)
end
local function number(v,empty)
 if empty and v==''then return true end
 if not token(v,32)then return false end
 local n=tonumber(v);return n and n==n and n>=0 and n<=1e15
end
local function dense(rows,max)
 if type(rows)~='table' or #rows>max then return false end
 local n=0;for k in pairs(rows)do if not int(k,1,#rows)then return false end;n=n+1 end
 return n==#rows
end
local function header(f)
 return type(f)=='table' and f.version==1 and int(f.term,1,2147483647) and int(f.worldEpoch,1,1000000)
  and token(f.context,256) and int(f.revision,1,9007199254740991) and int(f.journalSeq,1,2147483647)
  and int(f.enemyCount,0,S.MAX_ROWS) and int(f.pickupCount,0,S.MAX_ROWS-f.enemyCount)
end
local function rows(f)
 if not dense(f.enemies,S.MAX_ROWS)or not dense(f.pickups,S.MAX_ROWS)then return false end
 local seen={}
 for _,r in ipairs(f.enemies)do
  if type(r)~='table' or not id(r.id)or seen['e'..r.id]or not int(r.slot,0,8191)or not int(r.enemyType,0,255)
   or not int(r.x,-2000000,2000000)or not int(r.y,-2000000,2000000)or not int(r.z,-100000,100000)
   or not number(r.hp)or not number(r.damage,true)or type(r.dead)~='boolean'then return false end
  seen['e'..r.id]=true
 end
 for _,r in ipairs(f.pickups)do
  if type(r)~='table' or not id(r.id)or seen['p'..r.id]or r.kind~='xp' or not int(r.amount,1,1000000000)
   or not int(r.x,-2000000,2000000)or not int(r.y,-2000000,2000000)or not int(r.z,-100000,100000)
   or (r.state~='born'and r.state~='retired')then return false end
  seen['p'..r.id]=true
 end
 return true
end
local fields={'version','term','worldEpoch','context','revision','journalSeq','enemyCount','pickupCount'}
local function same(a,b)for _,k in ipairs(fields)do if a[k]~=b[k]then return false end end;return true end
local function copyHeader(f)local r={};for _,k in ipairs(fields)do r[k]=f[k]end;return r end
local function copyAck(f)return {term=f.term,worldEpoch=f.worldEpoch,revision=f.revision,journalSeq=f.journalSeq}end
local function wire(f,sid)return Codec.Encode{type='OUTCOME_V1',ch='R',sid=sid,ep=2147483647,seq=9007199254740991,ack=9007199254740991,f=f}end
function S.Packets(batch,sid)
 if not header(batch)or not rows(batch)or #batch.enemies~=batch.enemyCount or #batch.pickups~=batch.pickupCount then return nil,'invalid_outcome' end
 local total=math.max(1,math.ceil((batch.enemyCount+batch.pickupCount)/S.ROWS));local packets={}
 for index=1,total do
  local f=copyHeader(batch);f.index=index;f.total=total;f.enemies={};f.pickups={}
  for i=(index-1)*S.ROWS+1,math.min(index*S.ROWS,batch.enemyCount+batch.pickupCount)do
   local dst,r;if i<=batch.enemyCount then dst=f.enemies;r=batch.enemies[i]else dst=f.pickups;r=batch.pickups[i-batch.enemyCount]end
   local detached={};for k,v in pairs(r)do detached[k]=v end;dst[#dst+1]=detached
  end
  local encoded=wire(f,sid);if not encoded or #encoded>1380 then return nil,'outcome_packet_budget'end
  packets[index]=f
 end
 return packets
end
function S.new(options)return setmetatable({o=options or {}},S)end
function S:_fail(reason)self.failed=reason;self.pending=nil;return false,reason end
function S:Receive(f,sid)
 if self.failed then return false,self.failed end
 if not header(f)or not rows(f)or not int(f.total,1,32)or not int(f.index,1,f.total)
  or f.total~=math.max(1,math.ceil((f.enemyCount+f.pickupCount)/S.ROWS))
  or #f.enemies+#f.pickups~=math.min(S.ROWS,f.enemyCount+f.pickupCount-(f.index-1)*S.ROWS)
  or #f.enemies~=math.min(S.ROWS,math.max(0,f.enemyCount-(f.index-1)*S.ROWS))then return false,'invalid_outcome_fragment'end
 local encoded=wire(f,sid);if not encoded or #encoded>1380 then return false,'outcome_packet_budget'end
 local authorized,current=pcall(self.o.authorize,f,sid)
 if not authorized or current~=true then return false,'native_outcome_authorization_unavailable'end
 if self.completed and same(self.completed,f)then
  if self.completed.sid~=sid then return false,'outcome_session_changed'end
  if self.completed.wires[f.index]~=encoded then return self:_fail('conflicting_applied_outcome')end
  return true,nil,copyAck(self.completed)
 end
 if self.completed and f.term==self.completed.term and f.worldEpoch==self.completed.worldEpoch
  and (f.revision<=self.completed.revision or f.journalSeq<=self.completed.journalSeq)then return false,'stale_outcome'end
 local p=self.pending
 if p and not same(p,f)then return false,'outcome_backpressure'end
 if not p then p=copyHeader(f);p.sid=sid;p.chunks={};p.wires={};p.count=0;self.pending=p end
 if p.sid~=sid then return self:_fail('outcome_session_changed')end
 if p.wires[f.index]then if p.wires[f.index]~=encoded then return self:_fail('conflicting_outcome_fragment')end;return true end
 -- Decode our canonical bounded encoding to detach caller-owned rows.
 local decoded=Codec.Decode(encoded);if not decoded then return self:_fail('outcome_decode_failed')end
 p.chunks[f.index]=decoded.f;p.wires[f.index]=encoded;p.count=p.count+1
 if p.count~=f.total then return true end
 local batch=copyHeader(p);batch.enemies={};batch.pickups={}
 for i=1,f.total do for _,r in ipairs(p.chunks[i].enemies)do batch.enemies[#batch.enemies+1]=r end;for _,r in ipairs(p.chunks[i].pickups)do batch.pickups[#batch.pickups+1]=r end end
 if #batch.enemies~=batch.enemyCount or #batch.pickups~=batch.pickupCount or not rows(batch)then return self:_fail('invalid_outcome_assembly')end
 local ok,applied,reason=pcall(self.o.apply,batch)
 if not ok or applied~=true then return self:_fail(reason or 'native_outcome_apply_failed')end
 authorized,current=pcall(self.o.authorize,batch,sid)
 if not authorized or current~=true then return self:_fail('native_outcome_authority_withdrawn')end
 p.ack={term=p.term,worldEpoch=p.worldEpoch,revision=p.revision,journalSeq=p.journalSeq};self.completed=p;self.pending=nil
 return true,nil,copyAck(p)
end
return S
