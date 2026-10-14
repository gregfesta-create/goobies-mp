-- GoobiesMP: multiplayer ENTRY flow (pure state machine, no UI toolkit):
--     Multiplayer -> choose connection method (Steam | Direct IP) -> compatibility check -> lobby
-- It only decides WHERE the player is in that flow and what to tell them; rendering is a separate concern (gmp_lobby_ui builds the text).
-- It never downloads/installs anything and never opens a socket itself: connecting is delegated to the injected `connect(method, address)`.
--
-- Method availability (honest, current):
--   direct_ip  loopback addresses only. Non-loopback Direct IP is NOT enabled for production (PHASE2 12.17/12.18): blocked with a reason.
--   steam      NOT implemented (Steam Networking Sockets is a later milestone): blocked with a reason, nothing is attempted.
local Compat = require("gmp_compat")

local Entry = {}
Entry.__index = Entry

-- states: menu | choose_method | address | connecting | compat_check | incompatible | lobby | blocked | failed
function Entry.new(opts)
    local self = setmetatable({}, Entry)
    self.intent = opts.intent or "join"                 -- "join" | "host"
    self.connect = opts.connect                         -- function(method, address) -> ok, err  (client path)
    self.host = opts.host                               -- function(method, address) -> ok, err  (host path)
    self.state, self.reason, self.message, self.method, self.address = "menu", nil, nil, nil, nil
    self.result = nil                                   -- the Compat result when incompatible
    return self
end

-- loopback only: 127.0.0.0/8, ::1, localhost (optional :port)
function Entry.ParseAddress(text)
    if type(text) ~= "string" then return nil, "bad_address" end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or #text > 64 or text:find("%c") then return nil, "bad_address" end
    local host, port = text:match("^%[(.-)%]:(%d+)$")
    if not host then host, port = text:match("^([^:]+):(%d+)$") end
    if not host then host = text end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return nil, "bad_port" end
    local loop = host:lower() == "localhost" or host == "::1" or host:match("^127%.%d+%.%d+%.%d+$") ~= nil
    if not loop and not host:match("^[%w%.%-:]+$") then return nil, "bad_address" end
    return { host = host, port = port and tonumber(port) or nil, loopback = loop }
end

function Entry:OpenMultiplayer()
    if self.state ~= "menu" then return false end
    self.state = "choose_method"
    return true
end

function Entry:_block(reason, msg) self.state, self.reason, self.message = "blocked", reason, msg; return false, reason end

function Entry:Choose(method, address)
    if self.state ~= "choose_method" and self.state ~= "blocked" and self.state ~= "failed" and self.state ~= "address" then return false, "wrong_state" end
    self.method, self.reason, self.message, self.result = method, nil, nil, nil
    if method == "steam" then
        return self:_block("steam_not_available", "Steam connections are not available yet (Steam Networking Sockets is a later milestone). Use Direct IP on this machine for now.")
    elseif method ~= "direct_ip" then
        return self:_block("unknown_method", "Unknown connection method.")
    end
    local a, why = Entry.ParseAddress(address)
    if not a then self.state, self.reason, self.message = "address", why, "Enter a valid address."; return false, why end
    if not a.loopback then
        return self:_block("direct_ip_non_loopback_disabled", "Direct IP to other computers is not enabled yet (production blocks non-loopback). Only this computer (127.0.0.1) can be used for now.")
    end
    self.address = address
    local fn = (self.intent == "host") and self.host or self.connect
    if not fn then return self:_block("no_connector", "No connection backend is available.") end
    local ok, err = fn(method, a)
    if not ok then self.state, self.reason, self.message = "failed", tostring(err or "connect_failed"), "Could not start the connection."; return false, self.reason end
    -- a host has nothing to check; a client must pass the compatibility gate before it sees a lobby
    self.state = (self.intent == "host") and "lobby" or "connecting"
    return true
end

-- Feed the client's current state in (call every tick). Returns the entry state.
function Entry:Update(client)
    if self.intent == "host" or not client then return self.state end
    if self.state ~= "connecting" and self.state ~= "compat_check" then return self.state end
    local st, why = client:State()
    local c = client.compat
    if c and not c.ok then
        self.state, self.reason, self.message, self.result = "incompatible", c.reason, c.message, c
    elseif c and c.ok and st ~= "joined" and st ~= "rejected" and st ~= "kicked" and st ~= "disconnected" then
        self.state = "compat_check"                       -- compatible; authenticating/joining
    elseif st == "joined" then
        self.state = "lobby"
    elseif st == "rejected" or st == "kicked" or st == "disconnected" then
        self.state, self.reason, self.message = "failed", tostring(why), "The host did not let you in (" .. tostring(why) .. ")."
    end
    return self.state
end

-- Case B: the player accepted "Do you want to enable it?". Writes Enabled=true and asks about a restart. Never hot-reloads.
function Entry:AcceptEnable(modsettings, fs, path)
    if not (self.result and self.result.action == "offer_enable") then return nil, "not_offered" end
    return Compat.AcceptEnable(modsettings, fs, path)
end

return Entry
