-- Development launch convenience: use normal menu callbacks once, never OpenLevel directly.
local A={};A.__index=A
local prefix='/Game/UI/WBP_MainMenu.WBP_MainMenu_C:'
local play='BndEvt__WBP_MainMenu_play_K2Node_ComponentBoundEvent_2_Click__DelegateSignature'
local start='BndEvt__WBP_MainMenu_char_play_K2Node_ComponentBoundEvent_3_Click__DelegateSignature'
local function valid(o) return o and o:IsValid()==true end
-- options.splashOnly (W3, SPLASH_SKIP_ONLY): a per-instance option, passed only by the boot dev driver in gmp_app.lua.
-- That instance dismisses the company splash and never presses Play; the lobby's MP-entry driver gets no option.
-- options.hideArtifactSelector (checklist row 23): a client's MP entry collapses the menu's artifact selection page
-- (WBP_ArtifactSelector, opened by Play) before and after start, so it never shows while the island loads; the
-- host's W11 artifact set is already in the native selection.
function A.new(G,log,options)
    return setmetatable({G=G,log=log,phase='wait',splashOnly=type(options)=='table' and options.splashOnly==true or nil,
        hideArtifacts=type(options)=='table' and options.hideArtifactSelector==true or nil},A)
end
function A:_hideArtifacts(menu)
    if not self.hideArtifacts then return end
    local ok=pcall(function() menu.WBP_ArtifactSelector:SetVisibility(1) end)   -- 1 = Collapsed
    if not self.hideLogged then self.hideLogged=true;self.log('DEVAUTOSTART artifact selection page hidden (client entry): '..tostring(ok)) end
end
function A:_skipSplash()
    if self.splashAttempted then return end
    for _,widget in ipairs(self.G.FindAllOf('WBP_SplashScreen_C') or {}) do
        if valid(widget) and widget:IsInViewport()==true and widget['IsDead?']==false then
            -- Inspected company-logo Blueprint: its AnyKey callback enters
            -- this graph at 176, marks IsDead, stops animation, broadcasts Dead
            -- to the menu and removes the widget. Calling that same path avoids
            -- merely hiding the logo while leaving the menu startup gate active.
            self.splashAttempted=true
            widget:ExecuteUbergraph_WBP_SplashScreen(176)
            self.log('DEVAUTOSTART dismissed company splash via normal key-dismiss path')
            if self.splashOnly then self.phase='done';self.log('DEVAUTOSTART splash dismissed (splash_only)') end
            return
        end
    end
end
function A:Tick(now,allowed)
    if self.phase~='done' and now<=30 then
        local ok,why=pcall(self._skipSplash,self)
        if not ok then self.splashAttempted=true;self.log('DEVAUTOSTART splash skip failed: '..tostring(why):sub(1,800)) end
    end
    -- splashOnly: no Play, and no menu-readiness timeout once the window closes without a splash.
    if self.splashOnly then if self.phase~='done' and now>30 then self.phase='done' end;return end
    if self.phase=='done' or now<3 then return end
    if now>30 then self.phase='done';self.log('DEVAUTOSTART stopped: menu readiness timeout');return end
    if allowed==false then return end
    local ok,why=pcall(function()
        local menus={}
        for _,menu in ipairs(self.G.FindAllOf('WBP_MainMenu_C') or {}) do
            if valid(menu) and menu:IsInViewport()==true then
                local visibility=menu:GetVisibility()
                if (visibility==0 or visibility==3 or visibility==4) and valid(menu.BP_Menu) and valid(menu.WBP_ArtifactSelector) then menus[#menus+1]=menu end
            end
        end
        if #menus~=1 then return end
        local menu=menus[1];local callback=self.phase=='wait' and play or start
        if self.phase=='start' and (not valid(menu.char_play) or menu.char_play:GetIsEnabled()~=true) then return end
        local fn=self.G.StaticFindObject(prefix..callback);assert(valid(fn),'missing_menu_callback')
        local names={};fn:ForEachProperty(function(p)
            local name=p:GetFName():ToString();if name~='ReturnValue' then names[#names+1]=name end
        end)
        assert(#names==1 and names[1]=='SetFocus?','unsupported_menu_callback_signature')
        -- Mark before invocation: an exception after level loading starts cannot retry.
        self.phase=self.phase=='wait' and 'start' or 'done'
        if callback==start then self:_hideArtifacts(menu) end
        menu[callback](menu,false)
        self:_hideArtifacts(menu)
        self.log('DEVAUTOSTART invoked '..callback)
    end)
    if not ok then self.phase='done';self.log('DEVAUTOSTART stopped: '..tostring(why):sub(1,800)) end
end
return A
