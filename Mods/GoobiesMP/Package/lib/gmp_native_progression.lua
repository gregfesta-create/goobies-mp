-- Native progression counters on the retained pawn. Never invokes reward,
-- upgrade or save callbacks; item state and active choices remain separate.
local P={};P.__index=P
P.CompleteCapture=false;P.CompleteRestore=false
local fields={'XP_Current','XP_Target','XP_Buffer','Level','TotalXPPickedUp','CurrentLevelNorm',
    'XP_Buffer_Temp','Rerolls','Artifact RouletteCounter'}
P.Fields=fields
local function finite(v,lo,hi) return type(v)=='number' and v==v and v>=lo and v<=hi end
local function validState(state)
    if type(state)~='table' or state.version~=2 or type(state.values)~='table'
        or type(state.pawn)~='string' or #state.pawn==0 or #state.pawn>4096 then return false end
    local v=state.values
    return finite(v.XP_Current,0,1e12) and finite(v.XP_Target,.000001,1e12)
        and finite(v.XP_Buffer,0,1e12) and finite(v.Level,0,2147483647) and v.Level%1==0
        and finite(v.TotalXPPickedUp,0,2147483647) and v.TotalXPPickedUp%1==0
        and finite(v.CurrentLevelNorm,0,1) and finite(v.XP_Buffer_Temp,0,1e12)
        and finite(v.Rerolls,0,2147483647) and v.Rerolls%1==0
        and finite(v['Artifact RouletteCounter'],0,2147483647) and v['Artifact RouletteCounter']%1==0
end
function P.new(world) return setmetatable({world=world},P) end
function P:_pawn()
    local world=self.world:_world();if not world then return nil end
    local pawn=self.world:_pawn(world);if not pawn then return nil end
    return pawn,world
end
function P:Capture()
    local pawn=self:_pawn();if not pawn then return nil,'missing_pawn' end
    local name=pawn:GetFullName();local values={}
    for _,name in ipairs(fields) do
        local ok,value=pcall(function() return pawn[name] end)
        if not ok then return nil,'read_failed:'..name end
        values[name]=value
    end
    local current=self:_pawn()
    if not current or current:GetFullName()~=name then return nil,'progression_context_changed' end
    local state={version=2,pawn=name,values=values}
    if not validState(state) then return nil,'invalid_native_progression' end
    return state
end
function P:ValidateRestore(state)
    if not validState(state) then return false,'invalid_progression' end
    local pawn=self:_pawn();if not pawn then return false,'missing_pawn' end
    if pawn:GetFullName()~=state.pawn then return false,'retained_player_changed' end
    if pawn['PresentTime?']==true then return false,'reward_pending' end
    -- Availability preflight before the first native write.
    local current=self:Capture();if not current then return false,'native_fields_unavailable' end
    return true
end
-- A diagnostic must never take ownership of an existing menu/reward pause.
function P:ValidateProbe()
    local state,why=self:Capture();if not state then return false,why end
    local accepted,reason=self:ValidateRestore(state);if not accepted then return false,reason end
    local _,world=self:_pawn();local library=self.world:_statics()
    if not library then return false,'missing_statics' end
    local ok,dilation=pcall(library.GetGlobalTimeDilation,library,world)
    if not ok or not finite(dilation,.001001,100) then return false,'existing_time_pause' end
    local success,paused=pcall(library.IsGamePaused,library,world)
    if not success or paused~=false then return false,'existing_game_pause' end
    return true
end
function P:Restore(state)
    local accepted,why=self:ValidateRestore(state);if not accepted then return false,why end
    local pawn,world=self:_pawn();local name=pawn:GetFullName()
    local library=self.world:_statics()
    if not library then return false,'missing_statics' end
    local ok,dilation=pcall(library.GetGlobalTimeDilation,library,world)
    if not ok or not finite(dilation,.000000001,.001) then return false,'not_paused' end
    local before=self:Capture();if not before then return false,'capture_failed' end
    local applied,problem=pcall(function()
        local current=self:_pawn();assert(current and current:GetFullName()==name,'pawn_changed')
        for _,field in ipairs(fields) do pawn[field]=state.values[field] end
        for _,field in ipairs(fields) do assert(pawn[field]==state.values[field],'write_not_applied:'..field) end
        current=self:_pawn();assert(current and current:GetFullName()==name,'pawn_changed_during_write')
    end)
    if applied then self.failed=nil;self.rollbackSucceeded=nil;return true end
    -- Best-effort rollback is never reported as a successful restoration.
    self.failed=tostring(problem);self.rollbackSucceeded=true
    local current=self:_pawn()
    if not current or current:GetFullName()~=name then
        self.rollbackSucceeded=false;return false,'native_write_failed'
    end
    for _,field in ipairs(fields) do
        local restored=pcall(function() pawn[field]=before.values[field];assert(pawn[field]==before.values[field]) end)
        self.rollbackSucceeded=self.rollbackSucceeded and restored
    end
    return false,'native_write_failed'
end
return P
