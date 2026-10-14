-- GoobiesMP: REAL Steam authentication provider adapter (kind "steam"). Implements the gmp_auth provider contract on top of the native
-- globals GMP_Auth_* registered by the C++ mod (native/goobiesmp_steam). This file is the ONLY Lua that knows the native function names, and it
-- contains no Steam logic: it translates identity KEYS ("steam:<id>") to the decimal SteamID64 strings the native layer uses, type-checks and
-- sanitises every value coming back (a missing / raising / garbage native function fails closed), and never invents a success.
--
-- Trust model (PHASE2 12.17/12.20): Verify() is a quick structural check only. Identity is proven solely by a "validate" event with ok=true
-- whose key equals the claimed key, which the native layer emits only for a session it opened and only from Steam's ValidateAuthTicketResponse_t.
-- Any response name other than the literal "OK" is a failure.
local Auth = require("gmp_auth")
local Identity = require("gmp_identity")

local brokers=setmetatable({}, {__mode="k"})
local S = {}
S.__index = S

S.GLOBALS = { "GMP_Auth_Status", "GMP_Auth_Begin", "GMP_Auth_State", "GMP_Auth_Chunk", "GMP_Auth_Cancel", "GMP_Auth_Verify", "GMP_Auth_Poll", "GMP_Auth_End" }

-- opts: G (global table, default _G), cfg (optional; refused in nothing - the steam provider is valid in dev and production)
function S.new(opts)
    local G = (opts and opts.G) or _G
    local fns = {}
    for _, name in ipairs(S.GLOBALS) do
        if type(G[name]) ~= "function" then return nil, "native_auth_missing" end
        fns[name] = G[name]
    end
    -- optional, read-only diagnostics (counters of the native layer); not part of the provider contract and not required
    if type(G.GMP_Auth_Adopt)=='function' and type(G.GMP_Tkt_Adopt)=='function' then fns.GMP_Auth_Adopt=G.GMP_Auth_Adopt;fns.GMP_Tkt_Adopt=G.GMP_Tkt_Adopt end
    if type(G.GMP_Auth_Counts) == "function" then fns.GMP_Auth_Counts = G.GMP_Auth_Counts end
    local broker=brokers[G]
    if not broker then broker={owners={},queues={}};brokers[G]=broker end
    local provider=setmetatable({ f=fns,log=opts and opts.log,broker=broker,tickets={} },S)
    broker.queues[provider]={};broker.default=broker.default or provider
    return provider
end

local function idOf(key)                        -- "steam:<SteamID64>" -> id string | nil. dev: keys and malformed keys never reach Steam.
    if type(key) ~= "string" then return nil end
    local id = key:match("^steam:(%d+)$")
    if id and Identity.IsValidSteamId64(id) then return id end
    return nil
end
local function keyOf(id)
    if type(id) == "string" and Identity.IsValidSteamId64(id) then return "steam:" .. id end
    return nil
end
local function reasonOf(r)                      -- reasons end up in logs and on the wire map: keep them short identifiers
    if type(r) == "string" and r:match("^[%w_]+$") and #r <= 40 then return r end
    return "native_error"
end

function S:_call(name, ...)
    local r = table.pack(pcall(self.f[name], ...))
    if not r[1] then return nil, "native_error" end
    return table.unpack(r, 2, r.n)
end

function S:Name() return "steam-auth (native, steam_api64.dll)" end
function S:Kind() return "steam" end

function S:Status()
    local ok, why = self:_call("GMP_Auth_Status")
    if ok == true then if why~=1 then return nil,'native_ownership_unavailable' end;return true end
    return nil, reasonOf(why or "steam_unavailable")
end

function S:UseRetention(context)
 if type(context)~='table' or math.type(context.generation)~='integer' or context.generation<1 or context.generation>0xffffffff
  or type(context.session)~='string' or #context.session<1 or #context.session>64 or math.type(context.term)~='integer' or context.term<2
  or context.term>0xffffffff or type(context.nonce)~='string' or #context.nonce~=32 or context.nonce:find('[^0-9a-f]') then return false,'invalid_retained_context' end
 if not self.f.GMP_Auth_Adopt or not self.f.GMP_Tkt_Adopt then return false,'native_retention_missing' end
 self.retention={generation=context.generation,session=context.session,term=context.term,nonce=context.nonce};return true
end
function S:ClearRetention()self.retention=nil;return true end
function S:_retained(name,peer)
 local c=self.retention
 if not c then return nil,'retained_context_unavailable' end
 return self:_call(name,c.generation,c.session,c.term,c.nonce,peer)
end
function S:TicketBegin(hostKey)
    local hid = idOf(hostKey)
    if not hid then return nil, "not_a_steam_identity" end      -- a ticket is addressed to a Steam host only
    local h,why
    if self.retention then h,why=self:_retained("GMP_Tkt_Adopt",hid) else h,why=self:_call("GMP_Auth_Begin",hid) end
    if math.type(h) == "integer" and h > 0 then self.tickets[h]=true;return h end
    return nil, reasonOf(why or "ticket_failed")
end

function S:TicketState(handle)
    if math.type(handle) ~= "integer" then return "failed", "no_such_ticket" end
    local st, v = self:_call("GMP_Auth_State", handle)
    if st == "pending" then return "pending" end
    if st == "ready" and math.type(v) == "integer" and v > 0 and v <= Auth.MAX_CHUNK_BYTES * Auth.MAX_CHUNKS then return "ready", v end
    if st == "failed" then return "failed", reasonOf(v) end
    return "failed", "native_error"
end

function S:TicketChunk(handle, offset, n)
    if math.type(handle) ~= "integer" or math.type(offset) ~= "integer" or math.type(n) ~= "integer" then return nil end
    if offset < 0 or n < 1 or n > Auth.MAX_CHUNK_BYTES then return nil end
    local hex, why = self:_call("GMP_Auth_Chunk", handle, offset, n)
    self.lastChunk = { t = type(hex), len = type(hex) == "string" and #hex or 0, why = reasonOf(why) }       -- diagnostics only (no ticket content)
    if type(hex) == "string" and #hex > 0 and #hex <= n * 2 and Auth.IsHex(hex) then return hex end
    return nil
end

function S:TicketCancel(handle)
    if math.type(handle) == "integer" and self.tickets[handle] then self:_call("GMP_Auth_Cancel", handle);self.tickets[handle]=nil end
end

function S:Verify(claimedKey, ticketHex, hostKey)
    local id = idOf(claimedKey)
    if not id then return nil, "InvalidTicket" end               -- dev: and malformed claims are never sent to Steam
    if not idOf(hostKey) then return nil, "InvalidTicket" end
    if not Auth.IsHex(ticketHex) or #ticketHex == 0 then return nil, "InvalidTicket" end
    if self.leasePeer and claimedKey~=self.leasePeer then return nil,"lease_identity_mismatch" end
    if self.broker.owners[claimedKey] then return nil,"AuthSessionOwned" end
    -- Reject an older provider before opening any SDK validation session whose
    -- cleanup capability this adapter could not own.
    local available,ownershipVersion=self:_call('GMP_Auth_Status')
    if available~=true or ownershipVersion~=1 then return nil,'native_ownership_unavailable' end
    if self.retention then
        local epoch,why=self:_retained('GMP_Auth_Adopt',id)
        if math.type(epoch)~='integer' or epoch<1 then return nil,reasonOf(why or 'retained_context_unavailable') end
        if math.type(why)~='integer' or why<1 or why>2147483647 then return nil,'InvalidTicket' end
        self.nativeOwners=self.nativeOwners or {};self.nativeOwners[claimedKey]=why
        self.broker.owners[claimedKey]=self;return true,{retainedEpoch=epoch}
    end
    local ok, why = self:_call("GMP_Auth_Verify", id, ticketHex)
    if ok == true then if math.type(why)~='integer' or why<1 or why>2147483647 then return nil,'native_ownership_unavailable' end;self.nativeOwners=self.nativeOwners or {};self.nativeOwners[claimedKey]=why;self.broker.owners[claimedKey]=self;return true end
    return nil, reasonOf(why or "InvalidTicket")
end

-- Native events: (idString, responseName, ownerString) one at a time, nil when empty. Bounded per call so a misbehaving native layer cannot hang the loop.
function S:Poll()
    for _ = 1, 64 do
        local r = table.pack(self:_call("GMP_Auth_Poll"))
        local id, name, owner = r[1], r[2], r[3]
        if id == nil then break end
        local key = keyOf(id)
        if key and type(name) == "string" then
            local ok = (name == "OK")
            local reason; if not ok then reason = reasonOf(name) end
            local recipient=self.broker.owners[key] or self.broker.default
            local queue=self.broker.queues[recipient]
            if queue and #queue<64 then queue[#queue+1]={kind="validate",key=key,ok=ok,reason=reason,owner=keyOf(owner)} end
        end                                                      -- an event with an unusable id is dropped, never turned into a success
    end
    local out=self.broker.queues[self] or {};self.broker.queues[self]={};return out
end

-- Diagnostics only: the native counters as a table { cb143=n, cb163=n, tickets=n, ... } or nil. Never used for decisions.
function S:Counts()
    if not self.f.GMP_Auth_Counts then return nil end
    local text = self:_call("GMP_Auth_Counts")
    if type(text) ~= "string" or #text > 400 then return nil end
    local t = {}
    for k, v in text:gmatch("([%w_]+)=(%d+)") do t[k] = math.tointeger(tonumber(v)) end
    return t
end

function S:End(key)
    local id = idOf(key)
    if id and self.broker.owners[key]==self then self:_call("GMP_Auth_End",id,self.nativeOwners and self.nativeOwners[key]);if self.nativeOwners then self.nativeOwners[key]=nil end;self.broker.owners[key]=nil end
end

-- A lease has exclusive Begin/End ownership for one attributed Steam peer.
-- All leases share one native callback dispatcher; they never steal events.
function S:Lease(peer)
 if not idOf(peer) then return nil,"invalid_lease_identity" end
 if self.broker.owners[peer] then return nil,"AuthSessionOwned" end
 local lease=setmetatable({f=self.f,broker=self.broker,log=self.log,leasePeer=peer,tickets={}},S)
 self.broker.queues[lease]={};return lease
end
function S:RetireValidation()
 local owned={};for key,owner in pairs(self.broker.owners)do if owner==self then owned[#owned+1]=key end end
 for _,key in ipairs(owned)do self:End(key)end
 return true
end
function S:CloseLease()
 local handles={};for handle in pairs(self.tickets)do handles[#handles+1]=handle end
 for _,handle in ipairs(handles)do self:TicketCancel(handle)end
 local owned={};for key,owner in pairs(self.broker.owners)do if owner==self then owned[#owned+1]=key end end
 for _,key in ipairs(owned)do self:End(key)end
 self.broker.queues[self]=nil
end
return S
