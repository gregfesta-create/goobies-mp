-- Confirmed controller scalar slice. Spawn timers and latent boss Delay are
-- captured separately but not reconstructed, so this is incomplete migration.
local W={};W.__index=W
W.CompleteCapture=false;W.CompleteRestore=false
local numbers={'EnemiesAlive','AliveBudget','MaxSpawnBudget','TimeUntilBoss','WavesPerIslandCount'}
-- Confirmed Blueprint spawn inputs; these keep future spawns at the host's
-- progression scale after takeover rather than the client's local wave scale.
local scaling={'EnemyDamageScale','EnemyHP Scale','EnemyHP ScaleBoss','SpawnBudgetMulti'}
W.ScalingFields=scaling
local derived={EnemiesAlive=true,AliveBudget=true}
-- BP tick assigns these from native UpdateInstances outputs each frame.
-- Capture for inspection, but restore the enemy records that produce them.
function W.IsDerivedField(field) return derived[field]==true end
local bools={'BossTime?','PauseSpawner?'}
local function finite(v) return type(v)=='number' and v==v and v>=0 and v<=1e12 end
local function valid(s)
    if type(s)~='table' or s.version~=1 or type(s.values)~='table' then return false end
    for _,f in ipairs(numbers) do if not finite(s.values[f]) then return false end end
    for _,f in ipairs(scaling) do if s.values[f]~=nil and not finite(s.values[f]) then return false end end
    for _,f in ipairs(bools) do if type(s.values[f])~='boolean' then return false end end
    return true
end
function W.new(world) return setmetatable({world=world},W) end
function W:CaptureTimers()
    local ok,state=pcall(function()
        local m=self.world:_enemyController();assert(m,'missing_controller')
        local name=m:GetFullName()
        local lib=self.world.G.StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
        assert(lib and lib:IsValid(),'missing_timer_library')
        local out={version=1,controller=name,remaining={}}
        for _,field in ipairs({'SpawnTimer','SeperateWaveTimer'}) do
            local value=lib:K2_GetTimerRemainingTimeHandle(m,m[field])
            -- UE returns -1 for an inactive/invalid timer. Preserve the sentinel
            -- rather than scheduling a new timer from unavailable state.
            assert(type(value)=='number' and value==value and value>=-1 and value<=1e12,'invalid_timer_remaining:'..field)
            out.remaining[field]=value
        end
        local current=self.world:_enemyController()
        assert(current and current:GetFullName()==name,'controller_changed')
        return out
    end)
    if not ok then return nil,'wave_timers_unavailable:'..tostring(state):sub(1,500) end
    return state
end
function W:Capture()
    local ok,s=pcall(function()
        local m=self.world:_enemyController();if not m then return nil end
        local s={version=1,values={}}
        for _,f in ipairs(numbers) do s.values[f]=m[f] end
        for _,f in ipairs(scaling) do
            local value=m[f]
            if type(value)=='number' then s.values[f]=value end
        end
        for _,f in ipairs(bools) do s.values[f]=m[f] end
        return s
    end)
    if not ok or not valid(s) then return nil,'wave_fields_unavailable' end
    return s
end
function W:ValidateRestore(s)
    if not valid(s) then return false end
    local current=self:Capture();if not current then return false end
    for _,f in ipairs(scaling) do
        if s.values[f]~=nil and current.values[f]==nil then return false,'missing_spawn_scaling:'..f end
    end
    return true
end
function W:MatchesCapture(expected,actual)
    if not valid(expected) or not valid(actual) then return false end
    for field,value in pairs(expected.values) do
        if not derived[field] and actual.values[field]~=value then return false end
    end
    return true
end
function W:Restore(s)
    if not self:ValidateRestore(s) then return false,'invalid_wave_state' end
    local world=self.world:_world();local lib=self.world:_statics()
    if not world or not lib then return false,'missing_world' end
    local ok,d=pcall(lib.GetGlobalTimeDilation,lib,world)
    if not ok or not finite(d) or d<=0 or d>.001 then return false,'not_paused' end
    local m=self.world:_enemyController();local name=m:GetFullName();local before=self:Capture()
    local function write(v)
        local current=self.world:_enemyController();assert(current and current:GetFullName()==name,'controller_changed')
        for _,f in ipairs(numbers) do if not derived[f] then current[f]=v.values[f] end end
        for _,f in ipairs(scaling) do if v.values[f]~=nil then current[f]=v.values[f] end end
        for _,f in ipairs(bools) do current[f]=v.values[f] end
        local read=self:Capture();assert(read,'wave_readback_unavailable')
        for f,value in pairs(v.values) do
            -- Only compare whitelisted fields; callers cannot request arbitrary native writes.
            if before.values[f]~=nil and not derived[f] then assert(read.values[f]==value,'wave_readback:'..f) end
        end
    end
    local restored,why=pcall(write,s)
    if not restored then self.rollbackSucceeded=pcall(write,before);return false,tostring(why) end
    return true
end
return W
