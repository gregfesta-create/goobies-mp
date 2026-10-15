-- Player display names. In a Steam session (friend, production) the host reads each player's Steam persona name
-- natively by its authenticated Steam ID (gmp_app.lua App.SteamNameResolver -> GMP_Name_Get) and shares it through the
-- ROSTER (Host:SetNameResolver, gmp_host.lua); a client's own claim is never shown. Dev sessions keep their dev names.
local Config = require('gmp_config')
local N = {}
N.REFRESH_SECONDS = 15        -- resolved names are asked again this often (a rename)
N.PENDING_SECONDS = 1         -- unresolved names are asked this often
N.UNKNOWN = { ['[unknown]'] = true }

-- text -> a display-safe name, or nil when there is nothing usable: control characters become spaces, runs of spaces
-- collapse, at most Config.MAX_NAME_BYTES bytes, never a cut UTF-8 sequence.
function N.Sanitize(text)
    if type(text) ~= 'string' then return nil end
    local s = text:gsub('%c', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
    if #s > Config.MAX_NAME_BYTES then
        local cut = Config.MAX_NAME_BYTES
        -- back off continuation bytes, then drop a lead byte whose sequence no longer fits
        while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = s:sub(1, cut):match('^(.-)%s*$')
    end
    if s == '' or N.UNKNOWN[s] or not utf8.len(s) then return nil end
    return s
end
function N.Fallback(slot) return 'Player ' .. tostring(slot) end
-- The pause notice: who paused, by the shared name (the slot fallback when it has none), "(host)" for the host.
function N.PausedBy(players, ownerKey)
    for _, p in ipairs(players or {}) do
        if p.key == ownerKey then
            local name = N.Sanitize(p.name) or (type(p.slot) == 'number' and N.Fallback(p.slot)) or 'a player'
            return 'Paused by ' .. name .. (p.role == 'host' and ' (host)' or '')
        end
    end
    return 'Paused by a player'
end
return N
