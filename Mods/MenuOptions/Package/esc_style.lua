-- Esc-only styling. Original widgets/text/materials stay owned by the game.
local E={};E.__index=E
local function valid(o) return o and o:IsValid() end
local function copy(c) return {R=c.R,G=c.G,B=c.B,A=c.A} end
function E.new(G,options) return setmetatable({G=G,options=options,saved={},esc={}},E) end
function E:_hooks()
    if type(self.G.RegisterHook)~='function' then return end
    local escape='/Game/Blueprints/BP_Player.BP_Player_C:InpActEvt_Escape_K2Node_InputActionEvent_1'
    local resume='/Game/UI/WBP_HUD.WBP_HUD_C:BndEvt__WBP_HUD_resume_K2Node_ComponentBoundEvent_1_Click__DelegateSignature'
    if not self.escapeHook and valid(self.G.StaticFindObject(escape)) then
        self.G.RegisterHook(escape,function(context)
            pcall(function()
                local pawn=context:get();local hud=pawn.HUD
                if valid(hud) and pawn['PresentTime?']~=true and (not valid(hud.tab) or hud.tab:GetVisibility()~=0) then
                    self.esc[hud:GetFullName()]=hud.pausemenu_overlay:GetVisibility()==0
                end
            end)
        end);self.escapeHook=true
    end
    if not self.resumeHook and valid(self.G.StaticFindObject(resume)) then
        self.G.RegisterHook(resume,function(context)
            pcall(function() self.esc[context:get():GetFullName()]=false end)
        end);self.resumeHook=true
    end
end
function E:_border(saved)
    if saved.border and valid(saved.border) then saved.border:RemoveFromParent() end
    saved.border=nil;saved.borderFactor=nil;saved.borderValue=nil
end
function E:_restore(saved)
    self:_border(saved)
    for _,row in ipairs(saved.layers) do
        if valid(row.widget) then
            if row.opacity then row.widget:SetRenderOpacity(row.opacity) end
            if row.tint then row.widget:SetColorAndOpacity(row.tint) end
        end
    end
    if not valid(saved.label) then return end
    local c=saved.label.ColorAndOpacity;local rgba=c.SpecifiedColor
    rgba.R=saved.color.R;rgba.G=saved.color.G;rgba.B=saved.color.B;rgba.A=saved.color.A;c.ColorUseRule=saved.rule
    saved.label:SetOpacity(saved.color.A)
    saved.label:SetRenderScale(saved.scale);saved.label:SetRenderTransformPivot(saved.pivot)
    if saved.root and valid(saved.root) and saved.stretch~=nil then saved.root:SetStretch(saved.stretch) end
end
function E:Cleanup()
    for key,saved in pairs(self.saved) do pcall(self._restore,self,saved);self.saved[key]=nil end
end
function E:_capture(button,label)
    local fontSize=label.Font.Size;assert(type(fontSize)=='number' and fontSize>0,'Esc font unavailable')
    local c=label.ColorAndOpacity;local saved={button=button,label=label,color=copy(c.SpecifiedColor),rule=c.ColorUseRule,
        fontSize=fontSize,scale={X=label.RenderTransform.Scale.X,Y=label.RenderTransform.Scale.Y},
        pivot={X=label.RenderTransformPivot.X,Y=label.RenderTransformPivot.Y},layers={}}
    local ok,root,stretch=pcall(function() local root=button.WidgetTree.RootWidget;return root,root.Stretch end)
    if ok and valid(root) and type(stretch)=='number' then saved.root=root;saved.stretch=stretch end
    -- Only this button's private WidgetTree; never normalize HUD ancestors.
    local seen={};local count=0
    local function capture(node,depth)
        if not valid(node) or depth>12 or count>=48 then return end
        local key=node:GetFullName();if seen[key] then return end;seen[key]=true;count=count+1
        local row={widget=node}
        local ok,value=pcall(node.GetRenderOpacity,node);if ok and type(value)=='number' then row.opacity=value end
        ok,value=pcall(function() local tint=node.ColorAndOpacity;return type(tint.R)=='number' and copy(tint) end)
        if ok and value then row.tint=value end
        saved.layers[#saved.layers+1]=row
        local ok,n=pcall(node.GetChildrenCount,node)
        if ok and type(n)=='number' then for i=0,math.min(n,48)-1 do capture(node:GetChildAt(i),depth+1) end end
    end
    capture(button,0)
    if button.WidgetTree then capture(button.WidgetTree.RootWidget,0) end
    capture(label,0)
    return saved
end
function E:_outline(hud,saved,factor,text)
    local baseSize=saved.label.Font.Size
    if saved.border and saved.borderFactor==factor and saved.borderValue==text and saved.borderBaseSize==baseSize then return true end
    self:_border(saved)
    local canvas,halo
    local ok,why=pcall(function()
        canvas=self.G.StaticConstructObject(self.G.StaticFindObject('/Script/UMG.CanvasPanel'),hud.WidgetTree)
        halo=self.G.StaticConstructObject(self.G.StaticFindObject('/Script/UMG.TextBlock'),hud.WidgetTree)
        assert(valid(canvas) and valid(halo),'Esc outline construction failed')
        local source=saved.label.Font;local font=halo.Font
        font.FontObject=source.FontObject;font.TypefaceFontName=source.TypefaceFontName
        font.Size=baseSize;font.LetterSpacing=source.LetterSpacing or 0
        local outline=font.OutlineSettings;outline.OutlineSize=math.max(1,math.floor(3/factor+.5))
        outline.bSeparateFillAlpha=true;outline.bApplyOutlineToDropShadows=false
        local edge=outline.OutlineColor;edge.R=1;edge.G=.8;edge.B=.05;edge.A=1
        local c=halo.ColorAndOpacity;c.ColorUseRule=0;local fill=c.SpecifiedColor
        fill.R=1;fill.G=1;fill.B=1;fill.A=0
        halo:SetText(self.G.FText(text));halo:SetJustification(saved.label.Justification)
        halo:SetVisibility(3);canvas:SetVisibility(3)
        local slot=canvas:AddChildToCanvas(halo);local size=saved.label:GetDesiredSize()
        slot:SetPosition({X=0,Y=0});slot:SetSize({X=size.X,Y=size.Y})
        halo:SetRenderTransformPivot({X=.5,Y=.5})
        halo:SetRenderScale({X=factor,Y=factor})
        local outer=saved.label:GetParent():AddChildToOverlay(canvas)
        outer:SetHorizontalAlignment(1);outer:SetVerticalAlignment(1)
        local p=saved.label.Slot.Padding
        outer:SetPadding({Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom})
    end)
    if not ok then if valid(canvas) then canvas:RemoveFromParent() end;return false,why end
    saved.border=canvas;saved.borderFactor=factor;saved.borderValue=text;saved.borderBaseSize=baseSize;return true
end
function E:_paint(hud,button,settings)
    local label=button.t_text;if not valid(label) then return end
    local key=label:GetFullName();local saved=self.saved[key]
    if saved and not valid(saved.label) then self.saved[key]=nil;saved=nil end
    if not saved then saved=self:_capture(button,label);self.saved[key]=saved end
    local hovered=false
    local ok,value=pcall(function() return button.b_button:IsHovered() end)
    if not ok then ok,value=pcall(button.IsHovered,button) end
    hovered=ok and value==true
    local baseSize=label.Font.Size;assert(type(baseSize)=='number' and baseSize>0,'Esc font unavailable')
    local factor=settings.fontSize/baseSize*(settings.grow and hovered and 1.2 or 1)
    -- Menu Options owns the effective styled size. Multiplying a captured
    -- native half-scale would make MP Pause smaller than the other labels.
    if saved.root then saved.root:SetStretch(0) end -- EStretch.None: no second ScaleBox font scaling.
    label:SetRenderTransformPivot({X=.5,Y=.5});label:SetRenderScale({X=factor,Y=factor})
    for _,row in ipairs(saved.layers) do
        if valid(row.widget) then
            if row.opacity then row.widget:SetRenderOpacity(1) end
            if row.tint then row.widget:SetColorAndOpacity({R=1,G=1,B=1,A=1}) end
        end
    end
    local c=label.ColorAndOpacity;local rgba=c.SpecifiedColor;c.ColorUseRule=0
    rgba.R=tonumber(settings.color:sub(2,3),16)/255;rgba.G=tonumber(settings.color:sub(4,5),16)/255
    rgba.B=tonumber(settings.color:sub(6,7),16)/255;rgba.A=settings.opacity/100
    label:SetOpacity(settings.opacity/100)
    if settings.glow and hovered then
        local text=label:GetText():ToString()
        local ok,why=self:_outline(hud,saved,factor,text)
        if not ok and not saved.outlineError then saved.outlineError=true;self.options.log('Esc outline unavailable; fill preserved: '..tostring(why)) end
    else self:_border(saved) end
end
function E:Tick()
    self:_hooks()
    local settings=self.options.settings()
    if not settings.enabled then self:Cleanup();return end
    local seen={};local hudSeen={}
    for _,hud in ipairs(self.G.FindAllOf('WBP_HUD_C') or {}) do
        if valid(hud) then hudSeen[hud:GetFullName()]=true end
        local actualOpen=valid(hud) and (self.escapeHook and self.esc[hud:GetFullName()]==true or not self.escapeHook)
        if actualOpen and hud:IsInViewport() and valid(hud.pausemenu_overlay) and hud.pausemenu_overlay:GetVisibility()==0 then
            local buttons={};local added={}
            local function add(button)
                if valid(button) and valid(button.t_text) and not added[button:GetFullName()] then
                    added[button:GetFullName()]=true;buttons[#buttons+1]=button
                end
            end
            add(hud.resume);add(hud.settings);add(hud.restart)
            -- Discover MP's inserted Pause/Unpause in the inspected Esc subtree.
            local count=0;local walked={}
            local function walk(node,depth)
                if not valid(node) or depth>16 or count>=96 or walked[node:GetFullName()] then return end
                walked[node:GetFullName()]=true;count=count+1
                local ok,text=pcall(function() return node.t_text:GetText():ToString() end)
                if ok and (text:lower()=='pause' or text:lower()=='unpause') then add(node) end
                local ok,n=pcall(node.GetChildrenCount,node)
                if ok and type(n)=='number' then for i=0,math.min(n,96)-1 do walk(node:GetChildAt(i),depth+1) end end
                pcall(function() if node.WidgetTree then walk(node.WidgetTree.RootWidget,depth+1) end end)
            end
            walk(hud.pausemenu_overlay,0)
            for _,button in ipairs(buttons) do
                local key=button.t_text:GetFullName();seen[key]=true
                local ok,why=pcall(self._paint,self,hud,button,settings)
                if not ok then local saved=self.saved[key];if saved then pcall(self._restore,self,saved);self.saved[key]=nil end
                    if not self.failed then self.failed=true;self.options.log('Esc style unavailable: '..tostring(why)) end
                end
            end
        end
    end
    for key in pairs(self.esc) do if not hudSeen[key] then self.esc[key]=nil end end
    for key,saved in pairs(self.saved) do
        if not seen[key] then pcall(self._restore,self,saved);self.saved[key]=nil end
    end
end
return E
