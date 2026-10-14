-- Known island FRandomStream slice only. Global/native RNG and enemy timers
-- are not covered. Inaccessible struct fields fail closed before any write.
local P={};P.__index=P;P.CompleteCapture=false;P.CompleteRestore=false
local function int(v) return type(v)=='number' and v%1==0 and v>=-2147483648 and v<=2147483647 end
function P.new(world) return setmetatable({world=world},P) end
function P:_generator()
    local list=self.world.G.FindAllOf('BP_IslandGenerator_C')
    for _,g in ipairs(type(list)=='table' and list or {}) do
        if g:IsValid() and g:GetFullName():find(self.world.map,1,true) then return g end
    end
end
function P:Capture()
    local ok,state=pcall(function()
        local g=self:_generator();if not g then return nil end
        local stream=g.Stream
        if not int(stream.InitialSeed) or not int(stream.Seed) then return nil end
        return {version=1,initial=stream.InitialSeed,current=stream.Seed,islandSeed=g.Seed,stage=g.BiomeIncrementer}
    end)
    if not ok or not state then return nil,'native_stream_unavailable' end
    return state
end
function P:ValidateRestore(state)
    if type(state)~='table' or state.version~=1 or not int(state.initial) or not int(state.current)
        or not int(state.islandSeed) or not int(state.stage) then return false,'invalid_stream' end
    local current=self:Capture()
    if not current or current.islandSeed~=state.islandSeed or current.stage~=state.stage then return false,'island_mismatch' end
    return true
end
function P:Restore(state)
    local accepted,why=self:ValidateRestore(state);if not accepted then return false,why end
    local library=self.world:_statics();local world=self.world:_world()
    if not library or not world then return false,'missing_world' end
    local ok,dilation=pcall(library.GetGlobalTimeDilation,library,world)
    if not ok or type(dilation)~='number' or dilation~=dilation or dilation<=0 or dilation>.001 then return false,'not_paused' end
    local before=self:Capture();local g=self:_generator();local name=g:GetFullName()
    local function write(value)
        local current=self:_generator();assert(current and current:GetFullName()==name,'generator_changed')
        current.Stream.InitialSeed=value.initial;current.Stream.Seed=value.current
        local read=self:Capture();assert(read and read.initial==value.initial and read.current==value.current,'stream_readback_failed')
    end
    local applied,problem=pcall(write,state)
    if applied then self.failure=nil;return true end
    self.failure=tostring(problem);self.rollbackSucceeded=pcall(write,before)
    return false,'native_stream_write_failed'
end
return P
