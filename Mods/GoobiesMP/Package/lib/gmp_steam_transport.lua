-- Steam message transport: opaque per-connection IDs, native sender attribution,
-- bounded drain, and fresh nonce framing. Real Steam tickets remain mandatory.
local Identity=require('gmp_identity')
local Lanes=require('gmp_lanes')
local T={};T.__index=T
-- Packets taken from GMP_Net_Poll per tick (was 16; one host tick can carry enemy, presence and prep traffic).
T.POLL_MAX=64
local function id(v)return type(v)=='string' and Identity.IsValidSteamId64(v) end
function T.new(options)
 local G=options.G or _G
 for _,name in ipairs{'GMP_Net_Send','GMP_Net_Poll','GMP_Net_Close'} do
  if type(G[name])~='function' then return nil,'native_network_missing' end
 end
 return setmetatable({G=G,clock=options.clock or os.clock,rng=options.rng or math.random,
  peers={},bySteam={},events={},serial=0,retired={},verifySwitch=options.verifySwitch,authorityTerm=1,
  lanes=Lanes.Counter.new((options.clock or os.clock)())},T)
end
function T:Name()return 'Steam messages (native)' end
function T:IsAuthenticated()return false end -- Never bypass GMP_Auth ticket exchange.
function T:PeerIdentity(peerId)
 local peer=self.peers[peerId];return peer and Identity.Steam(peer.steam) or nil
end
function T:SwitchRole(role,term,commit)
 if (role~='host' and role~='client') or term~=self.authorityTerm+1 or type(self.verifySwitch)~='function'
  or self.verifySwitch(role,term,commit)~=true then return false,'trusted_authority_commit_required' end
 self:Close();self.authorityTerm=term;return true
end
-- lane (gmp_lanes) and reliable are extra arguments for a lane-capable native (CROSS_PC_GAPS 2.1/2.2); the current
-- native checks only a minimum argument count and ignores them.
function T:_send(steam,text,lane,reliable)
 local ok,result,why=pcall(self.G.GMP_Net_Send,steam,text,lane or 1,reliable~=false)
 return ok and result==true or nil,ok and why or 'native_network_error'
end
function T:_event(event)if #self.events<64 then self.events[#self.events+1]=event end end
function T:_peer(steam,nonce)
 self.serial=self.serial+1;local key='steam-connection:'..self.serial
 local p={steam=steam,nonce=nonce,key=key};self.peers[key]=p;self.bySteam[steam]=p
 self:_event{kind='peer_connected',peerId=key};return p
end
function T:Listen()if self.mode then return nil,'transport_already_started' end;self.mode='host';return true end
function T:Connect(address)
 if not id(address) then return nil,'invalid_steam_address' end
 if self.mode=='host' then return nil,'transport_is_listening' end
 local old={};for _,peer in pairs(self.peers) do old[#old+1]=peer end
 for _,peer in ipairs(old) do self:_drop(peer,'reconnecting',true) end
 self.mode='client';self.address=address;self.nonce=string.format('%08x',self.rng(0,0x7fffffff));self.connectAt=0
 return true
end
function T:Send(peerId,data)
 local p=self.peers[peerId]
 if not p or type(data)~='string' or #data<1 or #data>4000 then return nil,'invalid_packet_or_peer' end
 local lane=Lanes.ForData(data)
 local ok,why=self:_send(p.steam,'GMP2|M|'..p.nonce..'|'..data,lane,lane~=0 and lane~=3)
 if ok then self.lanes:Add(lane,#data) end
 return ok,why
end
function T:_drop(p,reason,notify)
 if not p then return end
 if notify then self:_send(p.steam,'GMP2|X|'..p.nonce) end
 self.retired[p.steam]=self.retired[p.steam] or {_count=0}
 local retired=self.retired[p.steam]
 if not retired[p.nonce] and retired._count<128 then retired[p.nonce]=true;retired._count=retired._count+1 end
 self.peers[p.key]=nil;self.bySteam[p.steam]=nil
 self:_event{kind='peer_disconnected',peerId=p.key,reason=reason}
end
function T:Close(peerId)
 if peerId then self:_drop(self.peers[peerId],'closed',true);return end
 local peers={};for _,p in pairs(self.peers) do peers[#peers+1]=p end
 for _,p in ipairs(peers) do self:_drop(p,'closed',true);pcall(self.G.GMP_Net_Close,p.steam) end
 self.mode=nil;self.address=nil
end
-- Once a second: "LANES tx p0=<msgs>/<bytes> ..." plus, with the native GMP_Net_Counts() (received, dropped, queued,
-- sent lane 0..3, all totals but queued), " native rx=<d> drop=<d> queued=<n> sent n0=<d> .. n3=<d>" since the last line.
function T:LaneLine(now)
 local suffix=''
 if type(self.G.GMP_Net_Counts)=='function' then
  local ok,rx,drop,queued,s0,s1,s2,s3=pcall(self.G.GMP_Net_Counts)
  if ok and type(rx)=='number' then
   local cur={rx,drop or 0,queued or 0,s0 or 0,s1 or 0,s2 or 0,s3 or 0};local last=self.netCounts or cur
   if self.lanes.start and (now or self.clock())-self.lanes.start>=1 then
    suffix=string.format(' native rx=%d drop=%d queued=%d sent n0=%d n1=%d n2=%d n3=%d',cur[1]-last[1],cur[2]-last[2],cur[3],
     cur[4]-last[4],cur[5]-last[5],cur[6]-last[6],cur[7]-last[7])
    self.netCounts=cur
   elseif not self.netCounts then self.netCounts=cur end
  end
 end
 return self.lanes:Line(now or self.clock(),suffix)
end
function T:Poll()
 if self.mode=='client' and not self.bySteam[self.address] and self.clock()>=(self.connectAt or 0) then
  self.connectAt=self.clock()+.25;self:_send(self.address,'GMP2|C|'..self.nonce)
 end
 for _=1,T.POLL_MAX do
  local ok,steam,text=pcall(self.G.GMP_Net_Poll)
  if not ok or steam==nil then break end
  if id(steam) and type(text)=='string' and #text<=4096 then
   local kind,nonce,tail=text:match('^GMP2|([CAMX])|(%x%x%x%x%x%x%x%x)(.*)$')
   local body=tail and tail:sub(1,1)=='|' and tail:sub(2) or ''
   if kind=='M' and (not tail or tail:sub(1,1)~='|') or kind~='M' and tail~='' then kind=nil end
   local p=self.bySteam[steam]
   local retired=self.retired[steam]
   if kind=='C' and self.mode=='host' and not (retired and retired[nonce])
      and not (retired and retired._count>=128 and (not p or p.nonce~=nonce)) then
    if p and p.nonce~=nonce then self:_drop(p,'replaced',false);p=nil end
    if not p then p=self:_peer(steam,nonce) end
    self:_send(steam,'GMP2|A|'..nonce)
   elseif kind=='A' and self.mode=='client' and steam==self.address and nonce==self.nonce then
    if not p then self:_peer(steam,nonce) end
   elseif p and p.nonce==nonce and kind=='M' and #body>0 and #body<=4000 then
    self:_event{kind='message',peerId=p.key,data=body}
   elseif p and p.nonce==nonce and kind=='X' then self:_drop(p,'closed_by_peer',false) end
  end
 end
 local events=self.events;self.events={};return events
end
return T
