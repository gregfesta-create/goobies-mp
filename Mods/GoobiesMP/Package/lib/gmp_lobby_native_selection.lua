-- Native menu selection bridge. Source fields/calls are evidenced by
-- evidence/native_autostart_static_20261011/WBP_MainMenu.txt. No save writes,
-- SetCharText calls or world entry: SetCharText can persist unlock progress.
local N={};N.__index=N
N.NAME='Name_37_2A5E302F45AF70ED80F5018DC0B22DA4'
N.LOCK='Locked_5_B2E318594FE8254660BE1EA7A64F48E5'
N.LOCK_HOOK='/Game/UI/WBP_MainMenu.WBP_MainMenu_C:SetCharText'
N.ARTIFACT_ACTOR='Actor_8_C1984DE445F528C4E0C3E0840A7776F8'
N.ARTIFACT_SCORE='ScoreMultiplier_11_88D422DC4B911CF9822BCFB328C0CC48'
-- Class unlocks (R1 attempt 4: the picker offered only the Play screen's class). The game's own source is the
-- playerstats save: WBP_MainMenu.SetCharText reads LoadGameFromSlot('playerstats',0).CharacterStats[CurrentChar].Locked
-- (evidence native_autostart_static_20261011/WBP_MainMenu.txt 812-836). Loading a save only reads it; nothing is saved.
-- The SetCharText hook observations still count: a class is available once either source says it is unlocked
-- (unlocking is one-way in the game). A character past the end of the save's CharacterStats is unlocked: the game
-- reads CharacterStats[CurrentChar] by reference, which past the end is a zeroed entry (Locked=false). The real save
-- (2026-10-13) has 5 entries for 12 characters; reading only the entries offered just Bingus and Wooby.
N.SAVE_SLOT='playerstats'
N.SAVE_REFRESH=5
local function valid(o) return o and o:IsValid() end
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function parentMatches(slot,selector)
    return valid(slot.Parent) and valid(selector) and slot.Parent:GetFullName()==selector:GetFullName()
end
local function integer(v,max) return type(v)=='number' and v%1==0 and v>=0 and v<=max end
local function nativeCallable(G,object,name,path)
    local method=object[name]
    if type(method)=='function'then return true end -- plain-function boundary fixtures.
    if (type(method)~='userdata' and type(method)~='table') or not valid(method) then return false end
    local binding=G.StaticFindObject(path)
    if not valid(binding) or method:GetFullName()~=binding:GetFullName() then return false end
    local count=0;binding:ForEachProperty(function()count=count+1 end)
    return count==0 -- inspected NextChar/SelectThisArtifact have no parameters.
end
function N.new(G,options) return setmetatable({G=G,options=options or {},locks={},logged={}},N) end
function N:_once(line)
    if self.logged[line] then return end
    self.logged[line]=true
    if self.options.log then self.options.log(line) end
end
-- index (engine, zero-based) -> Locked from the playerstats save; nil when unreadable. Read at most every SAVE_REFRESH s.
function N:_saveLocks()
    local now=(self.options.clock or os.clock)()
    if self.saveReadAt and now-self.saveReadAt<N.SAVE_REFRESH then return self.saveLocks end
    self.saveReadAt=now
    local ok,result=pcall(function()
        local statics=self.G.StaticFindObject('/Script/Engine.Default__GameplayStatics')
        assert(valid(statics),'missing_gameplay_statics')
        local save=statics:LoadGameFromSlot(N.SAVE_SLOT,0)
        assert(valid(save),'missing_playerstats_save')
        local stats=save.CharacterStats
        assert(stats~=nil and #stats>0 and #stats<=256,'invalid_character_stats')
        local locks={count=#stats}
        stats:ForEach(function(index,element)
            assert(type(index)=='number' and index%1==0 and index>=1 and index<=256,'invalid_character_stats_index')
            local value=element:get()[N.LOCK]
            if type(value)=='boolean' then locks[index-1]=value end
        end)
        return locks
    end)
    if ok then self.saveLocks=result
    else self.saveLocks=nil;self:_once('Lobby class unlocks unreadable from the save: '..tostring(result):sub(1,200)) end
    return self.saveLocks
end
function N:_menu()
    if self.options.menu then return self.options.menu() end
    local result
    for _,menu in ipairs(self.G.FindAllOf('WBP_MainMenu_C') or {}) do
        if valid(menu) and menu:IsInViewport() then assert(not result,'ambiguous_menu');result=menu end
    end
    assert(result and valid(result.BP_Menu),'missing_menu');return result
end
function N:Install()
    if self.installed then return true end
    if not valid(self.G.StaticFindObject(N.LOCK_HOOK)) then return false,'missing_lock_hook' end
    self.G.RegisterHook(N.LOCK_HOOK,function(context,locked)
        local ok,why=pcall(function()
            local menu=context:get();local index=menu.BP_Menu.CurrentChar;local value=locked:get()
            assert(integer(index,255) and type(value)=='boolean','invalid_lock_observation')
            local name=menu:GetFullName()
            self.locks[name]=self.locks[name] or {};self.locks[name][index]=value
        end)
        if not ok and self.options.log then self.options.log('Lobby lock observation: '..tostring(why)) end
    end)
    self.installed=true;return true
end
function N:Catalogue()
    local ok,result=pcall(function()
        local menu=self:_menu();local data=menu.BP_Menu.CharacterInfo
        assert(#data>0 and #data<=256,'invalid_character_catalogue')
        local library=self.G.StaticFindObject('/Script/Engine.Default__KismetNodeHelperLibrary')
        local enum=self.G.StaticFindObject('/Game/Enums/EnumsTranslate/E_CharacterNames.E_CharacterNames')
        assert(valid(library) and valid(enum),'missing_character_name_library')
        local observed=self.locks[menu:GetFullName()] or {};local classes={}
        local saveLocks=self:_saveLocks()
        data:ForEach(function(index,element)
            -- Pinned UE4SS LuaTArray.cpp supplies i+1; native CurrentChar and
            -- the observed lock hook use the engine's zero-based index.
            assert(type(index)=='number' and index%1==0 and index>=1 and index<=256,'invalid_character_array_index')
            index=index-1
            local row=element:get();local character=row[N.NAME]
            assert(integer(index,255) and integer(character,255),'invalid_character_identity')
            local label=library:GetEnumeratorUserFriendlyName(enum,character)
            -- Pinned LuaUnrealString.hpp exposes FString:ToString(); engine
            -- return values are userdata, not ordinary Lua strings.
            if type(label)~='string' then
                assert((type(label)=='userdata' or type(label)=='table') and type(label.ToString)=='function','invalid_character_label')
                label=label:ToString()
            end
            assert(type(label)=='string' and #label>0 and #label<=128,'invalid_character_label')
            local locked=observed[index]
            if self.options.lockAt then locked=self.options.lockAt(index,N.LOCK) end
            assert(locked==nil or type(locked)=='boolean','invalid_lock_value')
            local saved=saveLocks and saveLocks[index]
            if saveLocks and saved==nil and index>=saveLocks.count then saved=false end
            -- D41: the host's Unlock all classes (Cheat Mod) offers every class to every player.
            local all=self.options.unlockAll and self.options.unlockAll()==true
            classes[#classes+1]={id='character_'..index,label=label,available=all or locked==false or saved==false,index=index,character=character}
        end)
        local artifacts=self:_artifacts(menu)
        return {classes=classes,artifacts=artifacts,menu=menu:GetFullName(),current=menu.BP_Menu.CurrentChar}
    end)
    if not ok then return nil,tostring(result):sub(1,600) end
    return result
end
-- Read existing native slots rather than invoking AddArtifactsToGrid: that
-- function updates the save's artifact unlock records as a side effect.
function N:_artifacts(menu)
    local selector=menu.WBP_ArtifactSelector
    if not valid(selector) or not valid(selector.ArtifactsGrid) then return {} end
    local grid=selector.ArtifactsGrid;local count=grid:GetChildrenCount()
    assert(integer(count,256),'invalid_artifact_count')
    local result,seen={},{}
    for index=0,count-1 do
        local slot=grid:GetChildAt(index)
        assert(valid(slot),'invalid_artifact_slot')
        local actor=slot.ArtifactInfo[N.ARTIFACT_ACTOR]
        assert(valid(actor),'invalid_artifact_actor')
        local identity=actor:GetFullName()
        assert(type(identity)=='string' and #identity>0 and #identity<=512 and not seen[identity],'invalid_artifact_identity')
        seen[identity]=true
        local locked,selected=slot['Locked?'],slot['IsSelected?']
        assert(type(locked)=='boolean' and type(selected)=='boolean','invalid_artifact_flags')
        result[#result+1]={id='artifact_'..index,label=identity:match('([^./ ]+)_C$') or identity,
            available=not locked,selected=selected,index=index,actor=identity}
    end
    return result
end
-- options.held (Coder B): a rejoin applies the class this player held in the run; the relaunched selector may show it
-- locked (its unlock source can differ), so only an unknown class is refused then.
function N:ApplyClass(id,options)
    local catalogue,why=self:Catalogue();if not catalogue then return false,why end
    local selected
    for _,entry in ipairs(catalogue.classes) do if entry.id==id then selected=entry end end
    local held=type(options)=='table' and options.held==true
    if not selected or (not selected.available and not held) then return false,'class_locked_or_unknown' end
    local ok,err=pcall(function()
        local menu=self:_menu();assert(menu:GetFullName()==catalogue.menu,'menu_changed')
        local actor=menu.BP_Menu
        assert(nativeCallable(self.G,actor,'NextChar','/Game/Blueprints/BP_PlayerMenu.BP_PlayerMenu_C:NextChar'),'missing_class_initialization')
        assert(#actor.CharacterMeshes>selected.index,'missing_character_mesh')
        local gi=menu.BP_GameInstance
        assert(valid(gi),'missing_game_instance')
        local old=actor.CurrentChar
        if old==selected.index and gi.Character==selected.index then return end
        actor.CurrentChar=selected.index
        -- BP_PlayerMenu.NextChar jumps to SetStaticMesh, then sets
        -- BP_GameInstance.Character=CurrentChar and native preview material.
        -- The inspected path loads saved lock flags but never saves them.
        local initialized,problem=pcall(function()actor:NextChar()end)
        if not initialized or actor.CurrentChar~=selected.index or gi.Character~=selected.index then
            actor.CurrentChar=old
            local restored=pcall(function()actor:NextChar()end)
            restored=restored and actor.CurrentChar==old and gi.Character==old
            error('class_initialization_failed:'..tostring(problem or 'readback')..(restored and ':restored' or ':rollback_failed'))
        end
    end)
    if not ok then return false,tostring(err):sub(1,600) end
    return true
end
function N:CaptureCurrent()
    local catalogue,why=self:Catalogue();if not catalogue then return nil,why end
    for _,entry in ipairs(catalogue.classes) do
        if entry.index==catalogue.current then
            local artifacts={}
            for _,artifact in ipairs(catalogue.artifacts) do if artifact.selected then artifacts[#artifacts+1]=artifact.id end end
            return {class=entry.id,artifacts=table.concat(artifacts,'+'),available=entry.available}
        end
    end
    return nil,'invalid_current_character'
end
-- Apply one native slot toggle at a time. SelectThisArtifact schedules a
-- next-tick latent action; immediate flag writes would bypass score updates.
function N:_beginSelection(selection)
    if self.pending or self.cancelGuard then return false,'selection_pending' end
    if type(selection)~='table' or type(selection.class)~='string' or type(selection.artifacts)~='string' then return false,'invalid_selection' end
    local catalogue,why=self:Catalogue();if not catalogue then return false,why end
    local wanted,seen,count={},{},0
    if selection.artifacts~='' then
        for id in (selection.artifacts..'+'):gmatch('([^+]*)%+') do
            if id=='' or seen[id] then return false,'invalid_artifacts' end
            seen[id]=true;wanted[id]=true;count=count+1
        end
    end
    if count>require('gmp_config').LOBBY.MAX_ARTIFACTS then return false,'too_many_artifacts' end
    local changes={}
    for _,entry in ipairs(catalogue.artifacts) do
        if wanted[entry.id] then wanted[entry.id]=nil end
        local target=seen[entry.id]==true
        if entry.selected~=target then
            if not entry.available then return false,'artifact_locked' end
            changes[#changes+1]={id=entry.id,index=entry.index,actor=entry.actor,target=target}
        end
    end
    if next(wanted) then return false,'unknown_artifact' end
    local class
    for _,entry in ipairs(catalogue.classes) do if entry.id==selection.class then class=entry end end
    if not class or not class.available then return false,'class_locked_or_unknown' end
    local menu=self:_menu()
    for _,change in ipairs(changes) do
        local slot=menu.WBP_ArtifactSelector.ArtifactsGrid:GetChildAt(change.index)
        if not nativeCallable(self.G,slot,'SelectThisArtifact','/Game/UI/WBP_ArtifactsSlot.WBP_ArtifactsSlot_C:SelectThisArtifact') then return false,'missing_artifact_selection_function' end
        assert(parentMatches(slot,menu.WBP_ArtifactSelector),'artifact_parent_changed')
        local score=slot.ArtifactInfo[N.ARTIFACT_SCORE]
        assert(finite(score) and finite(menu.WBP_ArtifactSelector.TotalScoreMultiplier),'invalid_artifact_score')
        change.score=score
    end
    local ok,err=self:ApplyClass(selection.class);if not ok then return false,err end
    self.pending={menu=catalogue.menu,class=selection.class,artifacts=selection.artifacts,changes=changes,index=1,ticks=0}
    return true
end
function N:BeginSelection(selection)
    local ok,result,why=pcall(self._beginSelection,self,selection)
    if not ok then return false,tostring(result):sub(1,600) end
    return result,why
end
function N:StepSelection()
    local p=self.pending;if not p then return false,'no_selection' end
    local ok,result,why=pcall(function()
        local menu=self:_menu();assert(menu:GetFullName()==p.menu,'menu_changed')
        local current=self:CaptureCurrent();assert(current and current.class==p.class,'class_changed')
        assert(menu.BP_GameInstance.Character==menu.BP_Menu.CurrentChar,'class_game_instance_changed')
        local change=p.changes[p.index]
        if not change then
            local expected={};for id in p.artifacts:gmatch('[^+]+') do expected[id]=true end
            for id in current.artifacts:gmatch('[^+]+') do assert(expected[id],'artifact_readback_failed');expected[id]=nil end
            assert(not next(expected),'artifact_readback_failed');return true
        end
        local slot=menu.WBP_ArtifactSelector.ArtifactsGrid:GetChildAt(change.index)
        assert(valid(slot) and slot.ArtifactInfo[N.ARTIFACT_ACTOR]:GetFullName()==change.actor,'artifact_context_changed')
        assert(slot['Locked?']==false,'artifact_locked')
        assert(parentMatches(slot,menu.WBP_ArtifactSelector),'artifact_parent_changed')
        if not p.waiting then
            assert(slot['IsSelected?']~=change.target,'artifact_changed')
            local score=menu.WBP_ArtifactSelector.TotalScoreMultiplier
            assert(finite(score),'invalid_artifact_score')
            p.expectedScore=score+(change.target and change.score or -change.score)
            assert(finite(p.expectedScore),'invalid_artifact_score')
            p.waiting=true;p.ticks=0;p.lastSlot=slot;slot:SelectThisArtifact();return nil
        end
        if slot['IsSelected?']==change.target then
            local score=menu.WBP_ArtifactSelector.TotalScoreMultiplier
            assert(finite(score) and math.abs(score-p.expectedScore)<=0.0001,'artifact_score_readback_failed')
            p.index=p.index+1;p.waiting=false;return nil
        end
        p.ticks=p.ticks+1;assert(p.ticks<=120,'artifact_selection_timeout');return nil
    end)
    if not ok then self:CancelSelection();return false,tostring(result):sub(1,600) end
    if result==true then self.pending=nil;return true end
    return result,why
end
function N:CancelSelection()
    local pending=self.pending
    if pending and pending.waiting then
        self.cancelGuard={menu=pending.menu,change=pending.changes[pending.index],slot=pending.lastSlot}
    end
    self.pending=nil
end
-- Canceling publication cannot cancel the engine's latent action. Drain the
-- already issued toggle before allowing another operation on the same menu.
function N:StepCanceled()
    local guard=self.cancelGuard;if not guard then return true end
    local ok,done=pcall(function()
        if guard.slot and not valid(guard.slot) then return true end
        local menu=self:_menu()
        if menu:GetFullName()~=guard.menu then return true end
        local slot=menu.WBP_ArtifactSelector.ArtifactsGrid:GetChildAt(guard.change.index)
        if not valid(slot) or slot.ArtifactInfo[N.ARTIFACT_ACTOR]:GetFullName()~=guard.change.actor then return true end
        return slot['IsSelected?']==guard.change.target
    end)
    if ok and done then self.cancelGuard=nil;return true end
    return nil
end
function N:Diagnostic()
    local catalogue,why=self:Catalogue();if not catalogue then return nil,why end
    local report={menu=catalogue.menu,current=catalogue.current,classes={},artifacts={},pending=self.pending~=nil}
    for _,entry in ipairs(catalogue.classes) do
        report.classes[#report.classes+1]={id=entry.id,character=entry.character,available=entry.available,label=entry.label}
    end
    local ok,err=pcall(function()
        local menu=self:_menu()
        for _,entry in ipairs(catalogue.artifacts) do
            local slot=menu.WBP_ArtifactSelector.ArtifactsGrid:GetChildAt(entry.index)
            report.artifacts[#report.artifacts+1]={id=entry.id,actor=entry.actor,available=entry.available,selected=entry.selected,
                selectFunction=nativeCallable(self.G,slot,'SelectThisArtifact','/Game/UI/WBP_ArtifactsSlot.WBP_ArtifactsSlot_C:SelectThisArtifact')}
        end
    end)
    if not ok then return nil,tostring(err):sub(1,600) end
    return report
end
return N
