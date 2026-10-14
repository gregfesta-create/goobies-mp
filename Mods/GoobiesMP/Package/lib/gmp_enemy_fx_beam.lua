-- Boss attack visuals on clients (Coder C, follow-up to part A; dev flag ENEMY_FX): the Magmus laser beam.
-- The game's laser is not an effect but BP_Logic_Magmus_Laser's own mesh components (Laser: SM_Cylinder_hollow_Subd
-- with MI_Laser, scaled to the hit distance) plus NS_LaserHit moved to the hit point. The host streams the Laser
-- component's world transform and the end point (gmp_enemy_fx_host.lua, about 10 a second); this view draws the
-- same mesh and material in an owned StaticMeshComponent on the local enemy controller (collision off, so nothing
-- hits it) and keeps the game's NS_LaserHit at the end point, without a callback. Visual only.
--   B.new{G, log}; b:Update(ctx, m, now) -> ok   m = ENEMY_FX laser {id, x, y, z, ex, ey, ez, rx, ry, rz (1/100 deg), sx, sy, sz (1/1000)}
--   b:End(id); b:Tick(now) (a laser silent for STALE_SECONDS goes); b:Count(); b:Clear() -> ok
local Live = require('gmp_pickups_pawncache').Live
local B = {}; B.__index = B
B.MESH = '/Game/Meshes/FX/SM_Cylinder_hollow_Subd.SM_Cylinder_hollow_Subd'
B.MATERIAL = '/Game/Materials/MI_Laser.MI_Laser'
B.HIT = '/Game/FX/Test/BossMagmus/NS_LaserHit.NS_LaserHit'
B.CLASS = '/Script/Engine.StaticMeshComponent'
B.LIBRARY = '/Script/Niagara.Default__NiagaraFunctionLibrary'
B.MAX = 4
B.STALE_SECONDS = 1
local LIMIT = 2000000

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) <= LIMIT end
local function num(v, f) return finite(v) and v * f or 0 end

function B.new(options)
    options = options or {}
    return setmetatable({ G = options.G, log = options.log, beams = {}, logged = {} }, B)
end
function B:_once(key, fmt, ...)
    if self.logged[key] or not self.log then return end
    self.logged[key] = true
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function B:_find(path)
    local find = self.G and self.G.StaticFindObject
    if type(find) ~= 'function' then return nil end
    local ok, o = pcall(find, path)
    return ok and Live(o) and o or nil
end
function B:Count() local n = 0; for _ in pairs(self.beams) do n = n + 1 end; return n end
local function transform(m)
    return { Translation = { X = m.x, Y = m.y, Z = finite(m.z) and m.z or 0 },
        Rotation = { Pitch = num(m.rx, 0.01), Yaw = num(m.ry, 0.01), Roll = num(m.rz, 0.01) },
        Scale3D = { X = num(m.sx, 0.001), Y = num(m.sy, 0.001), Z = num(m.sz, 0.001) } }
end
local function hitAt(m) return { X = m.ex, Y = m.ey, Z = finite(m.ez) and m.ez or 0 } end
function B:_create(ctx, m)
    local _, pawn = ctx.islandWorld:LocalWorldPawn()
    if not Live(pawn) then return nil, 'no_pawn' end
    local controller = pawn.EnemyController
    if not Live(controller) then return nil, 'no_controller' end
    local class, mesh, material = self:_find(B.CLASS), self:_find(B.MESH), self:_find(B.MATERIAL)
    if not class or not mesh or not material then return nil, 'no_laser_assets' end
    local t = transform(m)
    local component = controller:AddComponentByClass(class, true, t, false)
    if not Live(component) then return nil, 'component_creation_failed' end
    local beam = { controller = controller, mesh = component }
    component:SetCollisionEnabled(0)
    component:SetMobility(2)
    component:SetStaticMesh(mesh)
    component:SetMaterial(0, material)
    local lib, hit = self:_find(B.LIBRARY), self:_find(B.HIT)
    if lib and hit then
        local context = controller
        local okHit, n = pcall(function() return lib:SpawnSystemAtLocation(context, hit, hitAt(m), { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, false, true, 0, true) end)
        if okHit and Live(n) then beam.hit = n end
    end
    return beam
end
function B:Update(ctx, m, now)
    if type(m) ~= 'table' or math.type(m.id) ~= 'integer' or m.id < 1 or not finite(m.x) or not finite(m.y)
        or not finite(m.ex) or not finite(m.ey) then return false end
    local ok, result, why = pcall(function()
        local beam = self.beams[m.id]
        if beam and not Live(beam.mesh) then self:End(m.id); beam = nil end
        if not beam then
            if self:Count() >= B.MAX then return false, 'beam_cap' end
            local made, cwhy = self:_create(ctx, m)
            if not made then return false, cwhy end
            beam = made
            self.beams[m.id] = beam
        end
        beam.at = now
        beam.mesh:K2_SetWorldTransform(transform(m), false, {}, false)
        if Live(beam.hit) then beam.hit:K2_SetWorldLocation(hitAt(m), false, {}, false) end
        return true
    end)
    if not ok then result, why = false, 'exception:' .. tostring(result):sub(1, 120) end
    if result ~= true then self:_once('update:' .. tostring(why), 'ENEMYFX laser not drawn reason=%s', tostring(why)) end
    return result == true
end
local function destroy(component, owner)
    if not Live(component) then return true end
    return pcall(function() component:K2_DestroyComponent(owner) end)
end
function B:End(id)
    local beam = self.beams[id]
    if not beam then return false end
    self.beams[id] = nil
    local a = destroy(beam.mesh, beam.controller)
    local b = destroy(beam.hit, beam.controller)
    return a and b
end
function B:Tick(now)
    for id, beam in pairs(self.beams) do
        if not beam.at or now - beam.at >= B.STALE_SECONDS then self:End(id) end
    end
end
function B:Clear()
    local clean = true
    for id in pairs(self.beams) do if not self:End(id) then clean = false end end
    self.beams = {}
    return clean
end
return B
