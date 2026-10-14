-- RunContext (PLAN_WORLD_ENTRY.md 3.2 item 8; frozen after C0). A read-only description of the current shared run,
-- derived from the app's session and its two world objects. It never creates, installs or writes anything.
--   RunContext.From(app) -> {sid, term, role, selfKey, hostKey, epoch, island, phase, stamp, key, generation=epoch,
--                            worldPath, controllerPath, world=<gmp_world>, islandWorld=<gmp_island_world>} | nil
-- nil unless the island phase is `playing` and the session is valid (host started; client joined with an
-- authenticated host). `key` names the context for run sync, combat and prep messages.
local Islands = require('gmp_islands')
local RC = {}

-- Object path rule from gmp_app.lua (UE4SS exposes GetFullName "Class /Path"; the path is the part after the class).
local function path(object)
    if object == nil then return nil end
    local ok, name = pcall(function()
        if object:IsValid() ~= true then return nil end
        return object:GetFullName()
    end)
    if not ok or type(name) ~= 'string' then return nil end
    return name:match('^[^ ]+ (.+)$')
end
local function read(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

function RC.From(app)
    if type(app) ~= 'table' then return nil end
    local role = app.role
    local session = role == 'host' and app.host or role == 'client' and app.client or nil
    if type(session) ~= 'table' then return nil end
    local flow = app.islandFlow
    if type(flow) ~= 'table' or flow.failed then return nil end
    local sid = session.sid
    if type(sid) ~= 'string' or sid == '' then return nil end
    local term = session.authorityTerm or 1
    if math.type(term) ~= 'integer' or term < 1 then return nil end
    local selfKey = type(session.identity) == 'table' and session.identity.key or nil
    local hostKey
    if role == 'host' then
        if session.started ~= true then return nil end
        hostKey = selfKey
    else
        if type(session.State) ~= 'function' or session:State() ~= 'joined' then return nil end
        hostKey = session.authenticatedHostKey
    end
    if type(selfKey) ~= 'string' or type(hostKey) ~= 'string' then return nil end
    local islands = session.islands
    if type(islands) ~= 'table' or islands.phase ~= 'playing' or not islands.current then return nil end
    local stamp = Islands.Stamp(islands.current)
    if not stamp then return nil end
    local world, islandWorld = app.nativeWorld, flow.world
    local worldPath, controllerPath
    if type(world) == 'table' then
        worldPath = read(function() return path(world:_world()) end)
        controllerPath = read(function() return path(world:_enemyController()) end)
    end
    if not worldPath and type(islandWorld) == 'table' and type(islandWorld.LocalWorldPawn) == 'function' then
        worldPath = read(function() return path((islandWorld:LocalWorldPawn())) end)
    end
    return { sid = sid, term = term, role = role, selfKey = selfKey, hostKey = hostKey,
        epoch = islands.epoch, island = islands.island, phase = islands.phase, stamp = stamp,
        key = table.concat({ sid, term, islands.epoch, islands.island, stamp }, ':'), generation = islands.epoch,
        worldPath = worldPath, controllerPath = controllerPath, world = world, islandWorld = islandWorld }
end

return RC
