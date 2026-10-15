-- Native async lobby operations + actual authenticated session activation.
-- A Steam lobby result is not multiplayer join success. Receipt acceptance is
-- delayed until the real Host starts or Client completes GMP_Auth + JOIN_ACCEPT.
local Identity=require('gmp_identity')
local B={};B.__index=B
local function decimal(v)return type(v)=='string' and #v<=20 and v:match('^[1-9]%d*$')~=nil end
local function generation(v)return type(v)=='number' and v%1==0 and v>=1 and v<=0xffffffff end
function B.new(options)
 assert(type(options.activate)=='function' and type(options.session)=='function','session activation required')
 local G=options.G or _G
 for _,name in ipairs{'GMP_Lob_Status','GMP_Lob_Create','GMP_Lob_Join','GMP_Lob_Cancel','GMP_Lob_Privacy','GMP_Lob_Leave'} do
  if type(G[name])~='function' then return nil,'native_lobby_missing' end
 end
 if options.requireAuthority then
  for _,name in ipairs{'GMP_Aut_Status','GMP_Aut_Hold','GMP_Aut_Prep','GMP_Aut_Owned','GMP_Auth_Adopt','GMP_Tkt_Adopt'}do
   if type(G[name])~='function'then return nil,'native_provider_incompatible:'..name end
  end
 end
 return setmetatable({o=options,G=G},B)
end
function B:_call(name,...)
 local fn=self.G[name]
 if type(fn)~='function' then self.lastNativeError={name=name,kind=type(fn),reason='native_function_missing'};return nil,'native_lobby_error' end
 local r=table.pack(pcall(fn,...))
 if not r[1] then self.lastNativeError={name=name,kind=type(fn),reason=tostring(r[2]):gsub('[%c]',' '):sub(1,240)};return nil,'native_lobby_error' end
 self.lastNativeError=nil;return table.unpack(r,2,r.n)
end
function B:Snapshot()
 local ready,gen,lobby,owner,request,accepted,reason=self:_call('GMP_Lob_Status')
 if type(ready)~='boolean' or not generation(gen) then return {ready=false,reason='Steam lobby backend unavailable.'} end
 if self.generation and self.generation~=gen then self.receipt=nil end
 self.generation=gen
 local pending=self.pending
 if pending and pending.generation~=gen then self.pending=nil;pending=nil end
 if pending and request==pending.request then
  if accepted~=true then self.receipt={request=pending.request,accepted=false,reason='steam_lobby_result_'..tostring(reason)};self.pending=nil
  elseif not decimal(lobby) or not Identity.IsValidSteamId64(owner) then
   self.receipt={request=pending.request,accepted=false,reason='invalid_native_lobby_result'};self.pending=nil;self:_call('GMP_Lob_Leave')
  else
   if not pending.activated then
    local activation={lobbyId=lobby,owner=owner,generation=gen,maxPlayers=pending.maxPlayers}
    if self.o.resolve then
     local ok,resolved,why=pcall(self.o.resolve,pending.kind,activation)
     if ok and resolved==nil and why=='host_metadata_pending' then return {ready=ready,generation=gen} end
     if not ok or not resolved then self.pending=nil;self:_call('GMP_Lob_Leave');return {ready=ready,generation=gen,receipt={request=pending.request,accepted=false,reason=ok and why or 'host_metadata_error'}} end
     activation=resolved
    end
    local ok,result,why=pcall(self.o.activate,pending.kind,activation)
    if not ok or result~=true then
     self.receipt={request=pending.request,accepted=false,reason=ok and (why or 'session_activation_failed') or 'session_activation_error'}
     self.pending=nil;self:_call('GMP_Lob_Leave')
    else pending.activated=true;pending.lobby=lobby end
   end
   if self.pending then
    local session,role=self.o.session()
    local joined=session and session.identity and session.sid and ((pending.kind=='create' and role=='host')
     or (pending.kind=='join' and role=='client' and type(session.State)=='function'
      and (session:State()=='joined' or session:State()=='waiting')))   -- D52: waiting for the next game is connected
    if joined and self.o.confirm then
     local ok,verified,why=pcall(self.o.confirm,session,role)
     if not ok or verified~=true then
      self.receipt={request=pending.request,accepted=false,reason=ok and (why or 'host_mapping_unverified') or 'host_mapping_error'}
      self.pending=nil;self:_call('GMP_Lob_Leave');if self.o.failed then self.o.failed() end
      joined=false
     end
    end
    if joined then self.receipt={request=pending.request,accepted=true,sid=session.sid};self.pending=nil end
    -- D52: the session ended the attempt itself (the host refused the join; the app left the Steam lobby)
    if session then pending.sawSession=true end
    if not session and self.pending and pending.sawSession then self.receipt={request=pending.request,accepted=false,reason='session_ended'};self.pending=nil end
    if session and role=='client' and session:State()=='disconnected' then
     self.receipt={request=pending.request,accepted=false,reason=session.reason or 'authentication_or_join_failed'}
     self.pending=nil;self:_call('GMP_Lob_Leave');if self.o.failed then self.o.failed() end
    end
   end
  end
 end
 local receipt=self.receipt and {request=self.receipt.request,accepted=self.receipt.accepted,sid=self.receipt.sid,reason=self.receipt.reason}
 return {ready=ready,generation=gen,receipt=receipt,reason=not ready and 'Cancelling the previous Steam lobby operation.' or nil}
end
function B:_begin(kind,operation)
 if type(operation)~='table' then return false,'invalid_operation' end
 if self.o.authorize then
  local ok,allowed,why=pcall(self.o.authorize);if not ok or allowed~=true then return false,ok and (why or 'real_steam_auth_required') or 'authentication_provider_error' end
 end
 local snapshot=self:Snapshot();if not snapshot.ready or self.pending or operation.generation~=snapshot.generation then return false,'lobby_operation_unavailable' end
 if type(operation.request)~='string' or #operation.request<1 or #operation.request>95 then return false,'invalid_request' end
 if kind=='create' and (type(operation.maxPlayers)~='number' or operation.maxPlayers%1~=0 or operation.maxPlayers<1 or operation.maxPlayers>64) then return false,'invalid_max_players' end
 local result,why
 if kind=='create' then
  local privacy=operation.privacy or self.o.privacy or 1
  if type(privacy)~='number' or privacy%1~=0 or privacy<0 or privacy>3 then return false,'invalid_lobby_privacy' end
  if self:_call('GMP_Lob_Privacy',privacy)~=true then return false,'lobby_privacy_unavailable' end
  result,why=self:_call('GMP_Lob_Create',operation.generation,operation.request,operation.maxPlayers)
 else result,why=self:_call('GMP_Lob_Join',operation.generation,operation.request,operation.lobbyId) end
 if result~=true then return false,why or 'steam_lobby_request_refused' end
 self.pending={kind=kind,generation=operation.generation,request=operation.request,maxPlayers=operation.maxPlayers};self.receipt=nil;return true
end
-- Cross-PC (CROSS_PC_GAPS 1.1/1.2), inert until the native exports exist: the Steam overlay invite dialog for the
-- current lobby, and an accepted invite or +connect_lobby lobby id (taken once). The export is GMP_Lob_JoinReq:
-- UE4SS registers names of at most 15 characters (Coder B's provider, e048e22).
function B:CanInvite() return type(self.G.GMP_Lob_Invite)=='function' end
function B:Invite()
 if not self:CanInvite() then return false,'invite_unavailable' end
 local ok,why=self:_call('GMP_Lob_Invite')
 return ok==true,why
end
function B:PendingJoin()
 if type(self.G.GMP_Lob_JoinReq)~='function' then return nil end
 local lobby=self:_call('GMP_Lob_JoinReq')
 return decimal(lobby) and lobby or nil
end
-- 1.0.1: a client leaves its Steam lobby (App:_leaveSteamLobby: voluntary LEAVE, then LeaveNative after the ack).
function B:Leave()
 if type(self.o.leave)~='function' then return false,'leave_unavailable' end
 local ok,accepted,why=pcall(self.o.leave)
 if not ok or accepted~=true then return false,ok and (why or 'leave_refused') or 'leave_callback_failed' end
 self.pending=nil;self.receipt=nil;return true
end
function B:LeaveNative() return self:_call('GMP_Lob_Leave') end
-- t3 friend reports (Coder A): the host's Cancel closes its lobby (App:_closeSteamLobby tells the players first).
function B:CloseLobby()
 if type(self.o.close)~='function' then return false,'close_unavailable' end
 local ok,accepted,why=pcall(self.o.close)
 if not ok or accepted~=true then return false,ok and (why or 'close_refused') or 'close_callback_failed' end
 self.pending=nil;self.receipt=nil;return true
end
-- D53: the Host dropdown's Steam lobbies (gmp_lobby_browser.lua), refreshed every LIST_SECONDS while asked for:
-- GMP_Lob_ListReq(friendsOnly) starts a native refresh, GMP_Lob_List() returns the latest result. Without the
-- exports the list is empty.
B.LIST_SECONDS=3
-- D55: the host's typed lobby size on the Steam lobby: GMP_Lob_Limit(n) -> true | false, reason (Coder C, b7ce24f;
-- SetLobbyMemberLimit, owner only). nil, 'unavailable' without the export.
function B:SetMemberLimit(n)
 if type(self.G.GMP_Lob_Limit)~='function' then return nil,'unavailable' end
 local ok,result,why=pcall(self.G.GMP_Lob_Limit,n)
 if not ok then return false,'error' end
 if result==true then return true end
 return false,why or 'refused'
end
-- Test 15: the Refresh button: a native list refresh now (GMP_Lob_ListReq).
function B:RefreshLobbies(friendsOnly)
 if type(self.G.GMP_Lob_ListReq)~='function' then return false,'lobby_list_unavailable' end
 self.listAt,self.listFriends=self.o.clock and self.o.clock() or os.clock(),friendsOnly==true
 if not self:_listReq(friendsOnly) then
  local why=self.listLog and self.listLog.error or 'refused'
  self:_log('LOBBYLIST refresh failed: %s',why)
  return false,'native_error: '..why
 end
 return true
end
function B:_log(fmt,...)
 if type(self.o.log)~='function' then return end
 local ok,line=pcall(string.format,fmt,...)
 pcall(self.o.log,ok and line or tostring(fmt))
end
local function nativeError(self)
 local e=self.lastNativeError
 return e and (tostring(e.name)..': '..tostring(e.reason)) or 'refused'
end
-- One native list request; the outcome is logged with the next list read (friend_check.py parses LOBBYLIST).
function B:_listReq(friendsOnly)
 local result=self:_call('GMP_Lob_ListReq',friendsOnly==true)
 local ok=result~=nil and result~=false
 self.listLog={ok=ok,error=not ok and nativeError(self) or nil,friendsOnly=friendsOnly==true}
 return ok
end
function B:ListLobbies(friendsOnly)
 if type(self.G.GMP_Lob_ListReq)~='function' or type(self.G.GMP_Lob_List)~='function' then return {} end
 local now=self.o.clock and self.o.clock() or os.clock()
 if not self.listAt or now-self.listAt>=B.LIST_SECONDS or self.listFriends~=friendsOnly then
  self.listAt,self.listFriends=now,friendsOnly;self:_listReq(friendsOnly)
 end
 local Browser=require('gmp_lobby_browser')
 local text,listGen=self:_call('GMP_Lob_List')
 local mine=self.o.modHash and self.o.modHash() or nil
 local out,same={},0
 for _,e in ipairs(Browser.Filter(Browser.Sort(Browser.Parse(text)),friendsOnly==true)) do
  -- t3 friend reports (Coder A): another Goobies MP version is marked and not joinable, with the reason
  local version=require('gmp_config').MOD_VERSION
  out[#out+1]={id=e.id,label=Browser.Label(e,mine,version),joinable=Browser.Joinable(e,version),refusal=Browser.Refusal(e,version),entry=e}
  if mine and e.mods==mine then same=same+1 end
 end
 -- at most one line per list request
 local l=self.listLog
 if l then
  self.listLog=nil
  self:_log('LOBBYLIST req=%s list_gen=%s lobbies=%d same_mods=%d friendsOnly=%s%s',l.ok and 'ok' or 'native_error',
   tostring(math.tointeger(listGen) or '-'),#out,same,tostring(l.friendsOnly),l.error and (' error='..l.error) or '')
 end
 return out
end
-- D53: the host's lobby data (GMP_Lob_Data -> SetLobbyData), sent only when a value changed.
function B:PublishData(fields)
 if type(self.G.GMP_Lob_Data)~='function' or type(fields)~='table' then return false end
 self.published=self.published or {}
 local keys={};for k in pairs(fields) do keys[#keys+1]=k end;table.sort(keys)
 for _,k in ipairs(keys) do
  local v=tostring(fields[k])
  if self.published[k]~=v and self:_call('GMP_Lob_Data',k,v)==true then self.published[k]=v end
 end
 return true
end
function B:Create(operation)return self:_begin('create',operation) end
function B:Join(operation)return self:_begin('join',operation) end
function B:Cancel(request,gen)
 local p=self.pending;if not p or p.request~=request or p.generation~=gen then return false,'cancellation_unavailable' end
 if p.activated then
  local accepted,why=self:_call('GMP_Lob_Leave')
  if accepted==true then self.pending=nil;self.receipt=nil;if self.o.failed then self.o.failed() end end
  return accepted==true,why
 end
 local accepted,why=self:_call('GMP_Lob_Cancel',gen,request)
 if accepted==true then self.pending=nil;self.receipt=nil end;return accepted==true,why
end
return B
