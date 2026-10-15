-- D53: the Host dropdown's Steam entries. Pure Lua.
-- Native list (Coder B): GMP_Lob_List() -> text, generation; one lobby per line, tab-separated fields:
--   lobbyId, ownerSteamId, ownerName, members, max, friend (1/0), gmp_state ('lobby'|'run'|''), gmp_mods (hash|''),
--   gmp_ver
-- gmp_* are the host's lobby data (GMP_Lob_Data; the app publishes them, App:_tickSteamLobbyData).
local B = {}
local function decimal(v) return type(v) == 'string' and #v >= 1 and #v <= 20 and v:match('^[1-9]%d*$') ~= nil end

-- FNV-1a 32 over the D42 manifest text: 8 hex digits, the same on every PC for the same mods.
function B.ModHash(manifest)
    local h = 2166136261
    for i = 1, #tostring(manifest or '') do
        h = h ~ tostring(manifest):byte(i)
        h = (h * 16777619) & 0xffffffff
    end
    return string.format('%08x', h)
end

function B.Parse(text)
    local out = {}
    for row in tostring(text or ''):gmatch('[^\n]+') do
        local f = {}
        for field in (row .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = field end
        local members, max = tonumber(f[4]), tonumber(f[5])
        if #f == 9 and decimal(f[1]) and decimal(f[2]) and f[3] ~= '' and #f[3] <= 64
            and math.type(members) == 'integer' and math.type(max) == 'integer' and members >= 0 and max >= 1 and max <= 64
            and (f[6] == '0' or f[6] == '1') and (f[7] == 'lobby' or f[7] == 'run' or f[7] == '') and #f[8] <= 16 and #f[9] <= 32 then
            out[#out + 1] = { id = f[1], owner = f[2], name = f[3], members = members, max = max, friend = f[6] == '1',
                state = f[7], mods = f[8], ver = f[9] }
        end
    end
    return out
end
-- friends first, then by name, then by id
function B.Sort(list)
    table.sort(list, function(a, b)
        if a.friend ~= b.friend then return a.friend end
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end
        return a.id < b.id
    end)
    return list
end
function B.Filter(list, friendsOnly)
    if not friendsOnly then return list end
    local out = {}
    for _, e in ipairs(list) do if e.friend then out[#out + 1] = e end end
    return out
end
-- t3 friend reports (Coder A): a host on another Goobies MP version (its published gmp_ver) cannot be joined; the
-- dropdown says so before anyone tries. A host that publishes no version is not blocked (the handshake still checks).
function B.OtherVersion(e, myVersion)
    return type(myVersion) == 'string' and myVersion ~= '' and type(e.ver) == 'string' and e.ver ~= '' and e.ver ~= myVersion
end
function B.Refusal(e, myVersion)
    if B.OtherVersion(e, myVersion) then
        return string.format('The host has Goobies MP %s; you have %s. Both players need the same version.', e.ver, myVersion)
    end
end
-- A full lobby cannot be joined; an in-progress one only by a returning player (the host decides, D52).
function B.Joinable(e, myVersion) return e.members < e.max and not B.OtherVersion(e, myVersion) end
function B.Label(e, myHash, myVersion)
    local parts = { string.format('%s (%d/%d)', e.name, e.members, e.max) }
    if e.members >= e.max then parts[#parts + 1] = 'full' end
    if e.state == 'run' then parts[#parts + 1] = 'in progress' end
    if B.OtherVersion(e, myVersion) then parts[#parts + 1] = 'different version: host ' .. e.ver
    elseif e.mods == '' or not myHash then parts[#parts + 1] = 'mods unknown'
    elseif e.mods == myHash then parts[#parts + 1] = 'same mods'
    else parts[#parts + 1] = 'different mods' end
    return table.concat(parts, ' - ')
end
return B
