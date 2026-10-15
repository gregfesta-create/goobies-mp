-- D45/D46 (Coder C; research/RESEARCH_PICKUPS.md 5): the team level on the host. Host role only, never raises.
-- The host pawn's own native XP and level ARE the team's (fed by its own pickups and the clients' collected clumps,
-- gmp_pickups_host.lua). This module:
--   * publishes XP_STATE {level, current, target} to every connected client: at once on a level change, otherwise at
--     most every STATE_SECONDS and again every STATE_REPUBLISH_SECONDS;
--   * opens one 'levelup' barrier (gmp_reward_barrier.lua) per level gained, for every connected player, holding the
--     shared pause (reason PAUSE_REASON) while any barrier is open; REWARD_SCREEN tells clients open/deadline/closed;
--   * marks the host done for level L once (Level - open pickers) >= L, and auto-picks a card of its own picker when a
--     barrier's deadline expired (D45 revised: each player picks their own; a level-up is auto-picked only when still
--     unanswered after the grace window; roulettes keep the D44 2 s auto-click, gmp_reward_barrier.QUICK_KINDS);
--   * opens a 'catchup' barrier for one player whose level report (REWARD_DONE id 0) is below the team level (D46:
--     late rejoin, revived ghost), with the D46 budget;
--   * credits a client's bounded report of its own local bonus orbs (PICKUP_LOCAL_XP, D46) to the team;
--   * D46 XP-gain bonuses: every connected player's bonus (XP Multiplier - 1; clients report theirs with XP_BONUS)
--     counts, divided by the number of connected players, written to the host pawn's XP Multiplier (the team's XP
--     gain; the host's own later upgrades still add to it and are tracked);
--   * D8 level requirement: XP_Target x (1 + 0.5 x (connected - 1)) from the game's own target of each level, again
--     when the player count changes; never lowered below the current XP (requirementScaling=false: vanilla).
--   X.new{game=<adapter>, log=fn, catchupPauses=true}; x:Tick(ctx, session, now, inbox)
local Barrier = require('gmp_reward_barrier')
local Wire = require('gmp_pickups_wire')
local X = {}; X.__index = X
X.PAUSE_REASON = 'reward_screen'
X.STATE_SECONDS = 0.25
X.STATE_REPUBLISH_SECONDS = 2
X.SCREEN_REPUBLISH_SECONDS = 1
X.AUTO_PICK_SECONDS = 0.3
X.LOCAL_XP_SECONDS = 2
X.CATCHUP_BASE = 1000000   -- catch-up barrier ids live above level ids
X.REWARD_BASE = 2000000    -- reward screen (loot, bush, roulette) barrier ids live above catch-up ids
X.PRESENT_TIMEOUT_SECONDS = 5   -- a screen that never opened counts as done after this long
X.REQUIREMENT_PER_PLAYER = 0.5   -- D8
X.presenting = 0                 -- D44: > 0 while Game:Present calls PresentRoulette (gmp_run_sync's hook skips it)

function X.Number(v)
    local s = string.format('%.15g', v)
    if tonumber(s) ~= v then s = string.format('%.17g', v) end
    return s
end

function X.new(options)
    options = options or {}
    return setmetatable({ game = options.game or X.Game.new({ G = options.G, autoPickOther = options.autoPickOther }), log = options.log,
        catchupPauses = options.catchupPauses ~= false,
        barrier = Barrier.new({ autoPickSeconds = options.autoPickSeconds }), members = {}, logged = {}, localXp = {},
        revision = 0, catchups = 0, rewards = 0, hostScreens = {}, bonus = {},
        requirementScaling = options.requirementScaling ~= false }, X)
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

local function connected(session)
    local out = {}
    local ok, players = pcall(function() return session.roster:Snapshot() end)
    if ok and type(players) == 'table' then
        for _, p in ipairs(players) do if p.conn == 'connected' then out[p.key] = true end end
    end
    return out
end
function X:_hostKey(session) return type(session.identity) == 'table' and session.identity.key or nil end
function X:_send(session, key, typ, f)
    if not Wire.Validate[typ](f) then return false end
    local ok, sent = pcall(session.SendPickups, session, key, typ, f)
    return ok and sent == true
end

------------------------------------------------------------------ shared pause
function X:_pause(session, want)
    if type(session.EnablePause) ~= 'function' then return end
    local ok, pause = pcall(session.EnablePause, session)
    if not ok or type(pause) ~= 'table' or pause.locked then return end
    local me = self:_hostKey(session)
    if want and not pause.paused then
        if session.authorityPrep then return end
        local set = pcall(pause.Set, pause, me, true, false, X.PAUSE_REASON)
        if set then self.pauseHeld = true; pcall(session.PublishPause, session); self:_log('XPSYNC shared pause held for reward screens') end
    elseif not want and pause.paused and pause.reason == X.PAUSE_REASON then
        local set = pcall(pause.Set, pause, me, false, false, X.PAUSE_REASON .. '_done')
        if set then self.pauseHeld = false; pcall(session.PublishPause, session); self:_log('XPSYNC shared pause released') end
    end
end

------------------------------------------------------------------ barriers
function X:_screen(session, ctx, id, now, phase)
    local f = self.barrier:Screen(id, now, ctx.key)
    if not f then
        local m = self.members[id]
        if not m then return end
        f = { context = ctx.key, id = id, kind = m.kind, phase = 'closed', count = m.count, remainMs = 0 }
    end
    if phase then f.phase = phase end
    local m = self.members[id] or {}
    f.rarity, f.text = m.rarity or -1, m.text or ''
    for key in pairs((self.members[id] or {}).keys or {}) do
        if key ~= self:_hostKey(session) then self:_send(session, key, 'REWARD_SCREEN', f) end
    end
end
function X:_open(session, ctx, id, kind, participants, now, opts)
    local ok, why = self.barrier:Open(id, kind, participants, now, opts)
    if not ok then return self:_once('open:' .. tostring(why) .. id, 'XPSYNC barrier refused id=%d reason=%s', id, tostring(why)) end
    local keys = {}
    for k in pairs(participants) do keys[k] = true end
    self.members[id] = { kind = kind, keys = keys, count = opts and opts.count or 1, rarity = opts and opts.rarity, text = opts and opts.text }
    self:_log('XPSYNC barrier open id=%d kind=%s players=%d', id, kind, #self.barrier:State(id).waiting)
    self:_screen(session, ctx, id, now)
    self.screenAt = now
end
function X:_levels(session, ctx, state, now)
    if self.levelSeen == nil or state.level < self.levelSeen then
        if self.levelSeen and state.level < self.levelSeen then self:_log('XPSYNC host level went down %d -> %d', self.levelSeen, state.level) end
        self.levelSeen = state.level; return
    end
    if state.level <= self.levelSeen then return end
    local players = {}
    for key in pairs(connected(session)) do players[key] = {} end
    for level = self.levelSeen + 1, state.level do
        if not self.barrier:State(level) then self:_open(session, ctx, level, 'levelup', players, now) end
    end
    self.levelSeen = state.level
end
function X:_inbox(session, ctx, inbox, now, state)
    for _, item in ipairs(inbox or {}) do
        if item.type == 'REWARD_DONE' then
            local m = Wire.Validate.REWARD_DONE(item.f)
            if m and m.context == ctx.key and type(item.peer) == 'string' then
                if m.id > 0 and m.picked == 0 then
                    if self.barrier:Skip(m.id, item.peer) then self:_log('XPSYNC skipped (ghost) id=%d peer=%s', m.id, item.peer:sub(-6)) end
                elseif m.id > 0 then
                    if self.barrier:Done(m.id, item.peer, now) then self:_log('XPSYNC done id=%d peer=%s', m.id, item.peer:sub(-6)) end
                elseif self.levelSeen and m.picked < self.levelSeen and #self.barrier:Owed(item.peer) == 0 then
                    local missed = self.levelSeen - m.picked
                    self.catchups = self.catchups + 1
                    self:_open(session, ctx, X.CATCHUP_BASE + self.catchups, 'catchup', { [item.peer] = {} }, now,
                        { count = missed, budgetSeconds = Barrier.CatchupSeconds(missed) })
                end
            end
        elseif item.type == 'PICKUP_LOCAL_XP' then
            self:_localXp(ctx, item, now, state)
        elseif item.type == 'XP_BONUS' then
            local m = Wire.Validate.XP_BONUS(item.f)
            local last = type(item.peer) == 'string' and self.bonus[item.peer]
            if m and m.context == ctx.key and type(item.peer) == 'string' and (not last or m.revision > last.revision) then
                self.bonus[item.peer] = { revision = m.revision, multiplier = m.multiplier }
            end
        end
    end
end
-- D46: the team's XP gain = 1 + (sum of every connected player's bonus) / players, on the host pawn.
function X:_shareBonus(ctx, session, state, peers)
    if type(self.game.WriteMultiplier) ~= 'function' or type(state.multiplier) ~= 'number' then return end
    local m = state.multiplier
    if self.writtenMultiplier == nil then self.hostMultiplier = m
    elseif math.abs(m - self.writtenMultiplier) > 1e-9 then
        self.hostMultiplier = self.hostMultiplier + (m - self.writtenMultiplier)   -- the host's own new upgrade
    end
    local me, n, sum = self:_hostKey(session), 0, 0
    for key in pairs(peers) do
        n = n + 1
        if key == me then sum = sum + (self.hostMultiplier - 1)
        else sum = sum + ((self.bonus[key] and self.bonus[key].multiplier or 1) - 1) end
    end
    if n == 0 then return end
    local team = 1 + sum / n
    if math.abs(team - m) > 1e-9 then
        local ok, written = pcall(self.game.WriteMultiplier, self.game, ctx, team)
        if ok and written ~= false then
            self:_log('XPSYNC team xp gain %.4f (players=%d, host own %.4f)', team, n, self.hostMultiplier)
            state.multiplier = team
        end
    end
    self.writtenMultiplier = state.multiplier
end
-- D8: the level requirement x (1 + 0.5 x (connected - 1)), from the game's own target of the current level.
function X:_scaleRequirement(ctx, state, peers)
    if not self.requirementScaling or type(self.game.WriteTarget) ~= 'function' then return end
    if self.baseLevel ~= state.level then self.baseLevel, self.baseTarget = state.level, state.target end
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    if n < 1 then n = 1 end
    local want = self.baseTarget * (1 + X.REQUIREMENT_PER_PLAYER * (n - 1))
    if math.abs(want - state.target) < 1e-9 then return end
    if want <= state.current then return end   -- never lower below the current XP (the next award would level)
    local ok, written = pcall(self.game.WriteTarget, self.game, ctx, want)
    if ok and written ~= false then
        self:_log('XPSYNC level %d requirement %.4f (base %.4f, players=%d)', state.level, want, self.baseTarget, n)
        state.target = want
        -- test 13: writing XP_Target does not refresh the game's bar (only AddExperience does); draw it like the clients
        if type(self.game.DrawBar) == 'function' then pcall(self.game.DrawBar, self.game, ctx, want, state.current) end
    end
end
function X:_localXp(ctx, item, now, state)
    local m = Wire.Validate.PICKUP_LOCAL_XP(item.f)
    if not m or m.context ~= ctx.key or type(item.peer) ~= 'string' then return end
    local last = self.localXp[item.peer] or { sequence = 0 }
    if m.sequence <= last.sequence then return end
    last.sequence = m.sequence; self.localXp[item.peer] = last
    if last.at and now - last.at < X.LOCAL_XP_SECONDS then
        return self:_log('XPSYNC local xp refused peer=%s reason=rate amount=%d', item.peer:sub(-6), m.amount)
    end
    local cap = state and math.ceil(state.target) or 0
    local amount = math.min(m.amount, cap)
    if amount < 1 then return end
    last.at = now
    local ok, awarded = pcall(self.game.Award, self.game, ctx, amount)
    self:_log('XPSYNC local xp credited peer=%s amount=%d reported=%d ok=%s', item.peer:sub(-6), amount, m.amount,
        tostring(ok and awarded == true))
end

function X:_reset(ctx, session)
    if #self.barrier:Active() > 0 then self:_log('XPSYNC context changed: %d open barriers dropped', #self.barrier:Active()) end
    self.contextKey = ctx.key
    self.barrier = Barrier.new({ autoPickSeconds = self.barrier.autoPick })
    self.members, self.levelSeen, self.sentState, self.stateAt, self.localXp, self.hostScreens = {}, nil, nil, nil, {}, {}
    self.baseLevel, self.baseTarget = nil, nil
    self:_pause(session, false)
end

function X:Tick(ctx, session, now, inbox)
    local ok, err = pcall(function()
        if type(ctx) ~= 'table' or type(ctx.key) ~= 'string' or type(session) ~= 'table' then return end
        self.session = session
        if ctx.key ~= self.contextKey then self:_reset(ctx, session) end
        local okRead, state, why = pcall(self.game.Read, self.game, ctx)
        if not okRead or type(state) ~= 'table' then
            self:_once('read:' .. tostring(okRead and why or state), 'XPSYNC host pawn unreadable reason=%s', tostring(okRead and why or state))
            state = nil
        end
        if state then self:_levels(session, ctx, state, now) end
        self:_inbox(session, ctx, inbox, now, state)
        local me = self:_hostKey(session)
        local peers = connected(session)
        for _, id in ipairs(self.barrier:Active()) do
            for key in pairs((self.members[id] or {}).keys or {}) do if not peers[key] then self.barrier:Leave(key) end end
        end
        if state and me then
            for _, id in ipairs(self.barrier:Owed(me)) do
                if id < X.CATCHUP_BASE then
                    if state.level - state.open >= id then self.barrier:Done(id, me, now) end
                elseif id >= X.REWARD_BASE then
                    local hs = self.hostScreens[id]
                    if hs then
                        if state.open > 0 then hs.sawOpen = true
                        elseif hs.sawOpen or now - hs.at >= X.PRESENT_TIMEOUT_SECONDS then
                            self.barrier:Done(id, me, now); self.hostScreens[id] = nil
                        end
                    end
                end
            end
        end
        for _, e in ipairs(self.barrier:Tick(now)) do
            if e.type == 'closed' then
                local last = self.barrier:LastClose()
                self:_log('XPSYNC barrier closed id=%d forced=%s', e.id, tostring(last and last.forced))
                self:_screen(session, ctx, e.id, now, 'closed')
                self.members[e.id] = nil
            else
                self:_screen(session, ctx, e.id, now)
            end
        end
        if state and me and state.open > 0 and (not self.pickAt or now - self.pickAt >= X.AUTO_PICK_SECONDS) then
            for _, id in ipairs(self.barrier:Owed(me)) do
                local s = self.barrier:State(id)
                if s and s.expired then
                    self.pickAt = now
                    local okPick, picked, pwhy = pcall(self.game.AutoPick, self.game, ctx)
                    self:_log('XPSYNC host auto-pick id=%d ok=%s reason=%s', id, tostring(okPick and picked == true), tostring(pwhy or ''))
                    break
                end
            end
        end
        -- pause: held while a level-up (or a catch-up, when catchupPauses) barrier is open
        local hold = false
        for _, id in ipairs(self.barrier:Active()) do
            local kind = self.members[id] and self.members[id].kind
            if kind ~= 'catchup' or self.catchupPauses then hold = true end
        end
        self:_pause(session, hold)
        if #self.barrier:Active() > 0 and (not self.screenAt or now - self.screenAt >= X.SCREEN_REPUBLISH_SECONDS) then
            self.screenAt = now
            for _, id in ipairs(self.barrier:Active()) do self:_screen(session, ctx, id, now) end
        end
        if state then
            self:_shareBonus(ctx, session, state, peers)
            self:_scaleRequirement(ctx, state, peers)
            self:_publish(session, ctx, state, now, peers)
        end
    end)
    if not ok then self:_once('tick:' .. tostring(err), 'XPSYNC host tick error %s', tostring(err):sub(1, 200)) end
end
function X:_publish(session, ctx, state, now, peers)
    local last = self.sentState
    local changed = not last or last.level ~= state.level or last.current ~= state.current or last.target ~= state.target
    local levelChanged = not last or last.level ~= state.level
    local due = not self.stateAt or (changed and now - self.stateAt >= X.STATE_SECONDS) or now - self.stateAt >= X.STATE_REPUBLISH_SECONDS
    if not (levelChanged or due) then return end
    self.revision = self.revision + 1
    local f = { context = ctx.key, revision = self.revision, level = state.level, current = X.Number(state.current), target = X.Number(state.target) }
    local me = self:_hostKey(session)
    for key in pairs(peers) do if key ~= me then self:_send(session, key, 'XP_STATE', f) end end
    self.sentState, self.stateAt = { level = state.level, current = state.current, target = state.target }, now
end
-- D46: a loot, bush or reward item (gmp_pickups_host.lua TakeRewards) gives EVERY connected player their own screen,
-- together under the shared pause with the auto-pick rule. event = {kind='loot'|'bush'|'roulette', by=<peer>|'host'}:
-- when a client collected it the host presents its own screen too; when the host collected it, its game already did.
-- D44: a roulette event may carry rarity (int, -1 = random) and text (the title, e.g. the boss DeathText); every player's
-- own PresentRoulette gets them.
function X:Reward(ctx, session, now, event)
    local ok, err = pcall(function()
        if type(event) ~= 'table' or not Barrier.KINDS[event.kind] or ctx.key ~= self.contextKey then return end
        -- D44: with the host roulette hook (gmp_run_sync), a roulette the host's game presented is already a round
        -- (source 'present'); the pickup sync's event for the same host-collected item is dropped
        if self.rouletteHooked and (event.kind == 'roulette' or event.kind == 'reward') and event.source ~= 'present'
            and (event.by == 'host' or event.by == self:_hostKey(session)) then
            return self:_log('XPSYNC host roulette item: the PresentRoulette hook has this round')
        end
        local players = {}
        for key in pairs(connected(session)) do players[key] = {} end
        self.rewards = self.rewards + 1
        local id = X.REWARD_BASE + self.rewards
        local me = self:_hostKey(session)
        self.hostScreens[id] = { at = now, sawOpen = false }
        local rarity = math.type(event.rarity) == 'integer' and event.rarity >= -1 and event.rarity <= 3 and event.rarity or -1
        local text = type(event.text) == 'string' and event.text:gsub('%c', ' '):sub(1, Wire.TEXT_BYTES) or ''
        if event.by ~= 'host' and event.by ~= me then
            local presented, why = pcall(self.game.Present, self.game, ctx, event.kind, text ~= '' and text or nil, rarity)
            self:_log('XPSYNC host reward screen %s presented=%s %s', event.kind, tostring(presented), tostring(why or ''))
        end
        self:_open(session, ctx, id, event.kind, players, now, { rarity = rarity, text = text })
        self:_pause(session, true)
    end)
    if not ok then self:_once('reward:' .. tostring(err), 'XPSYNC host reward error %s', tostring(err):sub(1, 200)) end
end
-- Run end / sync stop: drop open barriers and release a reward pause this module holds.
function X:Release()
    self.barrier = Barrier.new({ autoPickSeconds = self.barrier.autoPick })
    self.members = {}
    if self.session then pcall(self._pause, self, self.session, false) end
end
function X:Status()
    return { level = self.levelSeen, open = self.barrier:Active(), pauseHeld = self.pauseHeld == true }
end

------------------------------------------------------------------ the real host pawn
local Game = {}; Game.__index = Game; X.Game = Game
function Game.new(options) return setmetatable({ options = options or {} }, Game) end
local function len(arr)
    if arr == nil then return 0 end
    if type(arr) ~= 'table' then
        local ok, n = pcall(function() return arr:GetArrayNum() end)
        return ok and n or 0
    end
    if type(arr.GetArrayNum) == 'function' then return arr:GetArrayNum() end
    return #arr
end
X.Len = len
function Game:_pawn(ctx)
    local island = ctx.islandWorld
    if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return nil, 'no_island_world' end
    local _, pawn = island:LocalWorldPawn()
    if not pawn or pawn:IsValid() ~= true then return nil, 'no_pawn' end
    return pawn
end
function Game:Read(ctx)
    local pawn, why = self:_pawn(ctx)
    if not pawn then return nil, why end
    local level, current, target = pawn.Level, pawn.XP_Current, pawn.XP_Target
    if math.type(level) ~= 'integer' then level = math.tointeger(level) end
    if not level or type(current) ~= 'number' or type(target) ~= 'number' or target <= 0 then return nil, 'xp_fields' end
    local open = (pawn['PresentTime?'] == true and 1 or 0) + len(pawn.PresentQueue)
    local multiplier = pawn['XP Multiplier']
    return { level = level, current = current, target = target, open = open, dead = pawn.PlayerIsDead == true,
        multiplier = type(multiplier) == 'number' and multiplier or nil }
end
function Game:WriteMultiplier(ctx, m)
    local pawn = self:_pawn(ctx)
    if not pawn then return false end
    pawn['XP Multiplier'] = m
    return true
end
-- The game's own HUD XP bar: HUD.XPBar:UpdateBar(target, current) (what AddExperience calls).
function Game:DrawBar(ctx, target, current)
    local pawn = self:_pawn(ctx)
    local hud = pawn and pawn.HUD
    local bar = hud and hud.XPBar
    if not bar then return false end
    bar:UpdateBar(target, current)
    return true
end
function Game:WriteTarget(ctx, t)
    local pawn = self:_pawn(ctx)
    if not pawn then return false end
    pawn.XP_Target = t
    return true
end
-- One card of the open item picker (WBP_Item.CardChoosen() is click-equivalent, RESEARCH_PICKER 1.5). A roulette or
-- other screen is left to its own module: options.autoPickOther(pawn) -> true when it clicked a step (Coder B's
-- gmp_roulette_auto, D44).
function Game:AutoPick(ctx)
    local pawn, why = self:_pawn(ctx)
    if not pawn then return false, why end
    local grid = pawn.WBP_ItemGrid
    local cards = grid and grid.AllChilrenCards
    local n = len(cards)
    if n < 1 then
        if self.options.autoPickOther then return self.options.autoPickOther(pawn) end
        return false, 'no_cards'
    end
    local card = cards[math.random(n)]
    card:CardChoosen()
    return true
end
-- The player's own reward screen through the game's own objects (D46): the consumable components the game itself adds
-- on pickup (their BeginPlay presents the screen on pawn 0, then they destroy themselves), or the roulette.
Game.PRESENT = { loot = '/Game/Blueprints/Consumables/BPC_Item.BPC_Item_C', bush = '/Game/Blueprints/Consumables/BPC_BushItem.BPC_BushItem_C' }
function Game:Present(ctx, kind, text, rarity)
    local pawn, why = self:_pawn(ctx)
    if not pawn then return false, why end
    local G = self.options.G or {}
    if kind == 'roulette' or kind == 'reward' then
        local FText = G.FText or (type(_G.FText) == 'function' and _G.FText) or nil
        if not FText then return false, 'no_ftext' end
        local r = math.type(rarity) == 'integer' and rarity >= -1 and rarity <= 3 and rarity or -1
        -- D44: our own call is not a new round for the host roulette hook (gmp_run_sync)
        X.presenting = (X.presenting or 0) + 1
        local ok, err = pcall(pawn.PresentRoulette, pawn, r, FText((type(text) == 'string' and text ~= '') and text or 'spin to win!'))
        X.presenting = X.presenting - 1
        if not ok then error(err, 0) end
        return true
    end
    local path = Game.PRESENT[kind]
    if not path then return false, 'no_present_kind' end
    local find = G.StaticFindObject or (type(_G.StaticFindObject) == 'function' and _G.StaticFindObject) or nil
    local class = find and find(path)
    if not class or class:IsValid() ~= true then return false, 'no_present_class' end
    local controller = pawn.EnemyController
    if not controller or controller:IsValid() ~= true then return false, 'no_controller' end
    local component = controller:AddComponentByClass(class, false,
        { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    if not component or component:IsValid() ~= true then return false, 'present_component_failed' end
    return true
end
function Game:Award(ctx, n)
    local pawn = self:_pawn(ctx)
    if not pawn or math.type(n) ~= 'integer' or n < 1 then return false end
    pawn:AddExperience(n)
    return true
end
return X
