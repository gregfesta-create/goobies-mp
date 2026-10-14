-- Live HUD per player (user, test 10). Pure logic over an injected HUD object (the local pawn's WBP_HUD_C) and FText;
-- no widget is created. The game's HUD counts a kill for every enemy death in its world (EnemyKilled: Kills += 1, the
-- EnemiesKilled text, combo_meter:AddToCounter), and BP_Player writes its own "DPS Meter" text every second.
--   Host.new{FText, hostKey, send(key, fields)}:Tick(now, hud, attribution, runGeneration)
--     attribution = RunSync attribution {[peerKey] = {kills, damage}} (client-credited, host-resolved hits only).
--     The host's counter shows its own kills: the native total (followed through the game's increments) minus the kills
--     credited to clients. Every SEND_SECONDS each client gets LIVE_STATS{runGeneration, kills, dps} with its credit and
--     its credited damage per second over the last interval.
--   Client.new{FText}:Tick(now, hud, liveStats, runGeneration)
--     Writes Kills/EnemiesKilled when they differ, "DPS Meter" every tick (the game rewrites it), and one combo
--     AddToCounter per newly credited kill. Another generation's stats are never shown; no stats leave the HUD alone.
-- The host's own DPS stays the game's (its BP_Player measures its own weapons).
local L = {}
L.SEND_SECONDS = 0.5

function L.Format(n)
    local s = tostring(math.floor(n + 0.5))
    local sign, digits = s:match('^(-?)(%d+)$')
    if not digits then return s end
    local out = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return sign .. out
end
local function count(v) return type(v) == 'number' and v == v and v >= 0 and v < 1e15 and math.floor(v) or 0 end

local function short(e) return (tostring(e):gsub('%s+', ' '):sub(1, 120)) end

local Host = {}; Host.__index = Host; L.Host = Host
function Host.new(o) return setmetatable({ o = o, lastDamage = {}, nextSend = nil, lastSendAt = nil, status = {} }, Host) end
-- The own-counter part (native HUD read/write); its failure is recorded and never blocks the sends below.
function Host:_own(hud, attribution)
    local native = count(hud.Kills)
    if self.written == nil then self.total = native else self.total = self.total + math.max(0, native - self.written) end
    local clients = 0
    for key, a in pairs(attribution) do if key ~= self.o.hostKey and type(a) == 'table' then clients = clients + count(a.kills) end end
    local st = self.status
    st.native, st.credited, st.own = native, clients, math.max(0, self.total - clients)
    if clients > 0 or self.written ~= nil then
        local own = st.own
        if own ~= native then hud.Kills = own; hud.EnemiesKilled = self.o.FText(L.Format(own)) end
        self.written = own
    end
end
function Host:Tick(now, hud, attribution, generation)
    if type(hud) ~= 'table' and type(hud) ~= 'userdata' then return end
    attribution = type(attribution) == 'table' and attribution or {}
    local ok, err = pcall(self._own, self, hud, attribution)
    self.status.writeError = not ok and short(err) or nil
    if self.nextSend and now < self.nextSend then return end
    local span = self.lastSendAt and math.max(0.001, now - self.lastSendAt) or nil
    local sent, failed, peers = 0, 0, {}
    for key, a in pairs(attribution) do
        if key ~= self.o.hostKey and type(a) == 'table' then
            local damage = type(a.damage) == 'number' and a.damage or 0
            local dps = span and math.max(0, damage - (self.lastDamage[key] or damage)) / span or 0
            self.lastDamage[key] = damage
            local fields = { runGeneration = generation, kills = count(a.kills), dps = count(dps) }
            local okSend, done = pcall(self.o.send, key, fields)
            if okSend and done ~= false then sent = sent + 1 else failed = failed + 1 end
            peers[#peers + 1] = string.format('%s:%d/%d', tostring(key), fields.kills, fields.dps)
        end
    end
    table.sort(peers)
    self.status.sent, self.status.failed, self.status.peers = sent, failed, table.concat(peers, ',')
    self.lastSendAt, self.nextSend = now, now + L.SEND_SECONDS
end
-- "LIVEHUD host native=<n> own=<n> credited=<n> sent=<n> failed=<n> peers=<key:kills/dps,...>[ write_error=<e>]"
function Host:Line()
    local st = self.status
    return string.format('LIVEHUD host native=%d own=%d credited=%d sent=%d failed=%d peers=%s%s', st.native or 0, st.own or 0,
        st.credited or 0, st.sent or 0, st.failed or 0, st.peers ~= '' and st.peers or '-',
        st.writeError and (' write_error=' .. st.writeError) or '')
end

local Client = {}; Client.__index = Client; L.Client = Client
function Client.new(o) return setmetatable({ o = o, shown = nil, generation = nil, overwritten = 0, status = { state = 'no_stats' } }, Client) end
function Client:_show(hud, stats, generation)
    if self.generation ~= generation then self.generation, self.shown, self.lastWritten = generation, 0, nil end
    local kills, dps = count(stats.kills), count(stats.dps)
    local current = count(hud.Kills)
    if self.lastWritten ~= nil and current ~= self.lastWritten then self.overwritten = self.overwritten + 1 end
    if current ~= kills then hud.Kills = kills; hud.EnemiesKilled = self.o.FText(L.Format(kills)) end
    self.lastWritten = kills
    hud['DPS Meter'] = self.o.FText(L.Format(dps))
    if kills > self.shown then
        local combo = hud.combo_meter
        for _ = self.shown + 1, kills do pcall(function() combo:AddToCounter() end) end
        self.shown = kills
    end
    self.status = { state = 'shown', kills = kills, dps = dps, hudKills = count(hud.Kills), generation = stats.runGeneration }
end
function Client:Tick(now, hud, stats, generation)
    if type(hud) ~= 'table' and type(hud) ~= 'userdata' then self.status = { state = 'no_hud' }; return end
    if type(stats) ~= 'table' then self.status = { state = 'no_stats' }; return end
    if stats.runGeneration ~= generation then
        self.status = { state = string.format('generation host=%s mine=%s', tostring(stats.runGeneration), tostring(generation)),
            generation = stats.runGeneration }
        return
    end
    local ok, err = pcall(self._show, self, hud, stats, generation)
    if not ok then self.status = { state = 'write_error ' .. short(err), generation = stats.runGeneration } end
end
-- "LIVEHUD client stats=none|gen:<g> state=<no_stats|no_hud|generation host=.. mine=..|shown kills=.. dps=.. hud_kills=..
-- overwritten=..|write_error ...>"
function Client:Line()
    local st = self.status
    local state = st.state
    if state == 'shown' then
        state = string.format('shown kills=%d dps=%d hud_kills=%d overwritten=%d', st.kills, st.dps, st.hudKills, self.overwritten)
    end
    return string.format('LIVEHUD client stats=%s state=%s', st.generation and ('gen:' .. tostring(st.generation)) or 'none', state)
end
return L
