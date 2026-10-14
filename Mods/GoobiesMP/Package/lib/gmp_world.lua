-- GoobiesMP M3.1: the ONLY file that touches game objects for presence (pawn read and marker actors). Everything is pcall-protected;
-- an error here must never reach the networking code. UE4SS globals are INJECTED (`G`), never read from _G, so requiring this module
-- does nothing and tests can pass a fake.
--
-- STATUS: Local pawn reads verified in game on 2026-10-10. Marker operations remain unverified in this integration. Written from the Phase 1 POC, which
-- CONFIRMED: reading the local pawn (K2_GetActorLocation, PlayerIsDead) and spawning a StaticMeshActor marker with the pawn's mesh. NOT confirmed:
-- destroying or hiding a marker, behaviour across map changes, and marker tinting. Those are why marker operations have their own gate.
--
-- Interface used by gmp_presence.lua Driver:
--   World:ReadLocal()      -> nil (no game map / no valid pawn; NOT an error) | { x, y, z, dead, pawnId }   (reads only; never writes a property)
--   World:SetMarkers(list) -> creates/moves/removes marker actors so that exactly `list` {key,x,y,z,dead} is shown   (the only writer)
--   World:ClearMarkers()
--   World:Status()
-- Identity note: GetPlayerPawn(0) is used here ONLY to read this process's own pawn. It is never used as a player identity.
local World = {}
local Visual=require('gmp_presentation')
local Liveness=require('gmp_run_sync_liveness')
local Identity=require('gmp_identity')
World.__index = World

World.MAP = "/Game/Maps/Game"
World.MAX_SPAWN_TRIES = 3          -- immediate tries per marker key; then retries back off (R1 attempt 4: never give up)
World.RETRY_SECONDS = 2            -- first wait after the immediate tries; doubles per failure
World.RETRY_MAX_SECONDS = 30       -- cap of the wait
World.MAX_MARKERS = 64
-- Liveness rule (gmp_run_sync_liveness): a cached marker actor is trusted only while the island World it was spawned in
-- is the current one (same address) and, at most this often and before every destroy, it is found again by address
-- among the live StaticMeshActors (UE4SS IsValid cannot see freed memory).
World.MARKER_CLASS = "StaticMeshActor"
World.LIVENESS_SECONDS = 1
-- Test 13 (user): the floating spinning indicator above each remote player (d68ca0d) is gone. It was a small copy of the
-- LOCAL player's mesh (it never took the remote's model), so a client saw its own class over the host; the stand-in
-- itself shows the remote player's class (PRESENCE_APPEARANCE model).

local function valid(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function num(v) if type(v) == "number" then return v end return nil end

-- G: table of the UE4SS globals this module may use: FindAllOf, StaticFindObject.
-- opts: map, clock() -> seconds (spawn backoff, liveness checks; default os.clock), log(line).
function World.new(G, opts)
    opts = opts or {}
    return setmetatable({ G = G, map = opts.map or World.MAP, markers = {}, tries = {}, spawnLog = {}, gs = nil,
        clock = opts.clock or os.clock, log = opts.log or function() end, liveAt = nil,
        stats = { spawned = 0, spawn_failed = 0, moved = 0, removed = 0, hidden_instead = 0, remove_failed = 0, lost = 0, avatar_updates=0, avatar_failed=0 } }, World)
end

function World:_world()
    local ok, list = pcall(self.G.FindAllOf, "World")
    if not ok or type(list) ~= "table" then return nil end
    for _, w in ipairs(list) do
        local okn, n = pcall(function() return w:GetFullName() end)
        if okn and type(n) == "string" and n:find(self.map, 1, true) then return w end
    end
    return nil
end

function World:_statics()
    if valid(self.gs) then return self.gs end
    self.gs = self.G.StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return self.gs
end

function World:_pawn(w)
    local gs = self:_statics()
    if not valid(gs) then return nil end
    local p = gs:GetPlayerPawn(w, 0)
    if valid(p) then return p end
    return nil
end

function World:ReadLocal()
    local w = self:_world()
    if not w then return nil end
    local p = self:_pawn(w)
    if not p then return nil end
    local l = p:K2_GetActorLocation()
    local x, y, z = num(l.X), num(l.Y), num(l.Z)
    if not (x and y and z) then return nil end
    local dead = false
    pcall(function() dead = (p.PlayerIsDead == true) end)
    local id
    pcall(function() id = p:GetFullName() end)
    return { x = x, y = y, z = z, dead = dead, pawnId = id }
end

-- One marker part: a StaticMeshActor with the local pawn's mesh at `scale` of its size; collision off, movable.
function World:_spawnPart(w, cls, pawn, x, y, z, scale)
    local actor = w:SpawnActor(cls, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(actor) then error("spawn returned an invalid actor") end
    local ok,err=pcall(function()
        local comp = actor.StaticMeshComponent
        -- Collision must be disabled before assigning a mesh, rather than ignored on failure.
        comp:SetCollisionEnabled(0)
        comp:SetMobility(2)
        comp:SetStaticMesh(pawn.PlayerMesh.StaticMesh)
        pcall(function() comp:SetMaterial(0, pawn.PlayerMesh:GetMaterial(0)) end)
        pcall(function()
            local s = pawn.PlayerMesh:K2_GetComponentScale()
            comp:SetWorldScale3D({ X = s.X * scale, Y = s.Y * scale, Z = s.Z * scale })
        end)
        pcall(function() comp:SetCastShadow(false) end)
    end)
    if not ok then
        -- A partially initialized actor must not be abandoned when setup fails.
        local removed=pcall(function() actor:K2_DestroyActor() end)
        if not removed then pcall(function() actor:SetActorHiddenInGame(true) end) end
        error(err)
    end
    return actor
end

-- A marker: the remote player's stand-in at its position (no indicator any more, test 13).
function World:_spawn(w, pawn, x, y, z)
    local cls = self.G.StaticFindObject("/Script/Engine.StaticMeshActor")
    return self:_spawnPart(w, cls, pawn, x, y, z, 1)
end

-- Liveness (see World.MARKER_CLASS): false when the marker belongs to another (or no) world, or when a deep check does
-- not find one of its actors among the live StaticMeshActors. A deep check refreshes the handles.
function World:_alive(mk, worldAddr, deep)
    if mk.worldAddr ~= worldAddr then return false end
    for _, field in ipairs({ "actor", "indicator" }) do
        local o = mk[field]
        if o ~= nil then
            if deep then o = Liveness.Listed(self.G, o, World.MARKER_CLASS); mk[field] = o end
            if not valid(o) then return false end
        end
    end
    return true
end

-- A marker whose actors are gone (freed with their level, or in another world) is forgotten without touching them.
function World:_lose(key)
    self.markers[key] = nil
    self.stats.lost = self.stats.lost + 1
    self.spawnLog[key] = "lost"
end

function World:_destroy(actor)
    local live = Liveness.Listed(self.G, actor, World.MARKER_CLASS)
    if not valid(live) then return "lost" end
    if pcall(function() live:K2_DestroyActor() end) then return "removed" end
    if pcall(function() live:SetActorHiddenInGame(true) end) then return "hidden" end
    return "failed"
end

function World:_remove(key, worldAddr)
    local mk = self.markers[key]
    if not mk then return end
    if mk.worldAddr ~= worldAddr then return self:_lose(key) end
    self.markers[key] = nil
    local results = {}
    for _, field in ipairs({ "actor", "indicator" }) do
        if mk[field] ~= nil then results[self:_destroy(mk[field])] = true end
    end
    local s = self.stats
    if results.failed then s.remove_failed = s.remove_failed + 1
    elseif results.hidden then s.hidden_instead = s.hidden_instead + 1
    elseif results.removed then s.removed = s.removed + 1
    else s.lost = s.lost + 1 end
end

-- "PRESENCE marker spawn ok|failed player=<masked> reason=<why>", once per change of outcome for a key.
function World:_spawnOutcome(key, outcome, reason)
    local state = outcome == "ok" and "ok" or ("failed:" .. reason)
    if self.spawnLog[key] == state then return end
    self.spawnLog[key] = state
    pcall(self.log, string.format("PRESENCE marker spawn %s player=%s reason=%s", outcome, Identity.Mask(key), reason))
end

local function failure(err)
    local text = tostring(err):gsub("^.-:%d+: ", ""):gsub("[\r\n]+", " ")
    return text:sub(1, 120)
end

-- Shows exactly `list` {key,x,y,z,dead,pose}. Returns shown, wanted: the wanted markers that are live after the call
-- (a failed spawn is not a success; the caller counts it).
function World:SetMarkers(list)
    local now = self.clock()
    local want, n = {}, 0
    for _, m in ipairs(list) do
        n = n + 1
        if n > World.MAX_MARKERS then n = World.MAX_MARKERS; break end
        want[m.key] = m
    end
    local w = self:_world()
    if not w then                       -- not in the game map: the actors went with their level; forget them
        for key in pairs(self.markers) do self:_lose(key) end
        return 0, n
    end
    local worldAddr = Liveness.Address(w)
    local deep = now >= (self.liveAt or now)
    if deep then self.liveAt = now + World.LIVENESS_SECONDS end
    for key in pairs(self.markers) do
        if not want[key] then self:_remove(key, worldAddr) end
    end
    local pawn, shown = nil, 0
    for key, m in pairs(want) do
        local mk = self.markers[key]
        if mk and not self:_alive(mk, worldAddr, deep) then self:_lose(key); mk = nil end
        local try = self.tries[key]
        if not mk and (not try or now >= try.nextAt) then
            pawn = pawn or self:_pawn(w)
            if pawn then
                local ok, actor = pcall(self._spawn, self, w, pawn, m.x, m.y, m.z)
                if ok then
                    local again = self.spawnLog[key] == "lost"
                    mk = { actor = actor, worldAddr = worldAddr }
                    self.markers[key] = mk
                    self.tries[key] = nil
                    self.stats.spawned = self.stats.spawned + 1
                    self:_spawnOutcome(key, "ok", again and "respawn_after_lost" or "spawned")
                else
                    try = try or { fails = 0 }
                    try.fails = try.fails + 1
                    local extra = try.fails - World.MAX_SPAWN_TRIES
                    try.nextAt = extra < 0 and now
                        or now + math.min(World.RETRY_SECONDS * 2 ^ extra, World.RETRY_MAX_SECONDS)
                    self.tries[key] = try
                    self.stats.spawn_failed = self.stats.spawn_failed + 1
                    self:_spawnOutcome(key, "failed", failure(actor))
                end
            end
        end
        if mk then
            shown = shown + 1
            local a = mk.actor
            local model=m.pose and m.pose.model
            if model and model~=0 and model~=mk.model then
                local changed=pcall(function()
                    -- The peer sends a bounded ID, never an arbitrary asset path.
                    local path=assert(Visual.meshPath(model),'Invalid remote mesh ID')
                    local mesh=self.G.StaticFindObject(path)
                    assert(valid(mesh),'Remote character mesh is not loaded')
                    local comp=a.StaticMeshComponent
                    assert(comp:SetStaticMesh(mesh)~=false,'Remote mesh assignment rejected')
                    local material=mesh:GetMaterial(0)
                    if valid(material) then comp:SetMaterial(0,material) end
                    mk.model=model
                end)
                if changed then self.stats.avatar_updates=self.stats.avatar_updates+1
                elseif mk.failedModel~=model then self.stats.avatar_failed=self.stats.avatar_failed+1;mk.failedModel=model end
            end
            local s = m.dead and 0.3 or 1.0
            local ok = pcall(function()
                a:K2_SetActorLocation({ X = m.x, Y = m.y, Z = m.z }, false, {}, true)
                if m.pose then
                    local p=m.pose
                    a:K2_SetActorRotation({Pitch=p.pitch/100,Yaw=p.yaw/100,Roll=p.roll/100},true)
                    a.StaticMeshComponent:SetCustomPrimitiveDataFloat(1,p.motion/1000)
                end
                a:SetActorScale3D({ X = s, Y = s, Z = s })
            end)
            if ok then self.stats.moved = self.stats.moved + 1 end
        end
    end
    for key in pairs(self.tries) do if not want[key] then self.tries[key] = nil end end      -- bounded: one entry per wanted key
    return shown, n
end

-- Removes every marker (live ones are destroyed, gone ones forgotten untouched) and resets the spawn tries and the
-- spawn log, so a new island starts fresh even when nothing was ever shown.
function World:ClearMarkers()
    local w = self:_world()
    local worldAddr = w and Liveness.Address(w)
    local keys = {}
    for key in pairs(self.markers) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        if w then self:_remove(key, worldAddr) else self:_lose(key) end
    end
    self.tries, self.spawnLog, self.liveAt = {}, {}, nil
end

function World:Status()
    local n = 0
    local models={}
    for key,m in pairs(self.markers) do n=n+1;models[key]=m.model or 0 end
    return { markers = n, stats = self.stats, models=models }
end

-- Read-only diagnostic; a matching seed is insufficient if biome parameters differ.
function World:ReadGeneration()
    local list=self.G.FindAllOf('BP_IslandGenerator_C')
    if type(list)~='table' then return nil end
    for _,generator in ipairs(list) do
        if valid(generator) and generator:GetFullName():find(self.map,1,true) then
            local seed,stage=generator.Seed,generator.BiomeIncrementer
            local count=#generator.BiomeArray
            if type(seed)~='number' or seed%1~=0 or seed<0 or seed>9999999 or
                type(stage)~='number' or stage%1~=0 or stage<1 or count<1 or count>64 then return nil end
            local selected=(stage-1)%count+1
            local biome,ordinal=nil,0
            generator.BiomeArray:ForEach(function(_,element)
                ordinal=ordinal+1
                if ordinal==selected then biome=element:get():ToString();return true end
            end)
            local location=generator:K2_GetActorLocation()
            return {generator=generator:GetFullName(),seed=seed,stage=stage,biome=biome or 'unknown',
                chunks=generator.LandscapeChunks,foliage=generator.FoliageAmount,
                artifact=generator['Artifact Syrlig']==true,x=location.X,y=location.Y,z=location.Z}
        end
    end
end

-- Read-only cosmetic diagnostic. The game's movement material uses current
-- Partial handover observations, deliberately not a restorable checkpoint.
-- Inventory actors, pending reward selections, enemy lifetimes and RNG are not
-- recoverable from these scalars. Never publish them with complete coverage.
function World:ReadPauseScalar(field)
    local world=self:_world();if not world then return nil end
    local pawn=self:_pawn(world);if not pawn then return nil end
    return pawn[field]
end
function World:ReadCheckpointProbe()
    local world=self:_world();if not world then return nil end
    local pawn=self:_pawn(world);if not pawn then return nil end
    local result={pawn=pawn:GetFullName(),scalars={},unavailable={},complete=false}
    for _,name in ipairs({'HP_Current','HP_MAX','XP_Current','XP_Target','XP_Buffer','Level',
        'TotalXPPickedUp','CurrentLevelNorm','MovementSpeed','DamageMultiplier','CritChance','CritDamage','TimeDialation'}) do
        local ok,value=pcall(function() return pawn[name] end)
        if ok and type(value)=='number' and value==value and math.abs(value)<math.huge then
            result.scalars[name]=value
        else result.unavailable[#result.unavailable+1]=name end
    end
    for _,name in ipairs({'PlayerIsDead','PresentTime?','IsGamePaused?'}) do
        local ok,value=pcall(function() return pawn[name] end)
        if ok and type(value)=='boolean' then result.scalars[name]=value
        else result.unavailable[#result.unavailable+1]=name end
    end
    local ok,generation=pcall(self.ReadGeneration,self)
    result.generation=ok and generation or nil
    local library=self:_statics()
    if valid(library) then
        local success,value=pcall(library.GetGlobalTimeDilation,library,world)
        if success and type(value)=='number' and value==value and math.abs(value)<math.huge then result.dilation=value end
    end
    return result
end
-- The game's movement material uses current
-- velocity / current MaxSpeed, so upgrades must not be replaced by a constant.
function World:ReadPresentation()
    local w=self:_world();if not w then return nil end
    local pawn=self:_pawn(w);if not pawn then return nil end
    local mesh=pawn.PlayerMesh
    if not valid(mesh) then return nil end
    local rotation=mesh:K2_GetComponentRotation()
    local scale=mesh:K2_GetComponentScale()
    local velocity=pawn.FloatingPawnMovement.Velocity
    local maxSpeed=pawn.FloatingPawnMovement.MaxSpeed
    local speed=math.sqrt(velocity.X^2+velocity.Y^2+velocity.Z^2)
    if type(maxSpeed)~='number' or maxSpeed<=0 or speed~=speed or speed==math.huge then return nil end
    return {mesh=mesh.StaticMesh:GetFullName(),pitch=rotation.Pitch,yaw=rotation.Yaw,roll=rotation.Roll,
        sx=scale.X,sy=scale.Y,sz=scale.Z,speed=speed,maxSpeed=maxSpeed,motion=speed/maxSpeed}
end

-- Bounded, read-only horde diagnostic. Instance indices are observations, not
-- network entity IDs: removal may compact the game's instance arrays.
function World:ReadEnemySchema()
    local result,queue,seen,queued={},{},{},{}
    for _,name in ipairs({'EnemyController','EnemyClassType','InstanceStructInsideArray'}) do
        local object=self.G.StaticFindObject('/Script/Shooter.'..name)
        if valid(object) then queue[#queue+1]={name=name,object=object};queued[name]=true end
    end
    local cursor=1
    while cursor<=#queue do
        assert(#queue<=16,'Enemy reflection type limit exceeded')
        local entry=queue[cursor];cursor=cursor+1
        if not seen[entry.name] then
            seen[entry.name]=true
            local row={name=entry.name,fields={}}
            local function describe(property,depth)
                assert(depth<=4,'Enemy reflection nesting limit exceeded')
                local kind=property:GetClass():GetFName():ToString()
                if kind=='ArrayProperty' then return kind..'<'..describe(property:GetInner(),depth+1)..'>' end
                if kind=='StructProperty' then
                    local structure=property:GetStruct()
                    local full=structure:GetFullName()
                    if full:find('/Script/Shooter.',1,true) then
                        local name=structure:GetFName():ToString()
                        if not queued[name] then queue[#queue+1]={name=name,object=structure};queued[name]=true end
                    end
                    return kind..'<'..full..'>'
                end
                return kind
            end
            entry.object:ForEachProperty(function(property)
                assert(#row.fields<256,'Enemy reflection field limit exceeded')
                row.fields[#row.fields+1]={name=property:GetFName():ToString(),type=describe(property,0)}
            end)
            result[#result+1]=row
        end
    end
    return result
end

function World:_enemyController()
    if not self:_world() then return nil end
    local managers=self.G.FindAllOf('BP_EnemyController_C')
    if type(managers)~='table' then return nil end
    local manager
    for _,candidate in ipairs(managers) do
        if valid(candidate) and candidate:GetFullName():find(self.map,1,true) then
            assert(not manager,'Multiple active enemy controllers');manager=candidate
        end
    end
    return manager
end

-- Diagnostic records only. Membership/HP and slot reuse semantics must be
-- verified before these indices can identify network entities.
function World:ReadEnemyRecords()
    local manager=self:_enemyController();if not manager then return nil end
    local result={controller=manager:GetFullName(),records={},dead={},classes={},wave={},actors={},count=0,deadCount=0}
    for _,field in ipairs({'EnemiesAlive','AliveBudget','SpawnBudget','MaxSpawnBudget','StageCounter','BossTime?','TimeUntilBoss'}) do
        local ok,value=pcall(function() return manager[field] end)
        if ok and (type(value)=='boolean' or (type(value)=='number' and value==value and math.abs(value)<math.huge)) then result.wave[field]=value end
    end
    local function read(array,output,limit)
        local count=#array
        assert(count>=0 and count<=100000,'Enemy record limit exceeded')
        local sampled=0
        array:ForEach(function(_,element)
            if sampled>=limit then return true end
            local record=element:get()
            local row={enemyType=record.enemyType,index=record.Index,instanceIndex=record.instanceIndex,
                hp=record.HP,canMove=record.canMove,x=record.Location.X,y=record.Location.Y}
            for _,field in ipairs({'enemyType','index','instanceIndex','hp','x','y'}) do
                local n=row[field]
                assert(type(n)=='number' and n==n and math.abs(n)<math.huge,'Invalid native enemy field: '..field)
            end
            assert(type(row.canMove)=='boolean','Invalid native enemy movement flag')
            output[#output+1]=row;sampled=sampled+1
        end)
        return count
    end
    result.count=read(manager.InstanceStruct,result.records,4096)
    local groups=manager.AllDeadEnemies
    assert(#groups<=64,'Dead enemy group limit exceeded')
    groups:ForEach(function(_,element)
        result.deadCount=result.deadCount+read(element:get().enemies,result.dead,math.max(0,4096-#result.dead))
    end)
    local classes=manager.enemyClasses
    assert(#classes<=64,'Enemy class limit exceeded')
    classes:ForEach(function(_,element)
        local class=element:get()
        local row={}
        for _,field in ipairs({'Radius','Scale','Speed','Damage','Mass','StartHP','meshIndex','XP','spawnCost','spawnChance','obtstacle'}) do
            local value=class[field]
            assert(type(value)=='boolean' or (type(value)=='number' and value==value and math.abs(value)<math.huge),'Invalid enemy class field: '..field)
            row[field]=value
        end
        result.classes[#result.classes+1]=row
    end)
    -- Actor enemies also reference the native records. Static BP_MiniBoss
    -- UpdateHP reads InstanceStruct[MyIndex].HP; do not assume an actor's
    -- cached display HP is the authoritative value.
    local seenActors={}
    local function actorRow(actor)
            if valid(actor) then
                local name=actor:GetFullName()
                if seenActors[name] or not name:find(self.map,1,true) then return end
                assert(#result.actors<256,'Enemy actor limit exceeded')
                seenActors[name]=true
                local location=actor:K2_GetActorLocation()
                local row={name=name,x=location.X,y=location.Y,z=location.Z}
                for _,field in ipairs({'MyIndex','MaxHP','Current HP','Start HP','IsMiniBoss?'}) do
                    local ok,value=pcall(function() return actor[field] end)
                    if ok and (type(value)=='boolean' or (type(value)=='number' and value==value and math.abs(value)<math.huge)) then row[field]=value end
                end
                -- Static miniboss UI reads DA_MiniBoss.Name; keep this optional
                -- so unavailable display metadata cannot interrupt native records.
                if name:find('BP_MiniBoss_C ',1,true) then
                    local ok,display=pcall(function()
                        local data=actor.DA_MiniBoss
                        if valid(data) then return data.Name:ToString() end
                    end)
                    if ok and type(display)=='string' and #display<=256 then row.displayName=display end
                end
                result.actors[#result.actors+1]=row
            end
    end
    for _,field in ipairs({'AllEnemyActors','AllMiniBosses'}) do
        local actors=manager[field]
        if actors then
            assert(#actors<=256,'Enemy actor limit exceeded')
            actors:ForEach(function(_,element) actorRow(element:get()) end)
        end
    end
    local bosses=self.G.FindAllOf and self.G.FindAllOf('BP_Boss_C')
    if type(bosses)=='table' then for _,actor in ipairs(bosses) do actorRow(actor) end end
    return result
end

function World:ReadEnemies()
    local manager=self:_enemyController()
    if not manager then return nil end
    local name=manager:GetFullName()
    local ownerPath=name:match('%S+$')
    local result={controller=name,alive=manager.EnemiesAlive,components={},samples=0,total=0}
    local seen={}
    for _,class in ipairs({'InstancedStaticMeshComponent','HierarchicalInstancedStaticMeshComponent'}) do
        local components=self.G.FindAllOf(class)
        if type(components)=='table' then
            for _,component in ipairs(components) do
                if valid(component) then
                    local full=component:GetFullName()
                    local path=full:match('%S+$')
                    if ownerPath and path and path:sub(1,#ownerPath+1)==ownerPath..'.' and not seen[path] then
                        seen[path]=true
                        assert(#result.components<64,'Enemy component limit exceeded')
                        local count=component:GetInstanceCount()
                        assert(type(count)=='number' and count%1==0 and count>=0 and count<=1000000,'Invalid enemy instance count')
                        local mesh=component.StaticMesh
                        local row={component=full,count=count,mesh=valid(mesh) and mesh:GetFullName() or 'unassigned',transforms={}}
                        result.total=result.total+count
                        for index=0,math.min(count,8,64-result.samples)-1 do
                            local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
                            assert(component:GetInstanceTransform(index,transform,true)==true,'Enemy transform read rejected')
                            local position=transform.Translation
                            for _,axis in ipairs({'X','Y','Z'}) do
                                local n=position[axis]
                                assert(type(n)=='number' and n==n and math.abs(n)<math.huge,'Invalid enemy transform')
                            end
                            row.transforms[#row.transforms+1]={index=index,x=position.X,y=position.Y,z=position.Z}
                            result.samples=result.samples+1
                        end
                        result.components[#result.components+1]=row
                    end
                end
            end
        end
    end
    table.sort(result.components,function(a,b) return a.component<b.component end)
    return result
end

return World
