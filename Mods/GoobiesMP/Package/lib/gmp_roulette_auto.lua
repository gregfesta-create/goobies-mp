-- D44 roulette auto-click: one step of the open roulette per call, run by the shared reward barrier's auto-pick after
-- the deadline (gmp_xp_host/gmp_xp_client Game:AutoPick -> options.autoPickOther; gmp_pickups_sync SetAutoPickOther).
-- Static facts (evidence/roulette_static_20261013): WBP_RouletteItems and WBP_RouletteStats are one wheel button with
-- a FlipFlop. While FlipFlop is false the wheel spins; SpineDone_Event() (Items) / SpinIsDone() (Stats) stop it
-- exactly like the first click. Once FlipFlop is true the second click grants the prize and closes the screen; that
-- step exists only in the wheel button's bound handler, called directly here: the button guard's one named click-hook
-- exemption (tools/button_guard.lua NAMED_CLICK, coordinator-approved 2026-10-13 for the user's D44 auto-click
-- request). No hook, no button construction, no styling. Only a roulette in the viewport is touched, through a fresh
-- handle (FindAllOf at the time of the step; the auto-pick runs at most every few seconds).
--   Auto.Step(G) -> true, 'spin'|'accept' | false, reason       Auto.Plugin(G) -> fn(pawn) -> bool
local Auto = {}
Auto.CLASSES = { 'WBP_RouletteItems_C', 'WBP_RouletteStats_C' }
Auto.SPIN = { WBP_RouletteItems_C = 'SpineDone_Event', WBP_RouletteStats_C = 'SpinIsDone' }
local function open(G)
    if type(G) ~= 'table' or type(G.FindAllOf) ~= 'function' then return nil end
    for _, class in ipairs(Auto.CLASSES) do
        local ok, list = pcall(G.FindAllOf, class)
        if ok and type(list) == 'table' then
            for _, w in ipairs(list) do
                local okShown, shown = pcall(function() return w:IsValid() == true and w:IsInViewport() == true end)
                if okShown and shown then return w, class end
            end
        end
    end
    return nil
end
function Auto.Step(G)
    local w, class = open(G)
    if not w then return false, 'no_roulette' end
    local ok, flip = pcall(function() return w.FlipFlop end)
    if not ok then return false, 'roulette_unreadable' end
    if flip == true then
        local done, why = pcall(function() w:BndEvt__WBP_Wheels_Button_1_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() end)
        if not done then return false, 'accept_failed:' .. tostring(why):sub(1, 120) end
        return true, 'accept'
    end
    local spin = Auto.SPIN[class]
    local done, why = pcall(function() w[spin](w) end)
    if not done then return false, 'spin_failed:' .. tostring(why):sub(1, 120) end
    return true, 'spin'
end
function Auto.Plugin(G)
    return function() local ok = Auto.Step(G); return ok == true end
end
return Auto
