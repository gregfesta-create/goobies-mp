-- Game-thread-only island adapter. Inert until explicitly installed/enabled.
-- Session supplies manifests before client level entry/NextIsland, never after
-- terrain generation. No Cheat Mod settings or arbitrary remote asset paths.
local I=require('gmp_islands')
local W={};W.__index=W
W.SET_SEED='/Game/Blueprints/BP_IslandGenerator.BP_IslandGenerator_C:SetSeed'
W.PREPARE='/Game/Blueprints/BP_IslandGenerator.BP_IslandGenerator_C:Prepare'
W.GENERATE='/Game/Blueprints/BP_IslandGenerator.BP_IslandGenerator_C:Generate'
W.PORTAL_BEGIN='/Game/Blueprints/BP_Portal.BP_Portal_C:ReceiveBeginPlay'
W.NEXT='/Game/Blueprints/BP_Player.BP_Player_C:NextIsland'
W.KILL_ALL='/Script/Shooter.EnemyController:KillAllEnemies'
local function valid(object) return object and object:IsValid()==true end
local Liveness=require('gmp_run_sync_liveness')
function W.new(G,options)
    return setmetatable({G=G,options=options,busy=false,installed=false,portals={},failures=0},W)
end
function W:_game(object)
    return valid(object) and object:GetFullName():find('/Game/Maps/Game.',1,true)~=nil
end
function W:Capture(generator,epoch,island)
    assert(self:_game(generator),'Generator outside gameplay world')
    local order={}
    generator.BiomeArray:ForEach(function(_,value) order[#order+1]=value:get():ToString() end)
    local manifest={epoch=epoch,island=island,seed=generator.Seed,stage=generator.BiomeIncrementer,
        chunks=generator.LandscapeChunks,foliage=generator.FoliageAmount,
        artifactBiome=generator['Artifact Syrlig']==true,biomeOrder=order}
    assert(I.Valid(manifest),'Invalid generated island manifest');return manifest
end
function W:ApplySeed(generator,manifest)
    assert(self.options.role()=='client','Only client generators accept host manifests')
    assert(self:_game(generator) and I.Valid(manifest),'Invalid generator or manifest')
    assert(not self.busy,'Recursive island seed application')
    local originalRandom=generator['RandomSeed?']
    self.busy=true
    local ok,why=pcall(function()
        generator['RandomSeed?']=false;generator.Seed=manifest.seed
        generator:SetSeed()
        assert(generator.Seed==manifest.seed,'Host seed application failed')
    end)
    local restored,restoreWhy=pcall(function() generator['RandomSeed?']=originalRandom end)
    self.busy=false
    assert(restored,restoreWhy);assert(ok,why)
end
function W:_guard(fn,...)
    local ok,why=pcall(fn,self,...)
    if not ok then
        self.failures=self.failures+1;self.options.failed(tostring(why))
    end
    return ok
end
function W:_seed(generator)
    if self.busy or not self.options.active() or not self:_game(generator) or self.options.role()~='client' then return end
    local manifest=self.options.manifest()
    assert(manifest,'Client generation started before host manifest')
    self:ApplySeed(generator,manifest)
end
function W:_prepared(generator)
    if self.busy or not self.options.active() or not self:_game(generator) then return end
    if self.options.role()=='client' then
        local manifest=assert(self.options.manifest(),'Client preparation lacks host settings')
        local allowed,count={},0
        generator.BiomeArray:ForEach(function(_,value) allowed[value:get():ToString()]=true;count=count+1 end)
        assert(count==#manifest.biomeOrder,'Host biome table differs from local table')
        assert(generator['Artifact Syrlig']==manifest.artifactBiome,'Host artifact biome mode differs')
        local order={}
        for _,name in ipairs(manifest.biomeOrder) do
            assert(allowed[name],'Host biome is not in the local array')
            order[#order+1]=self.G.FName(name)
        end
        local originalRandom=generator['RandomSeed?']
        self.busy=true
        local ok,why=pcall(function()
            local index=0
            generator.BiomeArray:ForEach(function(_,value) index=index+1;value:set(order[index]) end)
            generator.ShuffleMyDuffle=false;generator.BiomeIncrementer=manifest.stage-1
            generator['RandomSeed?']=false;generator.Seed=manifest.seed
            -- Re-select the host biome before GenerateIsland runs, using the
            -- game's allocated array rather than constructing an out-array.
            generator:Prepare()
            assert(generator.BiomeIncrementer==manifest.stage,'Host biome stage failed')
        end)
        local restored,restoreWhy=pcall(function() generator['RandomSeed?']=originalRandom end)
        self.busy=false;assert(restored,restoreWhy);assert(ok,why)
    end
    self.options.prepared(generator)
end
function W:GatePortal(actor)
    if not self.options.active() or not self:_game(actor) or not actor:GetFullName():find('BP_Portal_C ',1,true) then return end
    local sphere=actor.Sphere
    assert(valid(sphere),'Portal sphere is unavailable')
    local name=actor:GetFullName()
    if self.portals[name] then return end
    local original=sphere:GetGenerateOverlapEvents()
    assert(type(original)=='boolean','Portal overlap state is unavailable')
    sphere:SetGenerateOverlapEvents(false)
    assert(sphere:GetGenerateOverlapEvents()==false,'Portal gate rejected')
    -- An overlap may have started the native travel timeline before discovery.
    -- Stop that path as well; proximity requests own shared travel instead.
    local timeline=actor.Timeline
    if valid(timeline) then timeline:Stop() end
    self.portals[name]={actor=actor,sphere=sphere,original=original,requested=false}
end
function W:_installGenerator()
    if self.generatorHooked then return true end
    if not valid(self.G.StaticFindObject(W.SET_SEED)) or not valid(self.G.StaticFindObject(W.PREPARE)) or not valid(self.G.StaticFindObject(W.GENERATE)) then return false end
    self.G.RegisterHook(W.SET_SEED,function(context) self:_guard(W._seed,context:get()) end)
    self.G.RegisterHook(W.PREPARE,function(context) self:_guard(W._prepared,context:get()) end)
    self.G.RegisterHook(W.GENERATE,function(context)
        local generator=context:get()
        if self.options.active() and self:_game(generator) and self.options.generated then
            -- Generate is followed by native CollectGarbage. Do not destroy
            -- actors or retain a generator wrapper inside that Blueprint frame.
            self.pendingGeneratedName=generator:GetFullName()
        end
    end)
    self.generatorHooked=true;return true
end
function W:FlushGenerated()
    local name=self.pendingGeneratedName
    if not name then return false end
    if not self.options.active() then self.pendingGeneratedName=nil;return false end
    for _,generator in ipairs(self.G.FindAllOf('BP_IslandGenerator_C') or {}) do
        if self:_game(generator) and generator:GetFullName()==name then
            self.pendingGeneratedName=nil
            return self:_guard(function()
                if self.cleanupPending then self:ConsumePortals();self.cleanupPending=nil end
                self.options.generated(generator)
            end)
        end
    end
    return false
end
function W:Install()
    assert(type(self.G.RegisterHook)=='function','Island hook APIs unavailable')
    if not self.portalBeginHooked and valid(self.G.StaticFindObject(W.PORTAL_BEGIN)) then
        self.G.RegisterHook(W.PORTAL_BEGIN,function(context)
            self:_guard(W.GatePortal,context:get())
        end)
        self.portalBeginHooked=true
    end
    self.travelHooks=self.travelHooks or {}
    for _,path in ipairs({W.NEXT,W.KILL_ALL}) do
        if not self.travelHooks[path] and valid(self.G.StaticFindObject(path)) then
            self.G.RegisterHook(path,function(context)
                self:_guard(function()
                    local object=context:get()
                    if not self.options.active() or not self:_game(object) then return end
                    self.travelCounts=self.travelCounts or {}
                    self.travelCounts[path]=(self.travelCounts[path] or 0)+1
                    if path==W.KILL_ALL and self.cleanupPending
                        and object:GetFullName()==self.cleanupControllerName and #object.InstanceStruct>0 then
                        -- A latent wave may have finished after the early Reset.
                        -- Recheck at the native entry boundary, before the unsafe loop.
                        local remaining=#object.InstanceStruct
                        object:Reset()
                        assert(#object.InstanceStruct==0,'Late travel enemy reset left native records')
                        if self.options.trace then self.options.trace('late shared cleanup reset records='..remaining..' remaining=0') end
                    end
                    if self.options.trace then
                        local count=path==W.KILL_ALL and #object.InstanceStruct or '-'
                        self.options.trace('native='..path..' calls='..self.travelCounts[path]..' records='..count)
                    end
                end)
            end)
            self.travelHooks[path]=true
        end
    end
    -- Do not intercept every Actor's BeginPlay during engine startup. The game
    -- thread loop retries loaded generator hooks and discovers gameplay portals.
    self.installed=true;return self:_installGenerator()
end
-- Test 12 audit: one shared lookup per tick. The ticking owner (App:Tick) calls NextFrame() once a tick; within a
-- frame the first LocalWorldPawn() call does the one FindAllOf('World') and later calls reuse its result while the
-- pawn is live (IsValid and not IsActorBeingDestroyed). Nothing is reused across ticks, so a world change is seen on
-- the next tick; a failed lookup returns nothing (never raises) and is retried next tick. Without NextFrame calls
-- every call looks up, as before.
function W:NextFrame() self.frame=(self.frame or 0)+1 end
local function livePawn(pawn)
    if pawn==nil then return nil end
    local ok,alive=pcall(function()
        if pawn:IsValid()~=true then return false end
        if pawn.IsActorBeingDestroyed~=nil and pawn:IsActorBeingDestroyed()==true then return false end
        return true
    end)
    return ok and alive and pawn or nil
end
function W:_lookupWorldPawn()
    local worlds=self.G.FindAllOf('World')
    local library=self.G.StaticFindObject('/Script/Engine.Default__GameplayStatics')
    if type(worlds)~='table' or not valid(library) then return nil end
    for _,world in ipairs(worlds) do
        if self:_game(world) then
            local pawn=library:GetPlayerPawn(world,0)
            return world,valid(pawn) and pawn or nil,library
        end
    end
end
function W:LocalWorldPawn()
    if not self.frame then return self:_lookupWorldPawn() end
    local c=self.worldCache
    if not c or c.frame~=self.frame then
        local ok,world,pawn,library=pcall(self._lookupWorldPawn,self)
        c={frame=self.frame}
        if ok then c.world,c.pawn,c.library=world,pawn,library end
        self.worldCache=c
    end
    if not c.world then return nil end
    return c.world,livePawn(c.pawn),c.library
end
-- Optional HUD label: UI failures cannot stop island travel.
-- Reuse BP_Player:Pause, the same gameplay pause used by the native menus.
-- Release only a pause acquired here; an existing local menu pause is preserved.
function W:ReadPauseScalar(field)
    local _,pawn=self:LocalWorldPawn()
    if not pawn then return nil end
    return pawn[field]
end
function W:SetSharedPaused(paused)
    if type(paused)~='boolean' then return false,'invalid_pause' end
    local world,pawn,library=self:LocalWorldPawn()
    if not pawn then return false,'missing_pawn' end
    local name=pawn:GetFullName()
    if self.sharedPausePawn~=name then self.sharedPausePawn=nil end
    local localPaused=pawn['IsGamePaused?']==true
    -- D44 (test 15): a reward screen of this player is closing: the game resumed itself to finish it (the roulette's
    -- accept -> Pause(true) -> Delay 0.2 s -> RemoveFromParent + RouletteDone runs on world time). Re-freezing now held
    -- every roulette open for as long as the shared pause; it is applied again once the screen has closed.
    if paused and pawn['PresentTime?']==true and not localPaused then return true end
    if paused then
        local currentDilation=library:GetGlobalTimeDilation(world)
        if (not localPaused and self.sharedPausePawn~=name) or type(currentDilation)~='number' or currentDilation>0.001 then
            pawn:Pause(false,false,false,false)
            self.sharedPausePawn=name
        end
        local dilation=library:GetGlobalTimeDilation(world)
        if (pawn['IsGamePaused?']~=true and self.sharedPausePawn~=name) or type(dilation)~='number' or dilation<=0 or dilation>0.001 then
            return false,'pause_not_applied'
        end
        return true
    end
    if self.sharedPausePawn~=name then
        -- An Esc menu can introduce a native freeze after the shared release.
        -- Reconcile it on every tick, not only on the Esc input callback. Leave
        -- reward/inventory pauses alone, and keep the menu open for input.
        local hud=pawn.HUD
        local overlay=valid(hud) and hud.pausemenu_overlay
        local tab=valid(hud) and hud.tab
        if valid(overlay) and overlay:GetVisibility()==0 and pawn['PresentTime?']~=true
            and (not valid(tab) or tab:GetVisibility()~=0) then
            if not self:KeepEscMenuPlaying({name=name,paused=true,previous=false}) then
                return false,'esc_resume_not_applied'
            end
        end
        return true
    end
    pawn:Pause(true,false,false,false)
    local dilation=library:GetGlobalTimeDilation(world)
    if pawn['IsGamePaused?']~=false or type(dilation)~='number' or dilation~=dilation or dilation<=0.001 then
        return false,'resume_not_applied'
    end
    self.sharedPausePawn=nil;return true
end
function W:KeepEscMenuPlaying(request)
    local world,pawn,library=self:LocalWorldPawn()
    if not pawn or pawn:GetFullName()~=request.name then return false end
    -- Leave the native menu flag intact, so the next Esc closes the menu.
    -- Only remove the time freeze introduced by opening that menu.
    if request.paused and not request.previous then
        local normal=pawn.TimeDialation
        if type(normal)~='number' or normal~=normal or normal<=0.001 or normal==math.huge then return false end
        library:SetGlobalTimeDilation(world,normal)
    end
    local dilation=library:GetGlobalTimeDilation(world)
    return type(dilation)=='number' and dilation>0.001
end
-- Observe the game's Esc action only; reward/inventory pauses never request
-- a shared pause. Hook callbacks store scalars, not retained engine objects.
function W:InstallEscapeHook()
    if self.escapeHook then return true end
    local path='/Game/Blueprints/BP_Player.BP_Player_C:InpActEvt_Escape_K2Node_InputActionEvent_1'
    if type(self.G.RegisterHook)~='function' or not valid(self.G.StaticFindObject(path)) then return false end
    self.G.RegisterHook(path,function(context)
        if not self.options.active() then return end
        local pawn=context:get()
        if self:_game(pawn) then
            local hud=pawn.HUD;local overlay=valid(hud) and hud.pausemenu_overlay
            if valid(overlay) and pawn['PresentTime?']~=true then
                local tab=hud.tab
                if valid(tab) and tab:GetVisibility()==0 then return end
                local opened=self:IsEscapeMenuOpen()
                self.escapeRequest={name=pawn:GetFullName(),paused=opened,previous=not opened}
                if self.options.trace then self.options.trace('Esc menu open='..tostring(opened)) end
            end
        end
    end)
    self.escapeHook=true;return true
end
function W:SyncPauseMenuFlag()
    local _,pawn=self:LocalWorldPawn();local hud=pawn and pawn.HUD
    local overlay=valid(hud) and hud.pausemenu_overlay
    if pawn and pawn['PresentTime?']~=true and valid(overlay) then
        local tab=hud.tab
        if not valid(tab) or tab:GetVisibility()~=0 then pawn['IsGamePaused?']=self:IsEscapeMenuOpen() end
    end
end
function W:IsEscapeMenuOpen()
    local _,pawn=self:LocalWorldPawn();local hud=pawn and pawn.HUD
    local overlay=valid(hud) and hud.pausemenu_overlay
    if not valid(overlay) or pawn['PresentTime?']==true then return false end
    local tab=hud.tab
    -- WBP_HUD switches the actual pause_menu Border independently from its
    -- overlay (native Resume/settings routes at dump offsets3877/3920).
    local panel=hud.pause_menu
    return overlay:GetVisibility()==0 and (not valid(panel) or panel:GetVisibility()==0)
        and (not valid(tab) or tab:GetVisibility()~=0)
end
function W:ConsumeEscapeRequest()
    local request=self.escapeRequest;self.escapeRequest=nil;return request
end
function W:InstallResumeHook()
    if self.resumeHook then return true end
    local path='/Game/UI/WBP_HUD.WBP_HUD_C:BndEvt__WBP_HUD_resume_K2Node_ComponentBoundEvent_1_Click__DelegateSignature'
    if not valid(self.G.StaticFindObject(path)) then return false end
    self.G.RegisterHook(path,function(context)
        if not self.options.active() then return end
        local _,player=self:LocalWorldPawn();local hud=player and player.HUD
        if valid(hud) and context:get():GetFullName()==hud:GetFullName() then
            self.escapeRequest={name=player:GetFullName(),paused=false,previous=true}
        end
    end)
    self.resumeHook=true;return true
end
function W:AdoptEscapePause(name)
    self.sharedPausePawn=name
end
function W:UndoEscapePause(request)
    local world,pawn,library=self:LocalWorldPawn()
    if not pawn or pawn:GetFullName()~=request.name then return false end
    pawn:Pause(not request.previous,false,false,false)
    local dilation=library:GetGlobalTimeDilation(world)
    return pawn['IsGamePaused?']==request.previous and type(dilation)=='number'
        and (request.previous and dilation>0 and dilation<=0.001 or not request.previous and dilation>0.001)
end
function W:UpdatePauseMenu(state,role,request)
    local _,pawn=self:LocalWorldPawn();local hud=pawn and pawn.HUD
    if not valid(hud) then self.pauseMenu=nil;return false end
    self:LightenPauseBackground(hud)
    self:_forgetDeadPauseMenu()
    local menu=self.pauseMenu
    if menu and (not valid(menu.hud) or menu.hud:GetFullName()~=hud:GetFullName() or not valid(menu.button)) then menu=nil;self.pauseMenu=nil end
    if not menu then
        -- The game's "End Run" control is named restart; quit opens its
        -- separate quit-confirmation path and must keep its original placement.
        local resume,settings,quit=hud.resume,hud.settings,hud.restart
        if not valid(resume) or not valid(settings) or not valid(quit) then return false end
        local function branch(child,ancestor)
            local current=child
            for _=1,24 do
                local parent=current:GetParent()
                if valid(parent) and parent:GetFullName()==ancestor:GetFullName() then return current end
                if not valid(parent) then return nil end
                current=parent
            end
        end
        local parent=resume:GetParent();local r,s,q
        for _=1,24 do
            if not valid(parent) then break end
            local class=parent:GetFullName():match('^(%S+)')
            r,s,q=branch(resume,parent),branch(settings,parent),branch(quit,parent)
            if (class=='VerticalBox' or class=='CanvasPanel') and r and s and q
                and r:GetFullName()~=s:GetFullName() and r:GetFullName()~=q:GetFullName()
                and s:GetFullName()~=q:GetFullName() then break end
            parent=parent:GetParent()
        end
        if not valid(parent) or not r or not s or not q or r:GetFullName()==s:GetFullName()
            or r:GetFullName()==q:GetFullName() or s:GetFullName()==q:GetFullName() then
            if not self.pauseLayoutReported and self.options.trace then
                self.pauseLayoutReported=true
                for label,widget in pairs({resume=resume,settings=settings,quit=quit}) do
                    local p=widget:GetParent()
                    self.options.trace('Pause layout unavailable; '..label..' parent='..tostring(valid(p) and p:GetFullName() or 'none'))
                end
            end
            return false
        end
        local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
        local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
        if not valid(lib) or not valid(cls) then return false end
        local button=lib:Create(hud,cls,nil)
        assert(valid(button) and valid(button.t_text),'Pause button unavailable')
        -- Initialize the newly-created label before attachment. All Esc rows
        -- use the native Resume face/size; its default WBP_Button font differs.
        local native=resume.t_text.Font;local font=button.t_text.Font
        font.FontObject=native.FontObject;font.TypefaceFontName=native.TypefaceFontName
        font.Size=native.Size;font.LetterSpacing=native.LetterSpacing or 0
        -- Native WBP_Button owns a ScaleBox. Match its allocated row instead
        -- of applying an extra text transform inside that scaling hierarchy.
        for _,control in ipairs({button,resume,settings,quit}) do
            local label=control.t_text
            label:SetRenderScale({X=1,Y=1})
            control.WidgetTree.RootWidget:SetStretch(0)
            label:SetJustification(1)
            local slot=label.Slot
            if valid(slot) then
                local kind=slot:GetFullName():match('^(%S+)')
                if kind=='CanvasPanelSlot' then
                    slot:SetAnchors({Minimum={X=.5,Y=.5},Maximum={X=.5,Y=.5}})
                    slot:SetAlignment({X=.5,Y=.5});slot:SetPosition({X=0,Y=0});slot:SetAutoSize(true)
                elseif kind=='ButtonSlot' or kind=='OverlaySlot' or kind=='BorderSlot' or kind=='SizeBoxSlot' then
                    slot:SetHorizontalAlignment(2);slot:SetVerticalAlignment(2)
                end
            end
        end
        local class=parent:GetFullName():match('^(%S+)')
        if class=='VerticalBox' then
            r:RemoveFromParent();s:RemoveFromParent();q:RemoveFromParent()
            for _,child in ipairs({button,r,s,q}) do
                local slot=parent:AddChildToVerticalBox(child);slot:SetHorizontalAlignment(2)
            end
        elseif class=='CanvasPanel' then
            local position=r.Slot:GetPosition();local size=r.Slot:GetSize()
            local nextPosition=s.Slot:GetPosition();local gap=nextPosition.Y-position.Y
            assert(gap>0,'Pause menu spacing unavailable')
            local slot=parent:AddChildToCanvas(button)
            slot:SetPosition({X=position.X,Y=position.Y-gap});slot:SetSize({X=size.X,Y=size.Y})
            local anchors=r.Slot:GetAnchors();local alignment=r.Slot:GetAlignment()
            slot:SetAnchors({Minimum={X=anchors.Minimum.X,Y=anchors.Minimum.Y},Maximum={X=anchors.Maximum.X,Y=anchors.Maximum.Y}})
            slot:SetAlignment({X=alignment.X,Y=alignment.Y})
        else button:RemoveFromParent();return false end
        menu={hud=hud,button=button,name=button:GetFullName(),parent=parent,
            controls={button,resume,settings,quit},branches={r,s,q},reference=r};self.pauseMenu=menu
        if self.options.trace then self.options.trace('Pause menu attached parent='..parent:GetFullName()) end
    end
    self:MatchPauseRows(menu)
    local enabled=not state.locked and (role=='host' or not state.hostOnly)
    menu.button:SetIsEnabled(enabled)
    menu.button:SetToolTipText(self.G.FText(state.locked and 'Host handover in progress' or
        (not enabled and 'Only the host can pause' or 'Pause or unpause the game for everyone')))
    menu.button.t_text:SetText(self.G.FText(state.paused and 'Unpause' or 'Pause'))
    menu.request=request;menu.enabled=enabled
    if not self.pauseButtonHook then
        local path='/Game/UI/WBP_Button.WBP_Button_C:BndEvt__WBP_Button01_b_button_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature'
        self.G.RegisterHook(path,function(context)
            local current=self.pauseMenu
            if current and current.enabled and self.options.active() and context:get():GetFullName()==current.name then
                self.pauseButtonClicked=true
            end
        end)
        self.pauseButtonHook=true
    end
    if self.pauseButtonClicked then
        self.pauseButtonClicked=nil
        if menu.enabled then menu.request() end
    end
    return true
end
function W:MatchPauseRows(menu)
    -- Slate slot Center is 2; TextJustification Center is 1. Mixing these
    -- enums left-aligns different text widths in otherwise identical rows.
    if menu.rowsMatched then return end
    if menu.parent:GetFullName():match('^(%S+)')~='VerticalBox' then return end
    -- Wait for Slate's first layout so the reference is the visible native row.
    local reference=menu.reference:GetDesiredSize()
    local function positive(v) return type(v)=='number' and v>0 and v<math.huge end
    if not positive(reference.Y) then return end
    local width=reference.X
    for _,control in ipairs(menu.controls) do
        local size=control:GetDesiredSize()
        if positive(size.X) then width=math.max(width,size.X) end
    end
    if not positive(width) then return end
    local cls=self.G.StaticFindObject('/Script/UMG.SizeBox')
    assert(valid(cls),'Pause row SizeBox unavailable')
    local rows={}
    -- Construct all wrappers before removing working menu controls.
    for i=1,#menu.controls do
        local row=self.G.StaticConstructObject(cls,menu.hud.WidgetTree)
        assert(valid(row),'Pause row construction failed')
        row:SetWidthOverride(width);row:SetHeightOverride(reference.Y);rows[i]=row
    end
    menu.button:RemoveFromParent()
    for _,control in ipairs(menu.controls) do control:RemoveFromParent() end
    -- Remove the former native wrapper branches from this menu only.
    for _,branch in ipairs(menu.branches) do branch:RemoveFromParent() end
    for i,control in ipairs(menu.controls) do
        local row=rows[i];row:SetContent(control)
        control.Slot:SetHorizontalAlignment(0);control.Slot:SetVerticalAlignment(0)
        local root=control.WidgetTree.RootWidget
        root:SetStretch(0) -- Native font owns size; avoid a second ScaleBox scaling pass.
        local content=root:GetChildAt(0)
        content.Slot:SetHorizontalAlignment(2);content.Slot:SetVerticalAlignment(2)
        if valid(control.b_button) then
            local body=control.b_button:GetChildAt(0)
            if valid(body) and valid(body.Slot) then
                body.Slot:SetPadding({Left=0,Top=0,Right=0,Bottom=0})
            end
        end
        local text=control.t_text
        text:SetRenderScale({X=1,Y=1});text:SetJustification(1)
        text.Slot:SetHorizontalAlignment(2);text.Slot:SetVerticalAlignment(2)
        text.Slot:SetPadding({Left=0,Top=0,Right=0,Bottom=0})
        local slot=menu.parent:AddChildToVerticalBox(row);slot:SetHorizontalAlignment(2)
    end
    menu.rowsMatched=true;menu.rows=rows
    if self.options.trace then self.options.trace('Pause rows matched width='..width..' height='..reference.Y) end
end
function W:LightenPauseBackground(hud)
    local key=hud:GetFullName()
    if self.pauseBackgroundHud==key then return end
    local root=hud.pausemenu_overlay
    if not valid(root) then return end
    local containers={Overlay=true,VerticalBox=true,HorizontalBox=true,CanvasPanel=true,Border=true,
        BackgroundBlur=true,SizeBox=true,ScaleBox=true,ScrollBox=true}
    local count=0
    local function walk(widget,depth)
        if not valid(widget) or depth>16 or count>=64 then return end
        count=count+1
        local full=widget:GetFullName();local class=full:match('^(%S+)')
        if class=='BackgroundBlur' then
            widget:SetBlurStrength(1.5)
        elseif class=='Border' and full:match('%.pause_menu$') then
            local color=widget.BrushColor
            widget:SetBrushColor({R=color.R,G=color.G,B=color.B,A=math.min(color.A*.5,.3)})
        end
        if containers[class] then
            for i=0,widget:GetChildrenCount()-1 do walk(widget:GetChildAt(i),depth+1) end
        end
    end
    local ok,why=pcall(walk,root,0)
    if ok then
        self.pauseBackgroundHud=key
        if self.options.trace then self.options.trace('Esc background lightened; blur=1.5 background alpha capped at 0.3') end
    elseif not self.pauseBackgroundError then
        self.pauseBackgroundError=true
        if self.options.trace then self.options.trace('Esc background adjustment unavailable: '..tostring(why)) end
    end
end
function W:SetTravelNotice(text)
    self.travelNoticeText=text
    return self:_RenderNotice(self.pauseNoticeText or text or self.playerNoticeText)
end
function W:SetPauseNotice(text)
    self.pauseNoticeText=text
    return self:_RenderNotice(text or self.travelNoticeText or self.playerNoticeText)
end
-- A short player notice (a player lost connection / rejoined); the pause and travel notices take precedence.
function W:SetPlayerNotice(text)
    self.playerNoticeText=text
    return self:_RenderNotice(self.pauseNoticeText or self.travelNoticeText or text)
end
-- Cached HUD widgets (the notice, the pause rows) are forgotten without touching them once their HUD is no longer a
-- live WBP_HUD_C: a level change frees them and UE4SS IsValid cannot detect freed memory (R1 attempt 2 crash rule).
function W:_forgetDeadPauseMenu()
    if self.pauseMenu and not Liveness.Listed(self.G,self.pauseMenu.hud,'WBP_HUD_C') then self.pauseMenu=nil end
    return self.pauseMenu==nil
end
function W:_RenderNotice(text)
    if self.notice and not Liveness.Listed(self.G,self.notice.hud,'WBP_HUD_C') then self.notice=nil end
    local ok,why=pcall(function()
        if not text then
            if self.notice and valid(self.notice.text) then self.notice.text:SetVisibility(1);self.notice.text:RemoveFromParent() end
            self.notice=nil;return
        end
        local pausedBy=type(text)=='string' and text:lower():match('^paused by ')~=nil
        if self.notice and self.notice.pausedBy~=pausedBy then
            if valid(self.notice.text) then self.notice.text:SetVisibility(1);self.notice.text:RemoveFromParent() end
            self.notice=nil
        end
        local _,pawn=self:LocalWorldPawn();local hud=pawn and pawn.HUD
        if not valid(hud) then return end
        if self.notice and (self.notice.hud~=hud or not valid(self.notice.hud) or not valid(self.notice.text)) then
            if valid(self.notice.text) then self.notice.text:SetVisibility(1);self.notice.text:RemoveFromParent() end
            self.notice=nil
        end
        if not self.notice then
            local canvas=hud.WidgetTree.RootWidget
            if not valid(canvas) then return end
            local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
            local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
            if not valid(lib) or not valid(cls) then return end
            local host=lib:Create(hud,cls,nil);local label=host.t_text
            assert(valid(label),'Travel label unavailable')
            self.notice={hud=hud,host=host,text=label}
            label:RemoveFromParent();label.Font.Size=pausedBy and 36 or 18
            local color=label.ColorAndOpacity;local rgba=color.SpecifiedColor
            local baseColor={R=rgba.R,G=rgba.G,B=rgba.B,A=rgba.A,rule=color.ColorUseRule}
            if pausedBy then color.ColorUseRule=0;rgba.R=1;rgba.G=0;rgba.B=0;rgba.A=1 end
            label:SetVisibility(4) -- HitTestInvisible: never intercept reward clicks.
            label:SetShadowOffset({X=2,Y=2})
            label:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
            local slot=canvas:AddChildToCanvas(label)
            slot:SetAnchors({Minimum={X=.5,Y=0},Maximum={X=.5,Y=0}})
            slot:SetAlignment({X=.5,Y=0});slot:SetPosition({X=0,Y=self.escRoleNoticeY or 24});slot:SetSize({X=1000,Y=60});slot:SetZOrder(100)
            label:SetJustification(1)
            self.notice={hud=hud,host=host,text=label,baseColor=baseColor,pausedBy=pausedBy}
        end
        self.notice.text.Font.Size=pausedBy and 36 or 18
        local color=self.notice.text.ColorAndOpacity;local rgba=color.SpecifiedColor;local base=self.notice.baseColor
        color.ColorUseRule=pausedBy and 0 or base.rule
        rgba.R=pausedBy and 1 or base.R;rgba.G=pausedBy and 0 or base.G
        rgba.B=pausedBy and 0 or base.B;rgba.A=pausedBy and 1 or base.A
        self.notice.text.Slot:SetSize({X=1000,Y=pausedBy and 88 or 60})
        self.notice.text.Slot:SetPosition({X=0,Y=self.escRoleNoticeY or 24})
        if self.notice.value~=text then self.notice.text:SetText(self.G.FText(text));self.notice.value=text end
    end)
    if not ok then
        if self.notice and valid(self.notice.text) then pcall(function() self.notice.text:SetVisibility(1);self.notice.text:RemoveFromParent() end) end
        self.notice=nil
    end
    if not ok and not self.noticeError then
        self.noticeError=true
        if self.options.trace then self.options.trace('notice unavailable: '..tostring(why)) end
    end
    return ok
end
-- Diagnostic checkpoints require positive visibility evidence; normal travel
-- deliberately retains its separate missing-HUD fallback.
function W:DiagnosticVisible()
    local ok,visible=pcall(function()
        local _,pawn=self:LocalWorldPawn()
        if not valid(pawn) or pawn['PresentTime?']==true then return false end
        local hud=pawn.HUD
        if not valid(hud) then return false end
        local fade=hud.FadeValue
        -- Native FadeIn increments overshoot to ~1.005 before stopping.
        return type(fade)=='number' and fade==fade and fade>=.999 and fade<=1.01
    end)
    return ok and visible==true
end
function W:RewardsBlocked()
    local _,pawn=self:LocalWorldPawn()
    if not pawn or pawn['PresentTime?']==true then return true end
    -- Generated/committed does not mean the HUD's radial fade has finished.
    -- Starting FadeOut while FadeIn is active runs opposing native timers.
    local hud=pawn.HUD
    if valid(hud) and type(hud.FadeValue)=='number' then return hud.FadeValue<.999 end
    return false
end
function W:SetWaiting(waiting)
    local world,_,library=self:LocalWorldPawn()
    if not world then return false end
    -- SetGamePaused may return false when unpausing an already unpaused world.
    -- Verify the resulting state rather than treating a no-op as rejection.
    if library:IsGamePaused(world)~=waiting then library:SetGamePaused(world,waiting) end
    assert(library:IsGamePaused(world)==waiting,'Island pause state rejected')
    self.waiting=waiting;return true
end
function W:ConsumePortals()
    -- Boss cleanup can create a fresh portal after the old one was consumed.
    -- Scan the world as well as tracked gates before releasing a new island.
    for _,actor in ipairs(self.G.FindAllOf and self.G.FindAllOf('BP_Portal_C') or {}) do
        if self:_game(actor) then actor:K2_DestroyActor() end
    end
    for name,portal in pairs(self.portals) do
        if valid(portal.actor) then portal.actor:K2_DestroyActor() end
        self.portals[name]=nil
    end
end
function W:Transition()
    local _,pawn=self:LocalWorldPawn()
    if not pawn then return false end
    -- A remote portal request or F8 may arrive while this player is choosing
    -- a reward. Leave the transition pending; Tick retries after it finishes.
    if pawn['PresentTime?']==true then return false end
    -- Shared travel retires the old horde without granting further rewards.
    -- KillAllEnemies writes every record's transform without checking whether
    -- its native transform buffer still exists (confirmed null-write dumps).
    -- Reset is the game's normal cleanup path: pauses spawn timers, retires
    -- miniboss actors and clears InstanceStruct and mesh instances. Run it
    -- before NextIsland's delayed KillAllEnemies so that routine has no rows.
    assert(self.options.active(),'Shared cleanup outside an active session')
    local controller=pawn.EnemyController
    assert(self:_game(controller),'Travel enemy controller is unavailable')
    local count=#controller.InstanceStruct
    self:SetWaiting(false) -- NextIsland contains timed cleanup before Generate.
    -- The normal portal overlap schedules its own destruction after NextIsland.
    -- Our shared gate replaces that overlap, so consume old portals explicitly.
    for name,portal in pairs(self.portals) do
        if valid(portal.actor) then portal.actor:K2_DestroyActor() end
        self.portals[name]=nil
    end
    -- Retiring a still-alive boss via controller Reset makes its next health
    -- update run BossDeath and award another portal. Retire its actor first.
    for _,boss in ipairs(self.G.FindAllOf and self.G.FindAllOf('BP_Boss_C') or {}) do
        if self:_game(boss) then
            for _,field in ipairs({'BossBar','MiniBossBar'}) do
                local bar=boss[field]
                if valid(bar) then bar:RemoveFromParent() end
            end
            boss:K2_DestroyActor()
        end
    end
    controller:Reset()
    assert(#controller.InstanceStruct==0,'Travel enemy reset left native records')
    if self.options.trace then self.options.trace('shared cleanup reset records='..count..' remaining=0') end
    self.cleanupControllerName=controller:GetFullName()
    self.cleanupPending=true
    pawn:NextIsland();return true
end
function W:PollPortals(pawn,requestsAllowed)
    if not self.options.active() then return self:RestorePortals() end
    local actors=self.G.FindAllOf and self.G.FindAllOf('BP_Portal_C')
    if type(actors)=='table' then for _,actor in ipairs(actors) do self:GatePortal(actor) end end
    -- Keep native overlaps gated even while disconnected or waiting for a manifest.
    if requestsAllowed==false then return end
    if not self:_game(pawn) then return end
    -- Roulette and upgrade choices must finish before proximity starts travel.
    if pawn['PresentTime?']==true then return end
    local location=pawn:K2_GetActorLocation()
    for name,portal in pairs(self.portals) do
        if not valid(portal.actor) or not valid(portal.sphere) then self.portals[name]=nil
        elseif not portal.requested then
            local center=portal.sphere:K2_GetComponentLocation()
            local radius=portal.sphere:GetScaledSphereRadius()
            -- The game's portal grows over time; a large radius is not a handoff failure.
            if type(radius)=='number' and radius==radius and radius>0 and radius<math.huge then
                radius=math.min(radius,20000)
            else radius=0 end
            if radius>0 and (location.X-center.X)^2+(location.Y-center.Y)^2+(location.Z-center.Z)^2<=radius^2 then
                -- Mark only accepted requests; a not-yet-ready session can retry.
                portal.requested=self.options.portal()==true
            end
        end
    end
end
function W:RestorePortals()
    self.pendingGeneratedName=nil
    for name,portal in pairs(self.portals) do
        if valid(portal.sphere) then portal.sphere:SetGenerateOverlapEvents(portal.original) end
        self.portals[name]=nil
    end
end
return W
