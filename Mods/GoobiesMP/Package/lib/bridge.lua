-- GoobiesMP: UE4SS/game bridge. THE ONLY production file allowed to touch UE4SS globals or game objects.
-- Everything else (gmp_*) is pure Lua and must never call UE4SS API.
--
-- Rules for this file:
--  * every UE4SS/game call is wrapped in pcall;
--  * M2a performs NO game reads at all: capability checks are `type(G.X)` only (no calls), and nothing is enumerated or written;
--  * no SteamID API is assumed. `steamProvider` is installed ONLY when the native UE4SS C++ provider (native/goobiesmp_steam) has registered
--    the Lua global GMP_SteamID64 (S1 integration). Without it, `steamProvider` stays nil;
--  * there is no fake/production-looking identity here: production without a verified provider yields nil,"steamid_unavailable".
local Identity = require("gmp_identity")
local SteamAuth = require("gmp_auth_steam")

local Bridge = {}
Bridge.__index = Bridge

-- UE4SS globals the PoC used successfully (Confirmed in Phase 1): LoopAsync, ExecuteInGameThread, StaticFindObject, RegisterKeyBind.
Bridge.WANTED = { "LoopAsync", "ExecuteInGameThread", "ExecuteWithDelay", "StaticFindObject", "FindFirstOf", "FindAllOf", "RegisterKeyBind" }

-- G: the table to look globals up in (default _G; tests pass a fake). env: gmp_env instance (for logging).
function Bridge.new(G, env)
    local self = setmetatable({}, Bridge)
    self.G = G or _G
    self.env = env
    self.steamProvider = nil        -- Must return a SteamID64 string or nil. Installed below only from the native provider.
    self.loops = {}
    self.steamProvider = self:_nativeSteamProvider()
    self.authProvider = self:_nativeAuthProvider()   -- native Steam ticket provider (gmp_auth contract, kind "steam"); nil if the native layer is absent => production hosts refuse remote peers
    return self
end

-- Native SteamID provider (S1 integration). The C++ mod registers the global GMP_SteamID64() -> idString | (nil, reason). That function reads the
-- game's ALREADY-initialised steam_api64.dll (no SteamAPI_Init/Shutdown, no other Steam interface). Here the value is validated structurally,
-- logged MASKED only, and a missing/failing/raising/garbage provider yields nil (=> production "steamid_unavailable"); there is never a fallback.
Bridge.NATIVE_STEAM_GLOBAL = "GMP_SteamID64"
function Bridge:_nativeSteamProvider()
    local fn = self.G[Bridge.NATIVE_STEAM_GLOBAL]
    if type(fn) ~= "function" then return nil end
    local loggedOk, loggedWhy = false, {}
    return function()
        local ok, id, why = pcall(fn)
        if not ok then
            if not loggedWhy.raised then loggedWhy.raised = true; self:_log("native steam provider raised an error (suppressed)") end
            return nil
        end
        if type(id) == "string" and Identity.IsValidSteamId64(id) then
            if not loggedOk then loggedOk = true; self:_log("native steam provider: local SteamID obtained, masked=%s", Identity.Mask("steam:" .. id)) end
            return id
        end
        local reason = (id == nil and type(why) == "string" and why:match("^[%w_]+$") and #why <= 40) and why or "invalid_value"
        if not loggedWhy[reason] then loggedWhy[reason] = true; self:_log("native steam provider: no SteamID (%s)", reason) end
        return nil
    end
end

-- Real Steam authentication (gmp_auth_steam over the native auth globals). All-or-nothing: if any native function is missing there is no provider.
function Bridge:_nativeAuthProvider()
    local p, why = SteamAuth.new({ G = self.G })
    if not p then return nil end
    return p
end

function Bridge:_log(...) if self.env then self.env:Log(...) end end

-- Test 15: the process command line (for -GMPSlot / -GMPDevName, gmp_dev_slot.lua), read once by main.lua BEFORE the log
-- is opened, so it is a static function of the UE4SS globals. One CDO lookup and one pure engine call; nil on anything
-- missing or failing.
Bridge.KISMET_CDO = "/Script/Engine.Default__KismetSystemLibrary"
function Bridge.CommandLine(G)
    if type(G) ~= "table" or type(G.StaticFindObject) ~= "function" then return nil end
    local ok, line = pcall(function()
        local cdo = G.StaticFindObject(Bridge.KISMET_CDO)
        if not cdo or (type(cdo.IsValid) == "function" and not cdo:IsValid()) then return nil end
        local v = cdo:GetCommandLine()
        if type(v) == "string" then return v end
        if v ~= nil and type(v.ToString) == "function" then return v:ToString() end
    end)
    if ok and type(line) == "string" then return line end
    return nil
end

-- type() checks only; never calls anything.
function Bridge:Capabilities()
    local caps = {}
    for _, name in ipairs(Bridge.WANTED) do caps[name] = type(self.G[name]) == "function" end
    caps.ue4ss = caps.LoopAsync and caps.ExecuteInGameThread or false
    return caps
end

-- Display name of the local player. No verified source exists yet (S1 open) -> nil, reason. Callers choose a dev name or a fallback.
function Bridge:LocalName() return nil, "name_source_unknown" end

-- Local authoritative identity. production: only via a verified steamProvider (the native provider, when present); dev: explicit dev name, dev mode only.
function Bridge:LocalIdentity(mode, devName)
    local ok, id, why = pcall(Identity.Resolve, {
        mode = mode,
        steamProvider = self.steamProvider,
        devName = (mode == "dev") and devName or nil,
    })
    if not ok then return nil, "identity_error" end
    return id, why
end

-- Run fn(dt) every intervalMs on the game thread. Errors are caught and logged; a failing step never kills the loop.
-- Returns a handle { stop = function } or nil,reason when UE4SS scheduling is unavailable.
function Bridge:Every(intervalMs, fn)
    local G = self.G
    if type(G.LoopInGameThreadWithDelay)=="function" and type(G.CancelDelayedAction)=="function" then
        local handle={stopped=false,fires=0,pending=false,skipped=0}
        local timer
        local last=self.env and self.env:Clock() or nil
        function handle.stop() handle.stopped=true; if timer then G.CancelDelayedAction(timer) end end
        local ok,why=pcall(function()
            timer=G.LoopInGameThreadWithDelay(intervalMs,function()
                if handle.stopped then return end
                local ran,err=pcall(function()
                    handle.fires=handle.fires+1
                    local now=self.env and self.env:Clock() or 0
                    local dt=last and (now-last) or 0;last=now
                    fn(dt)
                end)
                if not ran then self:_log("step error: %s",tostring(err)) end
            end)
        end)
        if not ok then return nil,"game_thread_timer_failed: "..tostring(why) end
        self.loops[#self.loops+1]=handle
        return handle
    end
    if type(G.LoopAsync) ~= "function" or type(G.ExecuteInGameThread) ~= "function" then return nil, "ue4ss_scheduler_unavailable" end
    local handle = { stopped = false, fires = 0, pending = false, skipped = 0 }
    function handle.stop() handle.stopped = true end
    local last = self.env and self.env:Clock() or nil
    local okLoop, err = pcall(G.LoopAsync, intervalMs, function()
        if handle.stopped then return true end
        -- Keep at most one action queued or executing during loading/stalls.
        if handle.pending then handle.skipped = handle.skipped + 1; return false end
        handle.pending = true
        local queued, queueError = pcall(G.ExecuteInGameThread, function()
            if handle.stopped then handle.pending = false; return end
            local ok, e = pcall(function()
                handle.fires = handle.fires + 1
                local now = self.env and self.env:Clock() or 0
                local dt = last and (now - last) or 0
                last = now
                fn(dt)
            end)
            handle.pending = false
            if not ok then self:_log("step error: %s", tostring(e)) end
        end)
        if not queued then
            handle.pending = false
            self:_log("scheduler error: %s", tostring(queueError))
        end
        return false
    end)
    if not okLoop then return nil, "loopasync_failed: " .. tostring(err) end
    self.loops[#self.loops + 1] = handle
    return handle
end

-- ===================================================================================================================
-- S1 probe: how can Lua read the LOCAL player's real SteamID?  READ-ONLY, pcall-protected, logs before every risky step.
-- Static evidence (see PHASE2.md 12.10): the game's own Blueprints call /Script/SteamCorePro.SteamProUser:GetSteamID() with no
-- arguments and compare the result with leaderboard entries to find "me". Nothing below is assumed callable from Lua.
--   stage a: existence only (StaticFindObject + IsValid + GetFullName).                       No calls into SteamCore.
--   stage b: reflection only (function flags, parameter/member names) of objects found in a.  No calls into SteamCore.
--   stage c: (opts.call only) ONE call of SteamProUser CDO:GetSteamID(). Result masked in logs, kept in memory only.
--   (M2d: a former stage d that called SteamProFriends:GetPersonaName_Pure crashed UE4SS (access violation). It has been REMOVED; that path is UNSAFE.)
-- It never writes a property, never spawns, never touches BP_Player/pawns, saves, achievements or leaderboards.
-- ===================================================================================================================
Bridge.S1_TARGETS = {
    { key = "userClass",  path = "/Script/SteamCorePro.SteamProUser" },
    { key = "userCdo",    path = "/Script/SteamCorePro.Default__SteamProUser" },
    { key = "getSteamID", path = "/Script/SteamCorePro.SteamProUser:GetSteamID", fn = true },
    { key = "getSteamIDPure", path = "/Script/SteamCorePro.SteamProUser:GetSteamID_Pure", fn = true },
    { key = "steamIdStruct", path = "/Script/SteamCorePro.SteamID", struct = true },
    { key = "breakSteamID", path = "/Script/SteamCorePro.SteamUtilities:BreakSteamID", fn = true },
    { key = "friendsCdo", path = "/Script/SteamCorePro.Default__SteamProFriends" },
    { key = "getPersonaPure", path = "/Script/SteamCorePro.SteamProFriends:GetPersonaName_Pure", fn = true },
}

-- standard UE EFunctionFlags values
Bridge.FUNC_FLAGS = { { 0x1, "Final" }, { 0x400, "Native" }, { 0x2000, "Static" }, { 0x20000, "Public" },
    { 0x04000000, "BlueprintCallable" }, { 0x08000000, "BlueprintEvent" }, { 0x10000000, "BlueprintPure" }, { 0x40000000, "Const" } }

function Bridge.DecodeFuncFlags(n)
    local out = {}
    if type(n) ~= "number" then return "?" end
    for _, f in ipairs(Bridge.FUNC_FLAGS) do if n & f[1] ~= 0 then out[#out + 1] = f[2] end end
    return table.concat(out, "|")
end

local function mask(str)
    if type(str) ~= "string" then return tostring(str) end
    if #str <= 4 then return string.rep("*", #str) end
    return str:sub(1, 2) .. string.rep("*", #str - 4) .. str:sub(-2)
end

function Bridge:ProbeS1(opts)
    opts = opts or {}
    local G = self.G
    local log = opts.log or function() end
    local res = { a = "not_run", b = "not_run", c = "not_run", found = {}, fields = {} }
    local function say(fmt, ...) log("S1 " .. fmt, ...) end
    local function try(label, fn, ...)
        say("about to %s", label)                         -- written to the log file BEFORE the risky step
        local ok, r1, r2 = pcall(fn, ...)
        if not ok then say("%s -> ERROR %s", label, tostring(r1)) end
        return ok, r1, r2
    end

    -- ---- stage a: existence ----
    if type(G.StaticFindObject) ~= "function" then say("stage a: StaticFindObject unavailable"); res.a = "no_api"; return res end
    local foundCount = 0
    for _, t in ipairs(Bridge.S1_TARGETS) do
        local ok, obj = try("StaticFindObject " .. t.path, G.StaticFindObject, t.path)
        local valid = false
        if ok and obj ~= nil then
            local vok, v = pcall(function() return obj:IsValid() end)
            valid = vok and v == true
        end
        local fullName = "?"
        if valid then
            local nok, n = pcall(function() return obj:GetFullName() end)
            if nok then fullName = tostring(n) end
        end
        say("stage a: %-14s valid=%s %s", t.key, tostring(valid), valid and fullName or "")
        if valid then res.found[t.key] = obj; foundCount = foundCount + 1 end
    end
    res.a = foundCount .. "/" .. #Bridge.S1_TARGETS

    -- ---- stage b: reflection only ----
    local bOk = true
    local function describeProps(label, obj)
        local names = {}
        local pok = try("ForEachProperty on " .. label, function()
            obj:ForEachProperty(function(prop)
                local info = {}
                local n1, n = pcall(function() return prop:GetFName():ToString() end)
                local t1, ty = pcall(function() return prop:GetClass():GetFName():ToString() end)
                info.name = n1 and tostring(n) or "?"
                info.type = t1 and tostring(ty) or "?"
                names[#names + 1] = info
            end)
        end)
        if pok then
            local parts = {}
            for _, i in ipairs(names) do parts[#parts + 1] = i.name .. ":" .. i.type end
            say("stage b: %s properties (%d): %s", label, #names, table.concat(parts, ", "))
        else bOk = false end
        return names
    end
    for _, t in ipairs(Bridge.S1_TARGETS) do
        local obj = res.found[t.key]
        if obj and t.fn then
            local fok, flags = try("GetFunctionFlags on " .. t.key, function() return obj:GetFunctionFlags() end)
            if fok and type(flags) == "number" then say("stage b: %s function flags=0x%X (%s)", t.key, flags, Bridge.DecodeFuncFlags(flags)); res.found[t.key .. "_flags"] = flags
            else say("stage b: %s function flags unavailable", t.key); bOk = false end
            describeProps(t.key, obj)
        elseif obj and t.struct then
            res.fields[t.key] = describeProps(t.key, obj)
        end
    end
    res.b = bOk and "ok" or "partial"

    -- ---- stage c/d: single read-only calls (opt-in) ----
    if not opts.call then say("stage c/d skipped (S1_PROBE=static: no SteamCore function is called)"); return res end
    local cdo, fnObj = res.found.userCdo, res.found.getSteamID
    if not (cdo and fnObj) then say("stage c skipped: Default__SteamProUser or GetSteamID not found"); res.c = "skipped_not_found"
    else
        local ok, ret = try("call SteamProUser CDO:GetSteamID() once (read-only getter, no arguments)", function() return cdo:GetSteamID() end)
        if not ok then res.c = "call_error"
        else
            local kind = type(ret)
            say("stage c: GetSteamID returned lua type=%s", kind)
            local cand
            local function consider(label, v)
                local sv = (type(v) == "number" and math.type(v) == "integer") and string.format("%d", v) or (type(v) == "string" and v or nil)
                if sv and Identity.IsValidSteamId64(sv) then cand = cand or sv; say("stage c: %s looks like a SteamID64 (len=%d, masked=%s)", label, #sv, Identity.Mask("steam:" .. sv)) 
                elseif sv then say("stage c: %s = %s-valued, len=%d, not SteamID64-shaped", label, type(v), #sv) end
            end
            if kind == "number" or kind == "string" then consider("return value", ret)
            elseif kind == "table" or kind == "userdata" then
                for _, f in ipairs(res.fields.steamIdStruct or {}) do      -- ONLY member names learned from reflection in stage b; none guessed
                    local rok, v = pcall(function() return ret[f.name] end)
                    if rok and v ~= nil then
                        say("stage c: member %s (%s) lua type=%s", f.name, f.type, type(v))
                        consider("member " .. f.name, v)
                        if cand == nil and type(v) == "userdata" then
                            local sok, sv2 = pcall(function() return v:ToString() end)
                            if sok then consider("member " .. f.name .. ":ToString()", tostring(sv2)) end
                        end
                    else say("stage c: member %s not readable", f.name) end
                end
                if cand == nil then
                    local tok, ts = pcall(tostring, ret)
                    if tok then consider("tostring(result)", ts) end
                end
            end
            if cand then res.candidate = cand; res.candidateMasked = Identity.Mask("steam:" .. cand); res.c = "candidate_found"
                local id, why = Identity.Steam(cand)
                say("stage c: Identity.Steam(candidate) -> %s", id and Identity.Mask(id.key) or tostring(why))
            else res.c = "no_candidate"; say("stage c: no SteamID64-shaped value could be extracted from the result (opaque struct?) - NOT guessing; see stage b members") end
        end
    end
    return res
end

-- ===================================================================================================================
-- S1 inspection probe (M2d-2): ONE GetSteamID() call, then LUA-LEVEL inspection of the immediate result only.
-- Never calls a function or method found in the result, never uses pairs()/tostring()/__index/__call (those can run metamethods),
-- uses raw next(), type(), rawlen(), getmetatable() only. Never recurses, never dereferences userdata. SteamCore: one call, nothing else.
-- Values are never logged except booleans; a SteamID64-valid candidate is logged masked, key name and Lua type only.
-- ===================================================================================================================
Bridge.S1_INSPECT_CDO = "/Script/SteamCorePro.Default__SteamProUser"
local MAX_KEYS = 40
local function safeName(k)
    if type(k) == "string" then return (k:sub(1, 48):gsub("[^%w_%.%-]", "?")) end
    return "<" .. type(k) .. ">"
end

function Bridge:ProbeS1Inspect(opts)
    opts = opts or {}
    local G = self.G
    local log = opts.log or function() end
    local res = { a = "not_run", c = "not_run", keys = {}, keyCount = 0 }
    local function say(fmt, ...) log("S1i " .. fmt, ...) end
    local function try(label, fn, ...)
        say("about to %s", label)
        local ok, r1 = pcall(fn, ...)
        if not ok then say("%s -> ERROR %s", label, type(r1) == "string" and r1 or ("<" .. type(r1) .. ">")) end
        return ok, r1
    end
    if type(G.StaticFindObject) ~= "function" then res.a = "no_api"; say("StaticFindObject unavailable"); return res end
    local ok, cdo = try("StaticFindObject " .. Bridge.S1_INSPECT_CDO, G.StaticFindObject, Bridge.S1_INSPECT_CDO)
    local valid = false
    if ok and cdo ~= nil then local vok, v = pcall(function() return cdo:IsValid() end); valid = vok and v == true end
    if not valid then res.a = "not_found"; say("stage a: Default__SteamProUser not resolved; GetSteamID NOT called"); return res end
    res.a = "found"; say("stage a: Default__SteamProUser valid")

    local cok, ret = try("call SteamProUser CDO:GetSteamID() once (no arguments; the ONLY SteamCore call in this probe)", function() return cdo:GetSteamID() end)
    if not cok then res.c = "call_error"; return res end
    local kind = type(ret)
    res.luaType = kind
    say("stage c: result lua type=%s", kind)

    local cand
    local function consider(key, v)
        local vt = type(v)
        if vt == "string" then
            if Identity.IsValidSteamId64(v) then cand = cand or { key = key, vt = vt, value = v }; say("stage c: key %s (string) is SteamID64-valid, masked=%s", key, Identity.Mask("steam:" .. v))
            else say("stage c: key %s string len=%d, not SteamID64-valid (content not logged)", key, #v) end
        elseif vt == "number" then
            if math.type(v) == "integer" then
                local sv = string.format("%d", v)
                if Identity.IsValidSteamId64(sv) then cand = cand or { key = key, vt = "integer", value = sv }; say("stage c: key %s (integer) is SteamID64-valid, masked=%s", key, Identity.Mask("steam:" .. sv))
                else say("stage c: key %s integer with %d digits, not SteamID64-valid (content not logged)", key, #sv) end
            else say("stage c: key %s float (not validated: a double cannot hold a uint64 exactly; content not logged)", key) end
        elseif vt == "boolean" then say("stage c: key %s boolean=%s", key, tostring(v))
        else say("stage c: key %s lua type=%s (not dereferenced)", key, vt) end
    end

    if kind == "table" then
        local rl; local rok, r = pcall(rawlen, ret); if rok then rl = r end
        say("stage c: rawlen=%s", tostring(rl))
        local n, truncated = 0, false
        local iok = try("iterate immediate keys with raw next() (no metamethods, no recursion)", function()
            local k, v = next(ret)
            while k ~= nil do
                n = n + 1
                if n > MAX_KEYS then truncated = true; break end
                local name = safeName(k)
                res.keys[#res.keys + 1] = { name = name, keyType = type(k), valueType = type(v) }
                consider(name, v)
                k, v = next(ret, k)
            end
        end)
        res.keyCount = math.min(n, MAX_KEYS)
        say("stage c: iterable=%s keys_seen=%d%s", tostring(iok), res.keyCount, truncated and " (truncated at " .. MAX_KEYS .. ")" or "")
        if n == 0 and iok then say("stage c: table has NO immediate keys (empty at Lua level)") end
        local mok, mt = try("getmetatable(result) (pure Lua; no metamethod is invoked)", getmetatable, ret)
        if mok then
            res.metatable = type(mt)
            say("stage c: metatable lua type=%s", type(mt))
            if type(mt) == "table" then
                local m = 0
                try("list metatable keys with raw next() (names and value types only; nothing is called)", function()
                    local k, v = next(mt)
                    while k ~= nil and m < MAX_KEYS do m = m + 1; say("stage c: metatable key %s -> %s", safeName(k), type(v)); k, v = next(mt, k) end
                end)
            end
        end
    elseif kind == "string" or kind == "number" or kind == "boolean" then consider("<result>", ret)
    else say("stage c: result is %s; no inspection performed (not dereferenced)", kind) end

    if cand then res.candidate = cand.value; res.candidateMasked = Identity.Mask("steam:" .. cand.value); res.candidateKey = cand.key; res.candidateType = cand.vt; res.c = "candidate_found"
        local id, why = Identity.Steam(cand.value); say("stage c: Identity.Steam(candidate) -> %s", id and Identity.Mask(id.key) or tostring(why))
    else res.c = "no_candidate" end
    say("stage c: done; result %s. Nothing adopted as identity.", res.c)
    return res
end

function Bridge:Shutdown() for _, h in ipairs(self.loops) do h.stop() end end

return Bridge
