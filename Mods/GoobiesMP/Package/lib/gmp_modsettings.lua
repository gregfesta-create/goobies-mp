-- GoobiesMP: the ONE persistent user-facing setting, GoobiesMP.ini:
--     [GoobiesMP]
--     Enabled=true
-- Read by main.lua BEFORE anything else is loaded (Enabled=false => nothing initialises: no bridge, no Steam provider, no tick loop, no
-- hooks), by the lobby settings UI (to show/change it) and by launchers (plain INI: GetPrivateProfileString works). Technical/network
-- settings stay in gmp_config.txt. A change takes effect on the NEXT game start; the mod is never unloaded/reloaded at run time.
-- Pure Lua; file access is injected (fs.read / fs.write).
local MS = {}

MS.SECTION, MS.KEY, MS.FILE = "GoobiesMP", "Enabled", "GoobiesMP.ini"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local TRUE = { ["true"] = true, ["1"] = true, ["yes"] = true, ["on"] = true }
local FALSE = { ["false"] = true, ["0"] = true, ["no"] = true, ["off"] = true }

-- text|nil -> { enabled=bool, source="default"|"file", reason=string }
--   no file / no section / no key  -> enabled (documented default: installing the mod enables it)
--   a value that is neither true nor false -> DISABLED (when unsure, leave vanilla Goobies alone) with reason "unparsable"
function MS.Parse(text)
    if type(text) ~= "string" then return { enabled = true, source = "default", reason = "no_file" } end
    local section, found, value = nil, false, nil
    for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        line = trim((line:gsub("^\239\187\191", "")))
        local sec = line:match("^%[([^%]]+)%]$")
        if sec then section = trim(sec)
        elseif section and section:lower() == MS.SECTION:lower() and line:sub(1, 1) ~= ";" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
            if k and k:lower() == MS.KEY:lower() and not found then found, value = true, trim((v:gsub("[;#].*$", ""))):lower() end   -- first Enabled wins
        end
    end
    if not found then return { enabled = true, source = "default", reason = "no_key" } end
    if TRUE[value] then return { enabled = true, source = "file", reason = "ok" } end
    if FALSE[value] then return { enabled = false, source = "file", reason = "ok" } end
    return { enabled = false, source = "file", reason = "unparsable" }
end

-- Rewrite text with Enabled=<bool> in [GoobiesMP]: keeps every other line/comment, keeps ONE Enabled line (extra ones are removed so
-- no competing setting can exist), creates the section/key when missing.
function MS.Render(text, enabled)
    local val = enabled and "true" or "false"
    local lines = {}
    text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")                    -- CRLF/CR/LF all mean one line break
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end
    local out, section, done, secEnd = {}, nil, false, nil
    for _, line in ipairs(lines) do
        local t = trim(line)
        local sec = t:match("^%[([^%]]+)%]$")
        if sec then
            if section and section:lower() == MS.SECTION:lower() and not secEnd then secEnd = #out end
            section = trim(sec)
            out[#out + 1] = line
        else
            local k = t:match("^([%w_]+)%s*=")
            if section and section:lower() == MS.SECTION:lower() and k and k:lower() == MS.KEY:lower() then
                if not done then out[#out + 1] = MS.KEY .. "=" .. val; done = true end        -- later duplicates are dropped
            else
                out[#out + 1] = line
            end
        end
    end
    if not done then
        local inSection = false
        for _, l in ipairs(out) do local s = l:match("^%s*%[([^%]]+)%]%s*$"); if s and s:lower() == MS.SECTION:lower() then inSection = true end end
        if inSection then
            -- insert right after the section header
            for i, l in ipairs(out) do
                local s = l:match("^%s*%[([^%]]+)%]%s*$")
                if s and s:lower() == MS.SECTION:lower() then table.insert(out, i + 1, MS.KEY .. "=" .. val); break end
            end
        else
            if #out > 0 and trim(out[#out]) ~= "" then out[#out + 1] = "" end
            out[#out + 1] = "[" .. MS.SECTION .. "]"
            out[#out + 1] = MS.KEY .. "=" .. val
        end
    end
    return table.concat(out, "\r\n") .. "\r\n"
end

-- Plain disk access (the only file API this module needs; main.lua uses it BEFORE any other module is loaded).
MS.DiskFs = {
    read = function(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end,
    write = function(path, text) local f = io.open(path, "wb"); if not f then return false end f:write(text); f:close(); return true end,
}

-- fs: { read(path)->string|nil, write(path,text)->bool }
function MS.Load(fs, path) return MS.Parse(fs.read(path)) end

-- Persist Enabled. Verifies by reading back. Returns { ok, enabled, restartRequired, message } -- never reloads anything.
function MS.Save(fs, path, enabled)
    local text = MS.Render(fs.read(path), enabled)
    if not fs.write(path, text) then return { ok = false, reason = "not_writable", message = "Could not write " .. MS.FILE .. "." } end
    local back = MS.Parse(fs.read(path))
    if back.enabled ~= enabled or back.source ~= "file" then return { ok = false, reason = "verify_failed", message = "Could not verify the written setting." } end
    return { ok = true, enabled = enabled, restartRequired = true,
        message = enabled and "GoobiesMP is enabled. Restart Goobies for this to take effect." or "GoobiesMP is disabled. Restart Goobies for this to take effect." }
end

return MS
