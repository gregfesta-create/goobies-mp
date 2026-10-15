-- GoobiesMP entry point (UE4SS loads Mods\GoobiesMP\Scripts\main.lua).
-- Thin on purpose: wires UE4SS (through bridge.lua) to the pure-Lua session core. No gameplay, no hooks, no game reads in M2a.
local options = ...
local ctx = type(options) == "table" and options.framework or nil
local G = rawget(_G, "GMP_TEST_GLOBALS") or _G            -- test hook: the offline tests inject a fake UE4SS global table
if ctx then
    assert(type(ctx.query) == "function" and type(ctx.readConfig) == "function", "GoobiesMP requires a framework context")
    local status = ctx.query(ctx.id)
    assert(status and status.managed and status.startupEnabled == true, "GoobiesMP framework startup is disabled or unmanaged")
end

local src = debug.getinfo(1, "S").source
local scriptDir = type(src) == "string" and src:match("^@(.*)[/\\][^/\\]*$") or nil
local usedFallbackDir = false
if not scriptDir then
    -- Chunk source not usable. UE4SS's working directory is the game's Win64 folder (Confirmed in UE4SS.log), so use the
    -- deployed layout relative to it instead of silently reading/writing files in the working directory.
    scriptDir, usedFallbackDir = "Mods\\GoobiesMP\\Scripts", true
end
if type(G.GMP_TEST_SCRIPTDIR) == "string" then scriptDir = G.GMP_TEST_SCRIPTDIR end
if ctx then scriptDir = assert(options.scriptDir, "GoobiesMP module path unavailable") end
local pkgOk = pcall(function()
    local entry = scriptDir .. "/?.lua"
    if not (";" .. package.path .. ";"):find(";" .. entry:gsub("%p", "%%%0") .. ";") then package.path = entry .. ";" .. package.path end
end)
-- Coder D (user report: no configs showing up for Goobies Multiplayer): GoobiesMP's settings gear in Mod Menu
-- (gmp_settings_page.lua). Registered first, so the page is there even if the session below fails to start.
if ctx and type(ctx.registerSettings) == "function" then
    local okPage, whyPage = pcall(function() ctx.registerSettings(require("gmp_settings_page").Provider(ctx)) end)
    if not okPage then (G.print or print)("[GoobiesMP] settings page unavailable: " .. tostring(whyPage)) end
end

local runtime
local okLoad, err = pcall(function()
    -- PERSISTENT ENABLE/DISABLE (GoobiesMP.ini, [GoobiesMP] Enabled): decided FIRST, before any other module is loaded. Disabled means nothing
    -- is initialised: no bridge, no native Steam provider, no network, no tick loop, no key binds, no log file. Takes effect on the next start.
    local MS = require("gmp_modsettings")
    local modDir0 = ctx and ctx.packagePath or G.GMP_TEST_MODDIR or (scriptDir:match("^(.*)[/\\][^/\\]*$") or ".")
    local iniPath = modDir0 .. "/" .. MS.FILE
    local setting = ctx and {enabled=true, source="framework", reason="startup_enabled"} or MS.Load(MS.DiskFs, iniPath)
    if not setting.enabled then
        (G.print or print)(string.format("[GoobiesMP] disabled by %s (Enabled=false%s); not initialising. Change it and restart Goobies to enable.", MS.FILE, setting.reason == "unparsable" and ", value unparsable -> treated as disabled" or ""))
        return
    end
    local Env = require("gmp_env")
    local Bridge = require("bridge")
    local App = require("gmp_app")

    local modDir = modDir0
    -- M3: ROLE=host|client|auto (dev only). Two instances share one mod folder, so the role is resolved BEFORE the log file is opened
    -- (each role logs to its own file). Without a role nothing changes: gmp.log, host-only in-memory session.
    local Role = require("gmp_role")
    local RealFs = require("gmp_relay_transport").RealFs
    local netDir = modDir .. "/net"
    -- Test 15 (single install): the launch slot (env GMP_SLOT, else -GMPSlot=N) gives this window its own log
    -- (gmp_slot<N>.log) and net dir (net/slot<N>) and its dev identity; the ini's ROLE is then not used.
    local DevSlot = require("gmp_dev_slot")
    local devSlot, slotWhy, slotRaw, slotSource = DevSlot.Resolve({ getenv = G.GMP_TEST_GETENV or (os and os.getenv), commandLine = Bridge.CommandLine(G) })
    if devSlot then netDir = DevSlot.NetDir(modDir, devSlot.slot) end
    local cfgText, cfgError
    if ctx then cfgText, cfgError = ctx.readConfig(); assert(not cfgError or cfgError == "missing", cfgError)
    else cfgText = RealFs.read(modDir .. "/gmp_config.txt") end
    local x = App.ParseExtras(cfgText)
    local role, roleWhy = nil, "none"
    if x.role ~= "none" and not devSlot then role, roleWhy = Role.Resolve(x.role, netDir, RealFs) end
    local logPath = modDir .. (devSlot and ("/" .. DevSlot.LogName(devSlot.slot)) or role and ("/gmp_" .. role .. ".log") or "/gmp.log")
    -- Test 15: a window relaunched after a crash truncated the crashed process's log; keep the previous boot's once
    if devSlot then
        local prev = logPath:gsub("%.log$", ".prev.log")
        pcall(os.remove, prev); pcall(os.rename, logPath, prev)
    end
    local env = Env.new({ print = G.print or print, logPath = logPath })
    env:Log("GoobiesMP main.lua loaded; scriptDir=%s modDir=%s%s", scriptDir, modDir, usedFallbackDir and " (FALLBACK: chunk source path unusable)" or "")
    if devSlot then
        env:Log("launch %s: dev name %s, net %s; the ini's ROLE / DEV_NAME / DEV_PLAYER_SLOT are not used%s", DevSlot.Describe(devSlot),
            devSlot.devName, netDir, devSlot.devNameRefused and (" (-GMPDevName=" .. devSlot.devNameRefused .. " refused: letters, digits, _ only)") or "")
    elseif slotWhy == "invalid_slot" then
        env:Log("launch slot: %s=%s is not a valid slot (a whole number from 1); ignored, booting without a slot", slotSource == "env" and DevSlot.ENV or DevSlot.SWITCH, tostring(slotRaw))
    end
    if x.role ~= "none" and not devSlot then env:Log("ROLE=%s resolved to %s%s", x.role, tostring(role), role and "" or (" (" .. tostring(roleWhy) .. "): staying a plain host-only instance")) end

    local bridge = Bridge.new(G, env)
    if ctx then env:Log("ModList.ini: startup enabled; legacy GoobiesMP.ini is not used")
    else env:Log("GoobiesMP.ini: Enabled=true (%s)", setting.source == "file" and "from file" or ("default: " .. tostring(setting.reason))) end
    local modSettings = {setting=setting, managed=ctx ~= nil}
    if not ctx then modSettings.path, modSettings.fs = iniPath, MS.DiskFs end
    -- D42: Mod Menu's registry (Win64/Configs/ModList.ini, two levels above Mods/GoobiesMP) for the mod mismatch check.
    local modListText = ctx and RealFs.read(modDir .. "/../../Configs/ModList.ini") or nil
    local app = App.new({ env = env, bridge = bridge, configText = cfgText, role = role, roleAuto = (x.role == "auto" and not devSlot), netDir = netDir,
        devSlot = devSlot,
        modSettings = modSettings, modListText = modListText })
    local state = app:Boot()
    runtime = { app = app, bridge = bridge, env = env }
    -- Keep optional lobby dependencies outside default package startup. Older
    -- development profiles may not contain the renderer dependency closure.
    local lobbyEnabled=false
    for line in ((cfgText or '')..'\n'):gmatch('[^\r\n]+') do
        local key,value=line:match('^%s*([%w_]+)%s*=%s*([^;#]*)')
        if key and key:upper()=='LOBBY_UI' then
            value=value:match('^%s*(.-)%s*$'):lower();lobbyEnabled=value=='1' or value=='true';break
        end
    end
    local lobby,lobbyWhy
    if lobbyEnabled then
        local lobbyOk
        lobbyOk,lobby,lobbyWhy=pcall(function()
            local LobbyRuntime=require('gmp_lobby_runtime')
            return LobbyRuntime.new{app=app,G=G,context=ctx,configText=cfgText,
                log=function(line) env:Log('%s',line) end}
        end)
        if not lobbyOk then lobbyWhy='load/construction failed: '..tostring(lobby):sub(1,600);lobby=nil end
        if lobby then env:Log('LOBBYUI managed lobby enabled; explicit Ready/Host start')
        else env:Log('LOBBYUI not enabled: %s',tostring(lobbyWhy)) end
    end
    runtime.lobby=lobby
    G.GoobiesMP = runtime   -- single global for inspection; no other globals are created
    -- D41: the cheat interface Cheat Mod reads (every mode: a client must fail closed whenever it is in a session).
    if ctx then
        local parent=getmetatable(G)
        if parent and type(parent.__index)=='table' then
            parent.__index.GoobiesMPCheatPolicy=function() return app:CheatPolicy() end
            parent.__index.GoobiesMPSetHostCheats=function(state) return app:SetHostCheats(state) end
        end
    end
    -- Managed packages have separate environments. Publish only this optional
    -- development request on their shared parent, never the whole runtime.
    -- D47: the island request (Cheat Mod) and shared pause are playtest gameplay (dev, friend); the forced handover
    -- test is a dev probe.
    local Mode=require("gmp_mode_policy")
    if ctx and Mode.Allows(app.cfg.MODE,'gameplay') and app.extras.islandHandoff then
        local parent=getmetatable(G)
        if parent and type(parent.__index)=='table' then
            parent.__index.GoobiesMPIslandTestRequest=function() return app:RequestIslandTest() end
            if Mode.Allows(app.cfg.MODE,'dev_probes') then
                parent.__index.GoobiesMPHandoverTestRequest=function(forced) return app:RequestHandoverTest(forced) end
            end
            if app.extras.sharedPause then
                parent.__index.GoobiesMPSharedPauseRequest=function(paused) return app:RequestSharedPause(paused) end
            end
        end
    end
    -- D56 (Coder D): a client's F6/F7/F8 go to the host, which carries them out with its own Cheat Mod settings
    -- (Cheat Mod hands the host's handler in). Playtest gameplay: dev and friend builds only, never production.
    if ctx and Mode.Allows(app.cfg.MODE,'gameplay') then
        local parent=getmetatable(G)
        if parent and type(parent.__index)=='table' then
            parent.__index.GoobiesMPCheatRequest=function(key) return app:RequestCheat(key) end
            parent.__index.GoobiesMPSetCheatHandler=function(fn) return app:SetCheatHandler(fn) end
        end
    end

    if state == "hosting" or state == "client" or state == "steam_lobby" or state == "dev_socket_lobby" or app:WantsIdentityRetry() or app.extras.runtimeFacts or app.extras.s1Probe ~= "off" then
        local h, why = bridge:Every(app.extras.tickMs, function(dt) app:Tick(dt);if lobby then lobby:Tick() end end)
        if h then env:Log("tick loop started every %d ms", app.extras.tickMs) else env:Log("tick loop NOT started: %s", tostring(why)) end
    end
end)
if not okLoad then
    if ctx then error(err, 0) end -- let the framework report a failed package startup
    pcall(function() (G.print or print)("[GoobiesMP] main.lua failed: " .. tostring(err)) end)
end
return runtime
