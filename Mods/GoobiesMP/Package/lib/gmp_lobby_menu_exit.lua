-- W10 menu exit (PLAN_WORLD_ENTRY.md section 4): leave a run through the game's own handlers. There is no direct
-- OpenLevel by design (gmp_dev_autostart.lua:1, gmp_lobby_runtime.lua "No direct OpenLevel").
-- Route 1: the HUD's End Run confirm path, WBP_HUD ubergraph entry 4441 (CustomEvent_0 <- the quit dialog's
--   Clicked_Yes): BP_EnemyController "Add All Enemy Stats" then the game's own OpenLevel(Menu)
--   (evidence lobby_departure_static_20261011/WBP_HUD.txt:297-299; the same call as gmp_lobby_native_departure ExitToMenu).
--   Needs the local pawn's HUD in the viewport and the one-parameter (EntryPoint) signature.
-- Route 2 (fallback, no usable HUD): the pawn's Death(true) event, then the death screen's own Quit handler
--   (WBP_DeathScreen_C "quit" WBP_Button_C, evidence deathscreen_probe_20261012). The handler's bound-event name is
--   resolved by exact name over the game's naming pattern and signature-checked; if it cannot be resolved within
--   QUIT_SECONDS the exit fails visibly and the player presses Quit.
-- No pawn: the player is already at the menu.
-- Logs: "MENUEXIT <route> reason=<why>", "MENUEXIT failed reason=<why>".
local E = {}; E.__index = E
E.HUD_GRAPH = '/Game/UI/WBP_HUD.WBP_HUD_C:ExecuteUbergraph_WBP_HUD'
E.HUD_ENTRY = 4441
E.QUIT_SECONDS = 10
local DEATH_PREFIX = '/Game/UI/WBP_DeathScreen.WBP_DeathScreen_C:'
-- Candidate bound-event names (the main menu uses ..._K2Node_ComponentBoundEvent_<n>_Click__DelegateSignature).
local function quitCandidates()
    local out = {}
    for n = 0, 15 do
        out[#out + 1] = 'BndEvt__WBP_DeathScreen_quit_K2Node_ComponentBoundEvent_' .. n .. '_Click__DelegateSignature'
    end
    return out
end
local function valid(o) return o ~= nil and o:IsValid() == true end
-- Blueprint compiler locals of an ubergraph (the "L:" entries of a graph dump): properties of the same UFunction.
local LOCAL_PREFIXES = { 'CallFunc_', 'Temp_', 'K2Node_' }
local function compilerLocal(name)
    for _, prefix in ipairs(LOCAL_PREFIXES) do if name:sub(1, #prefix) == prefix then return true end end
    return false
end
-- A Blueprint event on a UObject: UE4SS exposes UFunctions as callable userdata (never type 'function'), so any
-- callable value counts (R1 attempt 3: BP_Player.Death(DeathBySelf), BP_Player.txt 425-436).
function E.Callable(v)
    local t = type(v)
    if t == 'function' or t == 'userdata' then return true end
    local mt = t == 'table' and getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end
-- An ubergraph's signature: EntryPoint first (its only parameter), then nothing but compiler locals.
-- Evidence lobby_departure_static_20261011/WBP_HUD.txt lists 200+ CallFunc_/Temp_/K2Node_ locals after EntryPoint.
function E.UbergraphSignature(names)
    if type(names) ~= 'table' or names[1] ~= 'EntryPoint' then return false end
    for i = 2, #names do if not compilerLocal(names[i]) then return false end end
    return true
end
local function params(fn)
    local names = {}
    fn:ForEachProperty(function(p) local name = p:GetFName():ToString(); if name ~= 'ReturnValue' then names[#names + 1] = name end end)
    return names
end

function E.new(options)
    assert(type(options) == 'table' and options.G and type(options.world) == 'function', 'menu exit needs G and a world')
    return setmetatable({ o = options, G = options.G, phase = 'idle' }, E)
end
function E:_log(line) if self.o.log then self.o.log(line) end end
function E:Request(reason, now)
    if self.phase ~= 'idle' then return false, 'menu_exit_' .. self.phase end
    self.reason, self.phase, self.at = tostring(reason), 'pending', now or 0
    return true
end
function E:_finish(route)
    self.phase, self.route = 'done', route
    self:_log('MENUEXIT ' .. route .. ' reason=' .. self.reason)
end
function E:_fail(why)
    self.phase, self.reason = 'failed', why
    self:_log('MENUEXIT failed reason=' .. why)
end
-- Route 1. Returns true, or false and why it was skipped (logged once per exit, R1 attempt 3).
function E:_hudExit(pawn)
    local hud = pawn.HUD
    if not valid(hud) then return false, 'no_hud' end
    if hud:IsInViewport() ~= true then return false, 'hud_not_in_viewport' end
    local fn = self.G.StaticFindObject(E.HUD_GRAPH)
    if not valid(fn) then return false, 'hud_graph_missing' end
    local names = params(fn)
    if not E.UbergraphSignature(names) then return false, 'hud_graph_signature:' .. table.concat(names, ','):sub(1, 120) end
    hud:ExecuteUbergraph_WBP_HUD(E.HUD_ENTRY)
    return true
end
function E:_deathQuit()
    for _, screen in ipairs(self.G.FindAllOf('WBP_DeathScreen_C') or {}) do
        if valid(screen) and screen:IsInViewport() == true then
            for _, name in ipairs(quitCandidates()) do
                local fn = self.G.StaticFindObject(DEATH_PREFIX .. name)
                if valid(fn) then
                    local names = params(fn)
                    if #names == 0 then screen[name](screen); return true end
                    if #names == 1 and names[1] == 'SetFocus?' then screen[name](screen, false); return true end
                end
            end
        end
    end
    return false
end
function E:Tick(now)
    if self.phase ~= 'pending' and self.phase ~= 'death_wait' then return end
    now = now or 0
    local ok, why = pcall(function()
        local world = self.o.world()
        local pawn = world and select(2, world:LocalWorldPawn())
        if self.phase == 'pending' then
            if not valid(pawn) then return self:_finish('already_at_menu') end
            local exited, skipped = self:_hudExit(pawn)
            if exited then return self:_finish('hud_end_run') end
            self:_log('MENUEXIT route1 skipped reason=' .. tostring(skipped))
            if not E.Callable(pawn.Death) then return self:_fail('no_death_event') end
            self.phase, self.deathAt = 'death_wait', now
            pawn:Death(true)
            return
        end
        if self:_deathQuit() then return self:_finish('death_quit') end
        if now - self.deathAt >= E.QUIT_SECONDS then self:_fail('death_screen_quit_unresolved') end
    end)
    if not ok then self:_fail('menu_exit_error:' .. tostring(why):sub(1, 200)) end
end
return E
