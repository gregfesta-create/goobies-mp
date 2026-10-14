-- Cross-PC Steam lobby, Lua side (research/CROSS_PC_GAPS.md 1.1-1.3). Pure Lua.
--   ParseLobbyId: a typed or pasted lobby ID, read from the forms friends actually send (the bare number, with spaces,
--     "Lobby ID: <id>", a steam://joinlobby/<app>/<lobby>/<owner> link, "+connect_lobby <id>").
--   RichPresence: the Steam rich presence keys this mod owns. An empty value deletes the key (the native side calls
--     SetRichPresence(key, value)); ClearRichPresence is never used, so the game's own keys stay.
local I = {}
I.MAX_TEXT = 200
I.COPY_HINT = 'Click the ID, press Ctrl+A, then Ctrl+C to copy it. Friends paste it into Join lobby.'
I.COPY_TOOLTIP = 'The Steam lobby ID. Select it and press Ctrl+C to copy.'
I.REASON_TEXT = {
    empty = 'Paste the lobby ID the host shows under Lobby ID.',
    no_lobby_id = 'That is not a lobby ID. Paste the number the host shows under Lobby ID (17 to 20 digits).',
    several_ids = 'That text has more than one lobby ID. Paste only the one the host shows under Lobby ID.',
    player_id = "That is a player's Steam ID, not a lobby ID. Paste the number the host shows under Lobby ID.",
}
-- Individual Steam accounts (SteamID64 7656119...); a lobby ID is a different kind of Steam ID.
local function playerId(s) return #s == 17 and s:sub(1, 7) == '7656119' end
local function longId(s) return #s >= 17 and #s <= 20 and s:sub(1, 1) ~= '0' end

-- text -> lobby id string, or nil, reason (a key of REASON_TEXT).
function I.ParseLobbyId(text)
    if type(text) ~= 'string' then return nil, 'empty' end
    local t = text:sub(1, I.MAX_TEXT):match('^%s*(.-)%s*$')
    if t == '' then return nil, 'empty' end
    local linked = t:match('joinlobby/%d+/(%d+)')
    if linked then
        if longId(linked) then return linked end
        return nil, 'no_lobby_id'
    end
    local compact = t:gsub('[%s%-]', '')
    if compact:match('^[1-9]%d*$') and #compact <= 20 then
        if playerId(compact) then return nil, 'player_id' end
        return compact
    end
    local found, seen, players = {}, {}, 0
    for run in t:gmatch('%d+') do
        if longId(run) and not seen[run] then
            seen[run] = true
            if playerId(run) then players = players + 1 else found[#found + 1] = run end
        end
    end
    if #found == 1 then return found[1] end
    if #found > 1 then return nil, 'several_ids' end
    return nil, players > 0 and 'player_id' or 'no_lobby_id'
end

I.PRESENCE_KEYS = { 'status', 'connect', 'steam_player_group', 'steam_player_group_size' }
-- state: nil (no session) or { phase = 'lobby'|'run', lobbyId, players, slots } -> ordered { {key, value}, ... }.
-- "connect" turns on Join game in the Steam friends list; it is offered only for an open lobby with a free slot.
function I.RichPresence(state)
    local v = {}
    if type(state) == 'table' and type(state.lobbyId) == 'string' and state.lobbyId ~= '' then
        local players, slots = tonumber(state.players) or 0, tonumber(state.slots) or 0
        if state.phase == 'run' then
            v.status = string.format('Goobies MP: in a run (%d %s)', players, players == 1 and 'player' or 'players')
        else
            v.status = string.format('Goobies MP: in a lobby (%d/%d)', players, slots)
            if players < slots then v.connect = '+connect_lobby ' .. state.lobbyId end
        end
        v.steam_player_group, v.steam_player_group_size = state.lobbyId, tostring(players)
    end
    local out = {}
    for _, key in ipairs(I.PRESENCE_KEYS) do out[#out + 1] = { key, v[key] or '' } end
    return out
end
return I
