local Widgets=require('mm_widgets')
local Ini=require('mm_ini')
local UI={}; UI.__index=UI
local SORT_OPTIONS={{name='Alphabetical',reversible=true},{name='Enabled',reversible=true},
    {name='Installed',reversible=true},{name='Updated',reversible=true},{name='Unsorted',reversible=false}}
local CLICK='/Game/UI/WBP_Button.WBP_Button_C:BndEvt__WBP_Button01_b_button_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature'
local function valid(o) return o and o:IsValid() end
local function providerError(err)
    local ok,text=pcall(tostring,err)
    return 'Settings provider failed: '..(ok and type(text)=='string' and text or 'Unable to describe provider error')
end
local function slotCopy(slot)
    local p=slot.Padding
    return {pad={Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom},h=slot.HorizontalAlignment,
        v=slot.VerticalAlignment,size={SizeRule=slot.Size.SizeRule,Value=slot.Size.Value}}
end
local function slotApply(slot,v)
    slot:SetPadding(v.pad); slot:SetHorizontalAlignment(v.h); slot:SetVerticalAlignment(v.v); slot:SetSize(v.size)
end
function UI.new(G,core,paths,log,restart)
    return setmetatable({G=G,core=core,paths=paths,log=log,restart=type(restart)=='table' and restart or nil,dispatch={},queue={},epoch=0},UI)
end
function UI:message(s)
    local nextStatus=tostring(s or '')
    if self.status==nextStatus and self.statusBox and (nextStatus=='' or valid(self.statusText)) then return end
    self.status=nextStatus
    if self.statusBox then
        self.statusBox:ClearChildren()
        self.statusBox:GetParent():SetVisibility(self.status=='' and 1 or 0)
        self.statusText=nil
        if self.status=='' then return end
        local row=self.w:row(self.statusBox,32,930,true)
        self.statusText=self.w:text(row,self.status,0,0,930,32,12,self.status)
    end
end
function UI:result(ok,err) if not ok then self:message(err); return false end self:message(''); self:refreshNotice(); return true end
function UI:setValue(set,value)
    local ok,result,err=pcall(set,value)
    if not ok then return self:result(nil,providerError(result)) end
    if not result then
        local described,text=pcall(tostring,err or 'Setting change rejected')
        return self:result(nil,described and type(text)=='string' and text or providerError(err))
    end
    return self:result(result,err)
end
function UI:attach(menu)
    self.stage='attach: widget helpers'
    self.menu=menu; self.dispatch={}; self.queue={}
    self.mainMenuLayoutRefused=nil
    self.w=Widgets.new(self.G,menu,self.paths.mod .. '/Assets',self.dispatch)
    self.stage='attach: main-menu Play parent'
    local column=menu.Play:GetParent(); local upgrades=menu.upgrades
    assert(valid(upgrades),'Main menu Upgrades button unavailable')
    self.stage='attach: original button slots'
    local tail,started={},false
    for i=0,column:GetChildrenCount()-1 do
        local child=column:GetChildAt(i)
        if started then tail[#tail+1]={widget=child,slot=slotCopy(child.Slot)} end
        if child:GetFullName()==upgrades:GetFullName() then started=true end
    end
    assert(started,'Upgrades not in main menu column')
    self.stage='attach: button factory'
    local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
    local entry=lib:Create(menu,cls,nil); assert(valid(entry),'Mods entry creation failed')
    self.stage='attach: button label with TextBlock fallback'
    Widgets.buttonText(self.G,entry,'mods')
    self.stage='attach: match Upgrades label font'
    Widgets.font(entry.t_text,upgrades.t_text.Font)
    local entryBox=self.w:create('SizeBox')
    entryBox:SetContent(entry)
    local entrySlot=slotCopy(upgrades.Slot)
    -- Keep every original widget and slot alive until the transaction commits.
    local ok,err=pcall(function()
        slotApply(column:AddChildToVerticalBox(entryBox),entrySlot)
        for _,item in ipairs(tail) do item.widget:RemoveFromParent() end
        for _,item in ipairs(tail) do slotApply(column:AddChildToVerticalBox(item.widget),item.slot) end
    end)
    if not ok then
        -- Generic AddChild is an independent fallback when the typed wrapper fails.
        -- Retry transient reflection failures, retaining the snapshot on failure.
        self.restoreMenu=function()
            local errors={}
            local function attempt(fn)
                local success,problem=pcall(fn)
                if not success then errors[#errors+1]=tostring(problem) end
            end
            attempt(function() entryBox:RemoveFromParent() end)
            for _,item in ipairs(tail) do attempt(function() item.widget:RemoveFromParent() end) end
            -- A failed slot setter must not prevent later buttons being reattached.
            for _,item in ipairs(tail) do
                attempt(function()
                    local parent=item.widget:GetParent()
                    if not valid(parent) or parent:GetFullName()~=column:GetFullName() then
                        local added=pcall(function() column:AddChild(item.widget) end)
                        if not added then column:AddChildToVerticalBox(item.widget) end
                    end
                end)
            end
            for _,item in ipairs(tail) do attempt(function() slotApply(item.widget.Slot,item.slot) end) end
            if #errors>0 then error(table.concat(errors,'; ')) end
        end
        local restored,why
        for _=1,2 do restored,why=pcall(self.restoreMenu); if restored then break end end
        if restored then self.restoreMenu=nil end
        error('Mods insertion canceled: '..tostring(err)..(restored and '; original buttons restored' or '; restoration pending: '..tostring(why)))
    end
    self.entry=entry; self.entryBox=entryBox; self.entryName=entry:GetFullName()
    self.entryStylePending=true
    self.dispatch[self.entryName]=function() self:open() end
    -- D57: when the achievement guard cannot be confirmed the main menu says so; play stays allowed (warn and allow)
    if self.guardNotice then
        self.stage='attach: achievement notice'
        local shown,why=pcall(function()
            self.guardLabel=self.w:text(menu.WidgetTree.RootWidget,self.guardNotice,60,980,1500,60,18)
        end)
        if not shown then self.log('Achievement notice unavailable: '..tostring(why)) end
    end
end
function UI:matchEntryLabel()
    if not self.entryStylePending or self.overlay then return end
    -- Measure after Slate layout, rather than relying on a pre-Construct Font copy.
    -- Constrain the row once. The Blueprint's own layout scales its text to fit;
    -- applying an additional text render scale would shrink it a second time.
    local ok,done=pcall(function()
        local label=self.entry.t_text; local reference=self.menu.upgrades.t_text
        local source=reference:GetDesiredSize(); local target=label:GetDesiredSize()
        local row=self.menu.upgrades:GetDesiredSize()
        local ownRow=self.entry:GetDesiredSize()
        local function positive(n) return type(n)=='number' and n>0 and n<math.huge end
        if not positive(source.Y) or not positive(target.Y) or not positive(row.Y) or not positive(ownRow.Y) then return false end
        self.entryBox:SetHeightOverride(row.Y)
        -- The Blueprint root is a ScaleBox; anchor its scaled content at the
        -- left edge rather than centering the smaller button in the full row.
        self.entry.WidgetTree.RootWidget:GetChildAt(0).Slot:SetHorizontalAlignment(1)
        -- ScaleBox also shrinks the native button's leading padding. Compensate
        -- outside it so the text starts at the same inset as the reference row.
        local referenceInset=self.menu.upgrades.b_button:GetChildAt(0).Slot.Padding.Left
        local ownInset=self.entry.b_button:GetChildAt(0).Slot.Padding.Left
        local inset=math.max(0,referenceInset-ownInset*math.min(1,row.Y/ownRow.Y))
        self.entry.Slot:SetPadding({Left=inset,Top=0,Right=0,Bottom=0})
        label:SetJustification(reference.Justification)
        label.Slot:SetHorizontalAlignment(reference.Slot.HorizontalAlignment)
        label.Slot:SetVerticalAlignment(reference.Slot.VerticalAlignment)
        label.Slot:SetPadding({Left=reference.Slot.Padding.Left,Top=reference.Slot.Padding.Top,
            Right=reference.Slot.Padding.Right,Bottom=reference.Slot.Padding.Bottom})
        pcall(self.log,'Mods row matched Upgrades: row height='..row.Y..'; reference label='..source.Y..'; unscaled Mods label='..target.Y)
        return true
    end)
    if ok and done then self.entryStylePending=nil
    elseif not ok then
        self.entryStylePending=nil
        pcall(self.log,'Mods label sizing unavailable: '..tostring(done)..'; native button remains usable')
    end
end
function UI:close()
    self.log('Menu close trace: entered')
    if self.restart and self.restart.waiting and not self.restart.waiting.quitRequested then self.restart:cancel() end
    if self.restoreMenu then self.log('Menu close trace: before native menu restoration'); self.restoreMenu(); self.restoreMenu=nil end
    self.log('Menu close trace: before overlay removal')
    if valid(self.overlay) then self.overlay:RemoveFromParent() end
    self.log('Menu close trace: before saved visibility restoration')
    for _,s in ipairs(self.saved or {}) do if valid(s.widget) then s.widget:SetVisibility(s.visibility) end end
    self.saved=nil; self.overlay=nil; self.statusText=nil; self.statusBox=nil; self.notice=nil; self.dialog=nil; self.paletteItems=nil; self.info=nil
    self.selected=nil
    self.detailHeader=nil
    self.dispatch={}; if self.w then self.w.dispatch=self.dispatch; self.w.animations={}; self.w.labels={}; self.w.textHosts={}; self.w.autoRows={} end
    if self.entryName then self.dispatch[self.entryName]=function() self:open() end end
    self.epoch=self.epoch+1
    self.log('Menu close trace: completed')
end
function UI:open()
    self.stage='open: menu root'
    if valid(self.overlay) then return end
    local root=self.menu.WidgetTree.RootWidget
    self.saved={}
    for i=0,root:GetChildrenCount()-1 do
        local child=root:GetChildAt(i)
        self.saved[#self.saved+1]={widget=child,visibility=child:GetVisibility()}
    end
    local w=self.w
    -- A centered design surface scales uniformly to the menu's full viewport.
    self.stage='open: ScaleBox construction'
    local scale=w:create('ScaleBox'); scale:SetStretch(2) -- ScaleToFit
    local slot=root:AddChildToCanvas(scale)
    -- Flat-vector anchor setters avoid unsupported nested struct access.
    self.stage='open: minimum anchor'
    slot:SetMinimum({X=0,Y=0})
    self.stage='open: maximum anchor'
    slot:SetMaximum({X=1,Y=1})
    self.stage='open: stretch margins'
    slot:SetOffsets({Left=0,Top=0,Right=0,Bottom=0})
    self.stage='open: stretch alignment'
    slot:SetAlignment({X=0,Y=0}); slot:SetZOrder(1000)
    pcall(self.log,'Overlay anchored to full parent canvas; uniform design scaling')
    self.overlay=scale
    self.stage='open: SizeBox construction'
    local size=w:create('SizeBox'); size:SetWidthOverride(1280); size:SetHeightOverride(720); scale:SetContent(size)
    local page=w:create('CanvasPanel'); size:SetContent(page); self.page=page
    -- Keep the design surface transparent over the existing menu scene.
    self.stage='open: heading'
    local manager=self.core.byId.ModMenu
    local heading=w:text(page,'Mod Menu'..(manager and manager.version and ('  '..manager.version) or ''),170,18,940,52,32)
    heading:SetJustification(1)
    self.stage='open: Back button'
    w:button(page,'Back',1120,18,130,44,function() self:close() end)
    local function toolbar(label,x,width,action)
        local button,content=w:button(page,'',x,84,width,30,action,nil,true,true)
        w:rect(content,'#18242F',0,0,width,30):SetRenderOpacity(0.65)
        w:outline(content,'#84909C',0,0,width,30)
        local text=w:text(content,label,5,4,width-10,22,12); text:SetJustification(1)
        return button,text
    end
    self.sortMode=self.sortMode or 'Alphabetical'
    local sortLabel=w:text(page,'Sort:',30,88,55,22,12)
    sortLabel.WrapTextAt=0; sortLabel.AutoWrapText=false
    local sortContent
    self.sortLayout={x=95,y=84,width=200,height=30,textX=5,textWidth=160,optionHeight=38,gap=8}
    local s=self.sortLayout
    sortContent=w:canvas(page,s.x,s.y,s.width,s.height)
    w:rect(sortContent,'#18242F',0,0,s.width,s.height):SetRenderOpacity(0.65)
    w:outline(sortContent,'#84909C',0,0,s.width,s.height)
    local labelContent
    self.sortButton,labelContent=w:button(sortContent,'',0,0,s.width-30,s.height,function() self:showSort() end,nil,true,true)
    self.sortText=w:text(labelContent,self.sortMode,s.textX,4,s.textWidth,22,12)
    self.sortText:SetJustification(0)
    self.sortText.WrapTextAt=0; self.sortText.AutoWrapText=false
    local arrowContent
    self.sortArrowButton,arrowContent=w:button(sortContent,'',s.width-30,0,30,s.height,function()
        if not self:sortSupportsReverse() then return end
        self.sortDescending=not self.sortDescending
        self:updateSortArrow(); self:renderList()
    end,'Reverse sort order',true,true)
    self.sortArrowDivider=w:rect(sortContent,'#84909C',s.width-30,2,2,s.height-4)
    self.sortArrowDown=w:canvas(sortContent,s.width-24,10,12,9)
    self.sortArrowUp=w:canvas(sortContent,s.width-24,10,12,9)
    for i=0,2 do
        w:rect(self.sortArrowDown,'#FFFFFF',i*2,i*3,12-i*4,3)
        w:rect(self.sortArrowUp,'#FFFFFF',i*2,6-i*3,12-i*4,3)
    end
    self:updateSortArrow()
    self.stage='open: Disable All button'
    toolbar('Disable All',s.x+s.width+10,135,function()
        if self:result(self.core:disableAll()) then self.selected=nil; self:renderList(); self:renderDetail() end
    end)
    self.stage='open: Enable All button'
    toolbar('Enable All',s.x+s.width+155,135,function()
        if self:result(self.core:enableAll()) then self:renderList(); self:renderDetail() end
    end)
    self.stage='open: Restart button'
    self.notice=w:button(page,'Restart Required',1000,670,250,36,function() self:showRestartInstructions() end)
    local infoHeading=w:text(page,'Settings info',612,78,646,42,20)
    infoHeading:SetJustification(1)
    self.stage='open: Refresh button'
    toolbar('Refresh',1130,125,function()
        if self.restart and self.restart.waiting then self:message('Wait for the pending restart before refreshing.'); return end
        local ok,err=self.core:refresh()
        self.selected=nil
        self:renderList(); self:renderDetail(); self:refreshNotice()
        if ok then self:message(err or 'Refresh complete.') else self:result(ok,err) end
    end)
    self.stage='open: mod list scroll'
    local listPanel={x=22,y=132,width=586,height=526,border=2,padding=8}
    self.listLayout={width=listPanel.width-2*listPanel.border,inset=listPanel.padding-listPanel.border}
    self.toggleRightInset=listPanel.width-listPanel.padding-484-59.4
    w:rect(page,'#111722',listPanel.x,listPanel.y,listPanel.width,listPanel.height):SetRenderOpacity(0.35)
    w:rect(page,'#111722',612,132,646,526):SetRenderOpacity(0.35)
    w:outline(page,'#667080',listPanel.x,listPanel.y,listPanel.width,listPanel.height)
    w:outline(page,'#667080',612,132,646,526)
    local nameHeading=w:text(page,'Mod name',30,142,340,28,14)
    nameHeading:SetJustification(1)
    local versionHeading=w:text(page,'Version',372,142,96,28,14)
    versionHeading:SetJustification(1)
    local stateHeading=w:text(page,'On/Off',500,142,100,28,14)
    stateHeading:SetJustification(1)
    w:rect(page,'#667080',30,174,570,2)
    w:rect(page,'#667080',620,174,630,2)
    self.list=w:scroll(page,listPanel.x+listPanel.border,listPanel.y+50,self.listLayout.width,listPanel.height-58)
    self.stage='open: details scroll'
    self.detailHeader=w:canvas(page,620,142,630,30)
    self.detail=w:scroll(page,620,182,630,468)
    self.stage='open: status text'
    self.statusBox=w:scroll(page,30,666,950,44)
    self:message(self.status)
    self.stage='open: render mod list'
    self:renderList(); self.stage='open: render details'; self:renderDetail(); self.stage='open: restart notice'; self:refreshNotice()
    -- Hide every original root child, including charts, only after construction succeeds.
    for _,s in ipairs(self.saved) do s.widget:SetVisibility(1) end
end
function UI:refreshNotice()
    local required,warning=self.core:restartRequired()
    if valid(self.notice) then self.notice:SetVisibility(required and 0 or 1) end
    if warning then self:message(warning)
    elseif self.restartWarning and self.status==self.restartWarning then self:message('') end
    self.restartWarning=warning
end
function UI:clearBox(box)
    -- Drop callbacks/animations belonging to removed children on next full close;
    -- per-panel rebuilds explicitly prune by a captured registration set below.
    box:ClearChildren()
end
function UI:beginPanel(key,box)
    for name in pairs(self[key] or {}) do self.dispatch[name]=nil end
    self[key]={}; self:clearBox(box)
    local animations={}
    for _,a in ipairs(self.w.animations) do if a.panel~=key then animations[#animations+1]=a end end
    self.w.animations=animations
    local count=#animations
    local before={}; for name in pairs(self.dispatch) do before[name]=true end
    return function()
        for name in pairs(self.dispatch) do if not before[name] then self[key][name]=true end end
        for i=count+1,#self.w.animations do self.w.animations[i].panel=key end
    end
end
local function packageState(p)
    local state=''
    if p.error then state=p.dependencyError and 'Dependency blocked' or 'Startup failed' end
    if (p.liveToggle and p.enabled and not p.active) or (not p.liveToggle and p.enabled~=p.startEnabled) then state=state~='' and (state..' • restart required') or (p.liveToggle and 'Refresh to activate' or 'Restart required') end
    return state
end
function UI:renderList()
    local done=self:beginPanel('listCallbacks',self.list); local w=self.w
    local index=0
    for _,p in ipairs(self:sortedMods()) do
        if p.id~='ModMenu' then
        index=index+1
        local state=packageState(p)
        local layout=self.listLayout
        local height=state=='' and 60 or 80
        local frame=w:row(self.list,height,layout.width)
        local rowTint=w:rect(frame,index%2==1 and '#A9C7E0' or '#E0CCAA',0,0,layout.width,height)
        rowTint:SetRenderOpacity(0.18)
        local row=w:canvas(frame,layout.inset,0,layout.width-2*layout.inset,height)
        w:text(row,p.name,0,12,340,32,14,p.name)
        local versionText=w:text(row,p.version or '?',350,12,80,32,14,'Version: '..(p.version or 'Unknown version'))
        versionText:SetJustification(1)
        local stateText=w:text(row,state,0,48,530,26,12,p.dependencyError or p.error)
        stateText:SetVisibility(state=='' and 1 or 3)
        if self.core.providers[p.id] and (not p.liveToggle or p.enabled) then
            -- Draw in the row's coordinates, outside native Button content
            -- alignment, so the icon and its hit target share exact bounds.
            w:button(row,'',440,12,23,23,function() self.selected=p.id; self:renderDetail() end,'Settings',true,true)
            w:image(row,'cog.png',440,12,23,23):SetColorAndOpacity(Widgets.color('#AEB4BE'))
        end
        if not p.locked and not p.managed then
            w:text(row,'Unmanaged',470,13,80,26,12,p.reason):SetJustification(2)
        else
        local toggle=w:toggle(row,484,12,p.enabled,function(on)
            local ok=self:result(self.core:setEnabled(p.id,on))
            if ok then
                stateText:SetText(self.G.FText(packageState(p)))
                local status=packageState(p)
                stateText:SetVisibility(status=='' and 1 or 3)
                local height=status=='' and 60 or 80
                frame:GetParent():SetHeightOverride(height)
                row.Slot:SetSize({X=layout.width-2*layout.inset,Y=height})
                rowTint.Slot:SetSize({X=layout.width,Y=height})
                if self.sortMode and self.sortMode~='Alphabetical' then self:renderList() end
                if p.liveToggle then self:renderList(); if self.selected==p.id then self:renderDetail() end end
            end
            return ok
        end,p.locked)
        w.animations[#w.animations].packageId=p.id
        if not p.locked and not p.managed then toggle:SetIsEnabled(false); toggle:SetToolTipText(self.G.FText(p.reason or 'External loader')) end
        end
        end
    end
    done()
end
function UI:sortedMods()
    local view={}
    for _,p in ipairs(self.core.mods) do
        if not p.internalService then view[#view+1]=p end
    end
    local mode=self.sortMode or 'Alphabetical'
    if mode=='Unsorted' then
        local rank,section,nextRank={},'',0
        for _,line in ipairs(Ini.lines(self.core.text or '')) do
            local header=Ini.header(line)
            if header then section=header:lower()
            elseif section=='mods' then
                local id=line:match('^%s*([%w_%-%.]+)%s*=')
                if id and not rank[id:lower()] then nextRank=nextRank+1; rank[id:lower()]=nextRank end
            end
        end
        local discovery={}; for i,p in ipairs(view) do discovery[p]=i end
        table.sort(view,function(a,b)
            local ar,br=rank[a.id:lower()],rank[b.id:lower()]
            if ar and br then return ar<br end
            if ar then return true end
            if br then return false end
            return discovery[a]<discovery[b]
        end)
        return view
    end
    local function group(p)
        if mode=='Enabled' then
            if p.enabled==nil then return 2 end
            local first=not self.sortDescending
            return p.enabled==first and 0 or 1
        end
        return 0
    end
    table.sort(view,function(a,b)
        if mode=='Installed' or mode=='Updated' then
            local field=mode=='Installed' and 'installedDate' or 'updatedDate'
            local ad,bd=a[field],b[field]
            local av,bv=Ini.date(ad),Ini.date(bd)
            if av~=bv then return av end
            if av and ad~=bd then
                if self.sortDescending then return ad>bd end
                return ad<bd
            end
        end
        local x,y=group(a),group(b)
        if x~=y then return x<y end
        local an,bn=(a.name or a.id):lower(),(b.name or b.id):lower()
        local descending=mode=='Alphabetical' and self.sortDescending
        if an~=bn then if descending then return an>bn end; return an<bn end
        if descending then return a.id>b.id end
        return a.id<b.id
    end)
    return view
end
function UI:sortSupportsReverse()
    for _,option in ipairs(SORT_OPTIONS) do
        if option.name==self.sortMode then return option.reversible==true end
    end
    return false
end
function UI:updateSortArrow()
    local supported=self:sortSupportsReverse()
    local labelWidth=supported and self.sortLayout.width-30 or self.sortLayout.width
    self.sortButton.Slot:SetSize({X=labelWidth,Y=self.sortLayout.height})
    self.sortText.Slot:SetSize({X=labelWidth-10,Y=22})
    self.sortArrowButton:SetVisibility(supported and 0 or 1)
    self.sortArrowDivider:SetVisibility(supported and 3 or 1)
    self.sortArrowDown:SetVisibility(supported and not self.sortDescending and 3 or 1)
    self.sortArrowUp:SetVisibility(supported and self.sortDescending and 3 or 1)
end
function UI:showSort()
    if self.dialog then return end
    local s=self.sortLayout
    local dropdownWidth=self:sortSupportsReverse() and s.width-30 or s.width
    self.dialogPrior={}; for name in pairs(self.dispatch) do self.dialogPrior[name]=true end
    self.dialogCallbacks={}
    local d=self.w:canvas(self.page,0,0,1280,720); self.dialog=d
    self.w:button(d,'',0,0,1280,720,function() self:closeDialog() end,nil,true,true)
    for i,option in ipairs(SORT_OPTIONS) do
        local mode=option.name
        local row=self.w:canvas(d,s.x,s.y+s.height+s.gap+(i-1)*s.optionHeight,dropdownWidth,s.optionHeight)
        self.w:rect(row,'#111722',0,0,dropdownWidth,s.optionHeight)
        self.w:outline(row,'#84909C',0,0,dropdownWidth,s.optionHeight)
        local _,content=self.w:button(row,'',0,0,dropdownWidth,s.optionHeight,function()
            if self.sortMode==mode then return end
            self:closeDialog()
            if self.sortMode~=mode then self.sortDescending=false end
            self.sortMode=mode
            self.sortText:SetText(self.G.FText(mode))
            self:updateSortArrow()
            self:renderList()
        end,nil,self.sortMode~=mode,true)
        local option=self.w:text(content,mode,s.textX,7,dropdownWidth-2*s.textX,26,12)
        if self.sortMode==mode then option:SetRenderOpacity(0.5) end
        option:SetJustification(0)
        option.WrapTextAt=0; option.AutoWrapText=false
    end
    self:sealDialog()
end
-- This API is supplied to mod-owned build/buildInfo callbacks. The framework knows no mod settings.
function UI:providerUI(readonly)
    local host=self; local w=self.w; local api={}
    local rightEdge=630-(host.toggleRightInset or 0)
    function api.label(parent,text) local r=w:row(parent,40,590,true); w:text(r,text,0,2,590,32,14); return r end
    function api.boolean(parent,label,value,set,warning,tooltip)
        assert(type(value)=='boolean','Expected boolean control value')
        assert(readonly or type(set)=='function','Expected boolean setter')
        local toggleX=rightEdge-59.4
        local r=w:row(parent,48,630); w:text(r,label,0,10,toggleX-55,36,14)
        if readonly then w:text(r,value and 'ON' or 'OFF',toggleX,10,59.4,36,14)
        else local toggle=w:toggle(r,toggleX,12,value,function(on)
            if host:setValue(set,on) then host:renderInfo(); return true end return false
        end,false)
        end
        if warning then w:text(r,'⚠',toggleX-40,10,30,36,20,warning) end
    end
    function api.number(parent,label,value,min,max,step,set,warning)
        local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
        assert(finite(value) and finite(min) and finite(max) and finite(step),'Expected finite numeric control values')
        assert(min<=max and step>0,'Expected ordered number bounds and positive step')
        assert(readonly or type(set)=='function','Expected number setter')
        local r=w:row(parent,54,590); w:text(r,label,0,10,390,36,14)
        w:text(r,value,460,10,40,36,14)
        if warning then w:text(r,'⚠',390,10,25,36,20,warning) end
        if not readonly then
            local function change(v) if host:setValue(set,v) then host:renderDetail() end end
            w:button(r,'−',420,4,35,42,function() change(math.max(min,value-step)) end,nil,value>min)
            w:button(r,'+',505,4,45,42,function() change(math.min(max,value+step)) end,nil,value<max)
        end
    end
    function api.swatches(parent,controls)
        assert(type(controls)=='table','Expected swatch controls array')
        local count,max=0,0
        for key in next,controls do
            assert(type(key)=='number' and key>=1 and key%1==0,'Expected swatch controls array')
            count=count+1; max=math.max(max,key)
        end
        assert(count==max,'Expected dense swatch controls array')
        -- Four content-sized cells per line, 10 px gaps, always left aligned.
        local rows={}
        for i,control in ipairs(controls) do
            local line=math.floor((i-1)/4)+1
            if not rows[line] then rows[line]=w:row(parent,100,math.min(4,#controls-(line-1)*4)*85-10) end
            local row=rows[line]; local x=((i-1)%4)*85
            w:text(row,control.label,x,0,75,30,14)
            if readonly then w:rect(row,control.value,x,36,32,32)
            else
                local _,c=w:button(row,'',x,32,70,46,function() host:palette(control) end,nil,true,true)
                w:rect(c,control.value,5,7,32,32); w:text(c,'▾',45,7,20,30,20)
            end
        end
    end
    function api.colors(parent,control)
        local options,current,settings=host:paletteData(control)
        if not options then return end
        local row=w:row(parent,48,630)
        w:text(row,settings.label,0,10,145,28,14)
        local gap=6
        local width=math.min(48,(rightEdge-155-(#options-1)*gap)/#options)
        local start=rightEdge-(#options*width+(#options-1)*gap)
        for i,option in ipairs(options) do
            local x=start+(i-1)*(width+gap)
            local button,content=w:button(row,'',x,8,width,32,function()
                if host:setValue(settings.set,option.color) then host:renderDetail() end
            end,option.color,option.available or option.color==current,true)
            w:rect(content,option.color,3,3,width-6,26)
            w:outline(content,option.color:upper()==current:upper() and '#FFFFFF' or '#667080',0,0,width,32)
        end
    end
    function api.slider(parent,label,value,min,max,step,set,tooltip,suffix,defaultValue)
        assert(type(value)=='number' and value==value and min<=value and value<=max and step>0,'Invalid slider range/value')
        suffix=suffix==nil and '%' or suffix
        local row=w:row(parent,48,630)
        w:text(row,label,0,10,210,28,14,tooltip)
        local valueX=rightEdge-55
        local valueLabel=w:text(row,tostring(value)..suffix,valueX,10,55,28,14)
        valueLabel:SetJustification(2)
        if readonly then return end
        assert(type(set)=='function','Expected slider setter')
        local slider=w:create('Slider')
        slider.WidgetStyle.BarThickness=2
        slider:SetMinValue(0); slider:SetMaxValue(1); slider:SetStepSize(step/(max-min)); slider:SetValue((value-min)/(max-min))
        slider.MouseUsesStep=false
        local centerY=21
        local sliderWidth=valueX-10-220
        local trackStart,trackWidth=227,sliderWidth-16
        w:place(row,slider,220,centerY-16,sliderWidth,32)
        -- Keep the native drag target above the passive tick hover areas.
        slider.Slot:SetZOrder(1)
        local intervals=math.floor((max-min)/step)
        local tickTargets={}
        for i=0,intervals do
            local tickValue=min+i*step
            local isDefault=tickValue==defaultValue
            local tick=w:rect(row,isDefault and '#FFFFFF' or '#AEB4BE',trackStart+i*trackWidth/intervals,centerY-(isDefault and 5 or 3),isDefault and 3 or 2,isDefault and 10 or 6)
            tick:SetVisibility(0)
            local spacing=trackWidth/intervals
            local left=trackStart+math.max(0,i-.5)*spacing
            local right=trackStart+math.min(intervals,i+.5)*spacing
            local hit=w:text(row,' ',left,10,right-left,38,1)
            hit:SetVisibility(0)
            tickTargets[#tickTargets+1]={mark=tick,hit=hit,value=tickValue}
        end
        local preview=w:canvas(row,220,-12,100,24)
        preview.Slot:SetZOrder(2)
        w:rect(preview,'#000000',0,0,100,24)
        w:rect(preview,'#FFFFFF',1,1,98,22)
        local previewText=w:create('TextBlock')
        previewText.Font.Size=9
        previewText:SetText(w.G.FText(tostring(value)..suffix))
        previewText:SetVisibility(3)
        local previewColor=previewText.ColorAndOpacity.SpecifiedColor
        previewColor.R=0; previewColor.G=0; previewColor.B=0; previewColor.A=1
        previewText:SetOpacity(1)
        w:place(preview,previewText,5,2,90,20)
        preview:SetVisibility(1)
        host.sliders=host.sliders or {}
        host.sliders[#host.sliders+1]={widget=slider,value=value,pending=value,quiet=0,set=set,min=min,max=max,step=step,normalized=true,suffix=suffix,defaultValue=defaultValue,valueLabel=valueLabel,preview=preview,previewText=previewText,tickTargets=tickTargets,trackLeft=host.detail:GetParent().Slot:GetPosition().X+trackStart,trackStart=trackStart,trackWidth=trackWidth}
    end
    -- Mod-owned custom widgets can use primitives within their allocated detail panel.
    api.widgets=w
    return api
end
function UI:renderInfo()
    if not self.info then return end
    local done=self:beginPanel('infoCallbacks',self.info)
    local provider=self.core.providers[self.selected]
    local ok=self:callProvider(provider,'buildInfo',self:providerUI(true),self.info,true)
    done()
    if not ok then self:beginPanel('infoCallbacks',self.info)() end
    self:protectControls('infoCallbacks')
    self:refreshNotice()
end
-- Lookup is provider code too (tables may have __index). Build results are
-- intentionally ignored: providers render through the supplied UI API.
function UI:callProvider(provider,method,api,box,optional)
    local ok,err=pcall(function()
        if not provider and optional then return end
        assert(type(provider)=='table','Expected settings provider')
        local fn=provider[method]
        if fn==nil and optional then return end
        assert(type(fn)=='function','Expected '..method..' callback')
        fn(api,box)
    end)
    if not ok then self:message(providerError(err)) end
    return ok
end
function UI:protectControls(key)
    for name in pairs(self[key] or {}) do
        local action=self.dispatch[name]
        self.dispatch[name]=function(...)
            local results=table.pack(pcall(action,...))
            if not results[1] then self:message(providerError(results[2])); return nil end
            return table.unpack(results,2,results.n)
        end
    end
end
function UI:renderDetail()
    self.sliders={}
    if self.detailHeader then self.detailHeader:ClearChildren() end
    if self.info then self:beginPanel('infoCallbacks',self.info)() end
    local done=self:beginPanel('detailCallbacks',self.detail)
    local provider=self.core.providers[self.selected]; self.info=nil
    local selected=self.core.byId[self.selected]
    if selected and selected.liveToggle and selected.enabled==false then
        self.selected=nil; provider=nil
    end
    if not provider then done(); return end
    self.core.dirtyProviders[self.selected]=nil
    self.w:text(self.detailHeader,selected.name,0,0,630,28,14)
    local ok=self:callProvider(provider,'build',self:providerUI(false),self.detail,false)
    done()
    if not ok then self:beginPanel('detailCallbacks',self.detail)() end
    self:protectControls('detailCallbacks')
    self.info=self.w:create('VerticalBox'); self.detail:AddChildToVerticalBox(self.info)
    self:renderInfo()
end
function UI:modal(title)
    if valid(self.dialog) then self:closeDialog() end
    self.dialogCallbacks={}; self.dialogPrior={}
    for name in pairs(self.dispatch) do self.dialogPrior[name]=true end
    local d=self.w:canvas(self.page,0,0,1280,720); self.dialog=d
    -- A native button backdrop consumes clicks outside the dialog.
    local _,back=self.w:button(d,'',0,0,1280,720,function() end,nil,true,true)
    self.w:rect(back,'#10141E',0,0,1280,720)
    self.w:text(d,title,300,210,700,80,26)
    return d
end
function UI:sealDialog()
    for name in pairs(self.dispatch) do if not self.dialogPrior[name] then self.dialogCallbacks[name]=true end end
end
function UI:closeDialog()
    if valid(self.dialog) then self.dialog:RemoveFromParent() end
    for name in pairs(self.dialogCallbacks or {}) do self.dispatch[name]=nil end
    self.dialog=nil; self.dialogCallbacks=nil; self.paletteItems=nil; self.paletteProvider=nil
end
function UI:showRestartInstructions()
    local required,warning=self.core:restartRequired()
    if not required then if warning then self:message(warning) end return end
    local d=self:modal('Restart the game to apply your saved mod choices.')
    self.w:button(d,'Close',430,350,180,55,function()
        if self.restart then self.restart:cancel() end
        self:closeDialog()
    end)
    self.restartButton=self.w:button(d,'Restart',650,350,180,55,function()
        if not self.restart then self:message('Restart helper unavailable; exit and relaunch manually.'); return end
        if self.restart.waiting then return end
        local saved,why=self.core:save()
        if not saved then self:message(why); return end
        local ok,message=self.restart:request()
        if ok then self.restartButton:SetIsEnabled(false) end
        self:message(message)
    end,nil,self.restart~=nil)
    self:sealDialog()
end
-- Provider callbacks and data access share one error boundary. Copy validated
-- choices so provider-owned tables/metamethods never escape into rendering.
function UI:paletteData(control)
    local ok,options,current,settings=pcall(function()
        assert(type(control)=='table','Expected a swatch control table')
        assert(type(control.options)=='function','Swatch options must be a function')
        assert(type(control.set)=='function','Swatch setter must be a function')
        assert(type(control.label)=='string','Swatch label must be a string')
        local label,set=control.label,control.set
        local selected=control.value
        if control.current~=nil then
            assert(type(control.current)=='function','Swatch current must be a function')
            selected=control.current()
        end
        local function color(value)
            return type(value)=='string' and value:match('^#%x%x%x%x%x%x$')
        end
        assert(color(selected),'Swatch selection must be #RRGGBB')
        local supplied=control.options() -- Mod owns reservation/availability rules.
        assert(type(supplied)=='table','Swatch options must return an array')
        local count,max=0,0
        for key in next,supplied do
            assert(type(key)=='number' and key>=1 and key%1==0,'Swatch options must be an array')
            count=count+1; max=math.max(max,key)
        end
        assert(count==max,'Swatch options must not contain gaps')
        local choices,seen={},{}
        for i=1,count do
            local option=rawget(supplied,i)
            assert(type(option)=='table','Swatch option must be a table')
            local value,available=option.color,option.available
            assert(color(value),'Swatch color must be #RRGGBB')
            assert(available==nil or type(available)=='boolean','Swatch availability must be boolean')
            local key=value:upper()
            assert(not seen[key],'Duplicate swatch color'); seen[key]=true
            choices[i]={color=value,available=available~=false}
        end
        return choices,selected,{label=label,set=set}
    end)
    if not ok then
        if self.dialog then self:sealDialog(); self:closeDialog() end
        self:message('Settings provider failed: '..tostring(options))
        return nil
    end
    return options,current,settings
end
function UI:palette(control)
    local options,current,settings=self:paletteData(control)
    if not options then return end
    local d=self:modal(settings.label)
    self.paletteItems={}; self.paletteProvider=control
    for i,option in ipairs(options) do
        local x=390+((i-1)%4)*85; local y=300+math.floor((i-1)/4)*62
        local available=option.available or option.color==current
        local button,c=self.w:button(d,'',x,y,65,48,function()
            -- Provider MUST validate again; availability can change while the popup is open.
            if self:setValue(settings.set,option.color) then self:closeDialog(); self:renderDetail()
            else self:closeDialog(); self:palette(control) end
        end,nil,available,true)
        local swatch=self.w:rect(c,available and option.color or '#757575',4,4,57,40)
        self.paletteItems[option.color]={button=button,swatch=swatch}
    end
    self.w:button(d,'Close',800,580,160,48,function() self:closeDialog() end); self:sealDialog()
end
function UI:cleanupGameMenuStyles()
    for id,item in pairs(self.gameMenuStyles or {}) do self.gameMenuStyles[id]=nil;pcall(item.cleanup) end
end
function UI:tickGameMenuStyles()
    for id,item in pairs(self.gameMenuStyles or {}) do
        local ok,err=pcall(item.tick)
        if not ok then
            self.gameMenuStyles[id]=nil;pcall(item.cleanup)
            pcall(self.log,id..': game menu style failed: '..tostring(err))
        end
    end
end
function UI:tick()
    -- Esc styling must keep ticking while the main-menu widget is absent.
    self:tickGameMenuStyles()
    self.stage='tick: current menu validity'
    if not valid(self.menu) or not self.menu:IsInViewport() then
        if self.menu then
            if self.mainMenuLayout then
                local restored,err=pcall(self.mainMenuLayout.Restore,self.mainMenuLayout)
                if not restored then pcall(self.log,'Main-menu layout restoration pending: '..tostring(err));return end
                self.mainMenuLayout=nil
            end
            self:close()
            if valid(self.entryBox) then self.entryBox:RemoveFromParent() end
            self.entry=nil; self.entryBox=nil; self.entryName=nil; self.menu=nil; self.lastTime=nil
        end
        self.stage='tick: main-menu discovery'
        for _,m in ipairs(self.G.FindAllOf('WBP_MainMenu_C') or {}) do
            self.stage='tick: discovered menu viewport'
            if valid(m) and m:IsInViewport() then self:attach(m); self.stage='attach: click hook'; self:hook(); break end
        end
        return
    end
    self:matchEntryLabel()
    for id,style in pairs(self.menuStyles or {}) do
        local ok,err=pcall(style,self.menu,self.entry)
        if not ok then
            self.menuStyles[id]=nil
            self.log(id..': main menu style failed: '..tostring(err))
        end
    end
    -- Layout follows optional style providers so slot spacing has one owner.
    -- Mod Menu alone moves nothing: without a style hook the natives stay vanilla,
    -- and losing the last hook restores them (a later hook binds afresh).
    local hooked=next(self.menuStyles or {})~=nil
    if not hooked then
        if self.mainMenuLayout then
            local restored,err=pcall(self.mainMenuLayout.Restore,self.mainMenuLayout)
            if restored then self.mainMenuLayout=nil;self.mainMenuLayoutStamp=nil
            else pcall(self.log,'Main-menu layout restoration pending: '..tostring(err)) end
        end
    -- Missing native hierarchy fails before moving controls; retry on a new menu.
    elseif not self.mainMenuLayout and not self.mainMenuLayoutRefused then
        local ok,layout,why,retained=pcall(require('mm_main_menu_layout').Bind,self.G,self.w,self.menu)
        if ok and layout then self.mainMenuLayout=layout
        elseif ok and retained then self.mainMenuLayout=retained
        else
            local reason=tostring(ok and why or layout)
            if not reason:find('Awaiting native',1,true)then self.mainMenuLayoutRefused=true;pcall(self.log,'Shared main-menu layout unavailable: '..reason)end
        end
    end
    if hooked and self.mainMenuLayout then
        local ok,why=pcall(self.mainMenuLayout.Tick,self.mainMenuLayout)
        if not ok then
            pcall(self.log,'Shared main-menu layout failed: '..tostring(why))
            local restored=pcall(self.mainMenuLayout.Restore,self.mainMenuLayout)
            if restored then self.mainMenuLayout=nil;self.mainMenuLayoutRefused=true end
        elseif why and self.mainMenuLayout.plan then
            local p=self.mainMenuLayout.plan
            local stamp=p.rootWidth..':'..p.rootHeight..':'..p.scaleX..':'..p.scaleY..':'..tostring(p.scroll)
            if stamp~=self.mainMenuLayoutStamp then
                self.mainMenuLayoutStamp=stamp
                pcall(self.log,'Shared menu layout: root='..p.rootWidth..'x'..p.rootHeight..'; scale='..p.scaleX..','..p.scaleY..'; physicalGap='..p.gap*p.scaleY..'; scrolling='..tostring(p.scroll)..'; footerY='..p.footerY..'; menuBottom='..(p.menuTop+p.menuHeight))
            end
        end
    end
    -- Parent stretch anchors follow layout/resolution changes automatically.
    -- Animation timing is optional; reflection failure must not block queued clicks.
    local timed,clock=pcall(function()
        return self.G.StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(self.menu)
    end)
    local dt=0
    if timed and type(clock)=='number' and clock==clock and math.abs(clock)<math.huge then
        dt=self.lastTime and math.max(0,clock-self.lastTime) or 0
        self.lastTime=clock; self.clockUnavailable=nil
    else
        self.lastTime=nil
        if not self.clockUnavailable then
            self.clockUnavailable=true
            pcall(self.log,'Animation clock unavailable; animations paused, menu input remains active')
        end
    end
    self.stage='tick: animations'
    self.w:tick(dt)
    self.w:observeLabels(self.log)
    if self.restart and self.restart.waiting then
        self.stage='tick: restart handshake'
        self:message(self.restart:tick(self.menu))
        if not self.restart.waiting and valid(self.restartButton) then self.restartButton:SetIsEnabled(true) end
    end
    if self.paletteItems then
        local control=self.paletteProvider
        local options,current=self:paletteData(control)
        if options then
            local available={}
            for _,o in ipairs(options) do available[o.color]=o.available or o.color==current end
            for color,item in pairs(self.paletteItems) do
                item.button:SetIsEnabled(available[color]==true)
                item.swatch:SetBrushColor(Widgets.color(available[color] and color or '#757575'))
            end
        end
    end
    local queue=self.queue; self.queue={}
    local back=self.backEpoch; self.backEpoch=nil
    local allowModMenu=self.backAllowsModMenu;self.backAllowsModMenu=nil
    local requested=self.backNavigation;self.backNavigation=nil
    if back==self.epoch then
        local ids={};for id in pairs(self.menuBackHandlers or {}) do ids[#ids+1]=id end
        table.sort(ids,function(a,b)
            local x,y=self.menuBackHandlers[a],self.menuBackHandlers[b]
            local xp,yp=type(x)=='table' and x.priority or 0,type(y)=='table' and y.priority or 0
            if xp~=yp then return xp>yp end
            local xs,ys=type(x)=='table' and x.serial or 0,type(y)=='table' and y.serial or 0
            if xs~=ys then return xs>ys end;return a<b
        end)
        for _,id in ipairs(ids) do
            local item=self.menuBackHandlers[id]
            local state=self.core:query(type(item)=='table' and item.owner or id)
            if state.enabled==true and state.active==true then
                if type(item)=='table' then
                    local ok,visible=pcall(item.isVisible)
                    if ok and visible==true then
                        local pin=requested and requested[id]
                        if not pin or pin.item~=item or pin.generation~=item.generation then return end
                        if item.canBack then local allowed,value=pcall(item.canBack);if not allowed or value~=true then return end end
                        pcall(item.back);return
                    end
                else
                    local pin=requested and requested[id]
                    if pin and pin.item==item then local ok,consumed=pcall(item);if ok and consumed==true then return end end
                end
            end
        end
    end
    if back==self.epoch and allowModMenu~=false and valid(self.overlay) then
        self.log('Escape trace: game-thread back request consumed; dialog='..tostring(self.dialog~=nil))
        if self.dialog then
            if self.restart and self.restart.waiting then
                if self.restart.waiting.quitRequested then return end
                self.restart:cancel()
            end
            self:closeDialog()
        else self:close() end
        return
    end
    for _,event in ipairs(queue) do
        local action=self.dispatch[event.name]
        if action and event.epoch==self.epoch and (not self.dialog or self.dialogCallbacks[event.name]) then self.stage='tick: queued button action'; action() end
    end
    if self.overlay then
        if not self.dialog then self:pollSliders() end
        if not self.dialog and self.core.dirtyProviders[self.selected] then self:renderDetail() end
        self:refreshNotice()
    end
end
function UI:sliderPointerValue(item)
    local ok,value=pcall(function()
        local layout=self.G.StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
        local viewport=layout:GetViewportSize(self.menu)
        local dpi=layout:GetViewportScale(self.menu)
        local mouse=layout:GetMousePositionOnViewport(self.menu)
        local scale=math.min(viewport.X/1280,viewport.Y/720)
        assert(scale>0 and dpi>0,'Invalid viewport scale')
        local x=(mouse.X*dpi-(viewport.X-1280*scale)/2)/scale
        local position=math.max(0,math.min(1,(x-item.trackLeft)/item.trackWidth))
        return math.max(item.min,math.min(item.max,item.min+math.floor(position*(item.max-item.min)/item.step+.5)*item.step))
    end)
    if ok then return value end
    if not self.sliderPointerError then
        self.sliderPointerError=true
        pcall(self.log,'Slider pointer observation unavailable: '..tostring(value))
    end
end
function UI:pollSliders()
    for _,item in ipairs(self.sliders or {}) do
        if valid(item.widget) then
            local value=item.widget:GetValue()
            if type(value)=='number' and value==value then
                local captured=item.widget:HasMouseCapture()
                if item.normalized then value=item.min+value*(item.max-item.min) end
                value=math.max(item.min,math.min(item.max,item.min+math.floor((value-item.min)/item.step+.5)*item.step))
                if item.tooltipValue~=value then
                    if item.valueLabel then item.valueLabel:SetText(self.G.FText(tostring(value)..(item.suffix or '%'))) end
                    item.tooltipValue=value
                end
                if item.preview then
                    local shown=captured and value or nil
                    if not captured then
                        for _,tick in ipairs(item.tickTargets or {}) do
                            if tick.mark:IsHovered() or tick.hit:IsHovered() then shown=tick.value; break end
                        end
                        -- Keep the preview visible across gaps between ticks.
                        -- The native slider remains the click/drag target.
                        if not shown and item.widget:IsHovered() then shown=self:sliderPointerValue(item) end
                    end
                    if shown then item.hoverPreviewValue=shown else item.hoverPreviewValue=nil end
                    item.preview:SetVisibility(shown and 3 or 1)
                    if shown then
                        item.previewText:SetText(self.G.FText(tostring(shown)..(item.suffix or '%')..(shown==item.defaultValue and ' (Default)' or '')))
                        local position=captured and item.widget:GetValue() or (shown-item.min)/(item.max-item.min)
                        item.preview.Slot:SetPosition({X=(item.trackStart or 227)+(item.trackWidth or 324)*position-50,Y=-12})
                    end
                end
                local snapped=item.normalized and (value-item.min)/(item.max-item.min) or value
                if captured then item.pending=value; item.quiet=0
                else
                if math.abs(item.widget:GetValue()-snapped)>.00001 then item.widget:SetValue(snapped) end
                if value~=item.pending then item.pending=value; item.quiet=0
                elseif value~=item.value then
                    item.quiet=item.quiet+1
                    if item.quiet>=6 then
                        if self:setValue(item.set,value) then item.value=value
                        else item.widget:SetValue(item.normalized and (item.value-item.min)/(item.max-item.min) or item.value); item.pending=item.value end
                        item.quiet=0
                    end
                end
                end
            end
        end
    end
end
function UI:hook()
    if self.hooked then return end
    self.G.RegisterHook(CLICK,function(ctx)
        local name=ctx:get():GetFullName()
        pcall(self.log,'Button click: '..name..' | Mod_Menu handler='..tostring(self.dispatch[name]~=nil))
        if self.dispatch[name] then self.queue[#self.queue+1]={name=name,epoch=self.epoch} end
    end)
    self.hooked=true
end
-- Optional packages request navigation; the manager owns widget restoration.
function UI:requestBack(allowModMenu)
    self.backEpoch=self.epoch;self.backAllowsModMenu=allowModMenu~=false;self.backNavigation={}
    for id,item in pairs(self.menuBackHandlers or {}) do
        local visible=true
        if type(item)=='table' then local ok,value=pcall(item.isVisible);visible=ok and value==true end
        if visible then self.backNavigation[id]={item=item,generation=type(item)=='table' and item.generation or 0} end
    end
end
function UI:start()
    local function step()
        local ok,err=xpcall(function() self:tick() end,function(problem)
            local described,text=pcall(tostring,problem)
            return debug.traceback(described and text or 'Unprintable UI error',2)
        end)
        if not ok then
            self.log('UI error ['..tostring(self.stage or 'unknown stage')..'; widget: '..tostring(self.w and self.w.stage or 'none')..']: '..tostring(err))
            pcall(function() self:close() end)
            self:cleanupGameMenuStyles()
            self.failed=true
        end
    end
    if type(self.G.LoopInGameThreadWithDelay)=='function' and type(self.G.CancelDelayedAction)=='function' then
        local handle
        handle=self.G.LoopInGameThreadWithDelay(16,function()
            if not self.failed then step() end
            if self.failed then self.G.CancelDelayedAction(handle) end
        end)
        self.log('UI updates use game-thread timer')
    else
        self.G.LoopAsync(16,function()
            if not self.pending then
                self.pending=true
                self.G.ExecuteInGameThread(function() step();self.pending=false end)
            end
            return self.failed==true
        end)
    end
end
return UI
