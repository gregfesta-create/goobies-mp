-- Owned UI interception; native End Run must not destroy the departing host
-- before the acknowledged authority/state handover completes.
local Liveness=require('gmp_run_sync_liveness')
local D={};D.__index=D
local CLICK='/Game/UI/WBP_Button.WBP_Button_C:BndEvt__WBP_Button01_b_button_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature'
local GRAPH='/Game/UI/WBP_HUD.WBP_HUD_C:ExecuteUbergraph_WBP_HUD'
local function valid(o) return o and o:IsValid() end
function D.new(options)
    assert(options.G and options.world and type(options.request)=='function','departure UI bindings required')
    return setmetatable({o=options,G=options.G,queue={}},D)
end
function D:_context()
    local bridge=type(self.o.world)=='function' and self.o.world() or self.o.world
    if not bridge then return nil end
    local _,pawn=bridge:LocalWorldPawn();local hud=pawn and pawn.HUD
    if not valid(pawn) or not valid(hud) or not hud:IsInViewport() then return nil end
    return hud,pawn
end
function D:Release()
    local own=self.owned;self.owned=nil;self.queue={}
    if not own then return end
    -- A HUD freed by a level change is dropped without touching it (R1 attempt 2 crash rule).
    if not Liveness.Listed(self.G,own.hud,'WBP_HUD_C') then return end
    if valid(own.parent) and valid(own.original) then pcall(own.parent.SetContent,own.parent,own.original) end
    if valid(own.button) then pcall(own.button.RemoveFromParent,own.button) end
end
function D:_attach(hud)
    local original=hud.restart;assert(valid(original),'missing_end_run_control')
    local parent=original:GetParent();assert(valid(parent),'missing_end_run_container')
    local kind=parent:GetFullName():match('^(%S+)')
    local replaced=original
    if kind~='Border' and kind~='SizeBox' then
        -- The verified shared-pause layout uses a VerticalBox. Preserve its
        -- native row/control references by replacing only the button's inner
        -- ScaleBox content, rather than detaching the outer restart widget.
        local root=original.WidgetTree and original.WidgetTree.RootWidget
        assert(valid(root) and root:GetFullName():match('^(%S+)')=='ScaleBox','unsupported_end_run_container')
        parent=root;kind='ScaleBox';replaced=parent:GetChildAt(0)
        assert(valid(replaced),'missing_end_run_inner_content')
    end
    assert(parent:GetChildrenCount()==1,'ambiguous_end_run_container')
    local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
    assert(valid(lib) and valid(cls) and valid(self.G.StaticFindObject(CLICK)),'missing_end_run_widget_api')
    local button=lib:Create(hud,cls,nil);assert(valid(button) and valid(button.t_text),'end_run_creation_failed')
    local font=original.t_text.Font;local target=button.t_text.Font
    target.FontObject=font.FontObject;target.TypefaceFontName=font.TypefaceFontName
    target.Size=font.Size;target.LetterSpacing=font.LetterSpacing or 0
    button.t_text:SetText(self.G.FText('End Run'));button.t_text:SetJustification(1)
    self.owned={hud=hud,name=hud:GetFullName(),parent=parent,original=replaced,button=button,buttonName=button:GetFullName()}
    parent:SetContent(button)
    if not self.hooked then
        self.G.RegisterHook(CLICK,function(context)
            local own=self.owned
            if own and context:get():GetFullName()==own.buttonName and #self.queue==0 then self.queue[1]=own.name end
        end);self.hooked=true
    end
end
function D:Tick(enabled)
    local ok,why=pcall(function()
        local hud=self:_context()
        if hud then
            local name=hud:GetFullName()
            if self.lastHudName~=name then self.lastHudName=name;self.exitIssued=nil end
        end
        if not enabled or not hud then self:Release();return end
        if self.owned and self.owned.name~=hud:GetFullName() then self:Release() end
        if not self.owned then self:_attach(hud) end
        local queue=self.queue;self.queue={}
        for _,name in ipairs(queue) do
            if self.owned and self.owned.name==name then
                local accepted,reason=self.o.request()
                if not accepted and self.o.log then self.o.log('End Run departure refused: '..tostring(reason)) end
            end
        end
    end)
    if not ok then self:Release();return false,tostring(why):sub(1,300) end
    return true
end
-- Evidence: lobby_departure_static_20261011/WBP_HUD.txt graph 4441.
-- This includes native Add All Enemy Stats before Menu; it is not the Death
-- graph 2337 and must only be called by App's healthy-finished callback.
function D:ExitToMenu()
    if self.exitIssued then return false,'menu_exit_already_issued' end
    local ok,why=pcall(function()
        local hud=self:_context();assert(hud,'missing_exit_hud')
        local fn=self.G.StaticFindObject(GRAPH);assert(valid(fn),'missing_hud_exit_graph')
        local names={};fn:ForEachProperty(function(property)
            local name=property:GetFName():ToString();if name~='ReturnValue' then names[#names+1]=name end
        end)
        assert(require('gmp_lobby_menu_exit').UbergraphSignature(names),'unsupported_hud_exit_signature')
        self.exitIssued=true;self:Release();hud:ExecuteUbergraph_WBP_HUD(4441)
    end)
    if not ok then return false,tostring(why):sub(1,300) end
    return true
end
return D
