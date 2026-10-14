-- D42: gameplay mods and versions must match the host's. Pure Lua.
-- The source is Mod Menu's registry, Configs/ModList.ini: one "Id=true|Ver:x|..." line per package. Only enabled
-- packages count, and purely cosmetic ones (COSMETIC) may differ. The manifest is one canonical string,
-- "id:version;id:version" sorted by id, so two installs compare by plain equality.
local M = {}
M.COSMETIC = { MenuOptions = true }
M.MAX_BYTES = 1000

local function token(s) return type(s) == 'string' and s ~= '' and not s:find('[;:|%s]') end

-- ModList.ini text -> manifest string ('' when nothing is readable), or nil when there is no registry text at all.
function M.FromModList(text)
    if type(text) ~= 'string' then return nil end
    local mods = {}
    for line in (text .. '\n'):gmatch('([^\r\n]*)[\r\n]') do
        local id, enabled, rest = line:match('^%s*([%w_%-%.]+)%s*=%s*(%a+)(.*)$')
        if id and enabled == 'true' and not M.COSMETIC[id] then
            local version = rest:match('|%s*[Vv][Ee][Rr]%s*:%s*([^|]+)') or '?'
            version = version:gsub('%s+$', '')
            if token(id) and token(version) then mods[#mods + 1] = id .. ':' .. version end
        end
    end
    table.sort(mods)
    local s = table.concat(mods, ';')
    if #s > M.MAX_BYTES then s = s:sub(1, M.MAX_BYTES) end
    return s
end
local function parse(manifest)
    local out = {}
    for item in tostring(manifest or ''):gmatch('[^;]+') do
        local id, version = item:match('^([^:]+):(.+)$')
        if id then out[id] = version end
    end
    return out
end
-- host manifest, local manifest -> sorted lines naming each difference (empty when they match).
function M.Diff(host, mine)
    local h, m, ids, seen = parse(host), parse(mine), {}, {}
    for id in pairs(h) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    for id in pairs(m) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    table.sort(ids)
    local lines = {}
    for _, id in ipairs(ids) do
        local hv, mv = h[id], m[id]
        if hv and not mv then lines[#lines + 1] = id .. ': the host has ' .. hv .. ', you do not have it'
        elseif mv and not hv then lines[#lines + 1] = id .. ' ' .. mv .. ': the host does not have it'
        elseif hv ~= mv then lines[#lines + 1] = id .. ': the host has ' .. hv .. ', you have ' .. mv end
    end
    return lines
end
function M.Notice(lines)
    local text = 'Your mods differ from the host\'s, so you left the lobby: ' .. table.concat(lines, '; ')
        .. '. Install the same mods (Menu Options may differ) and join again.'
    return #text > 600 and (text:sub(1, 597) .. '...') or text
end
return M
