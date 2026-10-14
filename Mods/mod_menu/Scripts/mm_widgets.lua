-- UMG primitives. Existing WBP_Button supplies the inspected Blueprint click path.
local W = {}; W.__index = W
local function valid(o) return o and o:IsValid() end
function W.font(target,source,size)
    -- SetFont failed for userdata and flat/nested tables in this runtime.
    -- Keep the working-open path; visible Slate font synchronization is pending.
    local font=target.Font
    font.FontObject=source.FontObject
    font.TypefaceFontName=source.TypefaceFontName
    font.Size=size or source.Size
    font.LetterSpacing=source.LetterSpacing or 0
end
function W.buttonText(G,button,label)
    local text=G.FText(label)
    button.ButtonText=text
    local updated=pcall(function() button:UpdateButtonText() end)
    if not updated then
        -- This Blueprint helper throws in the inspected runtime. Its bound
        -- TextBlock provides the same label without replacing the button.
        assert(valid(button.t_text),'Button text widget unavailable')
        button.t_text:SetText(text)
    end
end
function W.new(G, menu, assets, dispatch)
    return setmetatable({G=G, menu=menu, assets=assets, dispatch=dispatch, textures={}, animations={}}, W)
end
function W:create(class)
    self.stage='construct '..class
    local c = self.G.StaticFindObject('/Script/UMG.' .. class)
    assert(valid(c), 'Missing UMG class ' .. class)
    local o = self.G.StaticConstructObject(c, self.menu.WidgetTree)
    assert(valid(o), 'Could not construct ' .. class); return o
end
function W:place(parent, child, x,y,w,h)
    self.stage='Canvas slot creation'
    local s = parent:AddChildToCanvas(child)
    self.stage='Canvas slot SetPosition'
    s:SetPosition({X=x,Y=y})
    self.stage='Canvas slot SetSize'
    s:SetSize({X=w,Y=h}); self.stage='placement completed'; return child
end
function W:canvas(parent,x,y,w,h)
    return self:place(parent,self:create('CanvasPanel'),x,y,w,h)
end
function W:text(parent,text,x,y,w,h,size,tooltip)
    self.stage='game-styled label factory'
    local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
    local host=lib:Create(self.menu,cls,nil)
    assert(valid(host) and valid(host.t_text),'Game-styled label unavailable')
    -- Retain the Blueprint host and reparent its already-styled text widget.
    self.textHosts=self.textHosts or {}; self.textHosts[#self.textHosts+1]=host
    local t=host.t_text; t:RemoveFromParent()
    self.stage='TextBlock SetText'; t:SetText(self.G.FText(tostring(text)))
    local font = self.menu.Play.t_text.Font
    self.stage='TextBlock font fields'
    W.font(t,font,size or 20)
    t.WrapTextAt=w
    t:SetJustification(0)
    self.stage='TextBlock color fields'
    -- This runtime zeroed the nested SpecifiedColor passed as a Lua table.
    -- Set reflected fields before attachment, when Slate synchronizes them.
    local color=t.ColorAndOpacity
    color.ColorUseRule=0
    local rgba=color.SpecifiedColor
    rgba.R=1; rgba.G=1; rgba.B=1; rgba.A=1
    self.stage='TextBlock visibility/tooltip'
    if tooltip then t:SetToolTipText(self.G.FText(tooltip)); t:SetVisibility(0)
    else t:SetVisibility(3) end
    self.labels=self.labels or {}
    self.labels[#self.labels+1]={widget=t,expected=tostring(text),height=h,width=w,y=y,
        autoRow=self.autoRows and self.autoRows[parent:GetFullName()]}
    return self:place(parent,t,x,y,w,h)
end
-- One observation after attachment; optional reflection must not stop the UI.
function W:observeLabels(log)
    local function read(fn)
        local ok,value=pcall(fn)
        if not ok then return 'unavailable: '..tostring(value) end
        return tostring(value)
    end
    for _,item in ipairs(self.labels or {}) do
        local t=item.widget
        if valid(t) then
            if item.autoRow then
                local ok,desired=pcall(function() return t:GetDesiredSize() end)
                if ok and type(desired.Y)=='number' and desired.Y>0 and desired.Y<math.huge then
                    local height=math.max(item.height,math.ceil(desired.Y))
                    t.Slot:SetSize({X=item.width,Y=height})
                    item.autoRow:SetHeightOverride(item.y+height+6)
                end
            end
            local values={}
            local function field(name,fn) values[#values+1]=name..'='..read(fn) end
            field('text',function() return t:GetText():ToString() end)
            field('font',function() return t.Font.FontObject:GetFullName() end)
            field('size',function() return t.Font.Size end)
            field('opacity',function() return t:GetRenderOpacity() end)
            field('color',function() local c=t.ColorAndOpacity.SpecifiedColor; return c.R..','..c.G..','..c.B..','..c.A end)
            field('colorRule',function() return t.ColorAndOpacity.ColorUseRule end)
            field('visibility',function() return t:GetVisibility() end)
            field('desired',function() local v=t:GetDesiredSize(); return v.X..','..v.Y end)
            field('slotSize',function() local v=t.Slot:GetSize(); return v.X..','..v.Y end)
            pcall(log,'Label observation ['..item.expected..'; height='..item.height..']: '..table.concat(values,' | '))
        end
    end
    self.labels={}
end
local function linear(v) v=v/255; return v <= 0.04045 and v/12.92 or ((v+0.055)/1.055)^2.4 end
function W.color(hex)
    assert(type(hex)=='string' and hex:match('^#%x%x%x%x%x%x$'), 'Expected #RRGGBB color')
    return {R=linear(tonumber(hex:sub(2,3),16)),G=linear(tonumber(hex:sub(4,5),16)),B=linear(tonumber(hex:sub(6,7),16)),A=1}
end
function W:rect(parent,color,x,y,w,h)
    local b=self:create('Border'); self.stage='Border SetBrushColor'; b:SetBrushColor(W.color(color)); self.stage='Border SetVisibility'; b:SetVisibility(3)
    return self:place(parent,b,x,y,w,h)
end
function W:outline(parent,color,x,y,w,h)
    local thickness=2
    self:rect(parent,color,x,y,w,thickness)
    self:rect(parent,color,x,y+h-thickness,w,thickness)
    self:rect(parent,color,x,y+thickness,thickness,h-2*thickness)
    self:rect(parent,color,x+w-thickness,y+thickness,thickness,h-2*thickness)
end
function W:image(parent,file,x,y,w,h)
    if not valid(self.textures[file]) then
        local lib=self.G.StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
        assert(valid(lib),'KismetRenderingLibrary unavailable')
        self.textures[file]=lib:ImportFileAsTexture2D(self.menu,self.assets .. '/' .. file)
        assert(valid(self.textures[file]),'Cannot import ' .. file)
    end
    local im=self:create('Image'); im:SetBrushFromTexture(self.textures[file],false); im:SetVisibility(3)
    return self:place(parent,im,x,y,w,h)
end
function W:button(parent,label,x,y,w,h,callback,tooltip,enabled,custom)
    self.stage='button factory'
    local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
    local b=lib:Create(self.menu,cls,nil); assert(valid(b),'Button creation failed')
    self.stage='button label'
    -- Custom controls replace the Blueprint label with their own canvas.
    -- Avoid empty FText/Blueprint label work that is irrelevant to that path.
    if not custom or label~='' then W.buttonText(self.G,b,label) end
    local content
    if custom then
        self.stage='custom button native reparent'
        -- Reparent the existing bound native button before Slate takes the widget.
        local native=b.b_button; native:RemoveFromParent(); b.WidgetTree.RootWidget=native
        local style=native.WidgetStyle
        style.Normal.DrawAs=0; style.Hovered.DrawAs=0; style.Pressed.DrawAs=0; style.Disabled.DrawAs=0
        -- UE4SS 3.0.1 cannot pass UScriptStruct userdata to SetStyle.
        -- The reflected style has already been updated before attachment.
        self.stage='custom button canvas content'
        content=self:create('CanvasPanel'); native:SetContent(content)
        self.stage='custom button slot padding'
        content.Slot:SetPadding({Left=0,Top=0,Right=0,Bottom=0})
    end
    self.stage='button enabled/tooltip'
    if tooltip then b:SetToolTipText(self.G.FText(tooltip)) end
    b:SetIsEnabled(enabled ~= false)
    self:place(parent,b,x,y,w,h)
    self.dispatch[b:GetFullName()]=callback
    return b,content
end
-- CSS cubic-bezier(.4,0,.2,1), solved for the time-axis before evaluating Y.
function W.ease(t)
    local lo,hi=0,1
    for _=1,16 do
        local u=(lo+hi)/2; local x=3*(1-u)^2*u*.4+3*(1-u)*u^2*.2+u^3
        if x<t then lo=u else hi=u end
    end
    local u=(lo+hi)/2; return 3*(1-u)*u*u+u^3
end
function W:toggle(parent,x,y,on,changed,locked)
    local target=on and 1 or 0
    local b,c=self:button(parent,'',x,y,59.4,23.1,function() end,
        locked and 'The mod manager is permanently enabled.' or (on and 'Turn off' or 'Turn on'),not locked,true)
    local off=self:image(c,'track-off.png',0,0,59.4,23.1)
    local green=self:image(c,'track-on.png',0,0,59.4,23.1)
    local no=self:text(c,'OFF',31.35,5.94,19.8,11.22,8); no:SetJustification(2)
    local yes=self:text(c,'ON',8.25,5.94,19.8,11.22,8); yes:SetJustification(1)
    local thumb=self:canvas(c,1.65,1.65,19.8,19.8)
    self:image(thumb,'thumb.png',0,0,19.8,19.8)
    local red=self:image(thumb,'inner-off.png',0,0,19.8,19.8)
    local inner=self:image(thumb,'inner-on.png',0,0,19.8,19.8)
    local function paint(v)
        green:SetRenderOpacity(v); yes:SetRenderOpacity(v); no:SetRenderOpacity(1-v)
        inner:SetRenderOpacity(v); red:SetRenderOpacity(1-v)
        thumb.Slot:SetPosition({X=1.65+36.3*v,Y=1.65})
    end
    paint(target)
    local anim={value=target,from=target,to=target,elapsed=.4,paint=paint,widget=b}
    self.animations[#self.animations+1]=anim
    self.dispatch[b:GetFullName()]=function()
        if locked then return end
        local desired=anim.to==0
        if changed(desired) then
            anim.from=anim.value; anim.to=desired and 1 or 0; anim.elapsed=0
            b:SetToolTipText(self.G.FText(desired and 'Turn off' or 'Turn on'))
        end
    end
    return b
end
function W:tick(dt)
    local live={}
    for _,a in ipairs(self.animations) do
        if valid(a.widget) and valid(a.widget:GetParent()) then
        live[#live+1]=a
        if a.elapsed<.4 then
            a.elapsed=math.min(.4,a.elapsed+dt)
            a.value=a.from+(a.to-a.from)*W.ease(a.elapsed/.4); a.paint(a.value)
        end
        end
    end
    self.animations=live
end
function W:scroll(parent,x,y,w,h)
    local scroll=self:create('ScrollBox'); scroll:SetClipping(1); self:place(parent,scroll,x,y,w,h)
    local box=self:create('VerticalBox'); scroll:AddChild(box); return box
end
function W:row(box,height,width,autoHeight)
    local size=self:create('SizeBox'); size:SetHeightOverride(height); size:SetWidthOverride(width)
    local canvas=self:create('CanvasPanel'); size:SetContent(canvas)
    box:AddChildToVerticalBox(size):SetHorizontalAlignment(1)
    if autoHeight then self.autoRows=self.autoRows or {}; self.autoRows[canvas:GetFullName()]=size end
    return canvas
end
return W
