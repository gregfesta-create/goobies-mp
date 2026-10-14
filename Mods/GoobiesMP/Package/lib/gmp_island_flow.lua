-- Binds reliable session state to an injected game adapter. No engine globals.
local I=require('gmp_islands')
local F={};F.__index=F
function F.new(options)
    return setmetatable({options=options,world=options.world,failed=false,started={},released={},hostQueuePending=false},F)
end
function F:_session() return self.options.session() end
function F:Menu()
    local session=self:_session();local state=session and session.islands
    if not state then return end
    if self.options.role=='host' and session.EndIslandRun then session:EndIslandRun() end
    self.world:RestorePortals()
    self.failed=false;self.started={};self.released={};self.waitAt=nil
    self.hostQueuePending=false;self.commitQueuePending=false;self.readySent=nil;self.resumeAt=nil;self.rewardWaitPaused=nil
    session.islandResumeToken=nil;session.loadingWaiting=nil;session.loadingSignature=nil
    state.phase='idle';state.island=0;state.pending=nil;state.current=nil
    state.ready={};state.required={}
    session.islandCommit=nil;session.travelCheck=nil;session.travelWaiting=nil
    if self.world.SetTravelNotice then self.world:SetTravelNotice(nil) end
end
function F:Fail(why)
    self.failed=true;pcall(self.world.SetWaiting,self.world,true)
    self.options.log('Island handoff stopped: '..tostring(why))
end
function F:Manifest()
    local session=self:_session()
    local state=session and session.islands
    if self.options.role=='client' and state and state.phase=='playing' and state:Retry() then
        -- Retry can generate before any menu-only tick is observable.
        self.started={};self.released={};self.readySent=nil;self.waitAt=nil
        self.rewardWaitPaused=nil;session.travelCheck=nil;session.travelWaiting=nil;session.loadingWaiting=nil
    end
    -- ODD_INTERACTIONS row 8 (Coder C): the generator has the settings now; a resume refresh must not replace them
    if self.options.role=='client' and state and state.phase=='generating' then state.taken=true end
    return state and state.pending
end
function F:WaitAfterLoading()
    -- Host authority keeps ticking while peers load. Pausing it resumes latent
    -- island cleanup against a paused Blueprint frame and stalls all peers.
    if self.options.role=='host' then self.waitAt=nil;return end
    if self.options.now then self.waitAt=self.options.now()+1.0
    else self.world:SetWaiting(true) end
end
function F:Generated(generator)
    if self.failed then return false end
    local session=self:_session();if not session or not session.islands then return false end
    local state=session.islands
    if self.options.role=='host' then
        -- Retry reloads gameplay without necessarily exposing a menu-only tick.
        -- Portal travel has already entered awaiting_manifest; generation while
        -- playing therefore starts a fresh run rather than extending the old one.
        if state.phase=='playing' then self:Menu() end
        if state.epoch==0 or state.phase=='idle' then session:BeginIslandRun() end
        local manifest=self.world:Capture(generator,state.epoch,state.island+1)
        self:WaitAfterLoading()
        local ok=session:PublishIsland(manifest)
        self.hostQueuePending=not ok
        assert(state.pending,'Host manifest rejected')
        assert(session:HostIslandReady(I.Stamp(manifest)),'Host readiness rejected')
    else
        assert(state.pending,'Client generated without host settings')
        local manifest=self.world:Capture(generator,state.pending.epoch,state.pending.island)
        self:WaitAfterLoading()
        assert(I.Stamp(manifest)==I.Stamp(state.pending),'Client island settings differ from host')
        session:IslandGenerated(I.Stamp(manifest)) -- queue pressure is retried by Tick
    end
    return true
end
function F:Portal()
    if self.failed then return false end
    local session=self:_session();if not session or not session.islands then return false end
    if self.options.role=='host' then
        return session:RequestIslandTransition(session.identity.key,session.islands.epoch,session.islands.island)
    end
    return session:RequestPortal()
end
function F:Tick()
    if self.failed then return end
    local session=self:_session();if not session or not session.islands then return end
    local state=session.islands
    if state.phase=='host_left' then
        self.world:SetWaiting(true)
        if self.world.SetTravelNotice then self.world:SetTravelNotice('Host left the run - return to the menu to rejoin') end
        return
    end
    -- row 8 (Coder C): also while a resumed entry has not started, so it follows a host that moved on
    if self.options.role=='client' and (state.phase=='idle' or (state.Refreshable and state:Refreshable())) and session.RequestIslandResume and self.options.now then
        local now=self.options.now()
        if not self.resumeAt or now>=self.resumeAt then session:RequestIslandResume();self.resumeAt=now+1 end
    end
    if session.travelGate and self.world.RewardsBlocked then
        local locallyBlocked=self.world:RewardsBlocked()
        session:UpdateTravelGate(locallyBlocked)
        if session.UpdateLoadingNotice then session:UpdateLoadingNotice() end
        local slots=session:TravelWaiters()
        if #slots==0 and session.LoadingWaiters then slots=session:LoadingWaiters() end
        -- Only ready players wait paused; reward choices and native fades must finish.
        local pauseWait=#slots>0 and not locallyBlocked and (state.phase=='playing' or state.phase=='generating' or state.phase=='ready')
        if pauseWait then self.world:SetWaiting(true);self.rewardWaitPaused=true
        elseif self.rewardWaitPaused then self.world:SetWaiting(false);self.rewardWaitPaused=nil end
        if self.world.SetTravelNotice then
            local text
            if #slots>0 then text='Waiting for Player'..(#slots>1 and 's ' or ' ')..table.concat(slots,', ')..' to be ready' end
            self.world:SetTravelNotice(text)
        end
    end
    if self.waitAt and self.options.now()>=self.waitAt then
        if state.phase=='generating' or state.phase=='ready' then self.world:SetWaiting(true) end
        self.waitAt=nil
    end
    if self.options.role=='host' then
        if state.phase=='awaiting_manifest' and state.island>0 then
            local token=state.epoch..':'..(state.island+1)
            if not self.started[token] and self.world:Transition() then self.started[token]=true end
        elseif state.phase=='generating' then
            if self.hostQueuePending then self.hostQueuePending=not session:PublishIsland(state.pending) end
            local allReady=true
            for key in pairs(state.required) do if not state.ready[key] then allReady=false end end
            if allReady and not self.hostQueuePending then
                local sent=session:CommitIsland()
                self.commitQueuePending=not sent
            end
        end
        if self.commitQueuePending then self.commitQueuePending=not session:ResendIslandCommit() end
    else
        if state.pending then
            local token=state.pending.epoch..':'..state.pending.island
            -- row 8 (Coder C): a resumed player sent on from the island it generated travels like a portal
            if state.phase=='generating' and not self.started[token] and (state.island>0 or state.travel) then
                if self.world:Transition() then self.started[token]=true end
            elseif state.phase=='ready' then
                local stamp=I.Stamp(state.pending)
                if self.readySent~=token and session:IslandGenerated(stamp) then self.readySent=token end
            end
        elseif state.phase=='transitioning' then self.world:SetWaiting(true) end
    end
    if state.phase=='playing' and not self.commitQueuePending then
        local token=state.epoch..':'..state.island
        if not self.released[token] and not self.rewardWaitPaused then self.world:SetWaiting(false);self.released[token]=true end
    end
end
return F
