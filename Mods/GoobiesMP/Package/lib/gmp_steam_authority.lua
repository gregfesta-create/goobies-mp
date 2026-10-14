-- Explicit GMP authority mapping. Steam ownership is admission/discovery only.
local Identity=require('gmp_identity');local A={};A.__index=A
local function parse(text)
 if type(text)~='string' or #text>=128 then return nil end
 local sid,term,id,phase=text:match('^GMPH1:([%w_%-]+):(%d+):(%d+):([CP])$');term=tonumber(term)
 if not sid or #sid>64 or not term or term%1~=0 or term<1 or term>0xffffffff or not Identity.IsValidSteamId64(id) then return nil end
 return {session=sid,term=term,hostKey='steam:'..id,address=id,phase=phase}
end
A.Parse=parse
local function text(record,phase)return table.concat({'GMPH1',record.session,record.term,record.address,phase},':')end
local function same(a,b)return a and b and a.session==b.session and a.term==b.term and a.hostKey==b.hostKey end
function A.new(options)
 local G=options.G or _G
 for _,name in ipairs{'GMP_Lob_Host','GMP_Lob_Pub','GMP_Lob_Move','GMP_Lob_Status'}do
  if type(G[name])~='function' then return nil,'native_authority_mapping_missing' end
 end
 return setmetatable({o=options,G=G},A)
end
function A:_call(name,...)local r=table.pack(pcall(self.G[name],...));if not r[1]then return nil,'native_authority_error'end;return table.unpack(r,2,r.n)end
-- Pending native callbacks are bounded; callers retain the physical hold on failure.
function A:_pending(kind)
 local now=self.o.clock and self.o.clock() or os.clock()
 self.waits=self.waits or {};local started=self.waits[kind]
 if not started then self.waits[kind]=now;return nil,kind=='stage' and 'transport_pending' or 'authority_finalize_pending' end
 if now-started>=25 then return false,'authority_'..kind..'_timeout' end
 return nil,kind=='stage' and 'transport_pending' or 'authority_finalize_pending'
end
function A:_clearWait(kind)if self.waits then self.waits[kind]=nil end end
function A:Invalidate()self.retired=true;self.context=nil;self.committed=nil;self.pending=nil;return true end
function A:Read(result)
 if self.retired then return nil,'authority_context_retired' end
 local raw,generation,lobby=self:_call('GMP_Lob_Host');local record=parse(raw)
 if not record or generation~=result.generation or lobby~=result.lobbyId or record.phase~='C' then return nil,'host_metadata_pending' end
 -- Discovery hint only: actual attributed transport + tickets + expected SID
 -- must confirm this host before an operation is reported joined.
 return record
end
function A:Initialize(session,result)
 if self.retired then return false,'authority_context_retired' end
 if not session or session.identity.key~=self.o.identity.key or session.sid==nil then return false,'actual_host_required' end
 local record={session=session.sid,term=1,hostKey=self.o.identity.key,address=self.o.identity.value}
 if not parse(text(record,'C')) then return false,'invalid_actual_session' end
 local ok,why=self:_call('GMP_Lob_Pub',result.generation,text(record,'C'))
 if ok~=true then return false,why or 'host_metadata_publish_refused' end
 self.context={generation=result.generation,lobbyId=result.lobbyId};self.committed=record;return true
end
function A:Confirm(session,record)
 if self.retired then return false,'authority_context_retired' end
 if not session or session:State()~='joined' or session.sid~=record.session or session.authenticatedHostKey~=record.hostKey
  or session.authorityTerm~=record.term or session.authenticatedAuthorityTerm~=record.term then return false,'authenticated_host_mapping_mismatch' end
 self.committed={session=record.session,term=record.term,hostKey=record.hostKey,address=record.address};return true
end
function A:_stageGraceful(commit,selected)
 if self.retired then return false,'authority_context_retired' end
 local proof=selected and self.o.verifyGracefulSelection or self.o.verifyCommit
 if selected and (type(commit)~='table' or commit.kind~='graceful' or commit.forced~=false) then return false,'untrusted_graceful_selection' end
 if type(proof)~='function' or proof(commit)~=true then return false,'untrusted_authority_commit' end
 local current=self.committed;local target=Identity.Parse(commit.hostKey)
 if not current or commit.session~=current.session or commit.term~=current.term+1 or commit.formerHost~=current.hostKey
  or not target or target.kind~='steam' or target.key==current.hostKey then return false,'stale_authority_commit' end
 local ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 if ready~=true or not self.context or generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context' end
 local nextRecord={session=commit.session,term=commit.term,hostKey=target.key,address=target.value}
 local raw=self:_call('GMP_Lob_Host');local native=parse(raw)
 if self.o.identity.key==current.hostKey then
  if same(native,current) and native.phase=='C' then
   local accepted,why=self:_call('GMP_Lob_Pub',generation,text(nextRecord,'P'))
   if accepted~=true then return false,why or 'pending_host_publish_refused' end
   raw=self:_call('GMP_Lob_Host');native=parse(raw)
  end
  if not same(native,nextRecord) or native.phase~='P' then return self:_pending('stage') end
  if owner~=target.value then
   local accepted,why=self:_call('GMP_Lob_Move',generation,target.value)
   if accepted~=true then return false,why or 'native_owner_transfer_refused' end
  end
 end
 ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 raw=self:_call('GMP_Lob_Host');native=parse(raw)
 if ready~=true or generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context' end
 if not same(native,nextRecord) or native.phase~='P' or owner~=target.value then return self:_pending('stage') end
 self:_clearWait('stage');self.pending=nextRecord;return true
end
-- Selection is verified against the authenticated host stage, independently of
-- local restoration completion. Native stage pin still gates pending P.
function A:ReadPreparation(context,commit)
 if self.retired or context~=self.context or type(commit)~='table' or commit.kind~='graceful'
  or commit.forced~=false or type(self.o.verifyGracefulSelection)~='function'
  or self.o.verifyGracefulSelection(commit)~=true then return nil,'untrusted_graceful_preparation'end
 local old=self.committed;local pending=self.pending
 if not old or not pending or commit.session~=old.session or commit.term~=old.term+1
  or pending.session~=commit.session or pending.term~=commit.term
  or commit.formerHost~=old.hostKey or commit.hostKey~=pending.hostKey then return nil,'stale_graceful_preparation'end
 local ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 local record=parse(self:_call('GMP_Lob_Host'))
 if ready~=true or generation~=context.generation or lobby~=context.lobbyId or owner~=pending.address
  or not same(record,pending) or record.phase~='P'then return nil,'native_preparation_changed'end
 if type(self.G.GMP_Aut_Prep)~='function' or self:_call('GMP_Aut_Prep',generation,commit.session,commit.term,commit.sequence,commit.digest,commit.nonce)~=true then
  return nil,'native_preparation_not_verified'end
 return {session=old.session,term=old.term,hostKey=old.hostKey,address=old.address}
end
function A:PrepareGraceful(commit)return self:_stageGraceful(commit,true)end
function A:Stage(commit)return self:_stageGraceful(commit,false)end
-- Pending discovery can precede restoration after authenticated first-claim
-- selection. It grants no game role; committed C still requires activation.
function A:_stageLoss(commit,selected)
 if self.retired then return false,'authority_context_retired' end
 if type(self.G.GMP_Lob_Loss)~='function' then return false,'native_loss_mapping_missing' end
 local verify=selected and self.o.verifyLossSelection or self.o.verifyLoss
 if type(verify)~='function' or verify(commit)~=true or commit.kind~='loss' then return false,'untrusted_loss_commit' end
 local current=self.committed;local target=Identity.Parse(commit.hostKey)
 if not current or not target or target.kind~='steam' or commit.session~=current.session
  or commit.term~=current.term+1 or commit.formerHost~=current.hostKey or target.key==current.hostKey then return false,'stale_loss_commit' end
 local ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 if ready~=true or not self.context or generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context' end
 local nextRecord={session=commit.session,term=commit.term,hostKey=target.key,address=target.value}
 if owner==self.o.identity.value then
  local raw=self:_call('GMP_Lob_Host');local record=parse(raw)
  if not same(record,nextRecord) or record.phase~='P' then
   local ok,why=self:_call('GMP_Lob_Loss',generation,text(nextRecord,'P'))
   if ok~=true then return false,why or 'loss_mapping_publish_refused' end
  end
  if owner~=target.value then local ok,why=self:_call('GMP_Lob_Move',generation,target.value);if ok~=true then return false,why or 'loss_owner_transfer_refused'end end
 end
 ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 local raw=self:_call('GMP_Lob_Host');local record=parse(raw)
 if ready~=true or generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context' end
 if owner~=target.value or not same(record,nextRecord) or record.phase~='P' then return self:_pending('stage')end
 self:_clearWait('stage');self.pending=nextRecord;return true
end
function A:PrepareLoss(commit)return self:_stageLoss(commit,true)end
function A:StageLoss(commit)return self:_stageLoss(commit,false)end
-- Abort is a withdrawal only. It never rolls authority back to a departed host.
function A:AbortLoss(commit)
 if self.retired or not self.context or not self.committed or type(commit)~='table'
  or commit.kind~='loss' or commit.session~=self.committed.session or commit.term~=self.committed.term+1 then return false,'stale_loss_abort' end
 if type(self.G.GMP_Lob_Abort)~='function'then return false,'native_loss_abort_unavailable'end
 local target=Identity.Parse(commit.hostKey);if not target or target.kind~='steam'then return false,'invalid_loss_abort_host'end
 local expected={session=commit.session,term=commit.term,hostKey=commit.hostKey,address=target.value}
 local ready,generation,lobby,owner=self:_call('GMP_Lob_Status')
 if ready~=true or generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context'end
 if owner==self.o.identity.value then
  local ok,why=self:_call('GMP_Lob_Abort',generation,text(expected,'P'));if ok~=true then return false,why or 'loss_abort_refused'end
 end
 local raw,g,l=self:_call('GMP_Lob_Host')
 if g~=generation or l~=lobby or raw~=text(expected,'A')then return nil,'loss_abort_pending'end
 self.pending=nil;self.lossAborted=true;return true
end
function A:HoldGameplay(commit)
 if self.retired or not self.context or type(commit)~='table' or not self.committed
  or commit.session~=self.committed.session or (commit.term~=self.committed.term and commit.term~=self.committed.term+1)then return false,'stale_gameplay_withdrawal'end
 if type(self.G.GMP_Aut_Hold)~='function'then return false,'native_gameplay_withdrawal_unavailable'end
 return self:_call('GMP_Aut_Hold',self.context.generation,commit.session,commit.term)
end
function A:Finish(session,commit)
 if self.retired then return false,'authority_context_retired' end
 if not self.pending and same(self.committed,{session=commit.session,term=commit.term,hostKey=commit.hostKey}) then return true end
 if not self.pending or not same(self.pending,{session=commit.session,term=commit.term,hostKey=commit.hostKey}) then return false,'unprepared_authority_commit' end
 if self.o.identity.key==commit.hostKey then
  if not session or session.sid~=commit.session or session.authorityTerm~=commit.term or session.identity.key~=commit.hostKey then return false,'actual_replacement_host_required' end
  local ok,why=self:_call('GMP_Lob_Pub',self.context.generation,text(self.pending,'C'))
  if ok~=true then return false,why or 'replacement_host_publish_refused' end
 else
  if not session or type(session.State)~='function' or session:State()~='joined' then return self:_pending('finalize') end
  if session.sid~=commit.session or session.authenticatedHostKey~=commit.hostKey or session.authenticatedAuthorityTerm~=commit.term then return false,'actual_authenticated_replacement_required' end
 end
 local raw,generation,lobby=self:_call('GMP_Lob_Host');local record=parse(raw)
 if generation~=self.context.generation or lobby~=self.context.lobbyId then return false,'stale_lobby_context' end
 if not same(record,self.pending) or record.phase~='C' then return self:_pending('finalize') end
 self:_clearWait('finalize');self.committed=self.pending;self.pending=nil;return true
end
-- D52: the host the lobby maps now (any phase), for a member that is not in the handover (a waiting player).
function A:CurrentHost()
 if self.retired then return nil,'authority_context_retired' end
 local raw,generation,lobby=self:_call('GMP_Lob_Host');local record=parse(raw)
 if not record then return nil,'host_metadata_pending' end
 if self.context and (generation~=self.context.generation or lobby~=self.context.lobbyId) then return nil,'other_lobby' end
 return record
end
function A:JoinContext(result)
 local record,why=self:Read(result);if not record then return nil,why end
 self.context={generation=result.generation,lobbyId=result.lobbyId};return record
end
return A
