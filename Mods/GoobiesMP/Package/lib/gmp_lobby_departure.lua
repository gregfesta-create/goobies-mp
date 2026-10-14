-- Presentation of authenticated authority updates, never local role election.
-- snapshot() is supplied by the transport owner after authentication/term checks.
local D={};D.__index=D
local function token(s) return tostring(s.sid)..':'..tostring(s.term)..':'..tostring(s.revision) end
local function integer(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
function D.new(options)
    assert(type(options.snapshot)=='function' and type(options.session)=='function','departure providers required')
    return setmetatable({options=options,serial=0},D)
end
function D:_current()
    local session,role=self.options.session();local s=self.options.snapshot()
    if not session or not s or s.authenticated~=true or s.active~=true or s.paused~=true
        or type(s.sid)~='string' or not integer(s.term,1) or not integer(s.revision,0)
        or type(s.me)~='string' or s.sid~=session.sid or not session.identity or s.me~=session.identity.key then return nil end
    return s,session,role
end
function D:Tick()
    local s,session,role=self:_current();local p=self.pending
    if not p then return end
    if not s or session~=p.session or role~=p.role or token(s)~=p.context then self.pending=nil;self.error=nil;return end
    local receipt=s.receipt
    if receipt and receipt.request==p.request then
        -- The winner is transport state. A local request acceptance only means
        -- queued; it cannot set a role or choose a winner here.
        if receipt.accepted==true and type(s.winner)=='string' then self.pending=nil;self.error=nil
        elseif receipt.accepted==false then self.pending=nil;self.error=receipt.reason or 'claim_rejected' end
    elseif type(s.winner)=='string' then self.pending=nil;self.error=nil end
end
function D:Model()
    self:Tick();local s=self:_current()
    if not s then return {active=false,canClaim=false} end
    local _,_,role=self:_current()
    return {active=true,paused=true,canClaim=s.eligible==true and not s.winner and not self.pending
            and type(self.options.claim)=='function',canLeave=role=='client' and type(self.options.leave)=='function',
        canCancel=role=='host' and s.phase=='offered' and not s.winner and type(self.options.cancel)=='function',
        pending=self.pending~=nil,winner=s.winner,error=self.error,players=s.players,
        status=self.pending and 'Requesting host authority...'
            or s.winner and ('Host selected: '..tostring(s.winner)..'. Restoring the session...')
            or self.error or (role=='host' and 'Waiting for another player to become host. Cancel to keep hosting.'
                or 'Host departure. Become host or quit to the main menu.')}
end
function D:Cancel()
    local s=self:_current()
    if not s or not self:Model().canCancel then return false,'cancel_unavailable' end
    local ok,accepted,why=pcall(self.options.cancel)
    if not ok then return false,'cancel_callback_failed' end
    if accepted then self.pending=nil;self.error=nil end
    return accepted,why
end
function D:Claim()
    self:Tick();local s,session,role=self:_current()
    if not s or not self:Model().canClaim then return false,'claim_unavailable' end
    self.serial=self.serial+1
    local request=token(s)..':'..s.me..':'..self.serial
    self.pending={session=session,role=role,context=token(s),request=request};self.error=nil
    local ok,accepted,why=pcall(self.options.claim,{sid=s.sid,term=s.term,revision=s.revision,key=s.me,request=request})
    if not ok or not accepted then self.pending=nil;self.error=ok and (why or 'claim_rejected') or 'claim_callback_failed';return false,self.error end
    return true
end
function D:Leave()
    local s=self:_current()
    if not s or not self:Model().canLeave then return false,'leave_unavailable' end
    local ok,accepted,why=pcall(self.options.leave,{sid=s.sid,term=s.term,revision=s.revision,key=s.me})
    if not ok then return false,'leave_callback_failed' end
    if accepted then self.pending=nil;self.error=nil end
    return accepted,why
end
return D
