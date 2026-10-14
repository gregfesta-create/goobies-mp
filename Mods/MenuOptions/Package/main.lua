-- Optional navigation settings; no gameplay, native loading or Steam changes.
local ctx=...
local Ini=require('mm_ini')
assert(type(ctx.requestMenuBack)=='function','Mod_Menu navigation API unavailable')
local text,err=ctx.readConfig()
assert(not err or err=='missing',err)
local value=(Ini.read(text or '').Settings or {}).EscapeClosesModMenu
local enabled=value~='false'
local growOnHover=(Ini.read(text or '').Settings or {}).GrowOnHover~='false'
local hoverGlow=(Ini.read(text or '').Settings or {}).HoverGlow=='true'
local opacity=tonumber((Ini.read(text or '').Settings or {}).MainMenuTextOpacity) or 50
if opacity~=opacity or opacity<10 or opacity>100 or opacity%10~=0 then opacity=50 end
local colors={'#FFFFFF','#AEB4BE','#FF0000','#FF9800','#FFEB3B','#66BB6A','#42A5F5','#AB47BC'}
local color=(Ini.read(text or '').Settings or {}).MainMenuTextColor or '#FFFFFF'
if not color:match('^#%x%x%x%x%x%x$') then color='#FFFFFF'; ctx.log('Invalid MainMenuTextColor; using white') end
if color:upper()=='#EF5350' then
    color='#FF0000'
    local nextText=Ini.set(text or '[Settings]\n','Settings','MainMenuTextColor',color)
    local called,saved,why=pcall(ctx.writeConfig,nextText)
    if called and saved then text=nextText else ctx.log('Red preset migration could not be saved: '..tostring(called and why or saved):sub(1,200)) end
end
local originals={}
local measuredMenu,hoverFactor,secondarySize,playSize,rowHeight
local settings=Ini.read(text or '').Settings or {}
local legacy=tonumber(settings.MainMenuFontScale) or 50
local fontPercent=tonumber(settings.MainMenuFontSize) or (legacy<=50 and 30*legacy/50 or 30+30*(legacy-50)/50)
fontPercent=math.max(30,math.min(60,5*math.floor(fontPercent/5+.5)))
if type(ctx.registerGameMenuStyle)=='function' then
    local ok,why=pcall(function()
        local source=debug.getinfo(1,'S').source
        local folder=ctx.packagePath and (ctx.packagePath..'/Package') or source:match('^@(.*)[/\\][^/\\]*$')
        assert(folder,'Menu Options package path unavailable')
        local Esc=assert(loadfile(folder..'/esc_style.lua','t',_ENV))()
        local esc=Esc.new(_G,{log=ctx.log,settings=function()
            local state=ctx.query(ctx.id)
            return {enabled=state.enabled and state.active,color=color,fontSize=fontPercent,
                opacity=opacity,grow=growOnHover,glow=hoverGlow}
        end})
        ctx.registerGameMenuStyle(function() esc:Tick() end,function() esc:Cleanup() end)
    end)
    if not ok then ctx.log('Esc button styling unavailable: '..tostring(why)) end
end
assert(type(ctx.registerMainMenuStyle)=='function','Main menu style API unavailable')
ctx.registerMainMenuStyle(function(menu,entry)
    local function checked(stage,fn)
        local ok,result=pcall(fn)
        if not ok then error(stage..': '..tostring(result)) end
        return result
    end
    local state=ctx.query(ctx.id)
    local desired=state.enabled and state.active and color or nil
    local menuName=menu:GetFullName()
    if measuredMenu~=menuName then
        local play=menu.Play.t_text.Font.Size; local secondary=menu.upgrades.t_text.Font.Size
        assert(type(play)=='number' and type(secondary)=='number' and secondary>0,'Main menu font sizes unavailable')
        hoverFactor=math.max(1,play/secondary); secondarySize=secondary; playSize=play; measuredMenu=menuName
        rowHeight=menu.Play:GetDesiredSize().Y
        ctx.log('Custom buttons: original font sizes; Play='..play..'; secondary='..secondary)
    end
    if not rowHeight or rowHeight<=0 then
        local height=menu.Play:GetDesiredSize().Y
        if height and height>0 then rowHeight=height; ctx.log('Main menu reserved row height='..height) end
    end
    local function paint(button)
        if not button or not button:IsValid() then return end
        local ok,label=pcall(function() return button.t_text end)
        if not ok or not label or not label:IsValid() then return end
        local key=label:GetFullName()
        local saved=originals[key]
        if not saved then
            if not desired then return end
            local c=label.ColorAndOpacity; local v=c.SpecifiedColor
            saved={widget=label,R=v.R,G=v.G,B=v.B,A=v.A,rule=c.ColorUseRule}; originals[key]=saved
            local ok,scale,pivot=pcall(function()
                local scale=label.RenderTransform.Scale; local pivot=label.RenderTransformPivot
                return {X=scale.X,Y=scale.Y},{X=pivot.X,Y=pivot.Y}
            end)
            saved.scale=ok and scale or {X=1,Y=1}; saved.pivot=ok and pivot or {X=.5,Y=.5}
            saved.opacity={}; saved.innerTints={}
            local seen={}
            local function capture(widget)
                if not widget or not widget:IsValid() then return end
                local name=widget:GetFullName()
                if seen[name] then return end; seen[name]=true
                local ok,alpha=pcall(function() return widget:GetRenderOpacity() end)
                if ok and type(alpha)=='number' then
                    saved.opacity[#saved.opacity+1]={widget=widget,value=alpha}
                    ctx.log('Main menu opacity layer: '..name..'; alpha='..alpha)
                end
                if widget~=button then
                    local ok,tint=pcall(function()
                        local c=widget.ColorAndOpacity
                        if type(c.R)=='number' then return {R=c.R,G=c.G,B=c.B,A=c.A} end
                    end)
                    if ok and tint then
                        saved.innerTints[#saved.innerTints+1]={widget=widget,value=tint}
                        ctx.log('Main menu inner tint: '..name..'; alpha='..tint.A)
                    end
                end
            end
            capture(button)
            local widget=label
            for _=1,16 do
                if not widget or not widget:IsValid() then break end
                capture(widget)
                local ok,parent=pcall(function() return widget:GetParent() end)
                if not ok then break end; widget=parent
            end
            local tinted,tint=pcall(function() return button.ColorAndOpacity end)
            if tinted and tint and type(tint.R)=='number' then
                saved.tint={R=tint.R,G=tint.G,B=tint.B,A=tint.A}
                ctx.log('Main menu outer tint: '..key..'; RGBA='..tint.R..','..tint.G..','..tint.B..','..tint.A)
            end
        end
        local hovered=false
        if desired and (growOnHover or hoverGlow) then
            local ok,value=pcall(function() return button.b_button:IsHovered() end)
            if not ok then ok,value=pcall(function() return button:IsHovered() end) end
            hovered=ok and value==true
        end
        local isPlay=button:GetFullName()==menu.Play:GetFullName()
        local isEntry=entry and button:GetFullName()==entry:GetFullName()
        local sharedStyle=type(ctx.mainMenuButtonStyle)=='function' and ctx.mainMenuButtonStyle(button) or nil
        local baseFontSize=sharedStyle and sharedStyle.baseFontSize or ((isPlay or isEntry) and playSize or secondarySize)
        if sharedStyle and label.Font.Size~=baseFontSize then return end -- Blueprint Construct still pending.
        if isEntry and rowHeight and rowHeight>0 then
            local frame=button:GetParent()
            if not saved.entryScaleBox then
                local ok,box,stretch=pcall(function()
                    local box=button.WidgetTree.RootWidget
                    return box,box.Stretch
                end)
                if ok and box then saved.entryScaleBox=box; saved.entryStretch=stretch end
            end
            if saved.entryScaleBox and saved.entryStretch~=nil then
                saved.entryScaleBox:SetStretch(desired and 0 or saved.entryStretch)
            end
            if not saved.entryAlignment then
                local slots={button.Slot,label.Slot}
                if saved.entryScaleBox then slots[#slots+1]=saved.entryScaleBox:GetChildAt(0).Slot end
                saved.entryAlignment={}
                for _,slot in ipairs(slots) do
                    saved.entryAlignment[#saved.entryAlignment+1]={slot=slot,value=slot.VerticalAlignment}
                end
            end
            if saved.entryAligned~=(desired~=nil) then
                for _,item in ipairs(saved.entryAlignment) do
                    item.slot:SetVerticalAlignment(desired and 2 or item.value)
                end
                saved.entryAligned=desired~=nil
            end
            if not saved.entryHeight then saved.entryHeight=frame:GetDesiredSize().Y end
            if saved.entryReserved~=(desired~=nil) then
                frame:SetHeightOverride(desired and rowHeight or saved.entryHeight)
                saved.entryReserved=desired~=nil
            end
        end
        local normalSize=fontPercent
        local normalFactor=desired and normalSize/baseFontSize or 1
        -- Reserve the native Play row height once. Never resize a hovered row
        -- or subtract padding: native ScaleBoxes own their internal allocation.
        if not isEntry and not saved.rowSlot and rowHeight and rowHeight>0 then
            local ok,slot,padding,height=pcall(function()
                local owner=button
                local slot=owner.Slot
                if not slot:GetFullName():find('VerticalBoxSlot',1,true) then
                    owner=button:GetParent(); slot=owner.Slot
                end
                if not slot:GetFullName():find('VerticalBoxSlot',1,true) then return end
                local p=slot.Padding
                return slot,{Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom},owner:GetDesiredSize().Y
            end)
            if ok and slot and height and height>0 then
                saved.rowSlot=slot; saved.rowPadding=padding
                saved.extraHeight=math.max(0,rowHeight-height)
            end
        end
        local reserve=desired~=nil
        if saved.rowSlot and saved.reserved~=reserve then
            local p=saved.rowPadding
            local extra=reserve and saved.extraHeight/2 or 0
            saved.rowSlot:SetPadding({Left=p.Left,Top=p.Top+extra,Right=p.Right,
                Bottom=p.Bottom+extra})
            saved.reserved=reserve
        end
        local factor=desired and ((hovered and growOnHover and playSize or normalSize)/baseFontSize) or 1
        if saved.scaleApplied~=factor then
            label:SetRenderTransformPivot(desired and {X=0,Y=.5} or saved.pivot)
            label:SetRenderScale({X=saved.scale.X*factor,Y=saved.scale.Y*factor})
            saved.scaleApplied=factor
        end
        local showGlow=desired and hoverGlow and hovered or false
        if not showGlow then saved.borderFailed=nil end
        if showGlow and not saved.borderFailed and (not saved.border or saved.borderFactor~=factor) then
            if saved.border then saved.border:RemoveFromParent(); saved.border=nil end
            local canvas,halo
            local ok,why=pcall(function()
                canvas=StaticConstructObject(StaticFindObject('/Script/UMG.CanvasPanel'),menu.WidgetTree)
                halo=StaticConstructObject(StaticFindObject('/Script/UMG.TextBlock'),menu.WidgetTree)
                assert(canvas:IsValid() and halo:IsValid(),'Outline widget creation failed')
                -- Configure BEFORE attachment so initial Slate construction sees
                -- the font outline. Never call the unsupported live SetFont.
                local font=halo.Font; local source=label.Font
                font.FontObject=source.FontObject; font.TypefaceFontName=source.TypefaceFontName
                local baseSize=baseFontSize
                -- Match the original font without modifying its text storage.
                local ratio=1
                local outlineFactor=factor/ratio
                font.Size=baseSize
                font.LetterSpacing=source.LetterSpacing or 0
                local outline=font.OutlineSettings
                outline.OutlineSize=math.max(2,math.floor(3/outlineFactor+.5))
                outline.bSeparateFillAlpha=true; outline.bApplyOutlineToDropShadows=false
                local edge=outline.OutlineColor
                edge.R=1; edge.G=.8; edge.B=.05; edge.A=1
                local color=halo.ColorAndOpacity; color.ColorUseRule=0
                local fill=color.SpecifiedColor; fill.R=1; fill.G=1; fill.B=1; fill.A=0
                local text=label:GetText():ToString()
                halo:SetText(FText(text)); halo:SetJustification(label.Justification)
                halo:SetVisibility(3); canvas:SetVisibility(3)
                local slot=canvas:AddChildToCanvas(halo)
                local size=label:GetDesiredSize()
                slot:SetPosition({X=0,Y=-size.Y*(ratio-1)/2}); slot:SetSize({X=size.X*ratio,Y=size.Y*ratio})
                halo:SetRenderTransformPivot({X=0,Y=.5})
                halo:SetRenderScale({X=saved.scale.X*outlineFactor,Y=saved.scale.Y*outlineFactor})
                local outer=label:GetParent():AddChildToOverlay(canvas)
                outer:SetHorizontalAlignment(0)
                outer:SetVerticalAlignment(0)
                local p=label.Slot.Padding
                outer:SetPadding({Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom})
            end)
            if ok then
                saved.border=canvas; saved.borderText=halo; saved.borderFactor=factor
                ctx.log('Outline layer: original='..key..'; overlay='..halo:GetFullName()..'; original alpha='..label.ColorAndOpacity.SpecifiedColor.A)
            else
                if canvas and canvas:IsValid() then canvas:RemoveFromParent() end
                saved.borderFailed=true
                ctx.log('Hover outline layer failed; original text preserved: '..tostring(why))
            end
        end
        if saved.border then saved.border:SetVisibility(showGlow and 3 or 1) end
        if saved.border and (saved.borderObserved~=showGlow or not saved.borderObservedOnce) then
            saved.borderObserved=showGlow; saved.borderObservedOnce=true
            local function observe(widget)
                local size=widget:GetDesiredSize()
                return widget:GetFullName()..'; visibility='..widget:GetVisibility()..'; renderAlpha='..widget:GetRenderOpacity()..'; desired='..size.X..','..size.Y
            end
            local ok,report=pcall(function()
                return observe(label)..' | parent '..observe(label:GetParent())..' | button '..observe(button)
                    ..' | fillAlpha='..label.ColorAndOpacity.SpecifiedColor.A..'; hover='..tostring(hovered)
            end)
            ctx.log('Outline visibility observation: '..tostring(report))
        end

        saved.hovered=hovered
        if not desired and saved.applied==nil then return end
        if saved.applied~=desired then
            for _,item in ipairs(saved.innerTints) do
                item.widget:SetColorAndOpacity(desired and {R=1,G=1,B=1,A=1} or item.value)
            end
        end
        if saved.tint and saved.tintApplied~=desired then
            checked('Outer button tint',function()
                button:SetColorAndOpacity(desired and {R=1,G=1,B=1,A=1} or saved.tint)
            end)
            saved.tintApplied=desired
        end
        for _,item in ipairs(saved.opacity) do
            local renderOpacity=desired and 1 or item.value
            if item.widget:GetRenderOpacity()~=renderOpacity then item.widget:SetRenderOpacity(renderOpacity) end
        end
        local c=label.ColorAndOpacity; local v=c.SpecifiedColor
        local r,g,b=desired and tonumber(desired:sub(2,3),16)/255 or saved.R,
            desired and tonumber(desired:sub(4,5),16)/255 or saved.G,
            desired and tonumber(desired:sub(6,7),16)/255 or saved.B
        if saved.applied==desired and (not desired or
            (math.abs(v.R-r)<.0001 and math.abs(v.G-g)<.0001 and math.abs(v.B-b)<.0001 and math.abs(v.A-opacity/100)<.0001)) then
            -- Keep Slate's original fill synchronized after adding an outline.
            -- Reflected RGBA alone does not establish visible Slate opacity.
            if desired and saved.border then label:SetOpacity(opacity/100) end
            return
        end
        if saved.applied==desired and desired and not saved.driftLogged then
            ctx.log('Main menu color overwritten: '..key..'; RGB='..v.R..','..v.G..','..v.B)
            saved.driftLogged=true
        end
        if desired then
            v.R=r; v.G=g; v.B=b; v.A=opacity/100; c.ColorUseRule=0
        else v.R=saved.R; v.G=saved.G; v.B=saved.B; v.A=saved.A; c.ColorUseRule=saved.rule end
        checked('Synchronize text color',function() label:SetOpacity(v.A) end)
        saved.applied=desired
    end
    local column=checked('Play parent',function() return menu.Play:GetParent() end)
    local count=checked('Column child count',function() return column:GetChildrenCount() end)
    for i=0,count-1 do checked('Button '..i,function() paint(column:GetChildAt(i)) end) end
    checked('Mods entry',function() paint(entry) end)
end)
if value and value~='true' and value~='false' then
    ctx.log('Invalid EscapeClosesModMenu; using default true')
end
local function escapeAllowed()
    local state=ctx.query(ctx.id)
    return enabled and state.enabled==true and state.active==true
end
if type(ctx.registerEscapePreference)=='function' then
    ctx.registerEscapePreference(escapeAllowed)
else
assert(Key and Key.ESCAPE and type(RegisterKeyBind)=='function','Escape key API unavailable')
RegisterKeyBind(Key.ESCAPE,function()
    ctx.log('Escape trace: callback entered')
    local state=ctx.query(ctx.id)
    ctx.log('Escape trace: enabled='..tostring(state.enabled)..'; active='..tostring(state.active)..'; setting='..tostring(enabled))
    if enabled and state.enabled==true and state.active==true then
        ctx.requestMenuBack()
        ctx.log('Escape trace: back request queued')
    end
end)
end
ctx.registerSettings({
    build=function(ui,panel)
        ui.boolean(panel,'(ESC) closes Mod Menu',enabled,function(nextValue)
            if type(nextValue)~='boolean' then return nil,'Expected boolean' end
            local current,why=ctx.readConfig()
            if why and why~='missing' then return nil,why end
            local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','EscapeClosesModMenu',tostring(nextValue)))
            if not ok then return nil,problem end
            enabled=nextValue; ctx.invalidate(); return true
        end,nil,'Controls Escape navigation in Mod Menu. Changes apply immediately.')
        ui.boolean(panel,'Custom buttons',growOnHover,function(nextValue)
            if type(nextValue)~='boolean' then return nil,'Expected boolean' end
            local current,why=ctx.readConfig(); if why and why~='missing' then return nil,why end
            local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','GrowOnHover',tostring(nextValue)))
            if not ok then return nil,problem end
            growOnHover=nextValue; ctx.invalidate(); return true
        end,nil,'Main-menu and Esc buttons grow while hovered. Changes apply immediately.')
        ui.boolean(panel,'Highlight hovered button',hoverGlow,function(nextValue)
            if type(nextValue)~='boolean' then return nil,'Expected boolean' end
            local current,why=ctx.readConfig(); if why and why~='missing' then return nil,why end
            local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','HoverGlow',tostring(nextValue)))
            if not ok then return nil,problem end
            hoverGlow=nextValue; ctx.invalidate(); return true
        end,nil,'Thin yellow outline outside main-menu letters while hovered; preserves fill color and opacity. Changes apply immediately.')
        ui.colors(panel,{label='Main Menu',value=color,current=function() return color end,
            options=function() local options={}; for _,v in ipairs(colors) do options[#options+1]={color=v} end; return options end,
            set=function(nextColor)
                if type(nextColor)~='string' or not nextColor:match('^#%x%x%x%x%x%x$') then return nil,'Expected #RRGGBB color' end
                local current,why=ctx.readConfig(); if why and why~='missing' then return nil,why end
                local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','MainMenuTextColor',nextColor))
                if not ok then return nil,problem end
                color=nextColor; ctx.invalidate(); return true
            end})
        ui.slider(panel,'Font size',fontPercent,30,60,5,function(nextPercent)
            if type(nextPercent)~='number' or nextPercent~=nextPercent or nextPercent<30 or nextPercent>60 or nextPercent%5~=0 then return nil,'Expected font size from 30 to 60 in steps of 5' end
            local current,why=ctx.readConfig(); if why and why~='missing' then return nil,why end
            local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','MainMenuFontSize',tostring(nextPercent)))
            if not ok then return nil,problem end
            fontPercent=nextPercent; ctx.invalidate(); return true
        end,'Original buttons: 30. Original Play: 60.', '',30)
        ui.slider(panel,'Text opacity',opacity,10,100,10,function(nextOpacity)
            if type(nextOpacity)~='number' or nextOpacity~=nextOpacity or nextOpacity<10 or nextOpacity>100 or nextOpacity%10~=0 then return nil,'Expected opacity from 10 to 100 in steps of 10' end
            local current,why=ctx.readConfig(); if why and why~='missing' then return nil,why end
            local ok,problem=ctx.writeConfig(Ini.set(current or '[Settings]\n','Settings','MainMenuTextOpacity',tostring(nextOpacity)))
            if not ok then return nil,problem end
            opacity=nextOpacity; ctx.invalidate(); return true
        end,nil,'%',50)
    end,
    restartRequired=function() return false end,
})
