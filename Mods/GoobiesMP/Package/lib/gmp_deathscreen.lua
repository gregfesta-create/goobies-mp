-- W9 client side (PLAN_WORLD_ENTRY.md section 4; D23, D31): the host-credited client end screen.
-- 1. RUN_STATS parts (S8a paging) are reassembled with Messages.RunStatsReceive for the client's run generation.
-- 2. A complete set makes the client invoke its own BP_Player Death event once (the client is invulnerable, so the end
--    screen has to be triggered): the game creates WBP_DeathScreen and calls its GenerateSCore
--    (evidence lobby_departure_static_20261011/BP_Player.txt 5894-6007). The death sequence may write the normal save (D31/D34).
-- 3. A post-hook on WBP_DeathScreen_C:GenerateSCore writes the host-credited kills and damage of the client's own row
--    into the screen's `kills` and `totaldmg` text blocks (widget names from deathscreen_probe_20261012). The weapon pie is
--    left to the game for now (its feed function is not yet known).
-- A set that arrives after the screen was built updates it; after the screen is gone it is logged.
-- Logs: "DEATHSCREEN ...".
local Messages = require('gmp_messages')
local Liveness = require('gmp_run_sync_liveness')
local D = {}; D.__index = D
D.GENERATE = '/Game/UI/WBP_DeathScreen.WBP_DeathScreen_C:GenerateSCore'
local function valid(o) return o ~= nil and o:IsValid() == true end
local function grouped(n)
    local s = tostring(math.tointeger(n) or n)
    local sign, digits = s:match('^(%-?)(%d+)$')
    if not digits then return s end
    return sign .. digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

-- o: G (RegisterHook, FText), world() -> island world (LocalWorldPawn), slot() -> own slot, generation() -> this run's
-- runGeneration, log(line)
function D.new(o)
    assert(type(o) == 'table' and o.G and type(o.world) == 'function' and type(o.slot) == 'function'
        and type(o.generation) == 'function', 'end screen bindings required')
    return setmetatable({ o = o, G = o.G, state = {} }, D)
end
function D:_log(line) if self.o.log then self.o.log('DEATHSCREEN ' .. line) end end
function D:Install()
    if self.installed or type(self.G.RegisterHook) ~= 'function' then return self.installed == true end
    self.G.RegisterHook(D.GENERATE, function() end, function(ctx)
        local ok, why = pcall(self._afterGenerate, self, ctx and ctx:get())
        if not ok then self:_log('post-hook failed: ' .. tostring(why):sub(1, 200)) end
    end)
    self.installed = true
    return true
end
function D:_row()
    if not self.stats then return nil end
    local slot = self.o.slot()
    for _, row in ipairs(self.stats.rows) do if row.slot == slot then return row end end
    return nil, slot
end
local function setText(G, screen, name, value)
    local widget = screen[name]
    if not valid(widget) and screen.WidgetTree and type(G.FName) == 'function' then
        local ok, found = pcall(function() return screen.WidgetTree:FindWidget(G.FName(name)) end)
        if ok then widget = found end
    end
    if not valid(widget) then return false end
    widget:SetText(G.FText(value))
    return true
end
function D:_apply(screen)
    local row, slot = self:_row()
    if not row then self:_log('no row for slot=' .. tostring(slot)); return false end
    local kills = setText(self.G, screen, 'kills', grouped(row.kills))
    local damage = setText(self.G, screen, 'totaldmg', grouped(row.damage))
    if not (kills and damage) then self:_log('text blocks missing kills=' .. tostring(kills) .. ' totaldmg=' .. tostring(damage)); return false end
    self:_log(string.format('host-credited slot=%d kills=%d damage=%d', row.slot, row.kills, row.damage))
    return true
end
function D:_afterGenerate(screen)
    if not self.stats or not valid(screen) then return end   -- a vanilla death screen is left alone
    self.screen = screen
    self:_apply(screen)
end
-- One RUN_STATS part. Returns nil while incomplete, true when a complete set was taken, or false, reason.
function D:Receive(f)
    local done, value = Messages.RunStatsReceive(self.state, f, self.o.generation())
    if done == nil then return nil end
    if done == false then self:_log('run stats refused: ' .. tostring(value)); return false, value end
    self.stats = value
    self:_log(string.format('run stats complete runGeneration=%d rows=%d', value.runGeneration, #value.rows))
    if self.screen then
        local live = Liveness.Listed(self.G, self.screen, 'WBP_DeathScreen_C')
        if live and valid(live) then self.screen = live; self:_log('late stats applied'); self:_apply(live)
        else
            local row, slot = self:_row()
            if row then self:_log(string.format('late stats logged slot=%d kills=%d damage=%d', row.slot, row.kills, row.damage))
            else self:_log('late stats logged: no row for slot=' .. tostring(slot)) end
        end
    elseif not self.died then self.pendingDeath = true end
    return true
end
-- Invoke the client's own Death event once a complete set is waiting.
function D:Tick()
    if not self.pendingDeath or self.died then return end
    self.pendingDeath = nil
    local world = self.o.world()
    local pawn = world and select(2, world:LocalWorldPawn())
    if not valid(pawn) or not require('gmp_lobby_menu_exit').Callable(pawn.Death) then
        local row, slot = self:_row()
        self:_log(row and string.format('no pawn; stats logged slot=%d kills=%d damage=%d', row.slot, row.kills, row.damage)
            or ('no pawn; no row for slot=' .. tostring(slot)))
        return
    end
    self.died = true
    pawn:Death(false)
    self:_log('death event invoked')
end
-- True while the end screen this controller filled is still shown. The cached screen is trusted only when it is
-- still among the live WBP_DeathScreen_C objects (a level change frees it; UE4SS IsValid cannot vouch for that).
function D:Showing()
    local live = self.screen and Liveness.Listed(self.G, self.screen, 'WBP_DeathScreen_C')
    return live ~= nil and valid(live)
end
return D
