-- W11 (PLAN_WORLD_ENTRY.md section 4; D25, D28, D29, D34): pure helpers between the native artifact grid
-- (gmp_lobby_native_selection.lua Catalogue: {id='artifact_<index>', actor=<full name>, available, selected}) and the
-- session policy (actor paths, never a grid index).
local A = {}
-- Fixed client view box (D29): rows of ROW px in a WIDTH x HEIGHT box; scrolling only when more entries than fit.
A.BOX = { width = 385, height = 294, row = 42 }
A.BOX.rows = math.floor(A.BOX.height / A.BOX.row)
-- "BlueprintGeneratedClass /Game/X/BP_Y.BP_Y_C" (or a bare path) -> "/Game/X/BP_Y.BP_Y_C"; anything else -> nil.
function A.ActorPath(identity)
    if type(identity) ~= 'string' then return nil end
    local p = identity:match('^%S+%s+(/%S+)$') or identity:match('^(/%S+)$')
    if p and #p <= 256 and p:match('^/[%w_%-%./]+$') then return p end
    return nil
end
local function byId(catalogue)
    local out = {}
    for _, e in ipairs(catalogue and catalogue.artifacts or {}) do out[e.id] = e end
    return out
end
-- Native ids ("artifact_0+artifact_2") -> actor paths, or nil, 'native_artifacts_unknown'.
function A.NativePaths(catalogue, ids)
    local entries, out = byId(catalogue), {}
    for id in tostring(ids or ''):gmatch('[^+]+') do
        local p = entries[id] and A.ActorPath(entries[id].actor)
        if not p then return nil, 'native_artifacts_unknown' end
        out[#out + 1] = p
    end
    return out
end
-- Actor paths -> native ids this grid can select, plus the paths it cannot ({path, why='locked'|'unknown'}).
function A.IdsForPaths(catalogue, paths)
    local byPath = {}
    for _, e in ipairs(catalogue and catalogue.artifacts or {}) do local p = A.ActorPath(e.actor); if p then byPath[p] = e end end
    local ids, missing = {}, {}
    for _, p in ipairs(paths or {}) do
        local e = byPath[p]
        if not e then missing[#missing + 1] = { path = p, why = 'unknown' }
        elseif not e.available then missing[#missing + 1] = { path = p, why = 'locked' }
        else ids[#ids + 1] = e.id end
    end
    return table.concat(ids, '+'), missing
end
-- The unlocked artifacts of this player's normal save (D34): every available grid entry.
function A.HostUnlocked(catalogue)
    local out = {}
    for _, e in ipairs(catalogue and catalogue.artifacts or {}) do
        local p = A.ActorPath(e.actor); if p and e.available then out[#out + 1] = p end
    end
    return out
end
function A.SameSet(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then return false end
    local seen = {}; for _, v in ipairs(a) do seen[v] = true end
    for _, v in ipairs(b) do if not seen[v] then return false end end
    return true
end
local function label(p) return p:match('([^./]+)_C$') or p:match('([^/]+)$') or p end
-- D29 client view: host-unlocked artifacts glow, the client's own unlocked ones are grey, anything else is hidden.
-- The host's set comes first, marked selected. Returns {entries={{path,label,state,selected}}, scroll, fits}.
function A.ClientView(catalogue, policy)
    local chosen, host = {}, {}
    for _, p in ipairs(policy and policy.artifacts or {}) do chosen[p] = true end
    for _, p in ipairs(policy and policy.hostUnlocked or {}) do host[p] = true end
    local entries, seen = {}, {}
    local function add(p, name, state) if not seen[p] then seen[p] = true; entries[#entries + 1] = { path = p, label = name, state = state, selected = chosen[p] == true } end end
    for _, e in ipairs(catalogue and catalogue.artifacts or {}) do
        local p = A.ActorPath(e.actor)
        if p and host[p] then add(p, e.label or label(p), 'glow') elseif p and e.available then add(p, e.label or label(p), 'grey') end
    end
    for _, p in ipairs(policy and policy.hostUnlocked or {}) do add(p, label(p), 'glow') end
    table.sort(entries, function(x, y) if x.selected ~= y.selected then return x.selected end; return false end)
    return { entries = entries, scroll = #entries > A.BOX.rows, fits = A.BOX.rows }
end
return A
