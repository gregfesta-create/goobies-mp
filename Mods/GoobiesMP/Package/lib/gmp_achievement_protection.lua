-- Native lease adapter. A policy receipt is bound to an authenticated session;
-- ownership token survives same-SID migration and is never cleared after a run.
-- Achievements are always blocked during multiplayer (D16): every multiplayer policy requires an active lease.
local Messages=require('gmp_messages')
local P={};P.__index=P
local function positive(v)return type(v)=='number' and v%1==0 and v>=1 and v<=9007199254740991 end
local function policyValid(p)return Messages.ValidatePolicy(p)==true end
local copy=Messages.CopyPolicy
local function same(a,b)return a and b and a.revision==b.revision and a.runGeneration==b.runGeneration and a.locked==b.locked end
P.EXPORTS={'MM_PortableProtectionReady','MM_PortableBeginMultiplayer','MM_PortableMultiplayerRunStarted','MM_PortableEndMultiplayerBeforeRun','MM_PortableMultiplayerActive'}
-- Read-only: true when every native lease export is present. Creates nothing.
function P.HasExports(G)
 if type(G)~='table'then return false end
 for _,name in ipairs(P.EXPORTS)do if type(G[name])~='function'then return false end end
 return true
end
function P.new(G,token)
 if type(token)~='string' or #token<16 or #token>128 or not token:match('^[%w_:%-]+$')then return nil,'invalid_protection_token'end
 if not P.HasExports(G)then return nil,'native_protection_lease_missing'end
 return setmetatable({G=G,token=token},P)
end
function P:_call(name,...)
 local ok,value,reason=pcall(self.G[name],...);if not ok then return nil,'native_protection_error'end;return value,reason
end
function P:Acquire(session,term,policy)
 if type(session)~='table' or type(session.sid)~='string' or session.sid=='' or not positive(term) or (session.authorityTerm or 1)~=term or not policyValid(policy) then return false,'invalid_protection_context'end
 local active=self:_call('MM_PortableMultiplayerActive');if type(active)~='boolean'then return false,'native_protection_unverified'end
 if self.sid and self.sid~=session.sid and active then return false,'achievement_protection_restart_required'end
 local ready,why=self:_call('MM_PortableProtectionReady');if ready~=true then return false,why or 'achievement_protection_unavailable'end
 if active and (self.session~=session or self.sid~=session.sid)then return false,'foreign_active_protection_lease'end
 if not active then local accepted,why=self:_call('MM_PortableBeginMultiplayer',self.token);if accepted~=true then return false,why or 'achievement_protection_unavailable'end end
 if policy.locked then local accepted,why=self:_call('MM_PortableMultiplayerRunStarted',self.token);if accepted~=true then return false,why or 'achievement_protection_run_unverified'end end
 if self:_call('MM_PortableMultiplayerActive')~=true then return false,'native_protection_unverified'end
 self.session=session;self.sid=session.sid;self.term=term;self.policy=copy(policy);return true
end
function P:Readback(session,term,policy)
 if type(session)~='table' or not positive(term) or not policyValid(policy) then return {verified=false,reason='invalid_protection_context'} end
 local active=self:_call('MM_PortableMultiplayerActive')
 local bound=self.session==session and self.sid==session.sid and self.term==term and same(self.policy,policy)
 local ready=self:_call('MM_PortableProtectionReady')==true
 return {session=self.session,term=self.term,policy=self.policy and copy(self.policy),active=active,
  verified=bound and ready and active==true}
end
function P:Transfer(session,term,policy,commit,verify)
 if type(session)~='table' or type(session.identity)~='table' or type(session.identity.key)~='string'
  or not policyValid(policy) or not positive(term) then return false,'invalid_protection_transfer'end
 if type(commit)=='table' and type(verify)=='function' and verify(commit)==true and session
  and session.sid==nil and session.expectedHandoverSession==self.sid and commit.session==self.sid
  and session.expectedHandoverHost==commit.hostKey and session.expectedAuthorityTerm==term
  and term==self.term+1 and commit.term==term and same(policy,self.policy)then
  return nil,'protection_transfer_auth_pending'
 end
 if type(commit)=='table' and self.session==session and self.term==term and same(policy,self.policy)
  and commit.session==self.sid and commit.term==term and type(verify)=='function' and verify(commit)==true then
  return self:Readback(session,term,policy).verified==true
 end
 if type(commit)~='table' or type(verify)~='function' or verify(commit)~=true or not self.session
  or session.sid~=self.sid or commit.session~=self.sid or term~=self.term+1 or commit.term~=term
  or (session.authorityTerm or 1)~=term or not same(policy,self.policy) or policy.locked~=true then return false,'untrusted_protection_transfer'end
 if session.identity.key~=commit.hostKey then
  if type(session.State)~='function' or session:State()~='joined' or session.authenticatedHostKey~=commit.hostKey
   or session.authenticatedAuthorityTerm~=term then return nil,'protection_transfer_auth_pending'end
 elseif not session.started then return nil,'protection_transfer_auth_pending'end
 local active=self:_call('MM_PortableMultiplayerActive')
 if active~=true or self:_call('MM_PortableProtectionReady')~=true then return false,'protection_transfer_native_refused'end
 self.session=session;self.term=term;return true
end
return P
