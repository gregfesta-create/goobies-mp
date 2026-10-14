-- D45/D46 (Coder C; research/RESEARCH_PICKUPS.md 5): the client's mirror of the team level. Client role only, never
-- raises. The host's level is the team level (gmp_xp_host.lua); the client never levels on its own:
--   * fence: its own BPC_CheckingForXP tick stays off (the game turns it on at BeginPlay, so this is checked every
--     tick), its own XP orb instances are cleared, and its XP_Target is held at GUARD_TARGET whenever no picker is
--     open, so a stray local AddExperience can never reach a level-up;
--   * local XP: cleared orbs plus any TotalXPPickedUp growth this module did not cause (dissolve AddXPDelay, bonus
--     orbs) are reported to the host as PICKUP_LOCAL_XP (D46: credited to the team, bounded by the host);
--   * bar: the host's XP_STATE is drawn with the game's own HUD.XPBar:UpdateBar(target, current);
--   * level-ups: for each open REWARD_SCREEN of kind levelup (id = the team level) the client triggers one real
--     level-up on its own pawn (XP_Current 0, XP_Target 1, AddExperience(1)): the game's own block runs (Level+1, its
--     own cards, SetLuck, AddUpgrades, SpawnArtifacts). Done for level L once (Level - open pickers) >= L. A catch-up
--     screen levels up to the team level. Past the host's deadline (or once the host closed a screen) the client
--     auto-picks a card. A ghost (or dead player) skips with picked 0 and reports its level after reviving (D46).
--   X.new{game=<adapter>, log=fn, ghost=function(ctx, session) -> bool}; x:Tick(ctx, session, now, inbox)
local Wire = require('gmp_pickups_wire')
local Host = require('gmp_xp_host')
local X = {}; X.__index = X
X.GUARD_TARGET = 100000.0      -- the game's own clamp maximum for XP_Target
X.TRIGGERS_PER_TICK = 10
X.AUTO_PICK_SECONDS = 0.3
X.DONE_RESEND_SECONDS = 3
X.LOCAL_XP_SECONDS = 2
X.LEVEL_REPORT_SECONDS = 5
X.BAR_SECONDS = 1
X.PRESENT_TIMEOUT_SECONDS = 5   -- a reward screen that never opened counts as done after this long
X.REWARD_KINDS = { loot = true, bush = true, roulette = true, reward = true }
X.BONUS_REPUBLISH_SECONDS = 5

local function defaultGhost(_, session)
    local ok, ghost = pcall(function()
        local state = session.LivesState and session:LivesState()
        local me = session.Me and session:Me()
        if type(state) ~= 'table' or type(me) ~= 'table' or type(state.ghosts) ~= 'table' then return false end
        for _, g in ipairs(state.ghosts) do if g.slot == me.slot then return true end end
        return false
    end)
    return ok and ghost == true
end

function X.new(options)
    options = options or {}
    return setmetatable({ game = options.game or X.Game.new({ G = options.G, autoPickOther = options.autoPickOther }), log = options.log,
        ghost = options.ghost or defaultGhost,
        screens = {}, logged = {}, sequence = 0, pending = 0, expected = 0 }, X)
end
function X:_log(fmt, ...)
    if not self.log then return end
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function X:_once(key, fmt, ...)
    if self.logged[key] then return end
    self.logged[key] = true; self:_log(fmt, ...)
end
function X:_send(session, typ, f)
    if not Wire.Validate[typ](f) then return false end
    local ok, sent = pcall(session.SendPickups, session, typ, f)
    return ok and sent == true
end
function X:_call(name, ...)
    local fn = self.game[name]
    if type(fn) ~= 'function' then return nil end
    local ok, a, b = pcall(fn, self.game, ...)
    if not ok then self:_once('game:' .. name .. tostring(a), 'XPSYNC client %s failed: %s', name, tostring(a):sub(1, 160)); return nil end
    return a, b
end
function X:_reset(ctx)
    self.contextKey = ctx.key
    self.screens, self.mirror, self.drawnRevision, self.drawAt = {}, nil, nil, nil
    self.lastTotal, self.expected, self.pending, self.reportAt, self.levelReportAt, self.wasGhost = nil, 0, 0, nil, nil, nil
end
function X:_inbox(ctx, inbox, now)
    for _, item in ipairs(inbox or {}) do
        if item.type == 'XP_STATE' then
            local m = Wire.Validate.XP_STATE(item.f)
            if m and m.context == ctx.key and (not self.mirror or m.revision > self.mirror.revision) then self.mirror = m end
        elseif item.type == 'REWARD_SCREEN' then
            local m = Wire.Validate.REWARD_SCREEN(item.f)
            if m and m.context == ctx.key then
                local s = self.screens[m.id]
                if not s then
                    if m.phase ~= 'closed' then
                        s = { id = m.id, kind = m.kind, count = m.count, rarity = m.rarity, text = m.text }
                        self.screens[m.id] = s
                        self:_log('XPSYNC client screen id=%d kind=%s count=%d', m.id, m.kind, m.count)
                    end
                end
                if s then
                    if m.phase == 'closed' then s.closed = true
                    elseif m.phase == 'deadline' then s.deadlineAt = now + m.remainMs / 1000 end
                end
            end
        end
    end
end
-- The level this client must reach for its open screens.
function X:_wanted(state)
    local want = state.level
    for id, s in pairs(self.screens) do
        if not s.closed and not s.skipped then
            if s.kind == 'catchup' then
                local target = self.mirror and self.mirror.level or (state.level + s.count)
                if target > want then want = target end
            elseif s.kind == 'levelup' and id > want then want = id end
        end
    end
    return want
end
function X:_satisfied(s, state, now)
    if X.REWARD_KINDS[s.kind] then
        if not s.presentedAt then return false end
        if state.open > 0 then return false end
        return s.sawOpen == true or now - s.presentedAt >= X.PRESENT_TIMEOUT_SECONDS
    end
    if s.kind == 'catchup' then
        return state.open == 0 and (not self.mirror or state.level >= self.mirror.level)
    end
    return state.level - state.open >= s.id
end
function X:Tick(ctx, session, now, inbox)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        if ctx.key ~= self.contextKey then self:_reset(ctx) end
        self:_inbox(ctx, inbox, now)
        local state, why = self:_call('Read', ctx)
        if type(state) ~= 'table' then return self:_once('read:' .. tostring(why), 'XPSYNC client pawn unreadable reason=%s', tostring(why)) end
        self:_call('Fence', ctx)
        -- local XP the client produced itself: cleared orbs and TotalXPPickedUp growth not caused here
        local cleared = self:_call('ClearLocalOrbs', ctx)
        if math.type(cleared) == 'integer' and cleared > 0 then self.pending = self.pending + cleared end
        if type(state.total) == 'number' then
            if self.lastTotal then
                local unexpected = math.floor(state.total - self.lastTotal - self.expected + 0.5)
                if unexpected > 0 then self.pending = self.pending + unexpected end
            end
            self.lastTotal, self.expected = state.total, 0
        end
        if self.pending > 0 and (not self.reportAt or now - self.reportAt >= X.LOCAL_XP_SECONDS) then
            local amount = math.min(self.pending, Wire.MAX_LOCAL_XP)
            local f = { context = ctx.key, sequence = self.sequence + 1, amount = amount }
            if self:_send(session, 'PICKUP_LOCAL_XP', f) then
                self.sequence, self.pending, self.reportAt = f.sequence, self.pending - amount, now
                self:_log('XPSYNC client local xp reported amount=%d', amount)
            end
        end
        -- D46: the client's own XP gain bonus, shared on the host
        if type(state.multiplier) == 'number' and (self.bonusSent ~= state.multiplier or not self.bonusAt
            or now - self.bonusAt >= X.BONUS_REPUBLISH_SECONDS) then
            self.bonusRevision = (self.bonusRevision or 0) + 1
            if self:_send(session, 'XP_BONUS', { context = ctx.key, revision = self.bonusRevision, multiplier = Host.Number(state.multiplier) }) then
                self.bonusSent, self.bonusAt = state.multiplier, now
            end
        end
        local ghost = state.dead == true or self.ghost(ctx, session) == true
        if ghost then
            for id, s in pairs(self.screens) do
                if not s.closed and not s.doneSent and not s.skipped then
                    if self:_send(session, 'REWARD_DONE', { context = ctx.key, id = id, picked = 0 }) then s.skipped = true end
                end
            end
        else
            local want, level, n = self:_wanted(state), state.level, 0
            while level < want and n < X.TRIGGERS_PER_TICK do
                local after = self:_call('TriggerLevelUp', ctx)
                n = n + 1
                self.expected = self.expected + 1
                if math.type(after) ~= 'integer' or after <= level then
                    self:_once('trigger', 'XPSYNC client level-up trigger had no effect level=%d', level); break
                end
                level = after
            end
            if n > 0 then self:_log('XPSYNC client level-ups triggered=%d level=%d', n, level) end
            -- D46 reward screens (loot, bush, roulette): presented once through the client's own game
            for id, s in pairs(self.screens) do
                if X.REWARD_KINDS[s.kind] and not s.closed and not s.presentedAt then
                    s.presentedAt = now
                    local presented, pwhy = self:_call('Present', ctx, s.kind, s.text ~= '' and s.text or nil, s.rarity)
                    self:_log('XPSYNC client reward screen id=%d kind=%s presented=%s %s', id, s.kind, tostring(presented == true), tostring(pwhy or ''))
                elseif X.REWARD_KINDS[s.kind] and s.presentedAt and state.open > 0 then
                    s.sawOpen = true
                end
            end
        end
        -- done, auto-pick, cleanup
        local owedExpired = false
        for id, s in pairs(self.screens) do
            if not s.skipped and not ghost then
                local satisfied = self:_satisfied(s, state, now)
                if satisfied and (not s.doneSent or (not s.closed and now - s.doneSent >= X.DONE_RESEND_SECONDS)) then
                    local picked = s.kind == 'catchup' and s.count or 1
                    if self:_send(session, 'REWARD_DONE', { context = ctx.key, id = id, picked = picked }) then s.doneSent = now end
                end
                if not satisfied and (s.closed or (s.deadlineAt and now >= s.deadlineAt)) then owedExpired = true end
                if s.closed and satisfied then self.screens[id] = nil end
            elseif s.closed then self.screens[id] = nil end
        end
        if owedExpired and state.open > 0 and (not self.pickAt or now - self.pickAt >= X.AUTO_PICK_SECONDS) then
            self.pickAt = now
            local picked, pwhy = self:_call('AutoPick', ctx)
            self:_log('XPSYNC client auto-pick ok=%s reason=%s', tostring(picked == true), tostring(pwhy or ''))
        end
        -- guard and bar (never while a picker is open: the game's own level-up target and bar belong to it then)
        if state.open == 0 then
            self:_call('Guard', ctx)
            local m = self.mirror
            if m and (self.drawnRevision ~= m.revision or not self.drawAt or now - self.drawAt >= X.BAR_SECONDS) then
                if self:_call('DrawBar', ctx, m.target, m.current) then self.drawnRevision, self.drawAt = m.revision, now end
            end
        end
        -- level report: after reviving, or while behind the team level with nothing open
        local revived = self.wasGhost == true and not ghost
        self.wasGhost = ghost
        local behind = self.mirror and state.level < self.mirror.level and next(self.screens) == nil and not ghost
        if revived or (behind and (not self.levelReportAt or now - self.levelReportAt >= X.LEVEL_REPORT_SECONDS)) then
            if self:_send(session, 'REWARD_DONE', { context = ctx.key, id = 0, picked = state.level }) then
                self.levelReportAt = now
                self:_log('XPSYNC client level report level=%d team=%s', state.level, tostring(self.mirror and self.mirror.level))
            end
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'XPSYNC client tick error %s', tostring(err):sub(1, 200)) end
end

------------------------------------------------------------------ the real client pawn
local Game = setmetatable({}, { __index = Host.Game }); Game.__index = Game; X.Game = Game
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
function Game:Read(ctx)
    local pawn, why = self:_pawn(ctx)
    if not pawn then return nil, why end
    local level = pawn.Level
    if math.type(level) ~= 'integer' then level = math.tointeger(level) end
    if not level then return nil, 'xp_fields' end
    local open = (pawn['PresentTime?'] == true and 1 or 0) + Host.Len(pawn.PresentQueue)
    local total = pawn.TotalXPPickedUp
    local multiplier = pawn['XP Multiplier']
    return { level = level, open = open, total = type(total) == 'number' and total or nil, dead = pawn.PlayerIsDead == true,
        multiplier = type(multiplier) == 'number' and multiplier or nil }
end
function Game:Fence(ctx)
    local pawn = self:_pawn(ctx)
    local checker = pawn and pawn.BPC_CheckingForXP
    if not checker then return false end
    if checker:IsComponentTickEnabled() == true then checker:SetComponentTickEnabled(false) end
    return true
end
function Game:ClearLocalOrbs(ctx)
    local pawn = self:_pawn(ctx)
    local controller = pawn and pawn.EnemyController
    if not controller or controller:IsValid() ~= true then return 0 end
    local component = controller.XPInstanceComponent
    if not component or component:IsValid() ~= true then return 0 end
    local n = math.tointeger(component:GetInstanceCount()) or 0
    if n > 0 then component:ClearInstances() end
    return n
end
local function open(pawn) return (pawn['PresentTime?'] == true and 1 or 0) + Host.Len(pawn.PresentQueue) end
function Game:Guard(ctx)
    local pawn = self:_pawn(ctx)
    if not pawn or open(pawn) > 0 then return false end
    if pawn.XP_Target ~= X.GUARD_TARGET then pawn.XP_Target = X.GUARD_TARGET end
    return true
end
function Game:DrawBar(ctx, target, current)
    local pawn = self:_pawn(ctx)
    local hud = pawn and pawn.HUD
    local bar = hud and hud.XPBar
    if not bar then return false end
    bar:UpdateBar(target, current)
    return true
end
-- One real level-up through the game's own AddExperience (research/RESEARCH_PICKUPS.md 5.3) -> the Level after.
function Game:TriggerLevelUp(ctx)
    local pawn = self:_pawn(ctx)
    if not pawn then return nil end
    pawn.XP_Current = 0.0
    pawn.XP_Target = 1.0
    pawn:AddExperience(1)
    return math.tointeger(pawn.Level)
end
return X
