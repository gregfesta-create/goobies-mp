-- D45 (Coder C): crash hardening for the shared XP modules (test 12: a client crashed inside UE4SS FindAllOf on an
-- object being destroyed). gmp_island_world's LocalWorldPawn runs FindAllOf('World') on every call, and the pickup/XP
-- adapters asked for the pawn many times per tick. This cache resolves the local world/pawn/library at most once per
-- tick and reuses it across ticks while the pawn is live (IsValid and not IsActorBeingDestroyed) for at most
-- REFRESH_SECONDS; a context change, a dead or destroyed pawn, or an empty lookup forces a new lookup on the next
-- tick. A failing lookup returns nothing and never raises.
--   P.new(); p:Wrap(ctx, now) -> a ctx whose islandWorld:LocalWorldPawn() is served from the cache (other fields
--   read through to ctx)
local P = {}; P.__index = P
P.REFRESH_SECONDS = 2

local function live(o)
    if o == nil then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    if not ok or valid ~= true then return false end
    local okD, dying = pcall(function()
        if o.IsActorBeingDestroyed == nil then return false end
        return o:IsActorBeingDestroyed()
    end)
    return okD and dying ~= true
end
P.Live = live

function P.new() return setmetatable({}, P) end
function P:_lookup(island, now)
    self.world, self.pawn, self.library, self.at, self.tick = nil, nil, nil, now, now
    if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then return end
    local ok, world, pawn, library = pcall(island.LocalWorldPawn, island)
    if ok then self.world, self.pawn, self.library = world, pawn, library end
end
function P:Get(island, key, now)
    local fresh = self.key == key and self.at ~= nil and now - self.at < P.REFRESH_SECONDS and live(self.pawn)
    -- an empty or failed lookup is retried at most once per tick
    local retried = self.key == key and self.tick == now
    if not fresh and not retried then self.key = key; self:_lookup(island, now) end
    if not live(self.pawn) then return nil end
    return self.world, self.pawn, self.library
end
function P:Wrap(ctx, now)
    local cache, island, key = self, ctx.islandWorld, ctx.key
    if cache.key ~= key then cache.key, cache.at, cache.tick, cache.pawn = key, nil, nil, nil end
    local proxy = setmetatable({}, { __index = island })
    function proxy.LocalWorldPawn() return cache:Get(island, key, now) end
    return setmetatable({ islandWorld = proxy }, { __index = ctx })
end
return P
