-- Native scalar slice for retaining the local pawn during authority migration.
-- Class, artifacts, item actors, death/revival and timers remain unsupported.
local P={};P.__index=P
P.CompleteCapture=false;P.CompleteRestore=false
local fields={'HP_Current','HP_MAX','MovementSpeed','DamageMultiplier','CritChance','CritDamage',
    'AttackSpeedMultiplier','NumProjectiles','AOE DamageMultiplier'}
P.Fields=fields
P.REFRESH='/Game/Blueprints/BP_Player.BP_Player_C:UpdatePlayerStats'
-- Exact Blueprint locals from the inspected UpdatePlayerStats bytecode.
-- UE4SS exposes locals in ForEachProperty alongside function parameters.
local refreshLocals={
    -- Blueprint callers supply this output parameter; UE4SS needs a Lua table.
    ['DamageFromItems']=true,
    ['CallFunc_Add_IntInt_ReturnValue']=true,
    ['CallFunc_Add_IntInt_ReturnValue_1']=true,
    ['CallFunc_Array_Get_Item']=true,
    ['CallFunc_Array_Get_Item_1']=true,
    ['CallFunc_Array_Length_ReturnValue']=true,
    ['CallFunc_Array_Length_ReturnValue_1']=true,
    ['CallFunc_IsValid_ReturnValue']=true,
    ['CallFunc_K2_GetComponentsByClass_ReturnValue']=true,
    ['CallFunc_Less_IntInt_ReturnValue']=true,
    ['CallFunc_Less_IntInt_ReturnValue_1']=true,
    ['CallFunc_Multiply_DoubleDouble_A_ImplicitCast']=true,
    ['CallFunc_Multiply_DoubleDouble_ReturnValue']=true,
    ['CallFunc_PlayerStatsUpdated_PlayerMS_ImplicitCast']=true,
    ['CallFunc_PlayerStatsUpdated_PlayerMS_ImplicitCast_1']=true,
    ['CallFunc_UpdatePlayerCrit_newCritChance_ImplicitCast']=true,
    ['CallFunc_UpdatePlayerCrit_newCritDamage_ImplicitCast']=true,
    ['K2Node_DynamicCast_AsBPI_Player_Abilities']=true,
    ['K2Node_DynamicCast_AsBPI_Player_Abilities_1']=true,
    ['K2Node_DynamicCast_bSuccess']=true,
    ['K2Node_DynamicCast_bSuccess_1']=true,
    ['K2Node_VariableSet_MaxSpeed_ImplicitCast']=true,
    ['Temp_int_Array_Index_Variable']=true,
    ['Temp_int_Array_Index_Variable_1']=true,
    ['Temp_int_Loop_Counter_Variable']=true,
    ['Temp_int_Loop_Counter_Variable_1']=true,
}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=1e12 end
local function valid(state)
    if type(state)~='table' or state.version~=1 or type(state.values)~='table'
        or type(state.pawn)~='string' or #state.pawn==0 or #state.pawn>4096 then return false end
    for _,field in ipairs(fields) do if not finite(state.values[field]) then return false end end
    local v=state.values
    return v.HP_Current>0 and v.HP_MAX>=v.HP_Current and v.MovementSpeed>=0
        and v.DamageMultiplier>=0 and v.CritChance>=0 and v.CritDamage>=0
        and v.AttackSpeedMultiplier>=0 and v['AOE DamageMultiplier']>=0
        and v.NumProjectiles>=0 and v.NumProjectiles%1==0 and v.NumProjectiles<=2147483647
        and finite(state.maxSpeed) and state.maxSpeed>=0
end
function P.new(world) return setmetatable({world=world},P) end
function P:_pawn()
    local world=self.world:_world();if not world then return nil end
    return self.world:_pawn(world),world
end
function P:Capture()
    local pawn=self:_pawn();if not pawn then return nil,'missing_pawn' end
    local ok,state=pcall(function()
        if pawn.PlayerIsDead~=false then return nil end
        local out={version=1,pawn=pawn:GetFullName(),values={},maxSpeed=pawn.FloatingPawnMovement.MaxSpeed}
        for _,field in ipairs(fields) do out.values[field]=pawn[field] end
        local current=self:_pawn()
        assert(current and current:GetFullName()==out.pawn,'player_capture_context_changed')
        return out
    end)
    if not ok or not valid(state) then return nil,'unsupported_player_state' end
    return state
end
function P:ValidateRestore(state)
    if not valid(state) then return false,'invalid_player_state' end
    local pawn=self:_pawn();if not pawn then return false,'missing_pawn' end
    if pawn:GetFullName()~=state.pawn then return false,'retained_player_changed' end
    if pawn['PresentTime?']==true then return false,'reward_pending' end
    local ok,why=pcall(function()
        local fn=self.world.G.StaticFindObject(P.REFRESH)
        assert(fn and fn:IsValid(),'missing_stat_refresh')
        assert(fn:GetFullName()=='Function '..P.REFRESH,'wrong_stat_refresh_function')
        local count=0;fn:ForEachProperty(function(property)
            count=count+1;assert(count<=64,'stat_refresh_property_limit')
            local name=property:GetFName():ToString()
            assert(refreshLocals[name],'unexpected_stat_refresh_property:'..name)
        end)
    end)
    if not ok then return false,'unsupported_stat_refresh:'..tostring(why):sub(1,700) end
    return self:Capture()~=nil
end
function P:Restore(state)
    if not self:ValidateRestore(state) then return false,'player_not_ready' end
    local pawn,world=self:_pawn();local name=pawn:GetFullName();local library=self.world:_statics()
    if not library then return false,'missing_statics' end
    local ok,dilation=pcall(library.GetGlobalTimeDilation,library,world)
    if not ok or not finite(dilation) or dilation<=0 or dilation>.001 then return false,'not_paused' end
    local before=self:Capture()
    if not before then return false,'player_capture_failed' end
    local function write(value)
        local current=self:_pawn();assert(current and current:GetFullName()==name,'pawn_changed')
        for _,field in ipairs(fields) do pawn[field]=value.values[field] end
        -- Refresh native crit state, item/component caches and HUD through the
        -- game's callback with its DamageFromItems output table. Restore the captured movement cap after
        -- it recalculates MaxSpeed, preserving a local testing override.
        local damageFromItems={}
        pawn:UpdatePlayerStats(damageFromItems)
        current=self:_pawn();assert(current and current:GetFullName()==name,'pawn_changed_during_refresh')
        pawn.FloatingPawnMovement.MaxSpeed=value.maxSpeed
        for _,field in ipairs(fields) do assert(pawn[field]==value.values[field],'readback:'..field) end
        assert(pawn.FloatingPawnMovement.MaxSpeed==value.maxSpeed,'readback:MaxSpeed')
    end
    local applied,why=pcall(write,state)
    if applied then self.failure=nil;self.rollbackSucceeded=nil;return true end
    self.failure=tostring(why);self.rollbackSucceeded=pcall(write,before)
    return false,'native_player_write_failed'
end
return P
