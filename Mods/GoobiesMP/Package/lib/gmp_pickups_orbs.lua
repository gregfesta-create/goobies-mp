-- D45 (Coder C; research/RESEARCH_PICKUPS.md 4-6): shared XP orb clumps. Pure logic, no game objects.
--
-- The game's XP orbs are instances of one instanced mesh (BP_EnemyController.XPInstanceComponent) and every picked-up
-- instance is worth exactly 1 XP (BPC_CheckingForXP: AddExperience(number removed)). The host groups its instances into
-- grid cells; every occupied cell is one clump {id = "cx:cy:gen", x, y, z (centroid), n (orbs)}. Clients draw one orb
-- per clump and report clump ids; the host removes exactly the instances of a claimed clump in the same tick as the scan
-- (indices never go stale) and awards the number removed. A cell that empties and refills gets a new generation, so an
-- old id never claims new orbs. Idempotent by construction: only instances the host really removes are awarded.
--
--   Host.new{cell=400, cap=2048}
--   h:Update(points) -> changed | nil, 'orb_scan_cap'   points[i] = {x, y, z} of instance i-1 (0-based)
--   h:Items()        -> {{kind='o', id, x, y, z, n, v}}  current clumps
--   h:Claim(id)      -> indices (0-based, ascending), n, clump | nil, reason   (consumed until the next Update)
--   h:DiffFor(view, max) -> items (n = 0: removed) that the receiver's `view` {id -> v} has not seen; updates view
--   Client.new{pendingSeconds=3}: c:Reset(context), c:Apply(items) -> changes, c:Get(id), c:Near(x, y, reach, now)
--     -> ids, hide; c:Expire(now) -> ids to show again; c:Each(fn)
local O = {}
O.CELL = 400            -- cm; D46 default about 4 m
O.CAP = 2048            -- instances scanned per update (refused above, never truncated)
O.BASE_RANGE = 650      -- BPC_CheckingForXP sphere radius before AdditionalPickUpRange
O.MAX_EXTRA_RANGE = 3000
O.SLACK = 400           -- presence latency allowance (cm)
O.ID_BYTES = 32
O.MAX_N = 100000
O.KINDS = { o = true, h = true, m = true, i = true, b = true, x = true, r = true }

local function int(v) return math.type(v) == 'integer' end
local function round(v) return math.floor(v + 0.5) end

-- Reach (cm) between a player's position and a clump centre: pickup radius + the player's bounded range + half a cell
-- diagonal + slack.
function O.Reach(range, cell)
    local extra = type(range) == 'number' and range == range and range or 0
    if extra < 0 then extra = 0 elseif extra > O.MAX_EXTRA_RANGE then extra = O.MAX_EXTRA_RANGE end
    return O.BASE_RANGE + extra + round((cell or O.CELL) * 0.70710678) + O.SLACK
end

function O.ValidItem(it)
    if type(it) ~= 'table' or not O.KINDS[it.kind] then return false end
    if type(it.id) ~= 'string' or #it.id < 1 or #it.id > O.ID_BYTES or it.id:find('[^%w:%-_]') then return false end
    for _, k in ipairs({ 'x', 'y', 'z' }) do
        if not int(it[k]) or math.abs(it[k]) > 2000000 then return false end
    end
    return int(it.n) and it.n >= 0 and it.n <= O.MAX_N and int(it.v) and it.v >= 1
end

------------------------------------------------------------------ host
local Host = {}; Host.__index = Host; O.Host = Host
function Host.new(options)
    options = options or {}
    return setmetatable({ cell = options.cell or O.CELL, cap = options.cap or O.CAP, cells = {}, gens = {}, version = 0,
        count = 0, claimed = {} }, Host)
end
function Host:_bump() self.version = self.version + 1; return self.version end
function Host:Reset()
    self.cells, self.gens, self.count, self.claimed = {}, {}, 0, {}
    -- the version keeps rising across resets so a receiver never mistakes a new clump for an old one
end
function Host:Update(points)
    if type(points) ~= 'table' then return nil, 'orb_scan_invalid' end
    if #points > self.cap then return nil, 'orb_scan_cap' end
    local cell, groups = self.cell, {}
    for i, p in ipairs(points) do
        local x, y, z = p.x, p.y, p.z or 0
        if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil, 'orb_scan_invalid' end
        local key = math.floor(x / cell) .. ':' .. math.floor(y / cell)
        local g = groups[key]
        if not g then g = { sx = 0, sy = 0, sz = 0, indices = {} }; groups[key] = g end
        g.sx, g.sy, g.sz = g.sx + x, g.sy + y, g.sz + (type(z) == 'number' and z == z and z or 0)
        g.indices[#g.indices + 1] = i - 1
    end
    local changed = false
    for key, old in pairs(self.cells) do
        if not groups[key] then
            self.cells[key] = nil; changed = true
            self.removed = self.removed or {}
            self.removed[old.id] = self:_bump()
        end
    end
    for key, g in pairs(groups) do
        local n = #g.indices
        local x, y, z = round(g.sx / n), round(g.sy / n), round(g.sz / n)
        local c = self.cells[key]
        if not c then
            local gen = (self.gens[key] or 0) + 1
            self.gens[key] = gen
            c = { id = key .. ':' .. gen, key = key }
            self.cells[key] = c
            c.n, c.x, c.y, c.z, c.v = n, x, y, z, self:_bump(); changed = true
        elseif c.n ~= n or c.x ~= x or c.y ~= y or c.z ~= z then
            c.n, c.x, c.y, c.z, c.v = n, x, y, z, self:_bump(); changed = true
        end
        c.indices = g.indices
    end
    self.count = #points
    self.claimed = {}
    return changed
end
function Host:Count() return self.count end
function Host:ClumpCount() local n = 0; for _ in pairs(self.cells) do n = n + 1 end; return n end
local function item(c) return { kind = 'o', id = c.id, x = c.x, y = c.y, z = c.z, n = c.n, v = c.v } end
function Host:Items()
    local out = {}
    for _, c in pairs(self.cells) do out[#out + 1] = item(c) end
    table.sort(out, function(a, b) return a.v < b.v end)
    return out
end
-- The current clump with this id (no claim), or nil.
function Host:Find(id)
    if type(id) ~= 'string' then return nil end
    local key = id:match('^(%-?%d+:%-?%d+):%d+$')
    local c = key and self.cells[key]
    if not c or c.id ~= id then return nil end
    return item(c)
end
function Host:Claim(id)
    if type(id) ~= 'string' then return nil, 'invalid_clump' end
    local key, gen = id:match('^(%-?%d+:%-?%d+):(%d+)$')
    if not key then return nil, 'invalid_clump' end
    local c = self.cells[key]
    if not c or c.id ~= id then return nil, 'unknown_clump' end
    if self.claimed[key] then return nil, 'claimed' end
    self.claimed[key] = true
    local indices = {}
    for i, v in ipairs(c.indices) do indices[i] = v end
    return indices, #indices, item(c)
end
-- Items the receiver has not seen, oldest change first, at most `max`. Removals (n = 0) are sent for ids the receiver
-- holds and then dropped from its view.
function Host:DiffFor(view, max)
    local out = {}
    max = max or 24
    local current = {}
    for _, c in pairs(self.cells) do
        current[c.id] = true
        if view[c.id] ~= c.v then out[#out + 1] = item(c) end
    end
    for id in pairs(view) do
        if not current[id] then
            local v = self.removed and self.removed[id] or self:_bump()
            out[#out + 1] = { kind = 'o', id = id, x = 0, y = 0, z = 0, n = 0, v = v }
        end
    end
    table.sort(out, function(a, b) if a.v ~= b.v then return a.v < b.v end return a.id < b.id end)
    while #out > max do out[#out] = nil end
    for _, it in ipairs(out) do
        if it.n == 0 then view[it.id] = nil else view[it.id] = it.v end
    end
    return out
end
-- Forget removal versions no receiver still holds (bounded memory); call after every receiver's diff.
function Host:Compact(views)
    if not self.removed then return end
    for id in pairs(self.removed) do
        local held = false
        for _, view in pairs(views or {}) do if view[id] then held = true; break end end
        if not held then self.removed[id] = nil end
    end
end

------------------------------------------------------------------ D49: virtual (merged) orbs (host)
-- The host takes its native orb instances over: each is merged into the nearest virtual orb within `merge` cm (the
-- merged orb stays where its first orb was, so it is stable on screen) or starts a new one; its value is the number
-- of native orbs (1 XP each) it holds. Absorb is all or nothing: past the cap nothing is absorbed, so the caller
-- leaves those natives native (never lost).
--   Virtual.new{merge=300, cap=4096}; v:Absorb(points) -> changed | nil, 'virtual_cap'; v:Items(); v:Find(id);
--   v:Take(id) -> value | nil; v:Near(x, y, reach) -> ids; v:TakeAll() -> total; v:Total(); v:Count(); v:Reset();
--   v:DiffFor(seen, max); v:Compact(views)
O.MERGE = 300
O.VIRTUAL_CAP = 4096
O.TIERS = { 10, 25, 100 }   -- D49: 1-9, 10-24, 25-99, 100+ (a boundary value goes to the higher tier)
function O.Tier(value)
    local tier = 1
    for _, at in ipairs(O.TIERS) do if (value or 0) >= at then tier = tier + 1 end end
    return tier
end
local Virtual = {}; Virtual.__index = Virtual; O.Virtual = Virtual
function Virtual.new(options)
    options = options or {}
    return setmetatable({ merge = options.merge or O.MERGE, cap = options.cap or O.VIRTUAL_CAP, orbs = {}, grid = {}, count = 0,
        total = 0, seq = 0, version = 0, removed = {} }, Virtual)
end
function Virtual:_bump() self.version = self.version + 1; return self.version end
function Virtual:_key(x, y) return math.floor(x / self.merge) .. ':' .. math.floor(y / self.merge) end
function Virtual:_nearest(x, y)
    local cx, cy = math.floor(x / self.merge), math.floor(y / self.merge)
    local best, bestD = nil, self.merge * self.merge
    for dx = -1, 1 do
        for dy = -1, 1 do
            for id in pairs(self.grid[(cx + dx) .. ':' .. (cy + dy)] or {}) do
                local o = self.orbs[id]
                local d = (o.x - x) ^ 2 + (o.y - y) ^ 2
                if d <= bestD then best, bestD = o, d end
            end
        end
    end
    return best
end
function Virtual:Absorb(points)
    if type(points) ~= 'table' then return nil, 'virtual_invalid' end
    -- all or nothing: dry-run the new orbs first
    local plan, created = {}, 0
    local shadow = {}
    for i, p in ipairs(points) do
        if type(p.x) ~= 'number' or type(p.y) ~= 'number' or p.x ~= p.x or p.y ~= p.y then return nil, 'virtual_invalid' end
        local target = self:_nearest(p.x, p.y)
        if not target then
            for _, s in ipairs(shadow) do
                if (s.x - p.x) ^ 2 + (s.y - p.y) ^ 2 <= self.merge * self.merge then target = s; break end
            end
        end
        if not target then
            created = created + 1
            if self.count + created > self.cap then return nil, 'virtual_cap' end
            target = { x = p.x, y = p.y, z = p.z or 0, new = true }
            shadow[#shadow + 1] = target
        end
        plan[i] = target
    end
    local changed = false
    for i, p in ipairs(points) do
        local target = plan[i]
        if target.new and not target.id then
            self.seq = self.seq + 1
            target.id = 'v' .. self.seq
            local o = { id = target.id, x = math.floor(target.x + 0.5), y = math.floor(target.y + 0.5), z = math.floor((target.z or 0) + 0.5),
                value = 0, key = self:_key(target.x, target.y) }
            self.orbs[o.id] = o
            self.grid[o.key] = self.grid[o.key] or {}
            self.grid[o.key][o.id] = true
            self.count = self.count + 1
            target.orb = o
        end
        local o = target.orb or target
        o.value = o.value + (p.value or 1)
        o.v = self:_bump()
        self.total = self.total + (p.value or 1)
        changed = true
    end
    return changed
end
local function vitem(o) return { kind = 'o', id = o.id, x = o.x, y = o.y, z = o.z, n = o.value, v = o.v } end
function Virtual:Items()
    local out = {}
    for _, o in pairs(self.orbs) do out[#out + 1] = vitem(o) end
    table.sort(out, function(a, b) return a.v < b.v end)
    -- stable order for callers that index: oldest orb first
    table.sort(out, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    return out
end
function Virtual:Find(id) local o = self.orbs[id]; return o and vitem(o) or nil end
function Virtual:Count() return self.count end
function Virtual:Total() return self.total end
function Virtual:Take(id)
    local o = self.orbs[id]
    if not o then return nil end
    self.orbs[id] = nil
    if self.grid[o.key] then self.grid[o.key][id] = nil end
    self.count, self.total = self.count - 1, self.total - o.value
    self.removed[id] = self:_bump()
    return o.value
end
function Virtual:Near(x, y, reach)
    local out = {}
    for id, o in pairs(self.orbs) do
        if (o.x - x) ^ 2 + (o.y - y) ^ 2 <= reach * reach then out[#out + 1] = id end
    end
    table.sort(out, function(a, b) return tonumber(a:sub(2)) < tonumber(b:sub(2)) end)
    return out
end
function Virtual:TakeAll()
    local sum = 0
    for id in pairs(self.orbs) do sum = sum + (self:Take(id) or 0) end
    return sum
end
function Virtual:Reset()
    for id in pairs(self.orbs) do self.removed[id] = self:_bump() end
    self.orbs, self.grid, self.count, self.total = {}, {}, 0, 0
end
function Virtual:DiffFor(view, max)
    local out = {}
    max = max or 24
    for id, o in pairs(self.orbs) do if view[id] ~= o.v then out[#out + 1] = vitem(o) end end
    for id in pairs(view) do
        if not self.orbs[id] then out[#out + 1] = { kind = 'o', id = id, x = 0, y = 0, z = 0, n = 0, v = self.removed[id] or self:_bump() } end
    end
    table.sort(out, function(a, b) if a.v ~= b.v then return a.v < b.v end return a.id < b.id end)
    while #out > max do out[#out] = nil end
    for _, it in ipairs(out) do if it.n == 0 then view[it.id] = nil else view[it.id] = it.v end end
    return out
end
function Virtual:Compact(views)
    for id in pairs(self.removed) do
        local held = false
        for _, view in pairs(views or {}) do if view[id] then held = true; break end end
        if not held then self.removed[id] = nil end
    end
end

------------------------------------------------------------------ client view model
local Client = {}; Client.__index = Client; O.Client = Client
function Client.new(options)
    options = options or {}
    return setmetatable({ pendingSeconds = options.pendingSeconds or 3, items = {}, tombs = {}, pending = {} }, Client)
end
function Client:Reset(context) self.context, self.items, self.tombs, self.pending = context, {}, {}, {} end
function Client:Get(id) return self.items[id] end
function Client:Each(fn) for id, it in pairs(self.items) do fn(id, it) end end
function Client:Apply(items)
    local changes = {}
    for _, it in ipairs(items or {}) do
        if O.ValidItem(it) then
            local known = self.items[it.id]
            local last = known and known.v or self.tombs[it.id] or 0
            if it.v > last then
                if it.n == 0 then
                    if known then changes[#changes + 1] = { op = 'remove', id = it.id } end
                    self.items[it.id] = nil; self.pending[it.id] = nil; self.tombs[it.id] = it.v
                else
                    self.items[it.id] = { kind = it.kind, id = it.id, x = it.x, y = it.y, z = it.z, n = it.n, v = it.v }
                    self.tombs[it.id] = nil
                    changes[#changes + 1] = { op = 'set', id = it.id, kind = it.kind, x = it.x, y = it.y, z = it.z, n = it.n,
                        hidden = self.pending[it.id] ~= nil }
                end
            end
        end
    end
    return changes
end
-- Clumps within `reach` (cm, or function(kind) -> cm) of (x, y) that are not already pending: reported now (and
-- hidden until the host answers).
function Client:Near(x, y, reach, now, max)
    local ids = {}
    max = max or 32
    for id, it in pairs(self.items) do
        local r = type(reach) == 'function' and reach(it.kind) or reach
        if not self.pending[id] and (it.x - x) ^ 2 + (it.y - y) ^ 2 <= r * r then ids[#ids + 1] = id end
    end
    table.sort(ids)
    while #ids > max do ids[#ids] = nil end
    for _, id in ipairs(ids) do self.pending[id] = now end
    local hide = {}
    for i, id in ipairs(ids) do hide[i] = id end
    return ids, hide
end
-- Pending clumps the host has not removed within pendingSeconds: shown (and reportable) again.
function Client:Expire(now)
    local out = {}
    for id, at in pairs(self.pending) do
        if now - at >= self.pendingSeconds then self.pending[id] = nil; if self.items[id] then out[#out + 1] = id end end
    end
    table.sort(out)
    return out
end
return O
