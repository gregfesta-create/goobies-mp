-- Game-thread application of reliable pause state; transport continues ticking.
local D={};D.__index=D
function D.new(options) return setmetatable({options=options},D) end
-- Only driver-owned presentation and checkpoint work is released. Native
-- world hooks and shared notices survive an authenticated role replacement.
function D:Dispose()
    if self.disposed then return end
    self.disposed=true
    if self.roleLabel then self.roleLabel:Clear();self.roleLabel=nil end
    if self.dump then self.dump:Cancel();self.dump=nil end
end
function D:Tick(now)
    if self.disposed then return end
    local o=self.options;local session=o.session();if not session then
        if self.roleLabel then self.roleLabel:Clear() end
        if self.dump then self.dump:Cancel() end;return end
    -- Optional presentation dependency: incomplete older profiles must not
    -- prevent transport/shared pause startup. Deployment includes the module.
    if not self.roleLabel and not self.roleLabelUnavailable and o.world.G and o.world.IsEscapeMenuOpen and o.world.LocalWorldPawn then
        local ok,label=pcall(require,'gmp_pause_role_label')
        if ok then self.roleLabel=label.new(o.world,o.log)
        else self.roleLabelUnavailable=true;o.log('Esc role label unavailable: '..tostring(label):sub(1,300)) end
    end
    if self.escRoleSession~=session then
        self.escRoleSession=session
        local _,pawn=o.world:LocalWorldPawn()
        self.escRoleMenuOpen=self.roleLabel and pawn and self.roleLabel:Observed(pawn:GetFullName()) or false
    end
    if o.world.ReadPauseScalar and not self.dump then
        self.dump=require('gmp_pause_dump').new(function(field) return o.world:ReadPauseScalar(field) end,o.log)
    end
    if self.dump and self.dumpSession~=session then self.dump:Cancel();self.dump.key=nil;self.dumpSession=session end
    local pause=session:EnablePause()
    if o.world.InstallEscapeHook then o.world:InstallEscapeHook() end
    if o.world.InstallResumeHook then o.world:InstallResumeHook() end
    local escape=o.world.ConsumeEscapeRequest and o.world:ConsumeEscapeRequest()
    if escape then
        local _,current=o.world:LocalWorldPawn()
        if current and current:GetFullName()==escape.name then
            self.escRoleMenuOpen=escape.paused==true
            if self.roleLabel then self.roleLabel:Observe(escape.name,self.escRoleMenuOpen) end
            local allowed,why
            if o.role()=='client' then
                if not pause.paused then o.world:KeepEscMenuPlaying(escape) end
                self.clientMenuOpen=escape.paused;self.deniedUntil=nil
            else allowed,why=o.request(escape.paused) end
            if allowed then
                if escape.paused then o.world:AdoptEscapePause(escape.name) end
            elseif o.role()=='host' then
                if why=='host_only' then
                    if not pause.paused then o.world:KeepEscMenuPlaying(escape) end
                    self.deniedUntil=escape.paused and now+2 or nil
                    o.log('Client Esc: only the host can pause; game still in play')
                else o.world:UndoEscapePause(escape) end
            end
        end
    end
    if o.role()=='host' and pause.revision>0 and (session.pauseQueuePending or not self.publishAt or now>=self.publishAt) then
        session:PublishPause();self.publishAt=now+1
    end
    local state=o.role()=='host' and pause:Snapshot() or pause
    if o.world.UpdatePauseMenu then
        local ok,why=pcall(o.world.UpdatePauseMenu,o.world,state,o.role(),function() return o.request(not state.paused) end)
        if not ok and self.menuError~=tostring(why) then self.menuError=tostring(why);o.log('Pause menu unavailable: '..self.menuError) end
    end
    if self.roleLabel then self.roleLabel:Tick(session,o.role(),self.escRoleMenuOpen) end
    if not state.paused then
        -- Presentation must not retain a previous pause owner if native
        -- application/readback refuses this revision or travel is underway.
        o.world:SetPauseNotice(nil)
        if self.dump then self.dump:Cancel() end
    end
    if state.revision==0 then return end
    local _,pawn=o.world:LocalWorldPawn()
    if not pawn then if self.dump then self.dump:Cancel() end;self.pawn=nil;self.ackRevision=nil;o.world:SetPauseNotice(nil);return end
    local name=pawn:GetFullName()
    if self.pawn~=name then self.pawn=name;self.ackRevision=nil end
    local ok,accepted,why=pcall(o.world.SetSharedPaused,o.world,state.paused)
    if not ok or accepted~=true then
        if self.dump then self.dump:Cancel() end
        local failure=tostring(ok and why or accepted)
        if self.failure~=failure then self.failure=failure;o.log('Shared pause not applied: '..failure) end
        return
    end
    self.failure=nil
    if self.dump then
        local contextOK,context=true,''
        if o.captureContext then contextOK,context=pcall(o.captureContext) end
        -- Nil context means travel/authority is unstable: discard, never defer.
        local captureAllowed=contextOK and type(context)=='string'
        local captured,problem=pcall(self.dump.Tick,self.dump,state.paused and captureAllowed,
            tostring(context)..':'..tostring(state.revision)..':'..name)
        if not captured then self.dump:Cancel();o.log('Pause diagnostic unavailable: '..tostring(problem)) end
    end
    if o.world.SyncPauseMenuFlag then o.world:SyncPauseMenuFlag() end
    if o.role()=='client' and o.world.IsEscapeMenuOpen then
        self.clientMenuOpen=o.world:IsEscapeMenuOpen()==true
    end
    if state.paused then
        local players=o.role()=='host' and session.roster:Snapshot() or session:Display()
        local owner='Player'
        for _,player in ipairs(players) do if player.key==state.owner then owner=player.name or ('Player '..player.slot);break end end
        o.world:SetPauseNotice('Paused by '..owner)
    elseif (o.role()=='client' and state.hostOnly and self.clientMenuOpen)
        or (self.deniedUntil and now<self.deniedUntil) then
        o.world:SetPauseNotice('Only the host can pause. Game is still in play.')
    else self.deniedUntil=nil;o.world:SetPauseNotice(nil) end
    if self.ackRevision~=state.revision then
        local ack=o.role()=='host' and pause:Acknowledge(session.identity.key,state.revision,state.paused)
        if o.role()=='client' then ack=session:PauseApplied() end
        if ack then
            self.ackRevision=state.revision
            o.log('Shared pause applied revision='..state.revision..' paused='..tostring(state.paused))
        end
    end
end
return D
