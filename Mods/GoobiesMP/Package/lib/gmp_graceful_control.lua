-- Authenticated all-member graceful control on owned Steam channel4737.
-- Star role-switch transport remains separate; native witness sees each sender.
local M={};M.__index=M
local function same(a,b)return a and b and a.session==b.session and a.term==b.term and a.sequence==b.sequence
 and a.digest==b.digest and a.hostKey==b.hostKey and a.formerHost==b.formerHost and a.nonce==b.nonce end
function M.new(o,commit,state)
 if type(o)~='table' or type(o.cfg)~='table' or type(o.identity)~='table' or type(o.G)~='table'
  or type(o.clock)~='function' or type(o.current)~='function' or type(o.verifyApplied)~='function'
  or type(commit)~='table' or type(state)~='table' or type(state.players)~='table'then return nil,'invalid_graceful_options'end
 local verified,accepted=pcall(o.verifyStage or function()return false end,commit)
 if o.cfg.MODE~='production' or o.cfg.AUTH_MODE~='steam' or commit.kind~='graceful' or commit.forced~=false
  or not verified or accepted~=true then return nil,'untrusted_graceful_stage'end
 local keys,participants={},{};local count=0
 for _,p in ipairs(state.players)do if type(p)~='table' or type(p.key)~='string'then return nil,'invalid_graceful_participants'end;if p.conn=='connected'then keys[#keys+1]=p.key;participants[p.key]=true;count=count+1 end end
 if count<2 or not participants[o.identity.key] or not participants[commit.formerHost] or not participants[commit.hostKey]
  or type(commit.nonce)~='string' or #commit.nonce~=32 or not commit.nonce:match('^[0-9a-f]+$') then return nil,'invalid_graceful_participants'end
 local pinned={session=commit.session,term=commit.term,sequence=commit.sequence,digest=commit.digest,
  hostKey=commit.hostKey,formerHost=commit.formerHost,nonce=commit.nonce,kind='graceful',forced=false}
 local constructed,mesh,why=pcall(require('gmp_survivor_mesh').new,{cfg=o.cfg,provider=o.provider,G=o.G,identity=o.identity,
  clock=o.clock,rng=o.rng,sid=commit.session,term=commit.term-1,survivors=keys,current=o.current,
  reuseEdges=o.reuseEdges,verifySeal=function(c)return same(c,pinned) and o.verifyApplied(c)==true end})
 if not constructed then return nil,'graceful_mesh_construction_failed'end
 if not mesh then return nil,why end
 return setmetatable({o=o,mesh=mesh,commit=pinned,participants=participants,events={},
  HandoverControlAttribution=true,ProductionGracefulControl=true},M)
end
function M:Tick()for _,event in ipairs(self.mesh:Tick())do if #self.events<64 then self.events[#self.events+1]=event end end end
function M:Ready()return self.mesh:Ready()end
function M:BindHandoverControl(nonce,ctx)
 if type(ctx)~='table' or type(ctx.participants)~='table' or not self:Ready() or nonce~=self.commit.nonce or ctx.session~=self.commit.session or ctx.term~=self.commit.term
  or ctx.sequence~=self.commit.sequence or ctx.digest~=self.commit.digest or ctx.localKey~=self.o.identity.key
  or ctx.masterKey~=self.commit.formerHost then return false end
 for key in pairs(self.participants)do if not ctx.participants[key]then return false end end
 for key in pairs(ctx.participants)do if not self.participants[key]then return false end end
 self.bound=true;return true
end
function M:SendHandoverControl(message)
 if not self.bound then return false end
 if message=='APPLIED'then self.localRestored=true elseif message=='ACTIVATED'then self.localActivated=true
 elseif message=='RELEASED'then self.localReleased=true end
 -- Coordinator commands also retransmit its actual local receipts; losing an
 -- early receipt cannot strand peers waiting for the all-member seal.
 if message=='EXECUTE' and self.localRestored then self:SendHandoverControl('APPLIED')end
 if message=='ACTIVATE' and self.localActivated then self:SendHandoverControl('ACTIVATED')end
 if (message=='DONE' or message=='FINALIZE') and self.localReleased then self:SendHandoverControl('RELEASED')end
 local names={SEALED='SEALED',APPLIED='RESTORED',ACTIVATED='ACTIVATED',RELEASED='RELEASED',FAILED='FAILED',
  EXECUTE='EXECUTE',ACTIVATE='ACTIVATE',RELEASE='RELEASE',DONE='DONE',DONEACK='DONEACK',FINALIZE='FINALIZE'}
 local kind=names[message];if not kind then return false end
 local c=self.commit;local raw=table.concat({kind,c.session,c.term-1,c.sequence,c.digest,c.hostKey,'graceful_'..c.nonce,c.nonce},'|')
 local accepted=true;for key in pairs(self.participants)do if key~=self.o.identity.key then
  local ok=self.mesh:Send(key,raw);if ok~=true then accepted=false end end end;return accepted
end
function M:PollHandoverControl()
 self:Tick();local rows={};local events=self.events;self.events={}
 for _,event in ipairs(events)do
  local f={}
  if type(event.data)=='string'then
   local start=1
   for separator in event.data:gmatch('()|')do f[#f+1]=event.data:sub(start,separator-1);start=separator+1 end
   f[#f+1]=event.data:sub(start)
  end
  local names={SEALED='SEALED',RESTORED='APPLIED',ACTIVATED='ACTIVATED',RELEASED='RELEASED',FAILED='FAILED',
   EXECUTE='EXECUTE',ACTIVATE='ACTIVATE',RELEASE='RELEASE',DONE='DONE',DONEACK='DONEACK',FINALIZE='FINALIZE'}
  local c=self.commit
  if #f==8 and names[f[1]] and self.participants[event.sender] and f[2]==c.session and f[3]==tostring(c.term-1)
   and f[4]==tostring(c.sequence) and f[5]==c.digest and f[6]==c.hostKey and f[7]=='graceful_'..c.nonce and f[8]==c.nonce then
   if f[1]=='SEALED'then self.sealedPeers=self.sealedPeers or {};self.sealedPeers[event.sender]=true else
   rows[#rows+1]={sender=event.sender,message=names[f[1]],nonce=c.nonce,sid=c.session,term=c.term,sequence=c.sequence,digest=c.digest}
   end
  end
 end
 if self.mesh.sealed then self:SendHandoverControl('SEALED')end
 return rows
end
function M:Seal(c)
 local ok,why=self.mesh:Seal(c);if not ok then return false,why end
 self.sealedPeers=self.sealedPeers or {};self.sealedPeers[self.o.identity.key]=true
 self:SendHandoverControl('SEALED');return true
end
function M:ActivationReady()
 for key in pairs(self.participants)do if not self.sealedPeers or not self.sealedPeers[key]then return false end end
 return true
end
function M:ClearHandoverControl()self.bound=false;self.events={};self.mesh:Close()end
return M
