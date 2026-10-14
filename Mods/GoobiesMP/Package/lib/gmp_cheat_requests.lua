-- D56 (Coder D; user 2026-10-13, amends D41): clients can use the cheat keys F6 (ordinary boss), F7 (unique boss) and
-- F8 (next island); the host carries them out in the shared world exactly as if the host had pressed the key, so every
-- player sees the result. The client's own cheat settings never matter: the HOST's Cheat Mod setting for that key
-- decides. Pure session plumbing, no game calls:
--   CHEAT_REQ  C2H {key = boss|unique|island}   dev message (not in Types/ReservedTypes, so protocol pins are unchanged)
--   Client:RequestCheat(key)                     sends it (joined sessions only)
--   Host.handlers.CHEAT_REQ                      host.cheatRequests (a Gate, attached by App:SetCheatHandler) decides;
--                                                every request is logged with the requesting player; a refusal other
--                                                than rate_limited goes back as REQ_DENIED{ofType='CHEAT_REQ'}
--   Gate                                         unknown key -> production mode (gameplay gate: dev and friend only) ->
--                                                at most one request per key per player per INTERVAL -> Cheat Mod's
--                                                handler(key, who), which checks the host's own setting and queues the
--                                                same action as the host's key press.
-- Count-independent (D54): any number of clients, keyed by the player's identity, never by slot number.
local Identity = require('gmp_identity')
local Mode = require('gmp_mode_policy')

local CR = {}
CR.KEYS = { boss = 'F6', unique = 'F7', island = 'F8' }
CR.INTERVAL = 1   -- seconds between accepted-for-handling requests of one key from one player
CR.Schema = { CHEAT_REQ = { dir = 'C2H', ch = 'R', fields = { { name = 'key', type = 'str' } } } }

-- Idempotent: adds the schema and appends the name to Messages.DevTypes once.
function CR.InstallMessages(Messages)
    Messages.DevTypes = Messages.DevTypes or {}
    if not Messages.Schema.CHEAT_REQ then Messages.Schema.CHEAT_REQ = CR.Schema.CHEAT_REQ end
    for _, t in ipairs(Messages.DevTypes) do if t == 'CHEAT_REQ' then return true end end
    Messages.DevTypes[#Messages.DevTypes + 1] = 'CHEAT_REQ'
    return true
end

local Gate = {}
Gate.__index = Gate
CR.Gate = Gate
-- opts.mode() -> the session MODE (dev | friend | production).
function Gate.new(opts)
    return setmetatable({ mode = (opts or {}).mode or function() return nil end, last = {}, handler = nil }, Gate)
end
function Gate:SetHandler(fn) self.handler = fn end
-- who: the requesting player's log label; peerKey: its identity key; now: the host clock (seconds). -> ok, reason
function Gate:Handle(who, peerKey, key, now)
    if CR.KEYS[key] == nil then return false, 'unknown_key' end
    local okMode, allowed = pcall(function() return Mode.Allows(self.mode(), 'gameplay') end)
    if not okMode or not allowed then return false, 'production_mode' end
    now = type(now) == 'number' and now or 0
    -- stays tiny; a clock that went back (a new host session after a handover) never holds a key forever
    for k, at in pairs(self.last) do if now - at >= CR.INTERVAL or now < at then self.last[k] = nil end end
    local id = tostring(peerKey) .. "|" .. key
    if self.last[id] then return false, 'rate_limited' end
    self.last[id] = now
    if type(self.handler) ~= 'function' then return false, 'cheat_mod_unavailable' end
    local ok, accepted, why = pcall(self.handler, key, who)
    if not ok then return false, 'handler_error' end
    if accepted ~= true then return false, type(why) == 'string' and why:sub(1, 64) or 'refused' end
    return true
end

function CR.Install(Host, Client)
    if Host then
        Host.handlers.CHEAT_REQ = function(self, peer, f)
            if not peer.key then self.stats.unbound_peer = (self.stats.unbound_peer or 0) + 1; return end
            local rec = self.roster:Get(peer.key)
            local who = string.format('slot %s (%s)', tostring(rec and rec.slot or '?'), tostring(rec and rec.name or Identity.Mask(peer.key)))
            local gate = self.cheatRequests
            local ok, why
            if gate then ok, why = gate:Handle(who, peer.key, f.key, self.clock())
            else ok, why = false, CR.KEYS[f.key] and 'cheat_mod_unavailable' or 'unknown_key' end
            self:_log('cheat request %s (%s) from %s key=%s: %s', CR.KEYS[f.key] or '?', tostring(f.key):sub(1, 16), who,
                Identity.Mask(peer.key), ok and 'carried out' or ('refused: ' .. tostring(why)))
            if not ok and why ~= 'rate_limited' then self:_send(peer, 'REQ_DENIED', { ofType = 'CHEAT_REQ', reason = why }) end
        end
    end
    if Client then
        function Client:RequestCheat(key)
            if self.state ~= 'joined' then return false, 'not_joined' end
            if CR.KEYS[key] == nil then return false, 'unknown_key' end
            return self:_send('CHEAT_REQ', { key = key })
        end
    end
    return true
end

return CR
