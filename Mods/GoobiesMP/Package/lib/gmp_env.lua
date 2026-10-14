-- GoobiesMP: runtime environment helpers. Pure Lua: NO UE4SS/game API here (that is bridge.lua's job).
-- Everything is injectable so it can be tested offline.
--   Env.ScriptDir(source)        -> directory of a "@path" chunk source, or nil
--   Env.AddPackagePath(dir, pkg) -> idempotently makes `require` look in dir (pkg defaults to the global `package`)
--   Env.new(opts)                -> env: Log, Clock, ReadFile, Info
-- opts: print=function, open=function(path, mode), clock=function->seconds, time=function->epoch, logPath=string|nil, truncate=bool
local Env = {}
Env.__index = Env

function Env.ScriptDir(source)
    if type(source) ~= "string" then return nil end
    return source:match("^@(.*)[/\\][^/\\]*$")
end

function Env.AddPackagePath(dir, pkg)
    pkg = pkg or package
    if type(dir) ~= "string" or dir == "" then return false end
    local entry = dir .. "/?.lua"
    if (";" .. pkg.path .. ";"):find(";" .. entry:gsub("%p", "%%%0") .. ";") then return false end
    pkg.path = entry .. ";" .. pkg.path
    return true
end

function Env.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Env)
    self.printFn = opts.print or print
    self.open = opts.open or io.open
    self.clockFn = opts.clock or os.clock
    self.timeFn = opts.time or os.time
    self.logPath = opts.logPath
    self.t0 = self.clockFn()
    self.epoch0 = self.timeFn()
    self.logged = 0
    self.logFailed = false
    if self.logPath and opts.truncate ~= false then
        local ok, f = pcall(self.open, self.logPath, "wb")
        if ok and f then f:close() else self.logFailed = true end
    end
    return self
end

-- seconds since this env was created, from the injected clock (default os.clock).
function Env:Clock() return self.clockFn() - self.t0 end

-- Log never raises: bad format args are logged raw; an unwritable file only disables file logging.
function Env:Log(fmtstr, ...)
    local ok, line = pcall(string.format, tostring(fmtstr), ...)
    if not ok then line = tostring(fmtstr) end
    line = string.format("[GoobiesMP %8.3f] %s", self:Clock(), line)
    pcall(self.printFn, line)
    self.logged = self.logged + 1
    if self.logPath and not self.logFailed then
        local fok, f = pcall(self.open, self.logPath, "ab")
        if fok and f then f:write(line, "\n"); f:close() else self.logFailed = true end
    end
    return line
end

-- Whole file as a string, or nil,err. Never raises.
function Env:ReadFile(path)
    local ok, f = pcall(self.open, path, "rb")
    if not ok or not f then return nil, "cannot_open" end
    local data = f:read("a"); f:close()
    return data
end

-- Facts about the running Lua (logged at boot so the real UE4SS runtime is documented).
function Env:Info()
    return {
        lua = _VERSION,
        packagePath = package.path,
        clock = self:Clock(),
        epochStart = self.epoch0,
        logPath = self.logPath,
        logFileWorks = self.logPath ~= nil and not self.logFailed,
    }
end

return Env
