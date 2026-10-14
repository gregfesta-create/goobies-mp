-- Lobby presentation controller. Engine widgets are supplied by the integration
-- layer; this module never binds or replaces the vanilla Play button.
local Ui = require('gmp_lobby_ui')
local Config = require('gmp_config')
local Loadout = require('gmp_lobby_loadout')
local Invite = require('gmp_lobby_invite')
local Screen = {}; Screen.__index = Screen
-- The dev socket backend's only local test group (gmp_dev_socket_lobby_backend.lua: join needs lobbyId '1').
Screen.LOCAL_GROUP = '1'
-- D37: readable reasons for refused clicks, the countdown and what a client waits for after START.
Screen.REASON_TEXT = { loadout_unconfirmed = 'Pick and confirm a class first' }
-- Cross-PC 1.1: a Join refused before the network says what to paste instead (gmp_lobby_invite.lua).
for reason, text in pairs(Invite.REASON_TEXT) do Screen.REASON_TEXT[reason] = text end
-- D55: the host's lobby size box
Screen.REASON_TEXT.max_players_invalid = 'Max players: a whole number from 2 to ' .. Config.MAX_PLAYERS_LIMIT .. ', and at least the players in the lobby.'
Screen.REASON_TEXT.max_players_below_players = 'Max players cannot be lower than the players in the lobby.'
Screen.REASON_TEXT.max_players_lobby_only = 'Max players can only change in the lobby.'
Screen.REASON_TEXT.max_players_steam_not_owner = 'Steam refused the new size: only the lobby owner can change it.'
Screen.REASON_TEXT.max_players_steam_refused = 'Steam refused the new lobby size.'
Screen.REASON_TEXT.max_players_steam_invalid = 'Steam refused the new lobby size.'
Screen.REASON_TEXT.max_players_steam_no_lobby = 'Steam refused the new lobby size: no Steam lobby.'
Screen.REASON_TEXT.max_players_steam_steam_refused = 'Steam refused the new lobby size.'
Screen.REASON_TEXT.max_players_steam_error = 'The Steam lobby size could not be changed.'
Screen.CANCELED_TEXT = { player_unready = 'Start canceled: a player is no longer ready.', players_changed = 'Start canceled: the players changed.',
    host_cancel = 'Start canceled.' }
Screen.WAITING_ISLAND = 'Waiting for the host to create the island...'
Screen.WAITING_NEXT_GAME = 'Waiting for the next game. You join when the host is back in the lobby.'
Screen.ARTIFACTS_HIDDEN = 'The host chooses artifacts for this session. Remove your artifacts in the game selector, then confirm again.'

function Screen.new(options)
    assert(type(options)=='table' and type(options.session)=='function', 'session provider required')
    return setmetatable({options=options,visible=false},Screen)
end

function Screen:_source()
    local session,mode=self.options.session()
    if not session or (mode~='host' and mode~='client') then return nil end
    local source=mode=='host' and Ui.HostSource(session,self.options.modSettings)
        or Ui.ClientSource(session,self.options.modSettings)
    source.pause=session.sharedPause
    return source,session,mode
end
function Screen:_departure()
    if self.options.departureController then return self.options.departureController:Model() end
    return self.options.departure and self.options.departure() or nil
end
function Screen:_connection()
    if type(self.options.connection)=='function' then return self.options.connection() end
    return self.options.connection
end
-- Connection screen. A created lobby always has the fixed four player slots (D12); there is no player-count choice.
function Screen:_connectionModel(connection)
    local model=connection and connection:Model() or {available=false,status='Steam lobby transport is not available in this build.'}
    local picker=self:_hostPicker(model)
    return {title=model.scope=='local_sockets' and 'Local Steam Sockets test' or 'Multiplayer',scope=model.scope,
        status=self.actionError and (Screen.REASON_TEXT[self.actionError] or ('Lobby action refused: '..self.actionError)) or model.status,rows={},kicks={},warnings={},colors={},connection=true,
        settings={},hostPicker=picker,
        actions=self:_connectionActions(model,picker)}
end
-- D53: the Host dropdown (the framework's selection list) and one Join. Nothing joins until a host is picked and Join
-- is pressed; a single joinable host is preselected. A Steam join without a pick uses the typed lobby ID.
function Screen:_hostPicker(model)
    local choices={}
    for _,lobby in ipairs(type(model.lobbies)=='table' and model.lobbies or {}) do
        choices[#choices+1]={id=lobby.id,label=lobby.label,joinable=lobby.joinable~=false}
    end
    -- Test 15: a host the player picked stays picked while its lobby misses a beacon or is full (Join waits); only an
    -- automatic preselection (the single joinable host) is dropped when that host goes away.
    local current;for _,c in ipairs(choices) do if c.id==self.hostChoice then current=c end end
    if current then self.hostChoiceLabel=current.label end
    if self.hostChoice and not current and not self.hostPicked then self.hostChoice=nil end
    if not self.hostChoice and #choices==1 and choices[1].joinable then
        self.hostChoice,self.hostChoiceLabel,self.hostPicked,current=choices[1].id,choices[1].label,false,choices[1]
    end
    local label=current and current.label or self.hostChoice and ((self.hostChoiceLabel or ('Lobby '..self.hostChoice))..' - not answering')
    return {open=self.hostListOpen==true and #choices>0,selected=self.hostChoice,selectedLabel=label,
        available=current~=nil and current.joinable,choices=choices,friendsOnly=model.friendsOnly,scope=model.scope}
end
function Screen:_connectionActions(model,picker)
    local selectedLabel=picker.selectedLabel
    local steam=model.scope~='local_sockets'
    local actions={{id='create_lobby',label='Create lobby',enabled=model.canCreate==true},
        {id='host_picker',label='Host: '..(selectedLabel or (#picker.choices>0 and 'pick a host' or 'none found')),enabled=#picker.choices>0},
        {id='join_lobby',label='Join lobby',value=picker.selected,enabled=model.canJoin==true
            and (picker.selected==nil and steam or picker.selected~=nil and picker.available==true)},
        -- Test 15: re-pull the host list (dev beacons now; Steam GMP_Lob_ListReq)
        {id='refresh_lobbies',label='Refresh',enabled=model.available==true,tooltip='Look for lobbies again.'}}
    if steam then actions[#actions+1]={id='friends_only',label='Friends only: '..(picker.friendsOnly and 'On' or 'Off'),enabled=true} end
    actions[#actions+1]={id='cancel_connection',label='Cancel',enabled=model.canCancel==true}
    -- D52: a run is in progress on the host that refused the join
    if model.canWait then actions[#actions+1]={id='wait_next_game',label='Wait for the next game',enabled=true,
        tooltip='Stay connected and join when the host is back in the lobby.'} end
    return actions
end

local function session_cfg_default(source)
    return source.defaultMaxPlayers or Config.Defaults().MAX_PLAYERS
end
function Screen:Model()
    local source=self:_source()
    local connection=self:_connection()
    if not source or (connection and connection.pending) then return self:_connectionModel(connection) end
    if not source then return {title='Multiplayer lobby',status='No multiplayer session',rows={},settings={},actions={},kicks={},warnings={},colors={}} end
    -- Test 12: Ready/Unready do not apply once a run is in progress (the client waits for, or rejoins, the host's run).
    -- D52: a player waiting for the next game is outside the roster: nothing to ready (only Leave)
    local waitingNext=source.mode=='client' and source.state=='waiting'
    local midRun=source.mode=='client' and source.roster and source.roster.phase=='run' or waitingNext
    local start=Ui.StartControl(source)
    local actions={}
    if not midRun then actions[1]=start end
    local connectionState=connection and connection:Model()
    if connectionState and connectionState.canLeave then
        local localLobby=connectionState.scope=='local_sockets'
        actions[#actions+1]={id=localLobby and 'leave_local_lobby' or 'leave_lobby',label=localLobby and 'Leave local lobby' or 'Leave lobby',enabled=true,
            tooltip=not localLobby and 'Leave this lobby and return to the multiplayer screen.' or nil}
    end
    if connectionState and connectionState.canInvite then actions[#actions+1]={id='invite_friends',label='Invite friends',enabled=true,
        tooltip='Open the Steam invite list for this lobby.'} end
    local counting=start.id=='cancel_countdown'
    if source.mode=='host' and self.options.canStart and not counting then
        local ready,reason=self.options.canStart()
        if not ready then
            actions[1].enabled=false;actions[1].reason='world_entry_unavailable'
            actions[1].tooltip=reason or 'Multiplayer world handoff is unavailable in this session.'
        end
    end
    if counting or midRun then
    elseif self.pendingSelection then
        actions[1].enabled=false;actions[1].reason='selection_pending';actions[1].tooltip='Applying native selection.'
    elseif self.selectionError then
        actions[1].enabled=false;actions[1].reason='selection_failed';actions[1].tooltip='Confirm a successful native selection before Ready.'
    elseif self.nativeReadyError then
        actions[1].enabled=false;actions[1].reason='native_selection_changed';actions[1].tooltip=self.nativeReadyError
    end
    local departure=self:_departure()
    if departure and departure.active then
        actions=departure.canCancel and {{id='cancel_departure',label='Cancel departure',enabled=true}} or {
            {id='become_host',label='Become host',enabled=departure.canClaim==true,
                tooltip='The first accepted claimant becomes host. Returning players join that host.'},
            {id='leave',label='Quit to menu',enabled=departure.canLeave~=false},
        }
    end
    local rows=departure and departure.active and departure.players or Ui.Rows(source);local mine
    for _,row in ipairs(rows) do if row.isMe then mine=row end end
    local catalogue,reason
    local success,value=pcall(function() return self.options.catalogue and self.options.catalogue() end)
    if success then catalogue,reason=Loadout.Catalogue(value) else reason='catalogue_unavailable' end
    -- W11-min: the host default artifact set applies to everyone, so a client never sees an artifact picker.
    local artifactsHidden=source.mode=='client'
    if catalogue and artifactsHidden then catalogue.artifacts={} end
    local colors={}
    for _,choice in ipairs(source.colors or {}) do colors[#colors+1]={color=choice.color,
        available=choice.free or choice.owner==source.me,selected=mine and mine.color==choice.color} end
    -- D55: the lobby size: the host types it (hint = the GoobiesMP.ini default); clients see it
    local default=session_cfg_default(source)
    local maxPlayers={value=source.roster and source.roster.maxPlayers or default,default=default,
        editable=source.mode=='host' and source.roster and source.roster.phase=='lobby' and not (departure and departure.active) or false}
    return {title=departure and departure.active and 'Host transfer' or 'Multiplayer lobby',scope=connectionState and connectionState.scope,mode=source.mode,rows=rows,
        maxPlayers=maxPlayers,
        lobbyId=self.options.lobbyId and self.options.lobbyId() or nil,
        settings=departure and departure.active and {} or Ui.Settings(source),
        departure=departure and departure.active or false,colors=departure and departure.active and {} or colors,loadout={catalogue=catalogue,reason=reason,current=mine,
            artifactsHidden=artifactsHidden,
            highlight=self.actionError=='loadout_unconfirmed' and (not mine or mine.class=='') or nil,
            editable=not (departure and departure.active) and not self.pendingSelection and source.lobby and source.lobby.state=='open' and source.roster.phase=='lobby'
                and mine~=nil and (source.mode=='host' or source.state=='joined')},
        actions=actions,kicks=Ui.KickControls(source),warnings=Ui.Warnings(source),
        status=departure and departure.active and (departure.status or 'Host left. Choose a new host or return to the main menu.')
            or (self.actionError and (Screen.REASON_TEXT[self.actionError] or ('Lobby action refused: '..self.actionError)))
            or (waitingNext and Screen.WAITING_NEXT_GAME)
            or self.selectionError or self.nativeReadyError or (self.pendingSelection and 'Applying native selection...')
            or (self.options.notice and self.options.notice())
            or self:_startStatus(source)
            or (source.lobby and source.lobby.state or 'Connecting'),chat=source.chat}
end

-- D37: the countdown every player sees, a canceled start (host), and what a client waits for after START.
function Screen:_startStatus(source)
    local _,session,mode=self:_source()
    local state=source.lobby and source.lobby.state
    local now=self.options.clock and self.options.clock() or 0
    if state~='countdown' then self.countdownSeenAt=nil end
    if state=='countdown' then
        local left
        if mode=='host' and session and type(session.StartCountdownRemaining)=='function' then left=session:StartCountdownRemaining()
        else self.countdownSeenAt=self.countdownSeenAt or now;left=Ui.START_COUNTDOWN_SECONDS-math.floor(now-self.countdownSeenAt) end
        return 'Starting in '..math.max(1,left or Ui.START_COUNTDOWN_SECONDS)..'...'
    end
    if mode=='host' and session and session.startCountdownCanceled and state=='open' then
        return Screen.CANCELED_TEXT[session.startCountdownCanceled] or 'Start canceled.'
    end
    if mode=='client' and state=='handoff_pending' and not (session and session.islands and session.islands.phase=='playing') then
        return Screen.WAITING_ISLAND
    end
end
function Screen:Open()
    self.visible=true
    -- First join starts with the player's existing native choices; choosing a
    -- class must not accidentally clear artifacts merely because metadata is
    -- still empty. Publish only after the same native completion gate.
    if self.options.nativeSelection and not self.pendingSelection then
        local source=self:_source();local mine
        for _,row in ipairs(source and Ui.Rows(source) or {}) do if row.isMe then mine=row end end
        if mine and mine.class=='' then
            local selection=self.options.nativeSelection:CaptureCurrent()
            if selection and selection.available then
                self:Activate('selection',selection);return self:Model()
            end
        end
    end
    return self:Refresh()
end
function Screen:Close()
    self.visible=false
    if self.options.hide then self.options.hide() end
end
-- A player's click. A refused action is logged ("action refused id=<id> reason=<why>") and shown in the status
-- until the next accepted action.
function Screen:Click(id,value)
    local ok,why=self:Activate(id,value)
    if ok then self.actionError=nil
    else
        self.actionError=tostring(why or 'refused'):sub(1,200)
        if self.options.log then self.options.log('action refused id='..tostring(id)..' reason='..self.actionError) end
    end
    self:Refresh()
    return ok,why
end
function Screen:Refresh()
    local model=self:Model()
    if self.visible and self.options.render then self.options.render(model,function(id,value) return self:Click(id,value) end) end
    return model
end
function Screen:TickSelection()
    local pending=self.pendingSelection
    if not pending then
        self:_autoConfirm()
        if self.options.nativeSelection and self.options.nativeSelection.StepCanceled then self.options.nativeSelection:StepCanceled() end
        self:CheckNativeReadiness()
        return
    end
    local source,session,mode=self:_source()
    if self.nativeReadySession~=session then self.nativeReadySession=session;self.nativeReadyRevocation=nil;self.nativeReadyError=nil end
    if session~=pending.session or mode~=pending.mode or not source.lobby or source.lobby.state~='open' then
        self.options.nativeSelection:CancelSelection();self.pendingSelection=nil;return false,'session_changed'
    end
    local result,why=self.options.nativeSelection:StepSelection()
    if result==nil then return nil end
    self.pendingSelection=nil
    if not result then self.selectionError=why;self:Refresh();return false,why end
    local ok,err
    if mode=='host' then ok,err=session:SetHostSelection(pending.class,pending.artifacts)
    else ok,err=session:RequestSelection(pending.class,pending.artifacts) end
    self.selectionError=not ok and (err or 'selection_rejected') or nil
    self:Refresh();return ok,err
end
-- After joining, confirm the class the game selector already shows (once per session), so a player does not have to
-- find the class list first; a busy selector is retried on the next tick.
function Screen:_autoConfirm()
    if not self.options.nativeSelection or self.selectionError then return end
    local source,session,mode=self:_source()
    if not source or not source.lobby or source.lobby.state~='open' or self.autoConfirmed==session then return end
    if mode=='client' and source.state~='joined' then return end
    local mine
    for _,row in ipairs(Ui.Rows(source)) do if row.isMe then mine=row end end
    if not mine then return end
    if mine.class~='' then self.autoConfirmed=session;return end
    local ok,selection=pcall(self.options.nativeSelection.CaptureCurrent,self.options.nativeSelection)
    if not ok or not selection or selection.available~=true then return end
    self.autoConfirmed=session
    if mode=='client' then selection={class=selection.class,artifacts=''} end
    self:Activate('selection',selection)
end
function Screen:CheckNativeReadiness()
    if not self.options.nativeSelection or self.pendingSelection then return true end
    local source,session,mode=self:_source()
    if self.nativeReadySession~=session then self.nativeReadySession=session;self.nativeReadyRevocation=nil;self.nativeReadyError=nil end
    if not source or not source.lobby or source.lobby.state~='open' then return true end
    local mine
    for _,row in ipairs(Ui.Rows(source)) do if row.isMe then mine=row end end
    if not mine or mine.class=='' then return false,'loadout_unconfirmed' end
    local ok,current=pcall(self.options.nativeSelection.CaptureCurrent,self.options.nativeSelection)
    if ok and current and current.available==true and Loadout.Same(current,mine) then
        self.nativeReadyError=nil;self.nativeReadyRevocation=nil;return true
    end
    self.nativeReadyError='Native selection changed. Confirm your class and artifacts again.'
    -- Vanilla character/artifact controls can change while the lobby is closed.
    -- Immediately revoke only this client's existing Ready; never start with a
    -- stale cached loadout or silently publish an unverified native change.
    if mode=='client' and mine.ready and not self.nativeReadyRevocation then
        local accepted=session:RequestReady(false)
        self.nativeReadyRevocation=accepted==true
    elseif not mine.ready then self.nativeReadyRevocation=nil end
    return false,'native_selection_changed'
end

-- Re-resolve the active session on every click, including after a role switch.
-- Only transport authority may accept a claim; rendering a choice grants none.
function Screen:Activate(id,value)
    local log=self.options.log or function() end
    if id=='host_picker' then
        self.hostListOpen=not self.hostListOpen
        log('host picker '..(self.hostListOpen and 'opened' or 'closed'));self:Refresh();return true
    end
    if id=='pick_host' then
        local connection=self:_connection()
        local picker=self:_hostPicker(connection and connection:Model() or {})
        for _,c in ipairs(picker.choices) do
            if c.id==value and c.joinable then
                self.hostChoice,self.hostChoiceLabel,self.hostPicked=value,c.label,true;self.hostListOpen=false
                log('pick_host '..tostring(value)..' ('..tostring(c.label)..')');self:Refresh();return true
            end
        end
        return false,'host_unavailable'
    end
    if id=='refresh_lobbies' then
        local connection=self:_connection()
        if not connection or type(connection.RefreshLobbies)~='function' then return false,'refresh_unavailable' end
        local ok,why=connection:RefreshLobbies()
        log('lobby list refresh '..(ok and 'requested' or ('refused: '..tostring(why))));self:Refresh();return ok,why
    end
    if id=='friends_only' then
        local connection=self:_connection();if not connection then return false,'lobby_backend_unavailable' end
        connection.friendsOnly=connection.friendsOnly==false;self:Refresh();return true
    end
    if id=='wait_next_game' then
        local connection=self:_connection();if not connection or type(connection.Wait)~='function' then return false,'lobby_backend_unavailable' end
        local ok,why=connection:Wait();self:Refresh();return ok,why
    end
    if id=='create_lobby' or id=='join_lobby' or id=='cancel_connection' then
        local connection=self:_connection();if not connection then return false,'lobby_backend_unavailable' end
        local ok,why
        if id=='cancel_connection' then ok,why=connection:Cancel()
        else
            if id=='join_lobby' and (value==nil or value=='') and connection:Model().scope=='local_sockets' then value=Screen.LOCAL_GROUP end
            -- Cross-PC 1.1: read the lobby ID from whatever the friend pasted (a link, "Lobby ID: ...", spaces).
            if id=='join_lobby' and connection:Model().scope~='local_sockets' then
                local lobby,reason=Invite.ParseLobbyId(value);if not lobby then return false,reason end
                value=lobby
            end
            ok,why=connection:Begin(id=='create_lobby' and 'create' or 'join',
                id=='create_lobby' and {maxPlayers=connection.o and connection.o.maxPlayers or Config.Defaults().MAX_PLAYERS} or {lobbyId=value})
        end
        self:Refresh();return ok,why
    end
    local source,session,mode=self:_source()
    if id=='invite_friends' then
        local connection=self:_connection()
        if not connection or not connection:Model().canInvite then return false,'invite_unavailable' end
        local ok,why=connection:Invite();self:Refresh();return ok,why
    end
    if id=='max_players' then
        local _,session,mode=self:_source()
        if mode~='host' or not session or type(session.SetLobbyMaxPlayers)~='function' then return false,'host_only' end
        local text=tostring(value or ''):match('^%s*(.-)%s*$')
        local n
        if text=='' then n=session.cfg and session.cfg.MAX_PLAYERS or Config.Defaults().MAX_PLAYERS
        else n=tonumber(text);if not n or n~=math.floor(n) or not text:match('^%d+$') then return false,'max_players_invalid' end;n=math.tointeger(n) end
        local ok,why=session:SetLobbyMaxPlayers(n);self:Refresh();return ok,why
    end
    if id=='leave_local_lobby' or id=='leave_lobby' then
        local connection=self:_connection()
        if not connection or not connection:Model().canLeave then return false,'leave_unavailable'end
        local ok,why=connection:Leave();self:Refresh();return ok,why
    end
    if not source then return false,'not_joined' end
    if self.pendingSelection then return false,'selection_pending' end
    local departure=self:_departure()
    local ok,why
    if departure and departure.active then
        if self.options.departureController and id=='become_host' then ok,why=self.options.departureController:Claim()
        elseif self.options.departureController and id=='cancel_departure' then ok,why=self.options.departureController:Cancel()
        elseif self.options.departureController and id=='leave' then ok,why=self.options.departureController:Leave()
        elseif id=='become_host' and departure.canClaim==true and self.options.claim then ok,why=self.options.claim()
        elseif id=='leave' and self.options.leave then ok,why=self.options.leave()
        else return false,'host_departed' end
    elseif id=='cancel_countdown' then
        if mode~='host' then return false,'not_host' end
        ok,why=session:CancelStartCountdown('host_cancel')
    elseif id=='ready' and mode=='client' and Ui.StartControl(source).ready then
        -- Unready is always allowed: it only cancels this player's Ready.
        ok,why=session:RequestReady(false)
    elseif id=='host' or id=='ready' or id=='host_start' then
        if self.selectionError then return false,'selection_failed' end
        local nativeReady,reason=self:CheckNativeReadiness()
        if not nativeReady then self:Refresh();return false,reason end
        if id=='host' and self.options.canStart and not self.options.canStart() then return false,'world_entry_unavailable' end
        if (mode=='host')~=(id=='host' or id=='host_start') then return false,'role_changed' end
        local others=0
        for _,row in ipairs(Ui.Rows(source)) do if not row.isHost then others=others+1 end end
        if id=='host' and self.options.countdown and others>0 then
            -- D37: the host's Ready starts the countdown; the gated start runs at 0 ('host_start').
            local control=Ui.StartControl(source)
            if not control.enabled then ok,why=false,control.reason
            else session.startCountdownCanceled=nil;ok,why=session:BeginStartCountdown(Ui.START_COUNTDOWN_SECONDS) end
        else ok,why=Ui.ActivateStart(session,mode) end
    elseif id=='class' or id=='artifact' then
        if id=='artifact' and mode=='client' then return false,'artifacts_host_policy' end
        local model=self:Model()
        if not model.loadout.editable then return false,'lobby_closed' end
        if not model.loadout.catalogue then return false,model.loadout.reason end
        local selection,err=Loadout.Change(model.loadout.catalogue,model.loadout.current,id,value)
        if not selection then return false,err end
        return self:Activate('selection',selection)
    elseif id=='selection' then
        if type(value)~='table' then return false,'bad_value' end
        if not source.lobby or source.lobby.state~='open' then return false,'lobby_closed' end
        -- W11-min: the host refuses client artifacts, so a client selection carrying any is refused before the
        -- native selector is driven; the player removes them in the game selector and confirms again.
        if mode=='client' and (value.artifacts or '')~='' then
            self.selectionError=Screen.ARTIFACTS_HIDDEN;self:Refresh();return false,'artifacts_host_policy'
        end
        if self.options.nativeSelection then
            self.selectionError=nil
            ok,why=self.options.nativeSelection:BeginSelection(value)
            if ok then self.pendingSelection={session=session,mode=mode,class=value.class,artifacts=value.artifacts}
            else self.selectionError=tostring(why or 'native_selection_refused'):sub(1,600) end
        elseif mode=='host' then ok,why=session:SetHostSelection(value.class,value.artifacts)
        else ok,why=session:RequestSelection(value.class,value.artifacts) end
    elseif id=='color' then
        if type(value)~='string' then return false,'bad_value' end
        local available=false
        for _,choice in ipairs(source.colors or {}) do
            if choice.color==value and (choice.free or choice.owner==source.me) then available=true end
        end
        if not available then return false,'color_unavailable' end
        if mode=='host' then ok,why=session:SetHostColor(value) else ok,why=session:RequestColor(value) end
    elseif id=='kick' then ok,why=Ui.ActivateKick(session,mode,value)
    elseif id=='allowAutoRejoin' or id=='hostOnlyPause' then
        if mode~='host' then return false,'not_host' end
        if not source.lobby or source.lobby.state~='open' or source.roster.phase~='lobby' then return false,'lobby_closed' end
        if type(value)~='boolean' then return false,'bad_value' end
        if id=='hostOnlyPause' then ok,why=session:SetPauseHostOnly(value)
        else ok,why=session:SetAllowAutoRejoin(value) end
    else return false,'unknown_action' end
    self:Refresh()
    return ok,why
end
return Screen
