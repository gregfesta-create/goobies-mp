-- D45/D44/D46 (Coder C): the shared reward-screen barrier. Pure logic, no game objects, no messages. Used for level-ups
-- (gmp_xp_host.lua) and, by Coder B, for roulettes (D44): every listed player gets their own screen(s) under the shared
-- pause; once the first player finishes, the others auto-pick after autoPickSeconds (D44/D45: about 2 s). Ghosts and
-- players who leave count as done (D46: ghosts get their missed picks after reviving, as a catch-up barrier). A
-- catch-up barrier (late rejoin, revive) starts with a fixed budget instead (D46: 30 s under 10 missed levels, about
-- 3 s more per extra level). A player who neither picks nor auto-picks is forced done graceSeconds after the deadline,
-- so a hung client can never hold the shared pause.
--   B.new{autoPickSeconds=2, graceSeconds=10}
--   b:Open(id, kind, participants{key -> {ghost=bool}}, now, {count=1, budgetSeconds=nil}) -> ok | nil, why
--   b:Done(id, key, now) -> true when newly done        b:Leave(key)   (done in every open barrier)
--   b:Skip(id, key) -> true: done without starting the deadline (a ghost)
--   b:Tick(now) -> {{type='deadline'|'expired'|'closed', id}}   (each once; closed barriers are removed)
--   b:State(id) -> {id, kind, phase='open'|'deadline', count, deadlineAt, waiting={keys}, ghosts={keys}} | nil
--   b:Screen(id, now, context) -> REWARD_SCREEN fields | nil    b:Remaining(id, now) -> seconds
--   b:Active() -> ids    b:Owed(key) -> ids the player still owes    b:LastClose() -> {id, forced, waiting}
local B = {}; B.__index = B
B.KINDS = { levelup = true, loot = true, bush = true, reward = true, roulette = true, catchup = true }
B.AUTO_PICK_SECONDS = 2
B.GRACE_SECONDS = 10

function B.CatchupSeconds(missed)
    missed = math.max(0, math.floor(missed or 0))
    if missed < 10 then return 30 end
    return 30 + 3 * (missed - 9)
end

function B.new(options)
    options = options or {}
    return setmetatable({ autoPick = options.autoPickSeconds or B.AUTO_PICK_SECONDS, grace = options.graceSeconds or B.GRACE_SECONDS,
        open = {} }, B)
end
local function sortedKeys(set, want)
    local out = {}
    for k, v in pairs(set) do if v == want then out[#out + 1] = k end end
    table.sort(out)
    return out
end
function B:Open(id, kind, participants, now, opts)
    opts = opts or {}
    if math.type(id) ~= 'integer' or id < 1 then return nil, 'barrier_id' end
    if self.open[id] then return nil, 'barrier_open' end
    if not B.KINDS[kind] or type(participants) ~= 'table' or next(participants) == nil then return nil, 'barrier_invalid' end
    local b = { id = id, kind = kind, count = opts.count or 1, state = {}, ghost = {} }
    for key, info in pairs(participants) do
        if type(key) ~= 'string' then return nil, 'barrier_invalid' end
        local ghost = type(info) == 'table' and info.ghost == true
        b.state[key] = ghost and 'done' or 'waiting'
        b.ghost[key] = ghost or nil
    end
    if opts.budgetSeconds then b.deadlineAt = now + opts.budgetSeconds end
    self.open[id] = b
    return true
end
function B:Done(id, key, now)
    local b = self.open[id]
    if not b or b.state[key] ~= 'waiting' then return false end
    b.state[key] = 'done'
    if not b.deadlineAt then b.deadlineAt = now + self.autoPick end
    return true
end
-- Done without starting the deadline (a ghost skips its screen; D46: it gets the pick after reviving).
function B:Skip(id, key)
    local b = self.open[id]
    if not b or b.state[key] ~= 'waiting' then return false end
    b.state[key] = 'done'; b.ghost[key] = true
    return true
end
function B:Leave(key)
    for _, b in pairs(self.open) do if b.state[key] == 'waiting' then b.state[key] = 'done' end end
end
function B:_ids()
    local ids = {}
    for id in pairs(self.open) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end
function B:Tick(now)
    local events = {}
    for _, id in ipairs(self:_ids()) do
        local b = self.open[id]
        local waiting = sortedKeys(b.state, 'waiting')
        if #waiting == 0 then
            self.open[id] = nil; self.last = { id = id, forced = false, waiting = {} }
            events[#events + 1] = { type = 'closed', id = id }
        elseif b.deadlineAt then
            if not b.announced then b.announced = true; events[#events + 1] = { type = 'deadline', id = id } end
            if now >= b.deadlineAt and not b.expired then b.expired = true; events[#events + 1] = { type = 'expired', id = id } end
            if b.expired and now >= b.deadlineAt + self.grace then
                self.open[id] = nil; self.last = { id = id, forced = true, waiting = waiting }
                events[#events + 1] = { type = 'closed', id = id }
            end
        end
    end
    return events
end
function B:LastClose() return self.last end
function B:State(id)
    local b = self.open[id]
    if not b then return nil end
    local ghosts = {}
    for k in pairs(b.ghost) do ghosts[#ghosts + 1] = k end
    table.sort(ghosts)
    return { id = id, kind = b.kind, phase = b.deadlineAt and 'deadline' or 'open', count = b.count, deadlineAt = b.deadlineAt,
        waiting = sortedKeys(b.state, 'waiting'), ghosts = ghosts, expired = b.expired == true }
end
function B:Remaining(id, now)
    local b = self.open[id]
    if not b or not b.deadlineAt then return nil end
    return math.max(0, b.deadlineAt - now)
end
function B:Screen(id, now, context)
    local b = self.open[id]
    if not b then return nil end
    local remain = b.deadlineAt and math.max(0, math.floor((b.deadlineAt - now) * 1000 + 0.5)) or 0
    return { context = context, id = id, kind = b.kind, phase = b.deadlineAt and 'deadline' or 'open', count = b.count, remainMs = remain }
end
function B:Active() return self:_ids() end
function B:Owed(key)
    local out = {}
    for _, id in ipairs(self:_ids()) do if self.open[id].state[key] == 'waiting' then out[#out + 1] = id end end
    return out
end
return B
