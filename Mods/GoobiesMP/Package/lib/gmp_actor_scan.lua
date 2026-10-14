-- D43 (host): the boss and non-boss unique actors of the host's world, mapped to their rows' host lifetimes, for the
-- clients' visual-only copies (ACTOR_INFO). research/RESEARCH_GAMEPLAY.md section 13: BP_Boss_C draws itself with
-- BossMesh (StaticMesh = the boss data asset's Mesh, scaled), BP_MiniBoss and its uniques with StaticMesh; each reads
-- its row through MyIndex. Read-only; every actor is read under pcall (a freed actor never breaks the scan).
--   Scan.Scan(G, registry, epoch) -> { {epoch, id, kind 'boss'|'unique', mesh, scale, name, maxHp}, ... },
--       stats { found = {class = n}, skip = {reason = n} } (reasons: no_index, no_row, no_mesh, read_error)
--   Scan.Summary(stats, mapped, sent) -> 'found=<class:n,...> mapped=<n> sent=<n> skip=<reason:n,...>' (ACTORSCAN)
local Scan = {}
Scan.CLASSES = {
    { name = 'BP_Boss_C', kind = 'boss' },
    { name = 'BP_MiniBoss_C', kind = 'unique' },
    { name = 'BP_Bacharach_C', kind = 'unique' }, { name = 'BP_Spider_C', kind = 'unique' }, { name = 'BP_Ulla_C', kind = 'unique' },
    { name = 'BP_Runner_C', kind = 'unique' }, { name = 'BP_Blobby_C', kind = 'unique' },
}
local function text(v)
    if v == nil then return nil end
    if type(v) == 'string' then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == 'string' and s or nil
end
local function number(v) return type(v) == 'number' and v == v and v or nil end
local function read(a, kind, registry, epoch)
    -- UE4SS may push an IntProperty as a float (test 10: nothing mapped): any whole number is a slot
    local index = type(a.MyIndex) == 'number' and math.tointeger(a.MyIndex) or nil
    if not index then return nil, 'no_index' end
    local id = registry:IdForSlot(index)
    if type(id) ~= 'string' then return nil, 'no_row' end
    -- a boss whose IsMiniBoss? is set draws like a unique
    if kind == 'boss' and a['IsMiniBoss?'] == true then kind = 'unique' end
    local component = kind == 'boss' and a.BossMesh or a.StaticMesh or a.BossMesh
    local meshName = component and text(component.StaticMesh and component.StaticMesh:GetFullName())
    local mesh = meshName and meshName:gsub('^%S+%s+', '') or nil
    if not mesh or mesh == '' then return nil, 'no_mesh' end
    local scale = number(component.RelativeScale3D and component.RelativeScale3D.X) or 1
    local name
    pcall(function() name = text(a.Boss and a.Boss.Name) end)
    name = name or text(a.MiniBossName) or (text(a:GetFullName()) or 'enemy'):match('^(%S+)')
    local maxHp = kind == 'boss' and (number(a['Start HP']) or number(a.MaxHP)) or (number(a.MaxHP) or number(a['Start HP']))
    return { epoch = epoch, id = id, kind = kind, mesh = mesh, scale = string.format('%.6g', scale), name = name:sub(1, 64),
        maxHp = string.format('%.6g', maxHp or 0) }
end
function Scan.Scan(G, registry, epoch)
    local out, stats = {}, { found = {}, skip = {} }
    if type(G) ~= 'table' or type(G.FindAllOf) ~= 'function' or type(registry) ~= 'table' then return out, stats end
    local function skip(why) stats.skip[why] = (stats.skip[why] or 0) + 1 end
    for _, class in ipairs(Scan.CLASSES) do
        local ok, list = pcall(G.FindAllOf, class.name)
        if ok and type(list) == 'table' and #list > 0 then
            stats.found[class.name] = #list
            for _, a in ipairs(list) do
                local okRead, info, why = pcall(read, a, class.kind, registry, epoch)
                if not okRead then skip('read_error')
                elseif info then out[#out + 1] = info
                else skip(why or 'read_error') end
            end
        end
    end
    return out, stats
end
local function counts(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. ':' .. t[k] end
    return #keys > 0 and table.concat(keys, ',') or '-'
end
function Scan.Summary(stats, mapped, sent)
    return string.format('found=%s mapped=%d sent=%d skip=%s', counts(stats and stats.found), mapped or 0, sent or 0,
        counts(stats and stats.skip))
end
return Scan
