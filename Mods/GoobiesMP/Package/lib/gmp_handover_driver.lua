-- Local game-thread migration executor. The caller supplies one authenticated
-- shared arbiter; this module never elects an independent local authority.
local H=require('gmp_handover')
local D={};D.__index=D
function D.new(options) return setmetatable({options=options,term=options.term or 1,phase='idle'},D) end
local function accepted(fn,...)
    local ok,result,why=pcall(fn,...)
    return ok and result==true,ok and why or tostring(result)
end
function D:_fail(stage,why)
    self.phase='failed';self.failure=stage..':'..tostring(why or 'rejected')
    return false,self.failure
end
function D:Apply(commit,checkpoint)
    local o=self.options
    if self.phase~='idle' then return false,'migration_in_progress' end
    if type(commit)~='table' or commit.session~=o.session or type(commit.term)~='number'
        or commit.term%1~=0 or commit.term~=self.term+1 or type(commit.sequence)~='number'
        or commit.sequence%1~=0 or commit.sequence<1 then return false,'stale_commit' end
    if type(o.verifyCommit)~='function' or not accepted(o.verifyCommit,commit) then return false,'untrusted_commit' end
    local ok,state=H.Validate(checkpoint);if not ok then return false,state end
    local participant,host
    for _,player in ipairs(state.players) do
        if player.key==o.key and player.conn=='connected' then participant=true end
        if player.role=='host' then host=player.key end
    end
    if not participant or host~=commit.hostKey then return false,'participant_mismatch' end
    if not o.game or type(o.game.Prepare)~='function' or type(o.game.Restore)~='function'
        or type(o.game.SetPaused)~='function' or not o.transport or type(o.transport.SwitchRole)~='function'
        or type(o.activate)~='function' or type(o.applied)~='function' then return false,'missing_runtime_adapter' end
    ok=accepted(o.game.Prepare,o.game,state);if not ok then return false,'restore_not_ready' end
    self.phase='applying'
    local why
    ok,why=accepted(o.game.SetPaused,o.game,true);if not ok then return self:_fail('pause',why) end
    if type(o.game.RestoreStep)=='function' then
        self.pendingCommit={session=commit.session,term=commit.term,sequence=commit.sequence,
            hostKey=commit.hostKey,formerHost=commit.formerHost,forced=commit.forced,kind=commit.kind,digest=commit.digest,nonce=commit.nonce,request=commit.request}
        self.pendingState=state;self.phase='restoring'
        return self:Step()
    end
    ok,why=accepted(o.game.Restore,o.game);if not ok then return self:_fail('restore',why) end
    return self:_restored(commit,state)
end
function D:Step()
    if self.phase~='restoring' then return false,'not_restoring' end
    local ok,result,why=pcall(self.options.game.RestoreStep,self.options.game)
    if ok and result==nil then return false,'restore_pending' end
    if not ok or result~=true then return self:_fail('restore',ok and why or result) end
    return self:_restored(self.pendingCommit,self.pendingState)
end
function D:_restored(commit,state)
    if not self.options.deferActivation then return self:_activate(commit,state) end
    self.pendingCommit=commit;self.pendingState=state;self.phase='restored'
    return true
end
function D:ActivateRestored()
    if self.phase~='restored' then return false,'native_restore_not_ready' end
    return self:_activate(self.pendingCommit,self.pendingState)
end
function D:_activate(commit,state)
    local o=self.options;local ok,why
    local role=o.key==commit.hostKey and 'host' or 'client'
    if o.beforeActivate then
        ok,why=accepted(o.beforeActivate,commit,state)
        if not ok and why=='transport_pending' then return false,'activation_pending' end
        if not ok then return self:_fail('authority_mapping',why) end
    end
    ok,why=accepted(o.transport.SwitchRole,o.transport,role,commit.term,commit)
    if not ok then return self:_fail('transport',why) end
    ok,why=accepted(o.activate,role,state,commit);if not ok then return self:_fail('session',why) end
    self.term=commit.term;self.commit={session=commit.session,term=commit.term,
        hostKey=commit.hostKey,sequence=commit.sequence};self.phase='waiting'
    self.pendingCommit=nil;self.pendingState=nil
    return self:ConfirmApplied()
end
function D:ConfirmApplied()
    if self.phase~='waiting' then return false,'not_waiting' end
    local o=self.options
    local ok=accepted(o.applied,o.key,self.commit.term,self.commit.sequence)
    if ok then self.confirmed=true end
    return ok,ok and nil or 'application_receipt_pending'
end
function D:Resume(commit)
    local o=self.options;local current=self.commit
    if self.phase~='waiting' or not self.confirmed or type(commit)~='table' or not current
        or commit.session~=current.session or commit.term~=current.term
        or commit.sequence~=current.sequence or commit.hostKey~=current.hostKey then return false,'stale_release' end
    if type(o.verifyRelease)~='function' or not accepted(o.verifyRelease,commit) then return false,'peers_not_restored' end
    if o.beforeRelease then
        local ok,why=accepted(o.beforeRelease,commit)
        if not ok and why=='authority_finalize_pending' then return false,'release_pending' end
        if not ok then return self:_fail('authority_finalize',why) end
    end
    local ok,why=accepted(o.game.SetPaused,o.game,false)
    if not ok then return self:_fail('resume',why) end
    self.phase='idle';self.commit=nil;self.confirmed=nil;return true
end
return D
