-- Safe use of UObjects cached across ticks (R1 attempt 2 client crash, 2026-10-13: UE4SS UObject::ProcessEvent on a
-- main-menu object freed by the level change into the island). A UE4SS Lua UObject keeps a raw pointer; after a level
-- change and garbage collection the memory can be freed or reused, and UE4SS IsValid reads that same memory, so it
-- cannot vouch for a cached object. Before touching a cached object, find its address again among the LIVE objects of
-- its class (FindAllOf walks the engine's object array). GetAddress only returns the stored pointer.
--   L.Address(object) -> integer | nil
--   L.Listed(G, object, className) -> the live object with that address (a fresh handle) | nil
--                                    (a plain table without GetAddress, i.e. an offline test double, is returned as is)
--   L.WorldLive(G, worldPath) -> true when a live World has that path (the part after the class in GetFullName)
local L = {}

function L.Address(object)
    if object == nil then return nil end
    local ok, address = pcall(function() return object:GetAddress() end)
    if ok and (math.type(address) == 'integer' or type(address) == 'number') and address ~= 0 then return address end
    return nil
end

function L.Listed(G, object, className)
    if object == nil then return nil end
    -- Every UE4SS UObject handle has GetAddress; a plain Lua table (an offline test double) has nothing to verify.
    if type(object) == 'table' and rawget(object, 'GetAddress') == nil and getmetatable(object) == nil then return object end
    local address = L.Address(object)
    if not address or type(G) ~= 'table' or type(G.FindAllOf) ~= 'function' then return nil end
    local ok, list = pcall(G.FindAllOf, className)
    if not ok or type(list) ~= 'table' then return nil end
    for _, candidate in ipairs(list) do
        if L.Address(candidate) == address then return candidate end
    end
    return nil
end

function L.WorldLive(G, worldPath)
    if type(worldPath) ~= 'string' or type(G) ~= 'table' or type(G.FindAllOf) ~= 'function' then return false end
    local ok, worlds = pcall(G.FindAllOf, 'World')
    if not ok or type(worlds) ~= 'table' then return false end
    for _, world in ipairs(worlds) do
        local named, name = pcall(function() return world:GetFullName() end)
        if named and type(name) == 'string' and name:match('^[^ ]+ (.+)$') == worldPath then return true end
    end
    return false
end

return L
