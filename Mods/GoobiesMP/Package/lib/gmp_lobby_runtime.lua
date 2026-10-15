-- Optional managed lobby integration. Existing session and island-flow code
-- retain transport authority and native world generation ownership.
local Native=require('gmp_lobby_native_selection')
local Renderer=require('gmp_lobby_renderer')
local AutoStart=require('gmp_dev_autostart')
local Islands=require('gmp_islands')
local WorldBinding=require('gmp_lobby_world_binding')
local AchievementBinding=require('gmp_lobby_achievement_binding')
local Artifacts=require('gmp_lobby_artifacts')
local L={};L.__index=L

function L.Enabled(text)
    if type(text)~='string' then return false end
    for line in (text..'\n'):gmatch('[^\r\n]+') do
        local key,value=line:match('^%s*([%w_]+)%s*=%s*([^;#]*)')
        if key and key:upper()=='LOBBY_UI' then
            value=value:match('^%s*(.-)%s*$'):lower()
            return value=='1' or value=='true'
        end
    end
    return false
end
function L.new(options)
    if not L.Enabled(options.configText) then return nil,'disabled' end
    if type(options.context)~='table' or type(options.context.Widgets)~='table'
        or type(options.context.Widgets.new)~='function' then return nil,'framework_widgets_unavailable' end
    local self=setmetatable({options=options,app=options.app,G=options.G,logged={},entered={}},L)
    self.native=(options.nativeFactory or Native.new)(self.G,{log=function(line) self:_log(line) end,
        unlockAll=function() return type(self.app.CheatUnlockAll)=='function' and self.app:CheatUnlockAll()==true end})
    self.renderer=(options.rendererFactory or Renderer.new){G=self.G,Widgets=options.context.Widgets,
        registerMainMenuButton=options.context.registerMainMenuButton,
        session=function() return self:Session() end,catalogue=function() return self.native:Catalogue() end,
        nativeSelection=self.native,modSettings=options.app.modSettings,
        connection=function() return type(self.app.SteamConnection)=='function' and self.app:SteamConnection() or nil end,
        lobbyId=function() return self.app.steamLobbyId end,
        departure=options.departure,claim=options.claim,leave=options.leave,
        canStart=function() return self:CanEnter() end,
        notice=function() return self.app.lobbyNotice end,
        log=function(line) self:_log(line) end,
        countdown=true,clock=function() return self.app.clockNow or 0 end,
        -- W11: the host picks in the game's own grid; clients see the D29 view; native readiness compares the set.
        nativeGrid=function() return self:_hostArtifacts() end,
        policyView=function() return self:_policyView() end,
        expectedArtifacts=function(current) return self:_expectedArtifacts(current) end}
    if type(options.context.registerMenuNavigation)=='function' then
        self.unregisterMenuBack,self.focusMenuBack=options.context.registerMenuNavigation{id='lobby',priority=10,
            isVisible=function()return self.renderer and self.renderer.screen.visible==true end,
            canBack=function()
                local departure=self.renderer.screen:_departure()
                return not self.renderer.departureSurface and not (departure and departure.active)
            end,
            back=function()self.renderer.screen:Close()end}
        self.renderer.options.focusNavigation=function()if self.focusMenuBack then self.focusMenuBack()end end
    end
    -- Lobby owns explicit start. The development convenience must not start a
    -- world before players have confirmed Ready in this opt-in configuration.
    -- The SPLASH_SKIP_ONLY boot driver (W3) never presses Play, so it is kept.
    self.previousAutoStart=self.app.extras.devAutoStart
    if not self.app.extras.splashSkipOnly then self.app.extras.devAutoStart=false end
    if options.app.extras.devSocketLobby and tostring(options.configText or ''):match('[\r\n]DEV_SOCKET_LOBBY_CHECK%s*=%s*1%s*[\r\n]') then
        local loaded,check=pcall(require,'gmp_dev_socket_lobby_check')
        if not loaded or type(check)~='table' or type(check.new)~='function' then error('local_ui_diagnostic_unavailable')end
        self.uiCheck=check.new(self)
    else
        -- lean builds may not carry the UI check (gmp_dev_modules.lua); it is only built when asked for
        local UiCheck,why=require('gmp_dev_modules').Load('gmp_lobby_ui_check')
        if UiCheck and UiCheck.Enabled(options.configText) then self.uiCheck=UiCheck.new(self)
        elseif not UiCheck and tostring(options.configText or ''):match('LOBBY_UI_CHECK%s*=%s*1') then
            self:_log('LOBBY_UI_CHECK=1 ignored: gmp_lobby_ui_check is not in this build ('..tostring(why)..')')
        end
    end
    return self
end
function L:_log(line)
    if self.options.log then self.options.log('LOBBYUI '..tostring(line)) end
end
function L:_once(reason,key)
    key=key or reason
    if self.logged[key] then return end
    self.logged[key]=true;self:_log(reason)
end
function L:Session()
    local app=self.app
    if app.role=='host' then return app.host,'host' end
    if app.role=='client' then return app.client,'client' end
    if app.state=='hosting' and app.host then return app.host,'host' end
end
-- Late-bound by the shared runtime owner after real authoritative departure
-- callbacks exist. No assumed App method, ForceClaim or takeover write.
function L:_configureDeparture(bindings)
    if type(bindings)~='table' or type(bindings.snapshot)~='function' or not bindings.world
        or type(bindings.claim)~='function' or type(bindings.leave)~='function' then return false,'departure_bindings_unavailable' end
    local Controller=require('gmp_lobby_departure')
    local Surface=require('gmp_lobby_pause_surface')
    local controller=Controller.new{session=function() return self:Session() end,snapshot=bindings.snapshot,
        claim=bindings.claim,leave=bindings.leave,cancel=bindings.cancel}
    if self.departureSurface then self.renderer.screen:Close();self.departureSurface:Release() end
    local surface=Surface.new{G=self.G,world=bindings.world}
    self.departureController=controller;self.departureSurface=surface
    self.renderer.screen.options.departureController=controller
    self.renderer.options.departureSurface=function() return surface:Surface(controller:Model().active) end
    self.renderer.options.departureHidden=function() return surface:HiddenControls() end
    self.renderer.options.departureFocus=function(button) return surface:Focus(button) end
    self.renderer.options.departureRelease=function() return surface:Release() end
    return true
end
function L:ConfigureDeparture(bindings)
    local ok,accepted,why=pcall(self._configureDeparture,self,bindings)
    if not ok then return false,'departure_configuration_failed: '..tostring(accepted):sub(1,300) end
    return accepted,why
end
function L:CanEnter()
    local binding=self:_worldBinding();local session,role=self:Session()
    local ready,reason=WorldBinding.Check(binding,session,role)
    if not ready then return false,WorldBinding.Message(reason) end
    local protected,why=self:_achievementReady(session,role)
    return protected,not protected and AchievementBinding.Message(why) or nil
end
function L:_achievementReady(session,role)
    local lobby=session and (role=='host' and session:LobbyState() or session:LobbyMirror())
    local policy=lobby and lobby.sessionPolicy
    local binding
    if type(self.app.LobbyAchievementBinding)=='function' then
        local ok,value=pcall(self.app.LobbyAchievementBinding,self.app,policy)
        if ok then binding=value end
    end
    return AchievementBinding.Check(policy,binding,session)
end
function L:_worldBinding()
    if type(self.app.LobbyWorldBinding)~='function' then return {available=false,reason='world_binding_unavailable'} end
    local ok,binding=pcall(self.app.LobbyWorldBinding,self.app)
    return ok and binding or {available=false,reason='world_binding_failed'}
end
function L:_selectionMatches(session,role)
    local wanted
    local lobby=role=='host' and session:LobbyState() or session:LobbyMirror()
    for _,row in ipairs(lobby and lobby.players or {}) do if row.key==session.identity.key then wanted=row end end
    local policy=lobby and lobby.sessionPolicy
    if not policy or type(policy.artifacts)~='table' then return false,'policy_artifacts_missing' end
    -- W11: a client enters only with the lists of the locked revision (when its host pages them).
    if role=='client' and type(session.PolicyListsComplete)=='function' and not session:PolicyListsComplete() then return false,'policy_lists_pending' end
    if not wanted or wanted.class=='' then return false,'loadout_unconfirmed' end
    local current,why=self.native:CaptureCurrent()
    if not current or not current.available then return false,why or 'native_loadout_locked' end
    if current.class~=wanted.class then return false,'native_class_changed' end
    if #policy.artifacts>0 then
        -- W11-min stays the default: a non-empty set is supported only with host artifacts (HOST_ARTIFACTS on the host,
        -- paged policy lists on a client).
        if not (self:_hostArtifacts() or (role=='client' and session.policyListsExpected)) then return false,'policy_artifacts_unsupported' end
        -- W11: the native selection must equal the host's set (actor paths), for the host as well as every client.
        local paths=Artifacts.NativePaths(self.native:Catalogue(),current.artifacts)
        if not paths or not Artifacts.SameSet(paths,policy.artifacts) then return false,'native_artifacts_not_policy' end
        return true
    end
    local artifacts={}
    for id in wanted.artifacts:gmatch('[^+]+') do artifacts[id]=true end
    for id in current.artifacts:gmatch('[^+]+') do
        if not artifacts[id] then return false,'native_artifacts_changed' end
        artifacts[id]=nil
    end
    if next(artifacts) then return false,'native_artifacts_changed' end
    -- The native artifacts must equal the (empty) policy set, for the host as well as every client.
    if current.artifacts~='' then return false,'native_artifacts_not_policy' end
    return true
end
-- W11 (D25/D28/D29/D34). Host with HOST_ARTIFACTS: its normal-save unlocks and its picks in the game's own grid become
-- the policy lists. Client: once the lists of the current revision are complete, the host's set is written into the
-- client's native selection (only class goes on the wire); artifacts its grid cannot select are logged once.
function L:_hostArtifacts()
    local session,role=self:Session()
    return role=='host' and session and session.hostArtifacts==true and self.app.extras.hostArtifacts==true or false
end
function L:_policy(session,role)
    local lobby=session and (role=='host' and session:LobbyState() or session:LobbyMirror())
    return lobby and lobby.sessionPolicy,lobby
end
function L:_policyView()
    local session,role=self:Session()
    if role~='client' or not session then return nil end
    local policy=self:_policy(session,role)
    if not policy or not session.policyListsExpected then return nil end
    local ok,catalogue=pcall(self.native.Catalogue,self.native)
    return Artifacts.ClientView(ok and catalogue or nil,policy)
end
function L:_expectedArtifacts(current)
    local session,role=self:Session()
    if self:_hostArtifacts() then return current and current.artifacts end
    if role~='client' or not session or not session.policyListsExpected then return nil end
    local policy=self:_policy(session,role)
    local ok,catalogue=pcall(self.native.Catalogue,self.native)
    if not policy or not ok then return nil end
    return (Artifacts.IdsForPaths(catalogue,policy.artifacts))
end
function L:_artifactPolicyTick()
    local session,role=self:Session()
    if not session then return end
    local policy,lobby=self:_policy(session,role)
    if not policy or not lobby or lobby.state~='open' then return end
    local ok,catalogue=pcall(self.native.Catalogue,self.native)
    if not ok or type(catalogue)~='table' then return end
    if self:_hostArtifacts() then
        local unlocked=Artifacts.HostUnlocked(catalogue)
        if not Artifacts.SameSet(unlocked,policy.hostUnlocked) then session:SetHostUnlocked(unlocked) end
        local current=self.native:CaptureCurrent()
        local paths=current and Artifacts.NativePaths(catalogue,current.artifacts)
        if paths and not Artifacts.SameSet(paths,policy.artifacts) then
            local accepted,why=session:SetPolicyArtifacts(paths)
            if not accepted then self:_once('host artifact set refused: '..tostring(why)) end
        end
        return
    end
    if role~='client' or not session.policyListsExpected or not session:PolicyListsComplete() then return end
    local screen=self.renderer and self.renderer.screen
    if not screen or screen.pendingSelection then return end
    local current=self.native:CaptureCurrent()
    if not current or not current.available then return end
    local ids,missing=Artifacts.IdsForPaths(catalogue,policy.artifacts)
    for _,m in ipairs(missing) do self:_once('host artifact not selectable here: '..m.path..' ('..m.why..')') end
    local now=Artifacts.NativePaths(catalogue,current.artifacts)
    local want=Artifacts.NativePaths(catalogue,ids)
    if now and want and Artifacts.SameSet(now,want) then return end
    if self.policyWriteRevision==policy.revision then return end   -- one write attempt per revision
    self.policyWriteRevision=policy.revision
    local accepted,why=screen:Activate('selection',{class=current.class,artifacts=ids,policyWrite=true})
    if not accepted then self:_once('host artifact set not written: '..tostring(why)) end
end
-- D37: the host's countdown reaching 0 runs the normal gated start (a refusal is logged and shown).
function L:_countdownTick()
    local session,role=self:Session()
    if role~='host' or not session or type(session.TickStartCountdown)~='function' then return end
    if session:TickStartCountdown()=='due' then
        local ok=self.renderer.screen:Click('host_start')
        if not ok then session:_broadcastLobby() end
    end
end
function L:_entryTick(now)
    local session,role=self:Session()
    local binding=self:_worldBinding();local bound,reason=WorldBinding.Check(binding,session,role)
    if self.entry and (self.entry.session~=session or self.entry.role~=role) then
        self.entry=nil;self:_once('pending world entry canceled: session changed')
    end
    if not session then return end
    local lobby=role=='host' and session:LobbyState() or session:LobbyMirror()
    -- A client that joins a run already in progress (test 12 rejoin) never saw START: the host's run phase counts.
    local runInProgress=role=='client' and type(session.Roster)=='function' and (session:Roster() or {}).phase=='run'
    if not lobby or lobby.state~='handoff_pending' or (role=='client' and not session.started and not runInProgress) then return end
    if not bound then self.entry=nil;self:_once('world entry unavailable: '..tostring(reason));return end
    if not lobby.sessionPolicy or lobby.sessionPolicy.locked~=true then
        self.entry=nil;self:_once('world entry refused: achievement_policy_not_locked');return
    end
    local protected,protectionReason=self:_achievementReady(session,role)
    if not protected then self.entry=nil;self:_once('world entry refused: '..tostring(protectionReason));return end
    local islands=session.islands
    if not islands or islands.phase=='playing' or islands.island>0 then return end
    -- A migrated session may retain its SID and reuse a lobby revision. Never
    -- reuse a pending native entry operation across an authority term or role.
    local token=table.concat({tostring(session.sid),tostring(binding.term),role,tostring(lobby.lrev),tostring(binding.flow)},':')
    if self.entered[token] then return end
    if self.entry and (self.entry.session~=session or self.entry.token~=token) then
        self.entry=nil;self:_once('pending world entry canceled: session changed')
    end
    if role=='client' then
        -- First entry (island 1) and a rejoin of a running run (test 12: a restarted client process gets the host's
        -- island N through ISLAND_RESUME) enter the same way: the normal Play entry with the host's pending settings.
        if session:State()~='joined' or not islands.pending or not Islands.Valid(islands.pending)
            or islands.phase~='generating' then return end
    end
    local matches,why=self:_selectionMatches(session,role)
    -- A rejoining client's game selector may show another class than its reclaimed lobby row: apply the row's class
    -- once (the game's own class initialization), then check again on the next tick.
    -- Coder B (test.3 report 1560096438933917776): on ANY island. A relaunched game rejoining a run still on island 1
    -- never saw START (the host's run phase counts) and was refused native_class_changed forever. The held class is the
    -- one this player had in the run, so it is applied even where the relaunched selector shows it locked; if it
    -- cannot be applied, the lobby screen says so and this entry stops (never a silent wait).
    local rejoining=role=='client' and ((runInProgress and not session.started) or islands.pending.island>1)
    if not matches and rejoining and (why=='native_class_changed' or why=='native_artifacts_changed') then
        local wanted;for _,row in ipairs(session:LobbyMirror().players or {}) do if row.key==session.identity.key then wanted=row end end
        if why=='native_class_changed' and self.rejoinClassApplied~=token then
            self.rejoinClassApplied=token
            local applied,problem=false,'no_row'
            if wanted and type(self.native.ApplyClass)=='function' then applied,problem=self.native:ApplyClass(wanted.class,{held=true}) end
            self:_log('rejoin: applied the lobby class '..tostring(wanted and wanted.class)..' to the game selector: '..tostring(applied and 'ok' or problem))
            if applied then return end
            return self:_rejoinRefused(token,wanted,problem)
        end
        return self:_rejoinRefused(token,wanted,why)
    end
    if not matches then self:_once('world entry refused: '..tostring(why));return end
    if not self.entry then
        self.renderer.screen:Close()
        local entry={session=session,role=role,token=token,at=now}
        entry.driver=(self.options.entryFactory or AutoStart.new)(self.G,function(line)
            if tostring(line):find('DEVAUTOSTART stopped:',1,true) then entry.failure=tostring(line) end
            self:_log(line)
        end,{hideArtifactSelector=role=='client'})
        self.entry=entry
        self:_log('accepted lobby start: role='..role)
    end
    -- Existing normal Blueprint Play/character-Play callbacks, signature checked
    -- by the proven entry helper. No direct OpenLevel or class-force operation.
    self.entry.driver:Tick(now-self.entry.at+3)
    if self.entry.driver.phase=='done' then
        -- Native entry is deliberately attempted once: a callback may have
        -- started loading even if a subsequent read fails. Do not retry it.
        self.entered[token]=self.entry.failure or true
        if self.entry.failure then self:_once('world entry failed: '..self.entry.failure,'entry_failure') end
        self.entry=nil
    end
end
-- Coder B: a rejoin that cannot take the held loadout. The lobby screen names the class and the reason, and this entry
-- token is closed (no retry loop); the player can leave and join again.
function L:_rejoinRefused(token,wanted,why)
    local label=wanted and wanted.class or '?'
    local ok,catalogue=pcall(self.native.Catalogue,self.native)
    if ok and type(catalogue)=='table' then
        for _,entry in ipairs(catalogue.classes or {}) do if wanted and entry.id==wanted.class then label=entry.label end end
    end
    local text='Could not rejoin with your class from the run ('..tostring(label)..'): '..tostring(why)
        ..'. Leave and join again, or choose '..tostring(label)..' in the game first.'
    self.entered[token]=text
    self:_log('rejoin refused: '..text)
    local screen=self.renderer and self.renderer.screen
    if screen then screen.selectionError=text;screen:Open() end
end
function L:Dispose()
    if self.unregisterMenuBack then self.unregisterMenuBack();self.unregisterMenuBack=nil;self.focusMenuBack=nil end
    self.renderer.screen:Close()
    if self.renderer.menuEntry then self.renderer.menuEntry:Remove();self.renderer.menuEntry=nil end
    self.disposed=true
end
function L:Tick()
    if self.disposed then return end
    local ok,why=pcall(function()
        local context=self.options.context
        if context.id and type(context.query)=='function' then
            local state=context.query(context.id)
            if state.enabled~=true or state.active~=true then self:Dispose();return end
        end
        self:_normalDepartureTick()
        local installed,reason=self.native:Install()
        if not installed then self:_once('native lock observation unavailable: '..tostring(reason),'lock_observation') end
        self.renderer:Tick()
        self:_inviteTick()
        if self.uiCheck then self.uiCheck:Tick() end
        self:_artifactPolicyTick()
        self:_countdownTick()
        self:_entryTick(self.app.clockNow or 0)
    end)
    if not ok then
        pcall(function() self.renderer.screen:Close() end)
        if self.departureSurface then pcall(self.departureSurface.Release,self.departureSurface) end
        self:_once('tick refused: '..tostring(why):sub(1,600),'tick_failure')
    end
end
-- Steam friends-list join / accepted invite while the game runs: the app starts the join; open the lobby screen
-- once for it, so the player sees it connect (a typed join is already on screen).
function L:_inviteTick()
    local app=self.app
    local connection=type(app.SteamConnection)=='function' and app:SteamConnection() or nil
    local pending=connection and connection.pending
    if not pending or not pending.fromInvite or pending.shown or not self.renderer.menu or self.renderer.screen.visible then return end
    pending.shown=true;self.renderer.screen:Open()
end
function L:_normalDepartureTick()
    local app=self.app
    if type(app.NormalDepartureSnapshot)~='function' or type(app.RequestNormalDeparture)~='function'
        or type(app.ClaimNormalDeparture)~='function' or type(app.BindNormalDepartureExit)~='function' then return end
    local world=app.islandFlow and app.islandFlow.world
    if not world then return end
    if not self.nativeDeparture then
        local Adapter=require('gmp_lobby_native_departure')
        self.nativeDeparture=(self.options.departureAdapterFactory or Adapter.new){G=self.G,world=function() return app.islandFlow and app.islandFlow.world end,
            request=function()
                -- D52: End Run always works (App:RequestEndRun: hand over when possible, else end the run / leave it).
                if type(app.RequestEndRun)=='function' then return app:RequestEndRun() end
                return app:RequestNormalDeparture()
            end,log=function(line) self:_log(line) end}
        local bound,reason=app:BindNormalDepartureExit(function() return self.nativeDeparture:ExitToMenu() end)
        assert(bound,reason)
        local configured,problem=self:ConfigureDeparture{world=function() return app.islandFlow and app.islandFlow.world end,
            snapshot=function() return app:NormalDepartureSnapshot() end,
            claim=function(request) return app:ClaimNormalDeparture(request) end,
            cancel=function() return app:CancelNormalDeparture() end,
            leave=function()
                if app.role~='client' or not app.client then return false,'client_leave_only' end
                -- D52: a quit to the menu holds the slot (no freeing LEAVE); the app closes the session at the menu.
                return self.nativeDeparture:ExitToMenu()
            end}
        assert(configured,problem)
    end
    local session,role=self:Session()
    -- D52 (test 13): during every multiplayer run (dev, friend) the End Run button is ours, host and client, so it
    -- always works (App:RequestEndRun). Production keeps the game's own End Run.
    local enabled=require('gmp_mode_policy').Allows(app.cfg.MODE,'gameplay') and (role=='host' or role=='client') and session
        and session.islands and session.islands.phase=='playing' and not app.handoverRuntimeHold
    local accepted,why=self.nativeDeparture:Tick(enabled==true)
    if not accepted then self:_once('native End Run interception unavailable: '..tostring(why),'end_run_adapter') end
end
return L
