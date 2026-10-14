-- Owned native channel4737. Each survivor verifies every other survivor's
-- real Steam ticket through the existing Host/Client auth implementations.
-- This source adapter is opt-in; constructing it never grants game authority.
local Identity=require('gmp_identity');local Auth=require('gmp_auth')
local Transport=require('gmp_steam_transport');local Host=require('gmp_host');local Client=require('gmp_client')
local M={};M.__index=M
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
function M.new(o)
 if type(o.sid)~='string' or #o.sid<1 or #o.sid>64 or not o.sid:match('^[%w_%-]+$')
  or type(o.term)~='number' or o.term%1~=0 or o.term<1 or not o.identity or o.identity.kind~='steam'
  or type(o.current)~='function' then return nil,'invalid_mesh_context' end
 for _,name in ipairs{'GMP_Mesh_Send','GMP_Mesh_Poll','GMP_Mesh_Close'} do
  if type(o.G[name])~='function' then return nil,'native_survivor_channel_missing' end
 end
 local allowed,why=Auth.AllowNonLoopback(o.cfg,o.provider);if not allowed then return nil,why end
 local self=setmetatable({o=o,edges={},events={},started=o.clock(),phase='authenticating'},M)
 local count=0
 for _,key in ipairs(o.survivors) do
  local id=Identity.Parse(key)
  if not id or id.kind~='steam' or self.edges[key] then return nil,'invalid_survivor_identity' end
  count=count+1
  if key~=o.identity.key then self.edges[key]={id=id,hostQueue={},clientQueue={},authEvents={}} end
 end
 if count<1 or count>Capacity then return nil,'survivor_auth_capacity' end
 for key,e in pairs(self.edges) do
  -- Poll results are dispatched once by key, so one Host cannot steal another
  -- edge's ValidateAuthTicketResponse. Tickets remain addressed per peer.
  local reuse=o.reuseEdges and o.reuseEdges[key]
  if reuse then
   if type(reuse.live)~='function' or reuse.live()~=true or type(reuse.nonce)~='string'
    or not reuse.nonce:match('^%x%x%x%x%x%x%x%x$')then self:Close();return nil,'invalid_reused_auth_edge'end
   e.reused=reuse
  else
  local edgeProvider=o.provider
  if type(o.provider.Lease)=='function' then
   local lease,reason=o.provider:Lease(key);if not lease then self:Close();return nil,reason end
   edgeProvider=lease;e.lease=lease
  end
  local proxy={}
  for _,method in ipairs(Auth.REQUIRED) do
   proxy[method]=function(_,...)return edgeProvider[method](edgeProvider,...)end
  end
  if not e.lease then proxy.Poll=function()local events=e.authEvents;e.authEvents={};return events end end
  local function adapter(direction,queue)
   return {GMP_Net_Send=function(to,text)return o.G.GMP_Mesh_Send(to,direction..'|'..text)end,
    GMP_Net_Poll=function()local row=table.remove(queue,1);if row then return row[1],row[2]end end,
    GMP_Net_Close=function(to)return o.G.GMP_Mesh_Close(to)end}
  end
  -- Each edge is a point-to-point mini session; the fixed four-slot capacity (D12) is never reached over one link.
  local cfg={};for k,v in pairs(o.cfg)do cfg[k]=v end
  e.hostTransport=assert(Transport.new{G=adapter('H',e.hostQueue),clock=o.clock,rng=o.rng})
  e.clientTransport=assert(Transport.new{G=adapter('C',e.clientQueue),clock=o.clock,rng=o.rng})
  -- Exactly one exchange per undirected edge. Protocol6 validates both
  -- directions; two simultaneous exchanges would duplicate SDK sessions.
  if o.identity.key<key then
   e.host=assert(Host.new{cfg=cfg,transport=e.hostTransport,clock=o.clock,rng=o.rng,identity=o.identity,name='Survivor',authProvider=proxy})
   e.clientTransport=nil;e.host:Start()
  else
   e.client=assert(Client.new{cfg=cfg,transport=e.clientTransport,clock=o.clock,rng=o.rng,identity=o.identity,name='Survivor',authProvider=proxy})
   e.hostTransport=nil;e.client:Connect(e.id.value)
  end
  end
 end
 return self
end
function M:Ready()
 if self.phase=='failed' or self.phase=='closed' or self.o.current(self.sealed)~=true then return false end
 if self.sealed then return self.o.clock()<self.sealed.expires end
 for key,e in pairs(self.edges)do
  if e.reused then if e.reused.live()~=true then return false end else
  if e.host then
   local p=e.hostTransport.bySteam[e.id.value];local peer=p and e.host and e.host.peers[p.key]
   if not peer or peer.authKey~=key or peer.key~=key then return false end
  elseif not e.client or e.client:State()~='joined' or not e.client.auth.hostValidated then return false end
  end
 end
 return true
end
-- A narrowly scoped control capability survives owned ticket retirement only
-- after unanimous native restoration. It cannot add peers or change contexts.
function M:Seal(commit)
 if self.sealed then return type(commit)=='table' and self:Ready() and self.sealed.session==commit.session
  and self.sealed.nextTerm==commit.term and self.sealed.digest==commit.digest
  and self.sealed.sequence==commit.sequence and self.sealed.hostKey==commit.hostKey end
 if not self:Ready() or type(self.o.verifySeal)~='function' or self.o.verifySeal(commit)~=true
  or commit.session~=self.o.sid or commit.term~=self.o.term+1 or type(commit.sequence)~='number'
  or commit.sequence%1~=0 or commit.sequence<1 or type(commit.digest)~='string' or #commit.digest<1 then return false,'untrusted_mesh_seal' end
 local seal={session=self.o.sid,term=self.o.term,nextTerm=commit.term,sequence=commit.sequence,digest=commit.digest,hostKey=commit.hostKey,
  expires=self.o.clock()+25,nonces={}}
 for key,e in pairs(self.edges)do
  local p=e.hostTransport and e.hostTransport.bySteam[e.id.value];seal.nonces[key]=e.reused and e.reused.nonce or (p and p.nonce or e.clientTransport.nonce)
 end
 for _,e in pairs(self.edges)do if not e.lease and not e.reused then return false,'owned_auth_lease_required' end end
 self.sealed=seal
 for _,e in pairs(self.edges)do
  if e.host then e.host:RetireAuthentication()end
  if e.reused then -- Original star retains ownership until its actual role-switch teardown.
  elseif e.lease then e.lease:RetireValidation()else return false,'owned_auth_lease_required' end
 end
 self.phase='sealed';return true
end
function M:Send(key,data)
 if not self:Ready() or type(data)~='string' or #data<1 or #data>3000 or data:find('[\r\n]') then return false,'mesh_unavailable' end
 local e=self.edges[key];if not e then return false,'not_survivor' end
 return self.o.G.GMP_Mesh_Send(e.id.value,table.concat({'D',self.o.sid,self.o.term,(e.reused and e.reused.nonce or (e.clientTransport and e.clientTransport.nonce or e.hostTransport.bySteam[e.id.value].nonce)),data},'|'))
end
function M:Tick()
 if self.phase=='closed' or self.phase=='failed' then return {} end
 if self.o.current(self.sealed)~=true then self.phase='failed';self.failure='mesh_context_changed';return {} end
 for _,event in ipairs(type(self.o.provider.Lease)=='function' and {} or self.o.provider:Poll())do local e=self.edges[event.key];if e and #e.authEvents<32 then e.authEvents[#e.authEvents+1]=event end end
 for _=1,16 do
  local sender,text=self.o.G.GMP_Mesh_Poll();if not sender then break end
  local e=self.edges['steam:'..sender]
  if e and type(text)=='string' and #text<=4096 then
   local direction,body=text:match('^([HC])|(.*)$')
   if direction and not self.sealed and not e.reused then local queue=direction=='H' and e.clientQueue or e.hostQueue;if #queue<64 then queue[#queue+1]={sender,body}end
   else
    local sid,term,nonce,data=text:match('^D|([%w_%-]+)|(%d+)|(%x%x%x%x%x%x%x%x)|(.*)$')
    local p=e.hostTransport and e.hostTransport.bySteam[sender];local peer=p and e.host and e.host.peers[p.key]
    local clientEdge=e.client and e.client:State()=='joined' and e.client.auth.hostValidated and nonce==e.clientTransport.nonce
    local reused=e.reused and nonce==e.reused.nonce and (self.sealed or e.reused.live()==true)
    if sid==self.o.sid and tonumber(term)==self.o.term and (reused or clientEdge or (p and nonce==p.nonce
     and peer and ((self.sealed and self.sealed.nonces[e.id.key]==nonce) or (peer.authKey==e.id.key and peer.key==e.id.key)))) and self:Ready() and #data<=3000 and #self.events<64 then
     self.events[#self.events+1]={sender=e.id.key,data=data}
    end
   end
  end
 end
 if not self.sealed then for _,e in pairs(self.edges)do if e.host then e.host:Poll();e.host:Tick()end;if e.client then e.client:Poll();e.client:Tick()end end end
 if self.sealed and not self:Ready() then self.phase='failed';self.failure='sealed_control_expired'
 elseif self:Ready() then self.phase=self.sealed and 'sealed' or 'ready'
 elseif self.o.clock()-self.started>=25 then self.phase='failed';self.failure='survivor_auth_timeout' end
 local events=self.events;self.events={};return events
end
function M:Close()
 if self.phase=='closed' then return end
 for _,e in pairs(self.edges)do if e.host then e.host:RetireAuthentication()end;if e.client then e.client:_cancelTicket()end;if e.hostTransport then e.hostTransport:Close()end;if e.clientTransport then e.clientTransport:Close()end;if e.lease then e.lease:CloseLease()end end
 self.events={};self.phase='closed'
end
return M
