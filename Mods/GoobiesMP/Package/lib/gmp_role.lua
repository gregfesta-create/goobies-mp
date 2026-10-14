-- GoobiesMP: instance ROLE resolution for the M3 two-instance test (pure Lua; file access injectable).
-- ROLE=none            (default) no networking: the M2 host-only session.
-- ROLE=host | client   fixed role from the config file.
-- ROLE=auto            the dev launcher hands each instance its role through <net>\role_assign.txt ("host", later "client").
--                      The first instance that reads a valid role writes "taken" so the launcher can start the next one.
-- Two instances share one config file and one mod folder, so a hand-off file is the only way to tell them apart.
local Role = {}

Role.VALID = { none = true, host = true, client = true, auto = true }

-- fs: { read(path)->string|nil, write(path, text)->bool }
function Role.Resolve(configRole, netDir, fs)
    if configRole == nil or configRole == "none" then return nil, "none" end
    if configRole == "host" or configRole == "client" then return configRole end
    if configRole ~= "auto" then return nil, "bad_role" end
    local path = netDir .. "/role_assign.txt"
    local text = fs.read(path)
    local r = text and text:match("^%s*(%a+)%s*$")
    if r ~= "host" and r ~= "client" then return nil, "no_role_assignment" end
    if not fs.write(path, "taken") then return nil, "role_assign_not_writable" end
    return r
end

return Role
