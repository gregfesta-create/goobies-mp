-- Local Esc-screen identity. Stable roster slot, current authenticated role;
-- independent of pause/wait notices and never consumes pointer input.
local Liveness=require('gmp_run_sync_liveness')
local L={};L.__index=L
local observations=setmetatable({},{__mode='k'})
local owners=setmetatable({},{__mode='k'})
local function valid(o) return o and o:IsValid() end
function L.Text(session,role)
    if not session or not session.identity or (role~='host' and role~='client') then return nil end
    local players
    if role=='host' then
        if not session.roster then return nil end
        players=session.roster:Snapshot()
    else
        local roster=session:Roster();players=roster and roster.players
    end
    for _,row in ipairs(players or {}) do
        if row.key==session.identity.key and row.role==role and row.conn=='connected'
            and type(row.slot)=='number' and row.slot%1==0 and row.slot>=1 and row.slot<=256 then
            return 'Player '..row.slot..' - '..(role=='host' and 'Host' or 'Client')
        end
    end
end
function L.new(world,log) return setmetatable({world=world,G=world.G,log=log},L) end
function L:Observe(name,opened) observations[self.G]={name=name,opened=opened==true} end
function L:Observed(name)
    local current=observations[self.G]
    return current and current.name==name and current.opened==true or false
end
-- Amended (R1 attempt 2 crash rule, gmp_run_sync_liveness.lua): a cached label or world notice whose HUD is no longer a
-- live WBP_HUD_C is dropped without any call into it (UE4SS IsValid cannot detect memory freed by a level change).
local function live(G,hud) return Liveness.Listed(G,hud,'WBP_HUD_C')~=nil end
function L:Clear()
    if self.label and live(self.G,self.label.hud) and valid(self.label.text) then pcall(function() self.label.text:SetVisibility(1);self.label.text:RemoveFromParent() end) end
    local registry=owners[self.G]
    if self.label and registry and registry[self.label.hudName]==self then registry[self.label.hudName]=nil end
    self.label=nil
    self.world.escRoleNoticeY=nil
    local notice=self.world.notice
    if notice and live(self.G,notice.hud) and valid(notice.text) then pcall(function() notice.text.Slot:SetPosition({X=0,Y=24}) end) end
end
function L:Tick(session,role,explicitOpen)
    local ok,why=pcall(function()
        local text=L.Text(session,role)
        if not text or explicitOpen==false or not self.world:IsEscapeMenuOpen() then self:Clear();return end
        local _,pawn=self.world:LocalWorldPawn();local hud=pawn and pawn.HUD
        if not valid(hud) then self:Clear();return end
        local hudName=hud:GetFullName()
        local registry=owners[self.G] or {};owners[self.G]=registry
        local previous=registry[hudName]
        if previous and previous~=self then previous:Clear() end
        if self.label and (self.label.hudName~=hudName or not live(self.G,self.label.hud) or not valid(self.label.text)) then self:Clear() end
        registry[hudName]=self
        local reference=hud.resume and hud.resume.t_text
        if not valid(reference) or type(reference.Font.Size)~='number' then self:Clear();return end
        local font=reference.Font
        local scale=reference.RenderTransform and reference.RenderTransform.Scale and reference.RenderTransform.Scale.Y or 1
        if type(scale)~='number' or scale<=0 or scale>=math.huge then scale=1 end
        local displaySize=math.max(1,math.floor(font.Size*scale+.5));local height=math.ceil(displaySize*1.2)
        local style=displaySize..':'..tostring(font.TypefaceFontName)..':'..tostring(font.LetterSpacing)
        if self.label and self.label.style~=style then self:Clear() end
        self.world.escRoleNoticeY=height+8
        if self.world.notice and live(self.G,self.world.notice.hud) and valid(self.world.notice.text) then self.world.notice.text.Slot:SetPosition({X=0,Y=self.world.escRoleNoticeY}) end
        if not self.label then
            local canvas=hud.WidgetTree.RootWidget
            local lib=self.G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
            local cls=self.G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C')
            if not valid(canvas) or not valid(lib) or not valid(cls) then return end
            local host=lib:Create(hud,cls,nil);local label=host.t_text
            assert(valid(label),'role_label_unavailable')
            self.label={hud=hud,hudName=hudName,host=host,text=label,style=style}
            label:RemoveFromParent();label:SetVisibility(4)
            -- As in the proven framework widgets, set reflected font fields
            -- before attachment so initial Slate construction sees the style.
            local target=label.Font
            target.FontObject=font.FontObject;target.TypefaceFontName=font.TypefaceFontName
            target.Size=displaySize;target.LetterSpacing=font.LetterSpacing or 0
            label:SetShadowOffset({X=2,Y=2});label:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
            local slot=canvas:AddChildToCanvas(label)
            slot:SetAnchors({Minimum={X=.5,Y=0},Maximum={X=.5,Y=0}})
            slot:SetAlignment({X=.5,Y=0});slot:SetPosition({X=0,Y=2})
            slot:SetSize({X=1000,Y=height});slot:SetZOrder(101);label:SetJustification(1)
        end
        registry[hudName]=self
        local target=self.label.text.Font
        target.FontObject=font.FontObject;target.TypefaceFontName=font.TypefaceFontName
        target.Size=displaySize;target.LetterSpacing=font.LetterSpacing or 0
        self.label.text.Slot:SetSize({X=1000,Y=height})
        if self.label.value~=text then self.label.text:SetText(self.G.FText(text));self.label.value=text end
    end)
    if not ok then
        self:Clear()
        if not self.failed then self.failed=true;if self.log then self.log('Esc role label unavailable: '..tostring(why)) end end
    end
    return ok
end
return L
