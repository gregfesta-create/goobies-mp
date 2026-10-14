-- Client rows mode (PLAN_WORLD_ENTRY.md 4: S2 client enemies in rows mode, S3 removal/death parity). Client role,
-- MODE=dev (the controller fence still reports incomplete coverage, so gmp_native_enemy_authority_adapter needs its
-- controllerOnlyDevelopmentTest opt-in).
--   Rows.new{api = {configure, status, spawn, update, retire}, presentation = <owned enemy view>, budget = 32, log}
--     api: the slice1 bridge GMPAuthorityControllerConfigure / ControllerStatus / HostSpawn / HostUpdate / HostRetire.
--   :Enable(ctx)            fence the client's controller (no local spawns, AI, damage or deaths), hide the local horde
--                           meshes and bind the owned presentation. Run at island prep, while the shared pause holds.
--   :Apply(ctx, snapshot)   mirror the host's enemy snapshot (Client:EnemySnapshot()): every live host enemy becomes a
--                           native controller row (HostSpawn once, HostUpdate when its position/HP/damage changes) that
--                           the client's own weapons can hit, and is drawn by the presentation. A host death or a
--                           lifetime missing from the snapshot retires the row (HostRetire: inert dead shape, no death,
--                           XP or reward route) and hides it. A retired lifetime is never spawned again. At most
--                           `budget` native writes per call; the next call continues. Leftover budget re-asserts up
--                           to `refresh` (default 4) unchanged rows round-robin with the host's values, so damage the
--                           client's own projectiles apply natively before the fenced hit event never sticks (the
--                           slice1 HostUpdate also restores canMove=true on a live row).
--   :EnemyIdAt(slot) / :SlotOf(enemyId)   the client slot <-> host lifetime mapping (the attack ring also records
--                           the lifetime that owned a slot at capture time).
--   :Disable()              retire every row, restore the controller and the local meshes. Returns nil,
--                           'component_cleanup_pending' while owned components are still being destroyed; call again.
--                           When the island's level is gone (options.worldLive(worldPath) false: back in the menu),
--                           nothing in it is touched: the native fence is released (it checks its own weak binding)
--                           and the presentation forgets its components (presentation:Forget()).
--   options.mapRefresh      (R1 attempt 4 candidate) after every active Apply, api.mapRefresh(generation)
--                           (GMPAuthorityClientMapRefresh: one UpdateInstances(0) behind a refresh gate) so the native
--                           spatial map that projectile collision queries includes the host rows. A refusal is counted
--                           and logged once; it never holds the rows.
--   Classes the presentation has no template for (presentation:HasTemplate(kind) false: 13-25, actor-driven
--                           uniques and bosses): with options.proxyClass (D43) each gets an invisible proxy native row
--                           of that ordinary class (the client's own weapons target and hit it; the capture names the
--                           boss's host lifetime) and, once the host's look arrives (snapshot.actors[id], ACTOR_INFO),
--                           an owned visual copy (presentation:SetActorVisual / RemoveActorVisual). Without a proxy
--                           class they are skipped (no slot, counted).
--   A spawn the native side reports as displacing a live lifetime (host_apply_spawned_displaced, 4th value) drops
--                           that lifetime's row; it is spawned again on the next apply (counted displaced).
--   :Recover(ctx)           after a hold: retire every mirrored row (best effort), release and reinstall the fence in
--                           the same call, forget the rows; the next apply mirrors the host's full state again.
--   :Status()               {state='idle'|'active'|'held', reason, live, spawned, updated, retired, applied,
--                           refreshed, mapRefreshed, mapRefreshFailed}
-- Any native refusal holds the rows (a spawn or write may have partially happened; it is never retried blindly),
-- except these (test 14, about 3850 live host enemies):
--   * native rows are a capped subset, nearest first (snapshot.focus = the local player; without it, id order): at
--     most nativeCap (R.NATIVE_CAP) rows; every other live host enemy is drawn only (the owned presentation draws every
--     live host enemy, native row or not). The ranking is rebuilt at most every R.RANK_SECONDS; new ids are appended.
--   * a full native pool lowers the cap and never holds: the native refusal host_apply_pool_full (the row stays drawn
--     only and spawns once there is room), or, with the older native, the same slot displaced twice within
--     R.POOL_FULL_SPAWNS spawns (the game answering every spawn with slot 0). One "ROWS native pool full" line.
--   * a native update refused for a row whose record changed (R.RESEED reasons) re-seeds that row as drawn only;
--     its lifetime stays reserved natively, so it is never spawned again.
--   Status().fill = {native, nativeTarget, drawn, drawnTarget} says when a (re)join fill is complete.
local Adapter = require('gmp_native_enemy_authority_adapter')
local R = {}
R.__index = R
-- Test 7: retire refusals that mean the game already freed the record (KillAllEnemies, level travel, records reset).
R.GONE = { host_record_missing_slot = true, host_record_missing_array = true, host_record_array_bounds = true,
    host_retire_record_gone = true }
-- The native fence binding each configure route currently holds ({generation, worldPath, controllerPath, key}), so a
-- new rows can release one an earlier rows left behind (an aborted run) before binding.
R.bindings = setmetatable({}, { __mode = 'k' })

function R.new(options)
    assert(type(options) == 'table' and type(options.api) == 'table' and type(options.presentation) == 'table', 'rows_options')
    local budget, refresh = options.budget or 32, options.refresh or 4
    assert(math.type(budget) == 'integer' and budget >= 1 and budget <= 4096, 'rows_budget')
    assert(math.type(refresh) == 'integer' and refresh >= 0 and refresh <= 4096, 'rows_refresh')
    assert(options.worldLive == nil or type(options.worldLive) == 'function', 'rows_world_live')
    local maxBudget = options.maxBudget or 256
    assert(math.type(maxBudget) == 'integer' and maxBudget >= budget and maxBudget <= 4096, 'rows_max_budget')
    assert(options.clock == nil or type(options.clock) == 'function', 'rows_clock')
    return setmetatable({ api = options.api, presentation = options.presentation, budget = budget, refresh = refresh,
        maxBudget = maxBudget, timeBudget = options.timeBudget or 0.004, clock = options.clock or os.clock,
        presentHz = options.presentHz, mapRefreshHz = options.mapRefreshHz, proxyClass = options.proxyClass, actorVisual = {},
        presentBudget = options.presentBudget or 256, writes = 0, window = { applied = 0, capped = 0 },
        worldLive = options.worldLive, mapRefresh = options.mapRefresh == true, mapRefreshLogged = {},
        cursor = 0, mapRefreshed = 0, mapRefreshFailed = 0,
        log = options.log or function() end, state = 'idle', rows = {}, bySlot = {}, retired = {},
        skippedIds = {}, drawn = {}, lost = {}, nativeCap = options.nativeCap or R.NATIVE_CAP, spawnCount = 0,
        slotDisplacedAt = {}, presentCursor = 0,
        counts = { spawned = 0, updated = 0, retired = 0, applied = 0, refreshed = 0, capped = 0, refused = 0,
            skipped = 0, displaced = 0, recovered = 0, deathfx = 0, deathfxRefused = 0, reseeded = 0, poolFull = 0 } }, R)
end

function R:_hold(why)
    self.state, self.reason = 'held', tostring(why)
    self.log('ROWS held reason=' .. self.reason)
    return false, self.reason
end

function R:Enable(ctx)
    if self.state == 'active' then return true, 'already_enabled' end
    if self.state == 'held' then return false, self.reason end
    for _, name in ipairs({ 'configure', 'status', 'spawn', 'update', 'retire' }) do
        if type(self.api[name]) ~= 'function' then return false, 'rows_native_unavailable' end
    end
    if type(ctx) ~= 'table' then return false, 'rows_bad_context' end
    local stale = R.bindings[self.api.configure]
    if stale and stale.key ~= ctx.key then
        local ok, done, why = pcall(self.api.configure, stale.generation, stale.worldPath, stale.controllerPath, false)
        self.log(string.format('ROWS released stale binding generation=%s ctx=%s result=%s', tostring(stale.generation),
            tostring(stale.key), ok and tostring(done == true and 'released' or why) or 'error'))
        R.bindings[self.api.configure] = nil
    end
    local adapter = Adapter.new({ configure = self.api.configure, status = self.api.status, spawn = self.api.spawn,
        update = self.api.update }, self.presentation, { controllerOnlyDevelopmentTest = true })
    local bound, why = adapter:Bind(ctx.key, ctx.generation, ctx.worldPath, ctx.controllerPath)
    if bound ~= true then return false, tostring(why) end
    local ok, enabled, detail = pcall(adapter.SuppressLocalSimulation, adapter, ctx.key, true)
    if not ok or enabled ~= true then return self:_hold('rows_enable_failed:' .. tostring(ok and detail or enabled)) end
    if adapter:LocalSimulationSuppressed(ctx.key) ~= true then return self:_hold('rows_fence_unverified') end
    self.adapter, self.state, self.reason = adapter, 'active', nil
    self.ctx = { key = ctx.key, generation = ctx.generation, worldPath = ctx.worldPath, controllerPath = ctx.controllerPath }
    R.bindings[self.api.configure] = self.ctx
    self.rows, self.bySlot, self.retired, self.epoch, self.revision = {}, {}, {}, nil, nil
    self.drawn, self.lost, self.ranked, self.rankOf, self.rankedAt = {}, {}, nil, nil, nil
    self.log('ROWS enabled ctx=' .. tostring(ctx.key))
    return true
end

-- R1 attempt 5: a client-local projectile kill freed a native slot that AddInstanceClassType reused while a live host
-- row still owned it (host_apply_reused_live_slot held the rows for the rest of the run). Host rows therefore carry a
-- large client-side HP: the client never kills one locally; the host's HP stays authoritative (snapshots, hit intents).
R.CLIENT_HP = 10000000
-- cm: smaller host movement costs no native write (the presentation still follows every tick). Test 7 rerun: with the
-- interpolated view every enemy moved every tick, so at 8 cm every row cost a native write every tick and the client's
-- app tick slowed to 10-13 a second. Native rows only serve collision; 40 cm is inside an enemy's radius.
R.POS_EPSILON = 40
R.PRESENT_EPSILON = 1  -- cm: smaller moves are not redrawn
R.DEATH_EFFECTS_PER_APPLY = 16   -- cosmetic death effects (presentation:DeathEffect) per call
R.PRESENT_MIN = 16    -- presentation transforms guaranteed per Apply; more while the frame-time budget lasts
-- Test 14: the client's native pool filled at about 2050 live rows (the game then answered spawns with slot 0).
R.NATIVE_CAP = 1600          -- native rows at most (nearest first); the presentation draws every live host enemy
R.NATIVE_CAP_MIN = 64        -- a full pool never lowers the cap below this
R.NATIVE_CAP_MARGIN = 32     -- headroom kept below a pool found full by displacement (records the game has not recycled)
R.POOL_FULL_SPAWNS = 256     -- the same slot displaced twice within this many spawns = a full pool, not a reuse
R.MAP_REFRESH_SHARE = 0.1    -- the native collision-map refresh takes at most this share of the frame time
R.RANK_SECONDS = 0.5         -- the nearest-first ranking is rebuilt at most this often (new ids are appended)
R.PRESENT_NEAR = 64          -- with a focus, the nearest rows are redrawn first every presentation pass
-- native update refusals that mean the row's record is no longer its own: the row is re-seeded as drawn only
R.RESEED = { host_record_slot_lifetime_type_changed = true, host_record_missing_slot = true,
    host_record_unknown_or_reused_lifetime = true }
local function changed(old, row)
    return math.abs(old.x - row.x) > R.POS_EPSILON or math.abs(old.y - row.y) > R.POS_EPSILON or old.damage ~= row.damage
end
local function nativeRow(r)
    return { id = r.id, x = r.x, y = r.y, z = 0, enemyType = r.enemyType, damage = r.damage or 0, hp = R.CLIENT_HP }
end

function R:_retire(id, tolerant)
    local entry = self.rows[id]
    local ok, done, why = pcall(self.api.retire, self.ctx.generation, id, entry.slot, entry.enemyType)
    local gone = ok and done ~= true and R.GONE[tostring(why)]
    if (not ok or done ~= true) and not gone then
        if not tolerant then return self:_hold(ok and why or done) end
        self.retireFailed = (self.retireFailed or 0) + 1
    end
    pcall(self.adapter.RemoveEnemy, self.adapter, id)
    self.rows[id], self.bySlot[entry.slot], self.retired[id] = nil, nil, true
    self.counts.retired = self.counts.retired + 1
    return true
end

function R:Apply(ctx, snapshot)
    local t0 = os.clock()
    local result = table.pack(self:_applyFramed(ctx, snapshot))
    local cost = (os.clock() - t0) * 1000
    self.window.ms, self.window.calls = (self.window.ms or 0) + cost, (self.window.calls or 0) + 1
    self.window.maxMs = math.max(self.window.maxMs or 0, cost)
    return table.unpack(result, 1, result.n)
end
-- Test 9: the view interpolation cost, measured by the run sync, for the prof= breakdown.
function R:NoteView(ms) if type(ms) == 'number' then self.window.view = (self.window.view or 0) + ms end end
local function due(self, field, hz)
    if not hz then return true end
    local now = self.clock()
    local last = self[field]
    if last and now - last < 1 / hz - 1e-6 then return false end
    self[field] = now
    return true
end
function R:_applyFramed(ctx, snapshot)
    -- one liveness proof of the owned presentation per Apply (reused briefly by the presentation itself), and only
    -- after the context is known to be this rows' (an island or level change always changes the context)
    local p = self.presentation
    local inContext = self.state == 'active' and type(ctx) == 'table' and self.ctx and ctx.key == self.ctx.key
    self.presentNow = due(self, 'presentAt', self.presentHz)
    local t0 = os.clock()
    local framed = inContext and self.presentNow and type(p.BeginFrame) == 'function' and pcall(p.BeginFrame, p)
    -- one fence proof for the whole apply (test 11), dropped again right after it
    local a = self.adapter
    if inContext and a and type(a.BeginFrame) == 'function' then pcall(a.BeginFrame, a, ctx.key) end
    local t1 = os.clock()
    local ok, why = self:_apply(ctx, snapshot)
    local t2 = os.clock()
    if a and type(a.EndFrame) == 'function' then pcall(a.EndFrame, a) end
    if framed and type(p.EndFrame) == 'function' then pcall(p.EndFrame, p) end
    local t3 = os.clock()
    if self.mapRefresh and self.state == 'active' and type(self.api.mapRefresh) == 'function'
        and (not self.refreshNotBefore or self.clock() >= self.refreshNotBefore) and due(self, 'refreshAt', self.mapRefreshHz) then
        -- test 14: an expensive refresh (UpdateInstances over thousands of rows) runs less often, at most
        -- MAP_REFRESH_SHARE of the frame time
        local c0 = self.clock()
        self:_refreshMap()
        local cost = self.clock() - c0
        self.refreshNotBefore = cost > 0 and c0 + cost / R.MAP_REFRESH_SHARE or nil
    end
    local t4 = os.clock()
    local w = self.window
    w.frame = (w.frame or 0) + ((t1 - t0) + (t3 - t2)) * 1000
    w.native = (w.native or 0) + math.max(0, (t2 - t1) * 1000 - (self.presentMs or 0))
    w.present = (w.present or 0) + (self.presentMs or 0)
    w.refresh = (w.refresh or 0) + (t4 - t3) * 1000
    self.presentMs = 0
    return ok, why
end
function R:_refreshMap()
    local called, ok, why = pcall(self.api.mapRefresh, self.ctx.generation)
    if called and ok == true then self.mapRefreshed = self.mapRefreshed + 1; return end
    self.mapRefreshFailed = self.mapRefreshFailed + 1
    local reason = tostring(called and why or ok):sub(1, 200)
    if not self.mapRefreshLogged[reason] then
        self.mapRefreshLogged[reason] = true
        self.log('ROWS map refresh refused reason=' .. reason)
    end
end
-- Nearest first (test 14): the ranked live ids, rebuilt at most every R.RANK_SECONDS; new ids are appended between.
function R:_rank(live, ids, focus)
    local now = self.clock()
    local function key(id)
        local r = live[id]
        if focus then return (r.x - focus.x) ^ 2 + (r.y - focus.y) ^ 2 end
        return 0
    end
    local function sortIds(list)
        local d = {}
        for _, id in ipairs(list) do d[id] = key(id) end
        table.sort(list, function(a, b)
            if d[a] ~= d[b] then return d[a] < d[b] end
            return a < b
        end)
    end
    if not self.ranked or (focus and now - (self.rankedAt or now) >= R.RANK_SECONDS) or (focus ~= nil) ~= (self.rankFocus == true) then
        local list = {}
        for i, id in ipairs(ids) do list[i] = id end
        sortIds(list)
        self.ranked, self.rankedAt, self.rankFocus = list, now, focus ~= nil
    else
        local fresh = {}
        local seen = self.rankOf or {}
        for _, id in ipairs(ids) do if not seen[id] then fresh[#fresh + 1] = id end end
        if #fresh > 0 then
            sortIds(fresh)
            local old = self.ranked
            local list = {}
            for _, id in ipairs(old) do if live[id] then list[#list + 1] = id end end
            for _, id in ipairs(fresh) do list[#list + 1] = id end
            self.ranked = list
        end
    end
    local order, rankOf = {}, {}
    for _, id in ipairs(self.ranked) do
        if live[id] and not rankOf[id] then order[#order + 1] = id; rankOf[id] = #order end
    end
    self.ranked, self.rankOf = order, rankOf
    return order
end
-- A full native pool: the cap becomes what fits now (less a margin when the pool was found full by displacement).
function R:_poolFull(how, margin)
    local native = 0
    for _ in pairs(self.rows) do native = native + 1 end
    local cap = math.max(R.NATIVE_CAP_MIN, native - (margin or 0))
    self.counts.poolFull = self.counts.poolFull + 1
    if cap < self.nativeCap then
        self.nativeCap = cap
        self.log(string.format('ROWS native pool full at %d rows (%s); native cap now %d, nearest first, the rest drawn only',
            native, how, cap))
    end
end
-- A native update refusal that means the row's record is no longer its own (R.RESEED): drawn only from now on.
function R:_reseed(id, why)
    local entry = self.rows[id]
    if not entry then return end
    self.rows[id], self.bySlot[entry.slot], self.lost[id] = nil, nil, true
    self.drawn[id] = { enemyType = entry.enemyType, px = entry.px, py = entry.py, presentedAt = entry.presentedAt,
        dirX = entry.dirX, dirY = entry.dirY, refusedAt = entry.refusedAt }
    self.counts.reseeded = self.counts.reseeded + 1
    self.reseedLogged = self.reseedLogged or {}
    if not self.reseedLogged[why] then
        self.reseedLogged[why] = true
        self.log(string.format('ROWS reseeded id=%s slot=%d reason=%s (drawn only; the stream goes on)', id, entry.slot, why))
    end
end
function R:_update(id, entry, native)
    local ok, updated, why = pcall(self.adapter.HostUpdate, self.adapter, self.ctx.key, entry.slot, native)
    if ok and updated == true then return true end
    if ok and R.RESEED[tostring(why)] then self:_reseed(id, tostring(why)); return true, 'reseeded' end
    return self:_hold(ok and why or updated)
end
function R:_apply(ctx, snapshot)
    if self.state == 'held' then return false, self.reason end
    if self.state ~= 'active' then return false, 'rows_not_enabled' end
    if type(ctx) ~= 'table' or ctx.key ~= self.ctx.key then return false, 'rows_context_changed' end
    if type(snapshot) ~= 'table' or type(snapshot.enemies) ~= 'table' then return true end
    if self.epoch == snapshot.epoch and self.revision and snapshot.revision < self.revision then return true end
    if self.epoch ~= snapshot.epoch or self.revision ~= snapshot.revision then
        self.epoch, self.revision = snapshot.epoch, snapshot.revision
        self.counts.applied = self.counts.applied + 1; self.window.applied = self.window.applied + 1
    end
    local focus = type(snapshot.focus) == 'table' and type(snapshot.focus.x) == 'number' and type(snapshot.focus.y) == 'number'
        and snapshot.focus or nil
    local live, ids = {}, {}
    local dead = 0
    local deaths = {}
    for _, r in ipairs(snapshot.enemies) do if type(r) == 'table' and r.dead then dead = dead + 1; deaths[r.id] = r end end
    self.viewTotal, self.viewDead = #snapshot.enemies, dead
    for _, r in ipairs(snapshot.enemies) do
        if type(r) == 'table' and type(r.id) == 'string' then
            if r.dead then
                -- A host death: retire a mirrored row; an unseen lifetime is simply never spawned.
                if not self.rows[r.id] and not self.drawn[r.id] then self.retired[r.id] = true end
            elseif not self.retired[r.id] then
                if self:_drawable(r.enemyType) or self.proxyClass then
                    -- drawable rows, and (D43) actor classes through a proxy row
                    live[r.id] = r; ids[#ids + 1] = r.id
                elseif not self.skippedIds[r.id] then
                    self.skippedIds[r.id] = true; self.counts.skipped = self.counts.skipped + 1
                end
            end
        end
    end
    local order = self:_rank(live, ids, focus)
    self.received = #order
    -- Native writes: `budget` guaranteed per call, more (up to maxBudget) while the frame-time budget lasts.
    local clock, spent, capped = self.clock, 0, false
    local started = clock()
    local function canWrite()
        if spent < self.budget then return true end
        if spent >= self.maxBudget or clock() - started >= self.timeBudget then capped = true; return false end
        return true
    end
    local touched = {}
    -- 1. retirements (host deaths and disappearances); a drawn-only row only leaves the presentation
    local gone = {}
    for id in pairs(self.rows) do if not live[id] then gone[#gone + 1] = id end end
    table.sort(gone)
    local pending = 0
    local effects = 0
    local function deathEffect(death, entry)
        if death and entry and not entry.actor and effects < R.DEATH_EFFECTS_PER_APPLY and type(self.presentation.DeathEffect) == 'function' then
            effects = effects + 1
            local called, played, why = pcall(self.presentation.DeathEffect, self.presentation, entry.enemyType,
                entry.px or death.x or entry.x, entry.py or death.y or entry.y, entry.dirX, entry.dirY)
            if called and played ~= false then self.counts.deathfx = self.counts.deathfx + 1
            else
                self.counts.deathfxRefused = self.counts.deathfxRefused + 1
                if not self.deathfxLogged then
                    self.deathfxLogged = true
                    self.log('ROWS death effect refused reason=' .. tostring(called and why or played))
                end
            end
        end
    end
    for id, entry in pairs(self.drawn) do
        if not live[id] then
            self.drawn[id] = nil; self.retired[id] = true
            if entry.px then pcall(self.adapter.RemoveEnemy, self.adapter, id); deathEffect(deaths[id], entry) end
        end
    end
    for i, id in ipairs(gone) do
        if not canWrite() then pending = pending + (#gone - i + 1); break end
        local entry = self.rows[id]
        local ok, why = self:_retire(id)
        if not ok then return false, why end
        spent = spent + 1
        -- a host death (not a disappearance) plays the death effect where the row was drawn, as soon as it arrives
        local death = deaths[id]
        if entry and entry.actor and self.actorVisual[id] then
            -- D43: the visual copy goes (the big death effect on a host death)
            self.actorVisual[id] = nil
            local called, done, why = pcall(self.presentation.RemoveActorVisual, self.presentation, id, death ~= nil,
                entry.x, entry.y)
            if not (called and done ~= false) then self:_actorRefusal('remove', called and why or done) end
        end
        deathEffect(death, entry)
    end
    -- 2. spawns, nearest first, while the native rows are under the cap
    local native = 0
    for _ in pairs(self.rows) do native = native + 1 end
    for _, id in ipairs(order) do
        if native >= self.nativeCap then break end
        if not self.rows[id] and not self.lost[id] then
            if not canWrite() then pending = pending + 1
            else
                local r = live[id]
                local nrow = nativeRow(r)
                local actor = not self:_drawable(r.enemyType)
                if actor then nrow.enemyType = self.proxyClass end   -- D43: an invisible ordinary proxy row
                local ok, spawned, why, slot, displaced = pcall(self.adapter.HostSpawn, self.adapter, self.ctx.key, nrow)
                spent = spent + 1
                if ok and spawned ~= true and why == 'host_apply_pool_full' then
                    -- the native pool is full: nothing was bound; the row stays drawn only and spawns once there is room
                    self:_poolFull('host_apply_pool_full', 0)
                    break
                end
                if not ok or spawned ~= true or math.type(slot) ~= 'integer' then return self:_hold(ok and why or spawned) end
                self.spawnCount = self.spawnCount + 1
                if type(displaced) == 'string' and displaced ~= '' and self.rows[displaced] then
                    -- the game reused a live host row's slot: that lifetime is spawned again on the next apply, unless
                    -- the same slot was displaced moments ago (a full pool answering every spawn with that slot)
                    self.log(string.format('ROWS displaced id=%s by=%s slot=%d', displaced, id, slot))
                    self.rows[displaced] = nil
                    self.counts.displaced = self.counts.displaced + 1
                    native = native - 1
                    local last = self.slotDisplacedAt[slot]
                    self.slotDisplacedAt[slot] = self.spawnCount
                    if last and self.spawnCount - last <= R.POOL_FULL_SPAWNS then
                        self:_poolFull('slot ' .. slot .. ' displaced again', R.NATIVE_CAP_MARGIN)
                    end
                end
                local drawn = self.drawn[id]
                self.drawn[id] = nil
                self.rows[id] = { slot = slot, enemyType = r.enemyType, x = nrow.x, y = nrow.y, damage = nrow.damage,
                    writtenAt = self.writes, actor = actor or nil }
                if drawn then
                    local e = self.rows[id]
                    e.px, e.py, e.presentedAt, e.dirX, e.dirY = drawn.px, drawn.py, drawn.presentedAt, drawn.dirX, drawn.dirY
                end
                if actor then self.rows[id].enemyType = self.proxyClass end
                self.bySlot[slot] = id
                self.counts.spawned = self.counts.spawned + 1
                touched[id] = true
                self.writes = self.writes + 1
                native = native + 1
            end
        end
    end
    -- 3. native position/damage updates, oldest-written first (nothing starves)
    local stale = {}
    for _, id in ipairs(order) do
        local entry = self.rows[id]
        if entry and not touched[id] and changed(entry, nativeRow(live[id])) then
            stale[#stale + 1] = id
        end
    end
    table.sort(stale, function(a, b)
        local wa, wb = self.rows[a].writtenAt, self.rows[b].writtenAt
        if wa ~= wb then return wa < wb end
        return a < b
    end)
    for _, id in ipairs(stale) do
        if not canWrite() then break end
        local entry, nrow = self.rows[id], nativeRow(live[id])
        nrow.enemyType = entry.enemyType   -- a proxy keeps its proxy class
        local ok, why = self:_update(id, entry, nrow)
        if not ok then return false, why end
        spent = spent + 1; touched[id] = true
        if why ~= 'reseeded' then
            entry.x, entry.y, entry.damage, entry.writtenAt = nrow.x, nrow.y, nrow.damage, self.writes
            self.writes = self.writes + 1
            self.counts.updated = self.counts.updated + 1
        end
    end
    -- 4. presentation: every live host enemy (native row or drawn only) at the host's newest position, separate from
    --    the native cap; at most presentBudget transforms per call: with a focus the nearest R.PRESENT_NEAR first, then
    --    round-robin through the rest (an interpolated view moves every row every tick; nobody is left behind)
    local presentStart = os.clock()
    local function entryOf(id)
        local e = self.rows[id]
        if e then return e end
        e = self.drawn[id]
        if not e then e = { enemyType = live[id].enemyType }; self.drawn[id] = e end
        return e
    end
    local function isDue(id)
        local entry, r = entryOf(id), live[id]
        return not entry.actor and (not entry.px or math.abs(entry.px - r.x) >= R.PRESENT_EPSILON or math.abs(entry.py - r.y) >= R.PRESENT_EPSILON)
            and entry.refusedAt ~= (r.x .. ',' .. r.y)
    end
    local due = {}
    if self.presentNow ~= false and #order > 0 then
        local near = focus and math.min(R.PRESENT_NEAR, #order, math.floor(self.presentBudget / 2)) or 0
        local picked = {}
        for i = 1, near do local id = order[i]; if isDue(id) then due[#due + 1] = id; picked[id] = true end end
        local n = #order
        local cursor = self.presentCursor % n
        local scanned = 0
        while #due < self.presentBudget and scanned < n do
            cursor = cursor % n + 1
            scanned = scanned + 1
            local id = order[cursor]
            if not picked[id] and isDue(id) then due[#due + 1] = id; picked[id] = true end
        end
        self.presentCursor = cursor
    end
    self.presents = self.presents or 0
    for i, id in ipairs(due) do
        if i > self.presentBudget or (i > R.PRESENT_MIN and clock() - started >= self.timeBudget) then break end
        local entry, r = entryOf(id), live[id]
        do
            local called, ok, why = pcall(self.adapter.SetEnemy, self.adapter, id, nativeRow(r))
            self.presents = self.presents + 1; entry.presentedAt = self.presents
            if called and ok ~= false then
                -- the drawn movement direction, for the death effect (the host's kill uses the row's dir; test 12)
                if entry.px then
                    local mx, my = r.x - entry.px, r.y - entry.py
                    local m = math.sqrt(mx * mx + my * my)
                    if m >= 1 then entry.dirX, entry.dirY = mx / m, my / m end
                end
                entry.px, entry.py, entry.refusedAt = r.x, r.y, nil
            else
                entry.refusedAt = r.x .. ',' .. r.y
                self.counts.refused = self.counts.refused + 1
                if not self.refusedLogged then
                    self.refusedLogged = true
                    self.log('ROWS presentation refused id=' .. id .. ' reason=' .. tostring(called and why or ok))
                end
            end
        end
    end
    -- D43: the visual copies of actor rows, from the host's look (snapshot.actors), at the presentation rate
    if self.presentNow ~= false and type(self.presentation.SetActorVisual) == 'function' then
        local looks = type(snapshot.actors) == 'table' and snapshot.actors or {}
        for id, look in pairs(looks) do
            local entry = self.rows[id]
            if entry and entry.actor and live[id] then
                local called, done, why = pcall(self.presentation.SetActorVisual, self.presentation, id, live[id], look)
                local okSet = called and done ~= false
                if okSet then self.actorVisual[id] = true else self:_actorRefusal('set', called and why or done) end
                self.actorFirst = self.actorFirst or {}
                if self.actorFirst[id] == nil then
                    self.actorFirst[id] = okSet
                    self.log('ACTORVISUAL id=' .. tostring(id) .. ' kind=' .. tostring(look.kind) .. ' ok=' .. tostring(okSet)
                        .. (okSet and '' or ' reason=' .. tostring(called and why or done)))
                end
            end
        end
    end
    self.presentMs = (os.clock() - presentStart) * 1000
    self.pending = pending
    if capped then self.counts.capped = self.counts.capped + 1; self.window.capped = self.window.capped + 1 end
    -- 5. `refresh` re-asserts per call, guaranteed even when the moves used the budget (a still row is otherwise
    --    never rewritten and a client-local kill could free its slot), the longest-unwritten rows first (a linear
    --    selection of the `refresh` oldest; no sort of every row)
    local picks = {}
    if self.refresh > 0 then
        for _, id in ipairs(order) do
            local entry = self.rows[id]
            if entry and not touched[id] then
                local w = entry.writtenAt
                local k = #picks
                if k < self.refresh or w < self.rows[picks[k]].writtenAt
                    or (w == self.rows[picks[k]].writtenAt and id < picks[k]) then
                    local at = k + 1
                    while at > 1 do
                        local o = self.rows[picks[at - 1]]
                        if o.writtenAt < w or (o.writtenAt == w and picks[at - 1] < id) then break end
                        at = at - 1
                    end
                    table.insert(picks, at, id)
                    if #picks > self.refresh then picks[#picks] = nil end
                end
            end
        end
    end
    for _, id in ipairs(picks) do
        local entry = self.rows[id]
        local nrow = { id = id, x = entry.x, y = entry.y, z = 0, enemyType = entry.enemyType, damage = entry.damage,
            hp = R.CLIENT_HP }
        local ok, why = self:_update(id, entry, nrow)
        if not ok then return false, why end
        if why ~= 'reseeded' then
            entry.writtenAt = self.writes; self.writes = self.writes + 1
            self.counts.refreshed = self.counts.refreshed + 1
        end
    end
    -- fill progress for a (re)join cover: native rows up to the cap, every live enemy drawn (up to the pool)
    local drawnNow = 0
    for _, e in pairs(self.rows) do if e.px or e.actor then drawnNow = drawnNow + 1 end end
    for _, e in pairs(self.drawn) do if e.px then drawnNow = drawnNow + 1 end end
    local pcap = math.type(self.presentation.cap) == 'integer' and self.presentation.cap or #order
    local lostLive = 0
    for _, id in ipairs(order) do if self.lost[id] then lostLive = lostLive + 1 end end
    self.fill = { native = native, nativeTarget = math.min(#order - lostLive, self.nativeCap), drawn = drawnNow,
        drawnTarget = math.min(#order, pcap) }
    return true
end
-- Once a second (call every tick with the clock): "ROWS received=<live host rows in the newest snapshot>
-- applied=<snapshot revisions applied> presented=<rows drawn> pending=<spawns/retirements waiting for budget>
-- capped=<applies that ran out of write budget> refused=<presentation refusals, total> pool=<owned instances>/<cap>".
function R:Report(now)
    if type(now) ~= 'number' then return end
    if not self.reportAt then self.reportAt = now; return end
    if now - self.reportAt < 1 then return end
    self.reportAt = now
    local presented = 0
    for _, entry in pairs(self.rows) do if entry.px then presented = presented + 1 end end
    for _, entry in pairs(self.drawn) do if entry.px then presented = presented + 1 end end   -- drawn-only rows (test 14)
    local p = self.presentation
    local pool = (type(p) == 'table' and math.type(p.count) == 'integer') and p.count or presented
    local cap = (type(p) == 'table' and math.type(p.cap) == 'integer') and tostring(p.cap) or '-'
    local scrubbed = '-'
    if type(self.api.status) == 'function' then
        local ok, _, _, _, _, n = pcall(self.api.status)
        if ok and math.type(n) == 'integer' then scrubbed = tostring(n) end
    end
    local w = self.window
    local avg = (w.calls or 0) > 0 and w.ms / w.calls or 0
    local function per(v) return (w.calls or 0) > 0 and (v or 0) / w.calls or 0 end
    local native = 0
    for _ in pairs(self.rows) do native = native + 1 end
    self.log(string.format('ROWS received=%d applied=%d presented=%d pending=%d capped=%d refused=%d pool=%d/%s skipped=%d displaced=%d recovered=%d view=%d dead=%d ms=%.1f/%.1f scrubbed=%s deathfx=%d/%d native=%d/%d reseeded=%d poolfull=%d prof=v%.2f/f%.2f/n%.2f/p%.2f/r%.2f',
        self.received or 0, w.applied, presented, self.pending or 0, w.capped, self.counts.refused, pool, cap,
        self.counts.skipped, self.counts.displaced, self.counts.recovered, self.viewTotal or 0, self.viewDead or 0, avg, w.maxMs or 0, scrubbed,
        self.counts.deathfx, self.counts.deathfxRefused, native, self.nativeCap, self.counts.reseeded, self.counts.poolFull,
        per(w.view), per(w.frame), per(w.native), per(w.present), per(w.refresh)))
    self.window = { applied = 0, capped = 0 }
end

function R:_drawable(kind)
    local p = self.presentation
    if type(p.HasTemplate) ~= 'function' then return true end
    local ok, has = pcall(p.HasTemplate, p, kind)
    return ok and has == true
end
function R:Recover(ctx)
    if self.state ~= 'held' then return false, 'rows_not_held' end
    if type(ctx) ~= 'table' or not self.ctx or ctx.key ~= self.ctx.key then return false, 'rows_context_changed' end
    local c = self.ctx
    local ids = {}
    for id in pairs(self.rows) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry = self.rows[id]
        pcall(self.api.retire, c.generation, id, entry.slot, entry.enemyType)
        pcall(self.adapter.RemoveEnemy, self.adapter, id)
    end
    -- Release everything and bind again from scratch in this same call (no local simulation runs in between).
    -- Test 10: a resume reloaded the world and the presentation stayed bound to the old controller, so reinstalling
    -- the fence alone was "suppression_lost" again at once; the presentation is now cleared, forgotten and rebound,
    -- and the local meshes hidden again, exactly as Enable does. Already-freed components are tolerated.
    local p = self.presentation
    if type(p.Clear) == 'function' then pcall(p.Clear, p) end
    if type(p.Forget) == 'function' then pcall(p.Forget, p) end
    pcall(self.api.configure, c.generation, c.worldPath, c.controllerPath, false)
    if R.bindings[self.api.configure] == c then R.bindings[self.api.configure] = nil end
    self.rows, self.bySlot, self.epoch, self.revision = {}, {}, nil, nil
    self.drawn, self.ranked, self.rankOf, self.fill = {}, nil, nil, nil
    self.actorVisual, self.actorFirst = {}, nil
    self.state, self.reason, self.adapter, self.ctx = 'idle', nil, nil, nil
    local ok, enabled, why = pcall(self.Enable, self, ctx)
    if not ok or enabled ~= true then
        self.state, self.ctx = 'held', self.ctx or c
        self.reason = 'rows_recover_failed:' .. tostring(ok and (why or self.reason) or enabled)
        self.log('ROWS recover failed reason=' .. self.reason)
        return false, self.reason
    end
    self.counts.recovered = self.counts.recovered + 1
    self.log('ROWS recovered ctx=' .. tostring(c.key))
    return true
end
-- Fail-safe while held (test 10): the client's own enemy simulation must never run. When the native fence reports
-- inactive it is released and installed again for the held context; logged once per hold.
function R:EnsureFence()
    if self.state ~= 'held' or not self.ctx then return true end
    local okStatus, active = pcall(self.api.status)
    if okStatus and active == true then return true end
    local c = self.ctx
    pcall(self.api.configure, c.generation, c.worldPath, c.controllerPath, false)
    local ok, done = pcall(self.api.configure, c.generation, c.worldPath, c.controllerPath, true)
    local fenced = ok and done == true
    if self.failsafeLogged ~= self.reason then
        self.failsafeLogged = self.reason
        self.log('ROWS failsafe fence reinstalled ok=' .. tostring(fenced) .. ' held=' .. tostring(self.reason))
    end
    return fenced
end
function R:EnemyIdAt(slot) return self.bySlot[slot] end
-- D43: whether a client slot is the proxy of a boss/unique (for the hit counters).
function R:IsActorSlot(slot)
    local id = self.bySlot[slot]
    return id ~= nil and self.rows[id] ~= nil and self.rows[id].actor == true
end
function R:_actorRefusal(step, why)
    self.actorRefusals = self.actorRefusals or {}
    if self.actorRefusals[step] then return end
    self.actorRefusals[step] = true
    self.log('ROWS actor visual refused step=' .. step .. ' reason=' .. tostring(why))
end
-- The drawn position (and class) of the row a client hit landed on: x, y, enemyType, or nil.
function R:PositionOfSlot(slot)
    local id = self.bySlot[slot]
    local entry = id and self.rows[id]
    if not entry then return nil end
    return entry.px or entry.x, entry.py or entry.y, entry.enemyType
end
function R:SlotOf(id) local entry = self.rows[id]; return entry and entry.slot or nil end
-- The drawn ordinary (not actor) rows within r cm of (x, y), at most max (test 13: AOE damage numbers).
function R:RowsWithin(x, y, r, max)
    local out = {}
    if type(x) ~= 'number' or type(y) ~= 'number' or type(r) ~= 'number' or r <= 0 then return out end
    local r2 = r * r
    for _, entry in pairs(self.rows) do
        if #out >= (max or 8) then break end
        local ex, ey = entry.px or entry.x, entry.py or entry.y
        if not entry.actor and ex and ey and (ex - x) ^ 2 + (ey - y) ^ 2 <= r2 then out[#out + 1] = { x = ex, y = ey } end
    end
    return out
end

function R:_abandon()
    pcall(self.api.configure, self.ctx.generation, self.ctx.worldPath, self.ctx.controllerPath, false)
    if R.bindings[self.api.configure] == self.ctx then R.bindings[self.api.configure] = nil end
    if type(self.presentation.Forget) == 'function' then pcall(self.presentation.Forget, self.presentation) end
    self.log('ROWS abandoned ctx=' .. tostring(self.ctx.key) .. ' (level gone; nothing in it was touched)')
    self.rows, self.bySlot, self.retired, self.drawn = {}, {}, {}, {}
    self.state, self.reason, self.adapter, self.ctx = 'idle', nil, nil, nil
    return true
end
function R:Disable()
    if self.state == 'idle' then return true end
    if self.state == 'held' and not self.adapter then return self:ForceRelease('held_without_binding:' .. tostring(self.reason)) end
    if self.worldLive and self.ctx then
        local ok, live = pcall(self.worldLive, self.ctx.worldPath)
        if not ok or live ~= true then return self:_abandon() end
    end
    if not self.adapter then return self:ForceRelease('no_adapter') end
    local ids = {}
    for id in pairs(self.rows) do ids[#ids + 1] = id end
    table.sort(ids)
    -- a record the game already freed counts as retired; any other refusal never holds the disable
    for _, id in ipairs(ids) do self:_retire(id, true) end
    for id in pairs(self.drawn) do pcall(self.adapter.RemoveEnemy, self.adapter, id) end
    self.drawn = {}
    local ok, done, why = pcall(self.adapter.SuppressLocalSimulation, self.adapter, self.ctx.key, false)
    if not ok then return self:_hold('rows_disable_failed:' .. tostring(done)) end
    if done ~= true then
        if tostring(why):find('component_cleanup_pending', 1, true) then return nil, 'component_cleanup_pending' end
        return self:_hold('rows_disable_failed:' .. tostring(why))
    end
    self.log('ROWS disabled ctx=' .. tostring(self.ctx.key))
    if R.bindings[self.api.configure] == self.ctx then R.bindings[self.api.configure] = nil end
    self.state, self.reason, self.adapter, self.ctx = 'idle', nil, nil, nil
    return true
end
-- Release no matter what (a disable that keeps failing, a stuck binding): best-effort mesh restore and component
-- cleanup, the native fence released, the ledger forgotten. One log line; the next Enable binds again.
function R:ForceRelease(reason)
    if self.state == 'idle' and not self.ctx then return true end
    local c = self.ctx
    if self.adapter and c then pcall(self.adapter.SuppressLocalSimulation, self.adapter, c.key, false) end
    if type(self.presentation.Clear) == 'function' then pcall(self.presentation.Clear, self.presentation) end
    if type(self.presentation.Forget) == 'function' then pcall(self.presentation.Forget, self.presentation) end
    if c then pcall(self.api.configure, c.generation, c.worldPath, c.controllerPath, false) end
    if c and R.bindings[self.api.configure] == c then R.bindings[self.api.configure] = nil end
    self.log('ROWS force released ctx=' .. tostring(c and c.key) .. ' reason=' .. tostring(reason))
    self.rows, self.bySlot, self.drawn = {}, {}, {}
    self.state, self.reason, self.adapter, self.ctx = 'idle', nil, nil, nil
    return true
end

function R:Status()
    local live = 0
    for _ in pairs(self.rows) do live = live + 1 end
    return { state = self.state, reason = self.reason, live = live, spawned = self.counts.spawned,
        updated = self.counts.updated, retired = self.counts.retired, applied = self.counts.applied,
        refreshed = self.counts.refreshed, pending = self.pending or 0, capped = self.counts.capped,
        refused = self.counts.refused, skipped = self.counts.skipped, displaced = self.counts.displaced,
        recovered = self.counts.recovered, deathfx = self.counts.deathfx, deathfxRefused = self.counts.deathfxRefused,
        mapRefreshed = self.mapRefreshed, mapRefreshFailed = self.mapRefreshFailed, reseeded = self.counts.reseeded,
        poolFull = self.counts.poolFull, nativeCap = self.nativeCap, fill = self.fill }
end

return R
