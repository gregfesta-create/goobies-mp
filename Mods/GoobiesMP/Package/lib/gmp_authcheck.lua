-- GoobiesMP: STAGE 1 DIAGNOSTIC for real Steam authentication (PHASE2 12.20/12.21). Pure Lua; it only uses the gmp_auth provider contract.
-- Enabled only by AUTH_CHECK=1 in gmp_config.txt, in production mode (AUTH_MODE=steam), one instance, no network, no roster.
-- It runs the whole Steam path ONCE against the instance's own real SteamID so a failure can be attributed to exactly one phase:
--   status -> ticket created -> ticket-ready callback (163) -> ticket bytes read -> BeginAuthSession accepted -> validation callback (143)
--   -> verdict OK for the right SteamID -> EndAuthSession -> no stray verdicts afterwards -> ticket cancelled.
-- It adds NO callback pumping: it only waits for the game's own Steam callback machinery to deliver. Nothing here reads or writes
-- achievements, stats, leaderboards or friends. The ticket itself is never logged (size only) and SteamIDs are masked.
local Identity = require("gmp_identity")
local Auth = require("gmp_auth")

local C = {}
C.__index = C

C.TIMEOUTS = { status = 60, ticket = 20, validate = 20, settle = 2 }

-- opts: provider (gmp_auth contract, kind steam), steamId (fn -> id64 string | nil), now (fn -> seconds), log (fn), fs ({write}), dir (result dir)
function C.new(opts)
    local self = setmetatable({}, C)
    self.provider, self.steamId, self.now, self.log, self.fs, self.dir = opts.provider, opts.steamId, opts.now, opts.log, opts.fs, opts.dir
    self.phase, self.t0, self.lines, self.done, self.passed = "status", self.now(), {}, false, nil
    self.unexpected = 0
    if self.fs and self.dir then
        self.fs.write(self.dir .. "/authcheck_result.txt", "")
        self.fs.write(self.dir .. "/authcheck_done.txt", "RUNNING")
    end
    return self
end

function C:_note(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    self.lines[#self.lines + 1] = line
    self.log("AUTHCHECK " .. line)
end

function C:_counts()
    local c = self.provider.Counts and self.provider:Counts() or nil
    if not c then return "counts=n/a", {} end
    local order = { "cb163", "cb143", "dropped143", "tickets", "ticket_fail", "verifies", "ok", "fail", "polled", "ends" }
    local t = {}
    for _, k in ipairs(order) do if c[k] ~= nil then t[#t + 1] = k .. "=" .. c[k] end end
    return table.concat(t, " "), c
end

function C:_enter(phase) self.phase, self.t0 = phase, self.now() end
function C:_age() return self.now() - self.t0 end

function C:_finish(ok, class, detail)
    if self.done then return end
    self.done, self.passed = true, ok
    if self.handle then pcall(function() self.provider:TicketCancel(self.handle) end); self.handle = nil end
    local cs = self:_counts()
    self:_note("RESULT %s class=%s%s native: %s", ok and "PASS" or "FAIL", class, detail and (" detail=" .. detail) or "", cs)
    if self.fs and self.dir then
        self.fs.write(self.dir .. "/authcheck_result.txt", table.concat(self.lines, "\n") .. "\n")
        self.fs.write(self.dir .. "/authcheck_done.txt", ok and "PASS" or "FAIL")
    end
end

local function readAll(self, size)
    local parts, off = {}, 0
    while off < size do
        local n = math.min(Auth.MAX_CHUNK_BYTES, size - off)
        local hex = self.provider:TicketChunk(self.handle, off, n)
        if type(hex) ~= "string" or #hex ~= n * 2 then
            local lc = self.provider.lastChunk
            return nil, string.format("chunk at offset %d (n=%d of size=%d): native returned type=%s len=%s reason=%s", off, n, size,
                lc and lc.t or "n/a", lc and tostring(lc.len) or "n/a", lc and tostring(lc.why) or "n/a")
        end
        parts[#parts + 1] = hex
        off = off + n
    end
    return table.concat(parts)
end

function C:Tick()
    if self.done then return end
    local p, T = self.phase, C.TIMEOUTS
    if p == "status" then
        local ok, why = self.provider:Status()
        if ok then
            self:_note("1 status: Steam usable after %.1fs (logged on)", self:_age())
            local id = self.steamId and self.steamId()
            if not Identity.IsValidSteamId64(id) then return self:_finish(false, "identity", "no valid local SteamID") end
            self.key = "steam:" .. id
            self:_note("2 identity: local SteamID masked=%s", Identity.Mask(self.key))
            local h, why2 = self.provider:TicketBegin(self.key)
            if not h then return self:_finish(false, "ticket_creation", tostring(why2)) end
            self.handle = h
            self:_note("3 ticket requested (GetAuthSessionTicket addressed to own SteamID): handle accepted")
            return self:_enter("ticket")
        elseif self:_age() > T.status then return self:_finish(false, "steam_unavailable", tostring(why)) end
    elseif p == "ticket" then
        local st, v = self.provider:TicketState(self.handle)
        if st == "ready" then
            local hex, why = readAll(self, v)
            if not hex then return self:_finish(false, "ticket_read", why) end
            self.hex = hex
            self:_note("4 ticket-ready callback (163) delivered OK after %.2fs; ticket size=%d bytes (not logged)", self:_age(), v)
            local ok, vwhy = self.provider:Verify(self.key, hex, self.key)
            if not ok then return self:_finish(false, "begin_auth_session_rejected", tostring(vwhy)) end
            self:_note("5 BeginAuthSession accepted the ticket (this alone is NOT proof of identity)")
            return self:_enter("validate")
        elseif st == "failed" then return self:_finish(false, "ticket_creation_failed", tostring(v))
        elseif self:_age() > T.ticket then
            local _, c = self:_counts()
            return self:_finish(false, (c.cb163 or 0) == 0 and "callback_163_never_delivered" or "ticket_not_ready", "pending after " .. T.ticket .. "s")
        end
    elseif p == "validate" then
        for _, ev in ipairs(self.provider:Poll()) do
            if ev.kind == "validate" and ev.key == self.key then
                if not ev.ok then return self:_finish(false, "validation_failed", tostring(ev.reason)) end
                self:_note("6 validation callback (143) delivered after %.2fs: verdict OK for the local SteamID (masked=%s); owner %s", self:_age(), Identity.Mask(ev.key),
                    ev.owner == self.key and "is the same account" or "DIFFERS (family sharing?)")
                self.verdictOwnerSame = ev.owner == self.key
                self.provider:End(self.key)
                self:_note("7 EndAuthSession requested")
                return self:_enter("settle")
            else
                self.unexpected = self.unexpected + 1
                self:_note("unexpected verdict for another key (masked=%s) ok=%s", Identity.Mask(tostring(ev.key)), tostring(ev.ok))
            end
        end
        if self:_age() > T.validate then
            local _, c = self:_counts()
            return self:_finish(false, (c.cb143 or 0) == 0 and "callback_143_never_delivered" or "verdict_not_for_session", "no verdict after " .. T.validate .. "s")
        end
    elseif p == "settle" then
        for _, ev in ipairs(self.provider:Poll()) do
            self.unexpected = self.unexpected + 1
            self:_note("stray verdict after End (masked=%s ok=%s)", Identity.Mask(tostring(ev.key)), tostring(ev.ok))
        end
        if self:_age() >= T.settle then
            self:_note("8 cleanup: %d stray verdicts after EndAuthSession", self.unexpected)
            if self.unexpected > 0 then return self:_finish(false, "cleanup", "stray verdicts") end
            self.provider:TicketCancel(self.handle); self.handle = nil
            self:_note("9 ticket cancelled (CancelAuthTicket)")
            return self:_finish(true, "ok")
        end
    end
end

return C
