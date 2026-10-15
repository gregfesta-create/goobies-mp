-- D51 (revised, user 2026-10-14): in a multiplayer run a client leaves with Esc > End Run and lands on the game's own
-- end screen (WBP_DeathScreen). There its Retry button reads "Rejoin" and takes it back into the host's current run;
-- Quit goes to the menu, from where it can rejoin through the lobby. Only for a client in an active multiplayer
-- session: single player (Play) keeps the game's own Retry exactly as it is.
-- The label goes through the game button's own UpdateButtonText(Text) event (WBP_Button: it sets ButtonText and then
-- whichever label the button shows, plain or rich text), so the button's RichTextBox flag and its hidden placeholder
-- label are never touched (writing t_text directly is what showed the placeholder "Bingos", test.2).
--   S.new{G, active() -> bool, log, mode = 'host' (disable Retry instead, Coder C)}; s:Tick(now) -> true when a NEW end screen came up (Coder C: the app holds the
--   session for a client whose own end screen came up after it died)
local S = {}; S.__index = S
S.CLASS = 'WBP_DeathScreen_C'
S.REJOIN = 'Rejoin'
S.SCAN_SECONDS = 0.25
local function valid(o) return o ~= nil and o:IsValid() == true end
local function callable(v)
    local t = type(v)
    if t == 'function' or t == 'userdata' then return true end
    local mt = t == 'table' and getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end
function S.new(o)
    assert(type(o) == 'table' and o.G and type(o.active) == 'function', 'end screen bindings required')
    return setmetatable({ o = o, G = o.G, done = {} }, S)
end
function S:_log(line) if self.o.log then pcall(self.o.log, 'ENDSCREEN ' .. line) end end
function S:Tick(now)
    if not self.o.active() then return end
    now = now or 0
    if self.scanAt and now - self.scanAt < S.SCAN_SECONDS then return false end
    self.scanAt = now
    local fresh = false
    local ok, why = pcall(function()
        if type(self.G.FindAllOf) ~= 'function' then return end
        for _, screen in ipairs(self.G.FindAllOf(S.CLASS) or {}) do
            if valid(screen) and screen:IsInViewport() == true then
                local name = screen:GetFullName()
                if not self.done[name] then
                    fresh = true
                    local retry = screen.retry
                    if self.o.mode == 'host' then
                        -- Coder C (host death): the host's Retry would restart the run under the others: disabled
                        if valid(retry) and callable(retry.SetIsEnabled) then
                            retry:SetIsEnabled(false); self.done[name] = true
                            self:_log('Retry disabled (the host on the game death screen in a multiplayer run)')
                        end
                    elseif valid(retry) and callable(retry.UpdateButtonText) then
                        retry:UpdateButtonText(self.G.FText(S.REJOIN))
                        self.done[name] = true
                        self:_log('Retry reads Rejoin (client in a multiplayer run)')
                    end
                end
            end
        end
    end)
    if not ok and not self.failed then self.failed = true; self:_log('relabel unavailable: ' .. tostring(why):sub(1, 200)) end
    return fresh
end
-- The game's main menu is up (the end screen's Quit went to the menu).
function S.MainMenuVisible(G)
    local ok, found = pcall(function()
        for _, menu in ipairs(G.FindAllOf('WBP_MainMenu_C') or {}) do
            if menu:IsValid() and menu:IsInViewport() then return true end
        end
        return false
    end)
    return ok and found == true
end
return S
