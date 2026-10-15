-- Uses the verified Mod_Menu mm_widgets interface and Blueprint click hook.
-- Inject Widgets from the framework; do not load a second framework runtime.
local Screen=require('gmp_lobby_screen')
local Liveness=require('gmp_run_sync_liveness')
local Invite=require('gmp_lobby_invite')
local R={};R.__index=R
local CLICK='/Game/UI/WBP_Button.WBP_Button_C:BndEvt__WBP_Button01_b_button_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature'
local function valid(o) return o and o:IsValid() end
local function stamp(model)
    local parts={}
    local function add(value) local text=tostring(value or '');parts[#parts+1]=#text..':'..text end
    add(model.mode);add(model.status)
    add(model.connection);add(model.lobbyId);add(model.scope)
    if model.maxPlayers then add(model.maxPlayers.value);add(model.maxPlayers.editable) end
    for _,row in ipairs(model.rows) do
        for _,key in ipairs{'key','name','ready','isHost','isMe','color','class','artifacts','conn'} do add(row[key]) end
    end
    for _,item in ipairs(model.settings) do add(item.id);add(item.value);add(item.editable) end
    for _,action in ipairs(model.actions) do add(action.id);add(action.enabled);add(action.ready);add(action.reason);add(action.label);add(action.value) end
    -- Test 15: the host list (its "(n/4)" counts change with the hosts' beacons) re-renders live
    local picker=model.hostPicker
    if picker then
        add(picker.open);add(picker.selected)
        for _,choice in ipairs(picker.choices or {}) do add(choice.id);add(choice.label);add(choice.joinable) end
    end
    for _,color in ipairs(model.colors or {}) do add(color.color);add(color.available);add(color.selected) end
    if model.loadout then
        add(model.loadout.editable);add(model.loadout.reason);add(model.loadout.highlight)
        for _,domain in ipairs{'classes','artifacts'} do
            for _,choice in ipairs(model.loadout.catalogue and model.loadout.catalogue[domain] or {}) do
                add(choice.id);add(choice.label);add(choice.available)
            end
        end
    end
    return table.concat(parts)
end
function R.new(options)
    assert(options.G and options.Widgets,'verified framework widget factory required')
    local self=setmetatable({options=options,G=options.G,dispatch={},queue={},epoch=0},R)
    self.screen=Screen.new{session=options.session,modSettings=options.modSettings,catalogue=options.catalogue,nativeSelection=options.nativeSelection,canStart=options.canStart,notice=options.notice,log=options.log,countdown=options.countdown,clock=options.clock,
        connection=options.connection,lobbyId=options.lobbyId,
        departure=options.departure,departureController=options.departureController,claim=options.claim,leave=options.leave,
        render=function(model,activate)
            local ok,err=pcall(function() self:Render(model,activate) end)
            if not ok then self:Hide();if self.options.departureRelease then pcall(self.options.departureRelease) end;error(err,0) end
        end,hide=function() self:Hide() end}
    return self
end
function R:Attach(menu)
    if self.menuEntry then self.menuEntry:Remove();self.menuEntry=nil end
    assert(valid(menu.Play) and valid(menu.upgrades),'main-menu controls unavailable')
    assert(type(self.options.registerMainMenuButton)=='function','shared main-menu button API unavailable')
    self.menu=menu
    self.w=self.options.Widgets.new(self.G,menu,self.options.assets or '',self.dispatch)
    local entry,reason,retained=self.options.registerMainMenuButton(menu,{id='multiplayer',label='Multiplayer',
        after='Play',before='upgrades',styleRole='secondary',onClick=function() self.screen:Open() end})
    self.menuEntry=entry or retained
    assert(entry,reason)
    self.entry=entry.widget;self.entryBox=entry.widget;self.entryName=entry.widget:GetFullName()
    self.dispatch[self.entryName]=entry.onClick
    self:_hook()
end
function R:_hook()
    if not self.hooked then
        self.G.RegisterHook(CLICK,function(ctx)
            local name=ctx:get():GetFullName()
            -- Test 15: the callback is taken now, so a re-render before the next tick (a beacon count change, an
            -- earlier click in the same batch) cannot drop the click; a new session or menu still discards it (epoch).
            local fn=self.dispatch[name]
            if fn then self.queue[#self.queue+1]={name=name,fn=fn,epoch=self.epoch} end
        end)
        self.hooked=true
    end
end
-- The session the screen shows (a re-render of the same session keeps queued clicks).
function R:_sessionTag()
    local ok,session,mode=pcall(self.options.session)
    return ok and (tostring(session)..':'..tostring(mode)) or 'none'
end
function R:Hide(rerender)
    -- A main menu freed by a level change is dropped, never restored (R1 attempt 2 crash rule).
    if self.menu and not self.departureSurface and not Liveness.Listed(self.G,self.menu,'WBP_MainMenu_C') then self:_abandonMenu();return end
    if valid(self.connectionInput) then
        local ok,value=pcall(function() return self.connectionInput:GetText():ToString() end)
        if ok then self.joinText=value:match('^%s*(.-)%s*$'):sub(1,Invite.MAX_TEXT) end
    end
    -- D55: the max players box keeps its text and its keyboard focus across a re-render
    if valid(self.maxInput) then
        local ok,focused=pcall(function() return self.maxInput:HasKeyboardFocus() end)
        self.maxFocused=ok and focused==true
    end
    self.maxInput=nil
    self.connectionInput=nil
    if valid(self.overlay) then self.overlay:RemoveFromParent() end
    for _,row in ipairs(self.saved or {}) do if valid(row.widget) then row.widget:SetVisibility(row.visibility) end end
    self.saved=nil;self.overlay=nil;self.dispatch={}
    if not rerender then self.epoch=self.epoch+1;self.queue={} end
    if self.w then self.w.dispatch=self.dispatch;self.w.labels={};self.w.textHosts={};self.w.animations={} end
    if self.entryName and self.menuEntry then self.dispatch[self.entryName]=self.menuEntry.onClick end
end
function R:Render(model,activate)
    if not valid(self.overlay) and self.options.focusNavigation then self.options.focusNavigation() end
    local tag=self:_sessionTag()
    self:Hide(valid(self.overlay) and tag==self.renderedSession)
    self.renderedSession=tag
    local root=self.menu.WidgetTree.RootWidget;local w=self.w
    self.saved={}
    if model.departure then
        for _,child in ipairs(self.options.departureHidden and self.options.departureHidden() or {}) do
            if valid(child) then self.saved[#self.saved+1]={widget=child,visibility=child:GetVisibility()} end
        end
    else
        for i=0,root:GetChildrenCount()-1 do local child=root:GetChildAt(i)
            self.saved[#self.saved+1]={widget=child,visibility=child:GetVisibility()} end
    end
    local scale=w:create('ScaleBox');scale:SetStretch(2)
    local slot=root:AddChildToCanvas(scale);slot:SetMinimum({X=0,Y=0});slot:SetMaximum({X=1,Y=1})
    slot:SetOffsets({Left=0,Top=0,Right=0,Bottom=0});slot:SetAlignment({X=0,Y=0});slot:SetZOrder(1000)
    self.overlay=scale
    local size=w:create('SizeBox');size:SetWidthOverride(1280);size:SetHeightOverride(720);scale:SetContent(size)
    local page=w:create('CanvasPanel');size:SetContent(page)
    w:text(page,model.title,90,25,1000,50,30)
    w:text(page,model.status,90,80,1050,45,16)
    if model.connection then
        -- D53: the Host dropdown: the picker button opens the framework selection list of hosts; Join is in the row.
        local picker=model.hostPicker
        local pickerAction,friendsAction
        for _,action in ipairs(model.actions) do
            if action.id=='host_picker' then pickerAction=action elseif action.id=='friends_only' then friendsAction=action end
        end
        w:text(page,'Host',90,135,200,40,22)
        if pickerAction then w:button(page,pickerAction.label,90,180,650,50,function() activate('host_picker') end,
            'Pick the host to join, then press Join lobby.',pickerAction.enabled) end
        if friendsAction then w:button(page,friendsAction.label,780,180,410,50,function() activate('friends_only') end,
            'Show only friends\' lobbies.',friendsAction.enabled) end
        if picker and picker.open then
            local list=w:scroll(page,90,240,650,330)
            for _,choice in ipairs(picker.choices) do
                local row=w:row(list,50,630)
                w:button(row,(choice.id==picker.selected and '> ' or '')..choice.label,0,2,620,46,function() activate('pick_host',choice.id) end,
                    choice.joinable and 'Pick this host.' or choice.tooltip or 'This lobby cannot be joined.',
                    -- t3 friend reports (Coder A): another version stays clickable: the click shows why (Join stays off)
                    choice.joinable or choice.refusal~=nil)
            end
        elseif model.scope~='local_sockets' then
            w:text(page,'Lobby ID',90,250,650,40,18)
            local input=w:create('EditableTextBox')
            input:SetText(self.G.FText(self.joinText or ''));input:SetIsReadOnly(false)
            input:SetToolTipText(self.G.FText('Paste the Steam lobby ID supplied by the host (used when no host is picked).'))
            w:place(page,input,90,295,650,55);self.connectionInput=input
        end
    elseif model.lobbyId then
        -- Cross-PC 1.1: the ID in a read-only text box, so it can be selected and copied (Ctrl+C), with the hint.
        w:text(page,'Lobby ID',90,108,100,30,14)
        local box=w:create('EditableTextBox')
        box:SetText(self.G.FText(model.lobbyId));box:SetIsReadOnly(true)
        box:SetToolTipText(self.G.FText(Invite.COPY_TOOLTIP))
        w:place(page,box,190,104,290,34)
        w:text(page,Invite.COPY_HINT,495,108,700,30,12)
    end
    if not model.departure then w:button(page,'Back',1060,25,130,48,function() self.screen:Close() end) end
    -- Test 15: Refresh (top right, left of Back) re-pulls the host list
    if model.connection then
        for _,action in ipairs(model.actions) do if action.id=='refresh_lobbies' then
            w:button(page,action.label,915,25,130,48,function() activate('refresh_lobbies') end,action.tooltip,action.enabled)
        end end
    end
    -- Test 15: the connection screen builds no player/settings scroll boxes: a ScrollBox is hit-testable, and these
    -- sat on top of the Host button and the host list and swallowed their clicks.
    local rows=not model.connection and w:scroll(page,90,140,650,420) or nil
    for _,player in ipairs(model.rows) do
        local row=w:row(rows,58,620)
        w:text(row,string.format('%d. %s  %s',player.displayPos,player.name,
            player.isHost and 'HOST' or player.ready and 'READY' or 'Not ready'),0,8,475,40,17)
        for _,kick in ipairs(model.kicks) do if kick.key==player.key then
            w:button(row,'Kick',485,6,110,44,function() activate('kick',player.key) end,nil,kick.enabled)
        end end
    end
    local controls=not model.connection and w:scroll(page,780,140,410,420) or nil
    -- D55: the lobby size. The host types it into the framework text box (the GoobiesMP.ini default is hint text, so
    -- typing replaces it); clients see it.
    local mp=not model.departure and model.maxPlayers
    if mp then
        local row=w:row(controls,76,385)
        if mp.editable then
            w:text(row,'Max players',0,0,380,32,15)
            local box=w:create('EditableTextBox')
            if self.maxText==nil then self.maxText=mp.value~=mp.default and tostring(mp.value) or '' end
            box:SetText(self.G.FText(self.maxText));box:SetIsReadOnly(false)
            pcall(function() box:SetHintText(self.G.FText(tostring(mp.default))) end)
            box:SetToolTipText(self.G.FText('Players in this lobby (2 to '..require('gmp_config').MAX_PLAYERS_LIMIT..'). Empty: the default '..mp.default..'.'))
            w:place(row,box,0,34,190,40);self.maxInput=box
            if self.maxFocused then pcall(function() box:SetKeyboardFocus() end) end
        else w:text(row,'Max players: '..tostring(mp.value),0,0,380,32,15) end
    end
    for _,item in ipairs(model.settings) do
        local row=w:row(controls,76,385)
        w:text(row,item.label,0,0,380,32,15)
        if item.id=='hostOnlyPause' or item.id=='allowAutoRejoin' then
            w:button(row,item.value,95,33,190,36,function() activate(item.id,item.value~='On') end,item.note,item.editable)
        elseif item.id=='color' then
            for i,color in ipairs(model.colors or {}) do
                local colorRow=w:row(controls,42,385)
                w:button(colorRow,(color.selected and '> ' or '')..color.color,0,0,365,38,
                    function() activate('color',color.color) end,'Choose player color',color.available)
            end
        else w:text(row,tostring(item.value or ''),0,34,380,35,14) end
    end
    local loadout=not model.departure and model.loadout or nil
    if loadout and loadout.catalogue then
        -- W11-min: a client has no artifact picker (the host default set applies to everyone).
        for _,domain in ipairs(loadout.artifactsHidden and {'classes'} or {'classes','artifacts'}) do
            local heading=w:row(controls,42,385)
            -- D37: a Ready refused for an unconfirmed class points at the class list (framework outline, no new button).
            local pointed=domain=='classes' and loadout.highlight
            w:text(heading,domain=='classes' and (pointed and 'Class - pick and confirm one' or 'Class') or 'Artifacts',0,2,380,36,18)
            if pointed and w.outline then w:outline(heading,'#FFD966',0,0,385,42) end
            for _,choice in ipairs(loadout.catalogue[domain]) do
                local selected=domain=='classes' and loadout.current and loadout.current.class==choice.id
                if domain=='artifacts' then
                    for _,id in ipairs(require('gmp_lobby_loadout').Artifacts(loadout.current and loadout.current.artifacts)) do
                        if id==choice.id then selected=true end
                    end
                end
                local row=w:row(controls,42,385)
                w:button(row,(selected and '> ' or '')..choice.label,0,0,365,38,
                    function() activate(domain=='classes' and 'class' or 'artifact',choice.id) end,
                    choice.available and 'Changing this selection clears Ready.' or 'Locked',loadout.editable and choice.available)
            end
        end
    elseif not model.departure and not model.connection then
        local row=w:row(controls,70,385)
        w:text(row,'Choose class and artifacts in the game selector before Ready.',0,0,380,65,13)
    end
    local focus
    local row={}
    for _,action in ipairs(model.actions) do
        if not (model.connection and (action.id=='host_picker' or action.id=='friends_only' or action.id=='refresh_lobbies')) then row[#row+1]=action end
    end
    for i,action in ipairs(row) do
        local button=w:button(page,action.label,90+(i-1)*350,590,320,55,function()
            local value
            if action.id=='join_lobby' and action.value then value=action.value     -- a listed local test lobby (D52 dev)
            elseif action.id=='join_lobby' then
                if not valid(self.connectionInput) then return end
                value=self.connectionInput:GetText():ToString():match('^%s*(.-)%s*$')
            end
            activate(action.id,value)
        end,action.tooltip,action.enabled)
        if not focus and action.enabled then focus=button end
    end
    if model.warnings[1] then w:text(page,model.warnings[1],90,660,1100,35,12) end
    -- Transaction commits only once every control has been constructed.
    for _,row in ipairs(self.saved) do row.widget:SetVisibility(1) end
    if model.departure and self.options.departureFocus then self.options.departureFocus(focus) end
    self.lastStamp=stamp(model)
end
-- The main menu (and everything built in it) is freed by the level change into a run. Its cached references are
-- dropped WITHOUT any call into them: UE4SS IsValid cannot vouch for freed memory (R1 attempt 2 client crash in
-- UObject::ProcessEvent). The shared main-menu button handle is marked inactive so the next menu can register it again.
function R:_abandonMenu()
    if self.menuEntry then self.menuEntry.active=false;self.menuEntry.cleanupPending=false end
    self.menu,self.menuEntry,self.overlay,self.saved,self.connectionInput=nil,nil,nil,nil,nil
    self.entry,self.entryBox,self.entryName,self.w=nil,nil,nil,nil
    self.epoch=self.epoch+1;self.queue={};self.dispatch={}
    self.screen.visible=false
    local log=self.options.log
    if log then pcall(log,'main menu gone (level change); lobby references dropped without touching them') end
end
function R:Tick()
    if self.menu and not self.departureSurface and not Liveness.Listed(self.G,self.menu,'WBP_MainMenu_C') then self:_abandonMenu() end
    if self.menuEntry then self.menuEntry:Tick(self.options.log or self.G.print) end
    self.screen:TickSelection()
    -- A runtime owner may supply its verified paused-game widget surface. This
    -- does not create a speculative Blueprint or pause/restore gameplay itself.
    local departure=self.screen:_departure()
    if departure and departure.active and self.options.departureSurface then
        local surface=self.options.departureSurface()
        if valid(surface) and surface:IsInViewport() then
            if self.menu~=surface then
                self.screen:Close()
                if self.menuEntry then self.menuEntry:Remove();self.menuEntry=nil end
                self.entryBox=nil;self.entryName=nil;self.menu=surface;self.departureSurface=true
                self.w=self.options.Widgets.new(self.G,surface,self.options.assets or '',self.dispatch);self:_hook()
            end
            if not self.screen.visible then self.screen.visible=true;self.screen:Refresh() end
        elseif self.departureSurface then
            self.screen:Close();self.menu=nil;self.departureSurface=nil
            if self.options.departureRelease then self.options.departureRelease() end
        end
    elseif self.departureSurface then
        self.screen:Close();self.menu=nil;self.departureSurface=nil
        if self.options.departureRelease then self.options.departureRelease() end
    end
    if self.menu and (not valid(self.menu) or not self.menu:IsInViewport()) then
        self.screen:Close();if self.menuEntry then self.menuEntry:Remove();self.menuEntry=nil end
        self.menu=nil;self.entryBox=nil;self.entryName=nil;self.dispatch={}
    end
    if not self.menu then
        for _,menu in ipairs(self.G.FindAllOf('WBP_MainMenu_C') or {}) do
            if valid(menu) and menu:IsInViewport() then self:Attach(menu);break end
        end
        return
    end
    local queue=self.queue;self.queue={}
    for _,click in ipairs(queue) do
        local fn=click.fn or self.dispatch[click.name]
        if click.epoch==self.epoch and fn then fn() end
    end
    if self.screen.visible then
        self:_tickMaxPlayers()
        local model=self.screen:Model()
        if self.lastStamp~=stamp(model) then self.screen:Refresh() end
    end
end
-- D55: the typed lobby size applies 0.5 s after the last keystroke (each apply re-renders; focus and text survive).
R.MAX_PLAYERS_SETTLE=0.5
function R:_tickMaxPlayers()
    if not valid(self.maxInput) then return end
    local ok,text=pcall(function() return self.maxInput:GetText():ToString() end)
    if not ok then return end
    local now=self.options.clock and self.options.clock() or os.clock()
    if text~=self.maxText then self.maxText=text;self.maxChangedAt=now;return end
    if self.maxChangedAt and now-self.maxChangedAt>=R.MAX_PLAYERS_SETTLE then
        self.maxChangedAt=nil
        local focused=pcall(function() return self.maxInput:HasKeyboardFocus() end) and self.maxInput:HasKeyboardFocus()==true
        self.maxFocused=focused
        self.screen:Click('max_players',text)
    end
end
-- Integration calls Refresh only for authoritative roster/lobby/pause/departure
-- revisions, rather than rebuilding Slate each game tick.
function R:Refresh() if self.screen.visible then return self.screen:Refresh() end end
return R
