-- D45/D46/D49 (Coder C): the drawing of shared pickups, used on the host (D49: its virtual orbs) and on clients alike.
-- Owned InstancedStaticMeshComponents added to the local enemy controller, one per drawn group, with collision
-- disabled, so the game's own pickup traces never hit them. Templates come from the local controller:
--   o  XP orbs (D49): the XPInstanceComponent's mesh (SM_PlaneAngled) and material (MI_XP_Plane, an M_Master
--      instance). One component per value tier (TIERS: 1-9, 10-24, 25-99, 100+); tiers 2-4 draw with a dynamic material
--      instance whose vector parameter MainColor is the tier color (read back and logged once per tier; tier 1 keeps
--      the game's own look); sizes 1.0 / 1.15 / 1.3 / 1.5. An orb that grows into another tier moves component.
--   x  XP consumable: the orb mesh at normal size
--   h/m/i/b  consumables: AllConsumableInstances[row] mesh/material (DT_Consumables rows 0..3), size 1
--   r  reward item actors (BP_RewardItem): the loot item mesh, size 1
-- One instance per item; hidden = scale 0; freed slots are reused. The game's own components are never touched.
-- Visual only: collection is decided by the host (gmp_pickups_host.lua).
--   V.new{G, log}; v:Bind(ctx) -> ok, why; v:Set(id, x, y, z, n, hidden, kind='o') -> ok; v:Hide(id, hidden);
--   v:Remove(id); v:Count(); v:Clear() -> ok
local Orbs = require('gmp_pickups_orbs')
local V = {}; V.__index = V
V.CAP = 2048
V.CLASS = '/Script/Engine.InstancedStaticMeshComponent'
V.ROWS = { h = 0, m = 1, i = 2, b = 3, r = 2 }   -- reward item actors are drawn with the loot item mesh
V.TIER_SCALES = { 1.0, 1.15, 1.3, 1.5 }
V.COLOR_PARAMETER = 'MainColor'
V.TIER_COLORS = { false, { R = 0.25, G = 1.0, B = 0.35, A = 1.0 }, { R = 0.65, G = 0.3, B = 1.0, A = 1.0 }, { R = 1.0, G = 0.72, B = 0.08, A = 1.0 } }
V.XP_CONSUMABLE_SCALE = 1

-- crash hardening (test 12): an object being destroyed is not used (IsValid, then not being destroyed)
local function valid(o)
    if o == nil then return false end
    local ok, live = pcall(function()
        if o:IsValid() ~= true then return false end
        if o.IsBeingDestroyed ~= nil and o:IsBeingDestroyed() == true then return false end
        if o.IsActorBeingDestroyed ~= nil and o:IsActorBeingDestroyed() == true then return false end
        return true
    end)
    return ok and live == true
end
local function transform(x, y, z, s)
    return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = s, Y = s, Z = s } }
end
local function len(arr)
    if arr == nil then return 0 end
    if type(arr) == 'table' and type(arr.GetArrayNum) ~= 'function' then return #arr end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    return ok and n or 0
end
-- the drawn group of an item, and its size
local function groupOf(kind, n)
    if kind == 'o' then
        local tier = Orbs.Tier(n)
        return 'o' .. tier, V.TIER_SCALES[tier], tier
    end
    if kind == 'x' then return 'x', V.XP_CONSUMABLE_SCALE end
    return kind, 1
end
local function name(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and type(n) == 'string' and n or tostring(o)
end

function V.new(options)
    options = options or {}
    return setmetatable({ G = options.G, log = options.log, slots = {}, groups = {}, colorLogged = {} }, V)
end
function V:_log(fmt, ...)
    if not self.log then return end
    local ok, line = pcall(string.format, fmt, ...)
    pcall(self.log, ok and line or tostring(fmt))
end
function V:Count() local n = 0; for _ in pairs(self.slots) do n = n + 1 end; return n end
function V:Bind(ctx)
    if self.controller and self.context == ctx.key and valid(self.controller) and self.groups.o1 and valid(self.groups.o1.component) then
        return true
    end
    if self.controller then self:Clear() end
    local ok, why = pcall(function()
        local island = ctx.islandWorld
        if type(island) ~= 'table' or type(island.LocalWorldPawn) ~= 'function' then error('no_island_world', 0) end
        local _, pawn = island:LocalWorldPawn()
        if not valid(pawn) then error('no_pawn', 0) end
        local controller = pawn.EnemyController
        if not valid(controller) then error('no_controller', 0) end
        local class = self.G and self.G.StaticFindObject and self.G.StaticFindObject(V.CLASS)
        if not valid(class) then error('no_component_class', 0) end
        self.controller, self.class, self.context = controller, class, ctx.key
        local _, gwhy = self:_group('o1')
        if gwhy then error(gwhy, 0) end
    end)
    if not ok then
        pcall(self.Clear, self)
        return false, tostring(why)
    end
    return true
end
-- The template mesh/material of a group on the local controller, or nil, why.
function V:_template(key)
    local controller = self.controller
    if key:sub(1, 1) == 'o' or key == 'x' then
        local native = controller.XPInstanceComponent
        if not valid(native) then return nil, 'no_xp_component' end
        return native.StaticMesh, native:GetMaterial(0)
    end
    local row = V.ROWS[key]
    if not row then return nil, 'no_template_kind' end
    local list = controller.AllConsumableInstances
    if len(list) <= row then return nil, 'no_consumable_row' end
    local source = list[row + 1]
    if not valid(source) then return nil, 'no_consumable_row' end
    return source.StaticMesh, source:GetMaterial(0)
end
-- D49: a tier component draws with its own dynamic material instance, MainColor = the tier color.
function V:_tierColor(component, material, tier)
    local color = V.TIER_COLORS[tier]
    if not color then return end
    local okMid, mid = pcall(component.CreateDynamicMaterialInstance, component, 0, material)
    if not okMid or not mid or mid:IsValid() ~= true then
        if not self.colorLogged[tier] then self.colorLogged[tier] = true; self:_log('PICKUPS view tier=%d color_ok=false reason=no_dynamic_material', tier) end
        return
    end
    component:SetMaterial(0, mid)
    local param = (self.G and type(self.G.FName) == 'function') and self.G.FName(V.COLOR_PARAMETER) or V.COLOR_PARAMETER
    local value = { R = color.R, G = color.G, B = color.B, A = color.A }
    local okSet = pcall(mid.SetVectorParameterValue, mid, param, value)
    local okRead, read = pcall(mid.K2_GetVectorParameterValue, mid, param)
    local same = okSet and okRead and type(read) == 'table' and math.abs((read.R or -1) - color.R) < 0.01
        and math.abs((read.G or -1) - color.G) < 0.01 and math.abs((read.B or -1) - color.B) < 0.01
    if not self.colorLogged[tier] then
        self.colorLogged[tier] = true
        self:_log('PICKUPS view tier=%d color_ok=%s material=%s', tier, tostring(same == true), name(material))
    end
end
function V:_group(key)
    local group = self.groups[key]
    if group then
        if valid(group.component) then return group end
        return nil, 'group_lost'
    end
    if not self.controller then return nil, 'unbound' end
    local mesh, material = self:_template(key)
    if not valid(mesh) or not valid(material) then return nil, type(material) == 'string' and material or 'no_template' end
    local component = self.controller:AddComponentByClass(self.class, true, transform(0, 0, 0, 1), false)
    if not valid(component) then return nil, 'component_creation_failed' end
    group = { component = component, free = {}, allocated = 0 }
    self.groups[key] = group   -- owned before configuration, so Clear destroys a partly configured one
    component:SetCollisionEnabled(0)
    component:SetMobility(2)
    if component:SetStaticMesh(mesh) == false then return nil, 'mesh_assignment_failed' end
    component:SetMaterial(0, material)
    local tier = key:match('^o(%d)$')
    if tier then self:_tierColor(component, material, tonumber(tier)) end
    return group
end
function V:_write(slot)
    local s = slot.hidden and 0 or slot.scale
    return slot.group.component:UpdateInstanceTransform(slot.index, transform(slot.x, slot.y, slot.z, s), true, true, true) == true
end
function V:Set(id, x, y, z, n, hidden, kind)
    kind = kind or 'o'
    if not self.controller then return false end
    local ok, result = pcall(function()
        local key, scale = groupOf(kind, n)
        local slot = self.slots[id]
        if slot and slot.key ~= key then self:Remove(id); slot = nil end
        if not slot then
            local group = self:_group(key)
            if not group then return false end
            local index = table.remove(group.free)
            if not index then
                if group.allocated >= V.CAP then return false end
                index = group.component:AddInstance(transform(x, y, z, 0), true)
                if math.type(index) ~= 'integer' then index = math.tointeger(index) end
                if not index then return false end
                group.allocated = group.allocated + 1
            end
            slot = { index = index, group = group, key = key }
            self.slots[id] = slot
        end
        slot.x, slot.y, slot.z, slot.n, slot.hidden, slot.scale = x, y, z, n, hidden == true, scale
        return self:_write(slot)
    end)
    return ok and result == true
end
function V:Hide(id, hidden)
    local slot = self.slots[id]
    if not slot or not valid(slot.group.component) then return false end
    slot.hidden = hidden == true
    local ok, result = pcall(self._write, self, slot)
    return ok and result == true
end
function V:Remove(id)
    local slot = self.slots[id]
    if not slot then return true end
    self.slots[id] = nil
    if not valid(slot.group.component) then return false end
    slot.hidden = true
    local ok, result = pcall(self._write, self, slot)
    slot.group.free[#slot.group.free + 1] = slot.index
    return ok and result == true
end
function V:Clear()
    local controller, groups = self.controller, self.groups
    self.slots, self.groups, self.controller, self.class, self.context = {}, {}, nil, nil, nil
    local clean = true
    for _, group in pairs(groups) do
        if group.component and valid(group.component) then
            if not pcall(group.component.K2_DestroyComponent, group.component, controller) then clean = false end
        end
    end
    return clean
end
return V
