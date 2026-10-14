-- Uses evidenced WBP_HUD pause overlay and native GameAndUI/SetFocus paths.
-- Owns presentation/input only; never changes shared pause or election state.
local Liveness=require('gmp_run_sync_liveness')
local P={};P.__index=P
local function valid(o) return o and o:IsValid() end
function P.new(options) return setmetatable({options=options,G=options.G},P) end
function P:_context()
    local bridge=type(self.options.world)=='function' and self.options.world() or self.options.world
    if not bridge then return nil,'world_unavailable' end
    local world,pawn,gameplay=bridge:LocalWorldPawn()
    local hud=pawn and pawn.HUD
    if not valid(pawn) or not valid(hud) or not hud:IsInViewport() or pawn['PresentTime?']==true then return nil,'missing_game_hud' end
    if valid(hud.tab) and hud.tab:GetVisibility()==0 then return nil,'native_inventory_open' end
    local overlay=hud.pausemenu_overlay;local root=hud.WidgetTree.RootWidget
    if not valid(overlay) or not valid(root) or root:GetFullName():match('^(%S+)')~='CanvasPanel' then return nil,'unsupported_pause_surface' end
    local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if not valid(gameplay) then return nil,'gameplay_library_unavailable' end
    local controller=gameplay:GetPlayerController(world,0)
    if not valid(lib) or not valid(controller) then return nil,'input_controller_unavailable' end
    if type(controller.bShowMouseCursor)~='boolean' then return nil,'cursor_state_unavailable' end
    return {pawn=pawn,hud=hud,overlay=overlay,controller=controller,lib=lib,name=pawn:GetFullName(),bridge=bridge}
end
function P:Release()
    local owned=self.owned;self.owned=nil
    if not owned then return end
    -- A HUD freed by a level change is dropped without any call into it or its widgets (R1 attempt 2 crash rule).
    if not Liveness.Listed(self.G,owned.hud,'WBP_HUD_C') then return end
    if valid(owned.overlay) then pcall(owned.overlay.SetVisibility,owned.overlay,owned.visibility) end
    for _,row in ipairs(owned.background or {}) do
        if valid(row.widget) then
            if row.color then pcall(row.widget.SetBrushColor,row.widget,row.color)
            else pcall(row.widget.SetBlurStrength,row.widget,row.strength) end
        end
    end
    if valid(owned.controller) and valid(owned.lib) then
        pcall(function() owned.controller.bShowMouseCursor=owned.cursor end)
        pcall(owned.lib.SetInputMode_GameAndUIEx,owned.lib,owned.controller,nil,0,false,false)
        if owned.visibility==0 and valid(owned.hud.resume) then pcall(owned.hud.resume.SetFocus,owned.hud.resume)
        else pcall(owned.lib.SetFocusToGameViewport,owned.lib) end
    end
end
function P:_background(owned)
    owned.background={};local seen={};local count=0
    local function visit(widget,depth)
        if depth>12 or count>=64 or not valid(widget) then return end
        local name=widget:GetFullName();if seen[name] then return end;seen[name]=true
        count=count+1;local class=name:match('^(%S+)')
        if class=='Border' and name:match('%.pause_menu$') then
            local c=widget.BrushColor
            local original={R=c.R,G=c.G,B=c.B,A=c.A}
            owned.background[#owned.background+1]={widget=widget,color=original}
            widget:SetBrushColor({R=c.R,G=c.G,B=c.B,A=.3})
        elseif class=='BackgroundBlur' then
            owned.background[#owned.background+1]={widget=widget,strength=widget.BlurStrength}
            widget:SetBlurStrength(1.5)
        end
        if ({Overlay=true,CanvasPanel=true,Border=true,BackgroundBlur=true,VerticalBox=true,HorizontalBox=true,SizeBox=true,ScaleBox=true,ScrollBox=true})[class] then
            for i=0,widget:GetChildrenCount()-1 do visit(widget:GetChildAt(i),depth+1) end
        end
    end
    visit(owned.overlay,0)
end
function P:_surface(active)
    if not active then self:Release();return nil end
    local context,why=self:_context()
    if not context then self:Release();return nil,why end
    if self.owned and self.owned.name~=context.name then self:Release() end
    if not self.owned then
        context.visibility=context.overlay:GetVisibility();context.cursor=context.controller.bShowMouseCursor
        self.owned=context;self:_background(context)
    end
    -- Native Esc may try to close its overlay; authoritative departure remains
    -- paused and this presentation reopens without calling pawn.Pause.
    context.overlay:SetVisibility(0);context.controller.bShowMouseCursor=true
    return context.hud
end
function P:Surface(active)
    local ok,surface,why=pcall(self._surface,self,active)
    if not ok then pcall(self.Release,self);return nil,'surface_failed: '..tostring(surface):sub(1,300) end
    return surface,why
end
function P:HiddenControls()
    local o=self.owned;if not o then return {} end
    local controls={}
    for _,key in ipairs{'resume','settings','restart','quit'} do if valid(o.hud[key]) then controls[#controls+1]=o.hud[key] end end
    local menu=o.bridge.pauseMenu
    if menu and valid(menu.button) then controls[#controls+1]=menu.button end
    return controls
end
function P:Focus(button)
    local o=self.owned
    if not o or not valid(button) then return false end
    o.lib:SetInputMode_GameAndUIEx(o.controller,nil,0,false,false)
    button:SetFocus();return true
end
return P
