-- Single authenticated coordinator, selected from a frozen ACKed checkpoint.
-- Sender identity comes from the transport adapter, never request.key alone.
-- This module selects a winner; it never writes game state or transport roles.
local H=require('gmp_handover')
local D={};D.__index=D
local function integer(n) return type(n)=='number' and n%1==0 and n>=1 and n<=9007199254740991 end
local function copy(t) local r={};for k,v in pairs(t or {}) do r[k]=v end;return r end
function D.new(o)
    local ok,state=H.Validate(o.checkpoint)
    if not ok or type(o.sid)~='string' or o.sid=='' or not integer(o.term)
        or not integer(o.sequence) or type(o.digest)~='string' or o.digest==''
        or type(o.paused)~='function' or type(o.ready)~='function'
        or (o.kind~='graceful' and o.kind~='loss') then return nil,'invalid_departure_binding' end
    local host,coordinator,slot;local required={};local eligible={}
    for _,p in ipairs(state.players) do
        if p.role=='host' then host=p.key end
    end
    for _,p in ipairs(state.players) do
        if p.conn=='connected' and (o.kind=='graceful' or p.key~=host) then required[p.key]=true end
        if p.conn=='connected' and p.key~=host then
            eligible[p.key]=true
            if not slot or p.slot<slot then slot=p.slot;coordinator=p.key end
        end
    end
    if o.kind=='graceful' then coordinator=host end
    if not coordinator or o.coordinator~=coordinator then return nil,'wrong_departure_coordinator' end
    local self=setmetatable({o=copy(o),state=state,host=host,coordinator=coordinator,required=required,
        eligible=eligible,revision=1,receipts={},applied={},phase='offered'},D)
    return self
end
function D:_paused()
    local ok,value=pcall(self.o.paused)
    return ok and value==true
end
function D:Snapshot(me)
    if not self.required[me] then return nil end
    return {authenticated=true,active=self.phase~='canceled',paused=self:_paused(),sid=self.o.sid,
        term=self.o.term,revision=self.revision,me=me,eligible=self.eligible[me]==true,winner=self.winner,
        receipt=self.receipts[me] and copy(self.receipts[me]),phase=self.phase,coordinator=self.coordinator}
end
function D:Claim(sender,r)
    if type(r)~='table' or sender~=r.key or not self.eligible[sender] then return false,'not_eligible' end
    if r.sid~=self.o.sid or r.term~=self.o.term or r.revision~=self.revision
        or type(r.request)~='string' or #r.request<1 or #r.request>256 then
        return false,'stale_departure_offer'
    end
    local receipt=self.receipts[sender]
    if receipt and receipt.request==r.request then
        return receipt.accepted,receipt.accepted and copy(self.commit) or receipt.reason
    end
    local function reject(reason)
        self.receipts[sender]={request=r.request,accepted=false,reason=reason};return false,reason
    end
    if self.phase~='offered' or self.winner then return reject('winner_selected') end
    if not self:_paused() then return reject('native_pause_unverified') end
    local ok,ready,reason=pcall(self.o.ready,sender,self.state)
    if not ok or ready~=true then return reject(ok and (reason or 'restore_unavailable') or 'restore_preflight_failed') end
    self.winner=sender;self.phase='selected'
    self.receipts[sender]={request=r.request,accepted=true}
    -- Authoritative next-term state is detached; original checkpoint/roster
    -- and the user's current role remain unchanged until runtime activation.
    local valid,state=H.Validate(self.state);assert(valid)
    for _,p in ipairs(state.players) do
        p.role=p.key==sender and 'host' or 'client'
        if self.o.kind=='loss' and p.key==self.host then p.conn='disconnected' end
    end
    self.selectedState=state
    self.commit={session=self.o.sid,term=self.o.term+1,sequence=self.o.sequence,
        digest=self.o.digest,hostKey=sender,formerHost=self.host,forced=false,kind=self.o.kind}
    return true,copy(self.commit)
end
function D:Applied(sender,token,success)
    if self.phase~='selected' or not self.required[sender] or type(token)~='table'
        or token.sid~=self.o.sid or token.term~=self.commit.term or token.sequence~=self.o.sequence
        or token.digest~=self.o.digest or token.hostKey~=self.winner then return false,'stale_application_receipt' end
    if success~=true then self.phase='failed';return false,'participant_restore_failed' end
    self.applied[sender]=true;return true
end
function D:ActivationReady()
    if self.phase~='selected' or not self:_paused() then return false end
    for key in pairs(self.required) do if not self.applied[key] then return false end end
    return true
end
function D:Cancel(sender)
    if self.o.kind~='graceful' or sender~=self.host or self.phase~='offered' then return false,'departure_committed' end
    self.phase='canceled';return true
end
return D
