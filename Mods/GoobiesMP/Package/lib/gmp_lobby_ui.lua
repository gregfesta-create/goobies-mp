-- GoobiesMP: lobby VIEW MODEL (pure Lua). Turns host/client session state into rows, a settings list and plain text lines.
-- No Unreal/UMG access: the game has no known-safe overlay hook yet, so the text lines are what a future overlay/screen (or the log) shows.
-- Rules the view enforces:
--   * rows are keyed by IDENTITY KEY; `displayPos` is only the visual order of ACTIVE players (derived from persistent slot), never identity
--   * a real SteamID never appears: non-dev keys are masked (first 4 + last 4)
--   * the persistent Enabled setting is shown apart from lobby/session settings and says that a restart is required
local Config = require("gmp_config")
local Identity = require("gmp_identity")
local Roster = require("gmp_roster")

local Ui = {}

-- Sources: a uniform read-only snapshot of "what this side knows".
function Ui.HostSource(host, ms)
    return { mode = "host", me = host.identity.key, defaultMaxPlayers = host.cfg and host.cfg.MAX_PLAYERS, roster = { players = host.roster:Snapshot(),
        currentPlayers = host.roster:CurrentPlayers(), phase = host.roster.phase, maxPlayers = host.roster.maxPlayers }, lobby = host:LobbyState(), chat = host.chat,
        colors = host:ColorAvailability(), modSettings = ms, pause = host.sharedPause }
end

function Ui.ClientSource(client, ms)
    local me = client:Me()
    local r = client:Roster()
    local colors
    if r then
        local owner = {}
        for _, p in ipairs(r.players) do owner[p.color:lower()] = p.key end
        colors = {}
        for _, c in ipairs(Config.ColorList(client.cfg)) do colors[#colors + 1] = { color = c, owner = owner[c:lower()], free = owner[c:lower()] == nil } end
    end
    return { mode = "client", me = client.identity.key, roster = r, lobby = client:LobbyMirror(), chat = client:ChatLog(), colors = colors,
        modSettings = ms, state = client:State(), pause = client.sharedPause }
end

local function label(key) return tostring(key):match("^dev:") and key or Identity.Mask(key) end

-- Rows ordered by DISPLAY position (active players, compacted); identity stays `key`.
function Ui.Rows(src)
    if not src.roster then return {} end
    local extra = {}
    for _, p in ipairs(src.lobby and src.lobby.players or {}) do extra[p.key] = p end
    local rows = {}
    for _, d in ipairs(Roster.DisplayOrder(src.roster.players)) do
        local x = extra[d.key] or { ready = false, class = "", artifacts = "" }
        rows[#rows + 1] = { displayPos = d.displayPos, slot = d.slot, key = d.key, label = label(d.key), name = d.name, color = d.color,
            isHost = d.role == "host", ready = (d.role == "host") or x.ready, class = x.class, artifacts = x.artifacts, conn = d.conn, isMe = d.key == src.me }
    end
    return rows
end

-- Lobby-only control; no main-menu Play binding or engine handoff here.
-- D37: the host's Ready starts a countdown every player sees; START happens only when it reaches 0.
Ui.START_COUNTDOWN_SECONDS = 5
function Ui.LobbyOpen(state) return state == "open" or state == "countdown" end
function Ui.StartControl(src)
    local rows = Ui.Rows(src)
    local mine, waiting = nil, {}
    for _, row in ipairs(rows) do
        if row.isMe then mine = row end
        if not row.isHost and not row.ready then waiting[#waiting + 1] = row.key end
    end
    local isHost = src.mode == "host"
    local open = src.lobby and Ui.LobbyOpen(src.lobby.state) and src.roster and src.roster.phase == "lobby"
    if isHost and open and src.lobby.state == "countdown" then
        return { id = "cancel_countdown", label = "Cancel", enabled = true, ready = true, waiting = waiting, tooltip = "Stop the start countdown." }
    end
    local control = { id = isHost and "host" or "ready", label = "Ready",
        enabled = false, ready = mine and mine.ready == true or false, waiting = waiting }
    if not mine or (not isHost and src.state ~= "joined") then control.reason = "not_joined"
    elseif not open then control.reason = "lobby_closed"
    elseif isHost and #waiting > 0 then control.reason = "players_not_ready"
    else control.enabled = true end
    -- A ready client's button reads Unready and cancels Ready (user request); the host keeps D37 (Ready -> countdown).
    if not isHost and control.ready then control.label = "Unready" end
    if control.reason == "players_not_ready" then control.tooltip = "Waiting for all players to click Ready."
    elseif control.reason then control.tooltip = "Join an open multiplayer lobby to continue."
    elseif isHost then control.tooltip = "Start a 5 second countdown with all ready players."
    elseif control.ready then control.tooltip = "Cancel Ready."
    else control.tooltip = "Confirm your class and artifacts, then wait for the host." end
    return control
end

-- Recompute eligibility at click time instead of trusting a stale rendered button.
-- The existing session remains responsible for authority and wire validation.
function Ui.ActivateStart(session, mode)
    if mode ~= "host" and mode ~= "client" then return false, "bad_mode" end
    local source = mode == "host" and Ui.HostSource(session) or Ui.ClientSource(session)
    local control = Ui.StartControl(source)
    if not control.enabled then return false, control.reason end
    if mode == "host" then return session:LobbyStart() end
    return session:RequestReady(not control.ready)
end

-- Only connected non-host rows can be kicked through the pre-run lobby.
function Ui.KickControls(src)
    local controls = {}
    local open = src.lobby and Ui.LobbyOpen(src.lobby.state) and src.roster and src.roster.phase == "lobby"
    if src.mode ~= "host" or not open then return controls end
    for _, row in ipairs(Ui.Rows(src)) do
        if not row.isHost and not row.isMe then
            controls[#controls + 1] = { key = row.key, label = "Kick", name = row.name, enabled = true }
        end
    end
    return controls
end

function Ui.ActivateKick(session, mode, key)
    if mode ~= "host" then return false, "not_host" end
    for _, control in ipairs(Ui.KickControls(Ui.HostSource(session))) do
        if control.key == key then return session:Kick(key, "Removed by the host") end
    end
    return false, "not_kickable"
end

-- Lobby warnings. Sessions always have four slots (D12), so the old player-count warning no longer exists.
function Ui.Warnings(src)
    return {}
end

-- Settings screen model. `editable` says WHO may change an item; the host still validates every change.
function Ui.Settings(src)
    local items = {}
    local isHost = src.mode == "host"
    local editable = isHost and src.lobby and src.lobby.state == 'open' and src.roster and src.roster.phase == 'lobby'
    local lob = src.lobby or {}
    local ms = src.modSettings
    -- No achievement item (D16: always blocked in multiplayer). The lobby size is the host's number box (D55, Screen).
    items[#items + 1] = { id = "allowAutoRejoin", scope = "session", label = "Allow Auto Rejoin", value = lob.allowRejoin and "On" or "Off", editable = editable == true }
    items[#items + 1] = { id = 'hostOnlyPause', scope = 'session', label = 'Only host can pause',
        value = src.pause and src.pause.hostOnly and 'On' or 'Off', editable = editable == true,
        note = 'Host Esc pauses everyone. Client Esc opens its menu while gameplay continues when host-only pause is enabled.' }
    local mine
    for _, p in ipairs(src.roster and src.roster.players or {}) do if p.key == src.me then mine = p.color end end
    local free = {}
    for _, c in ipairs(src.colors or {}) do if c.free then free[#free + 1] = c.color end end
    items[#items + 1] = { id = "color", scope = "player", label = "Player color", value = mine, editable = true, available = free }
    if ms and ms.setting and not ms.managed then
        items[#items + 1] = { id = "enabled", scope = "persistent", label = "GoobiesMP enabled", value = ms.setting.enabled and "On" or "Off", editable = true,
            note = "Saved in GoobiesMP.ini. A change takes effect after restarting Goobies (the mod is never unloaded while the game runs)." }
    end
    return items
end

function Ui.Lines(src)
    local L = {}
    local lob = src.lobby or {}
    local roster = src.roster
    L[#L + 1] = string.format("== GoobiesMP lobby (%s) mod %s protocol %d == state=%s players %d/%d auto-rejoin=%s",
        src.mode, Config.MOD_VERSION, Config.PROTOCOL_VERSION, tostring(lob.state or "?"), roster and roster.currentPlayers or 0,
        (roster and roster.maxPlayers) or lob.maxPlayers or 0, lob.allowRejoin and "On" or "Off")
    for _, w in ipairs(Ui.Warnings(src)) do L[#L + 1] = w end
    for _, r in ipairs(Ui.Rows(src)) do
        L[#L + 1] = string.format("%d. [slot %d] %s (%s) color=%s %s%s class=%s artifacts=%s%s", r.displayPos, r.slot, r.name, r.label, r.color,
            r.isHost and "HOST " or "", r.ready and "READY" or "not ready", r.class ~= "" and r.class or "-", r.artifacts ~= "" and r.artifacts or "-", r.isMe and " <you>" or "")
    end
    local n = #(src.chat or {})
    for i = math.max(1, n - 4), n do L[#L + 1] = string.format("<%s> %s", src.chat[i].name, src.chat[i].text) end
    if lob.state == "handoff_pending" then L[#L + 1] = "Run starting - gameplay hand-off pending (not implemented yet)." end
    return L
end

return Ui
