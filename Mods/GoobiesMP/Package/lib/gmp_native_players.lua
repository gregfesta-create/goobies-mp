-- Player-keyed retained native state. Remote records are supplied by the
-- session's acknowledged peer-state cache, never inferred from host stats.
local Group=require('gmp_native_slice_group')
local Identity=require('gmp_identity')
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
local P={};P.__index=P
P.CompleteCapture=false;P.CompleteRestore=false
function P.new(localSlices,options)
    assert(localSlices and type(options)=='table' and Identity.Parse(options.key),'invalid_player_domain')
    return setmetatable({localSlices=localSlices,options=options},P)
end
function P:Capture()
    local localState,why=self.localSlices:Capture()
    if not localState then return nil,why end
    return self:CaptureCached(localState)
end
function P:CaptureCached(localState)
    local roster=self.options.roster();localState=Group.Detach(localState)
    if type(localState)~='table' or localState.version~=1 or type(localState.slices)~='table' then
        return nil,'invalid_local_native_state'
    end
    if type(roster)~='table' or #roster<1 or #roster>Capacity then return nil,'invalid_player_roster' end
    local out,seen={},{};local found=false
    for _,player in ipairs(roster) do
        if not Identity.Parse(player.key) or seen[player.key] then return nil,'invalid_player_identity' end
        seen[player.key]=true
        local row=Group.Detach(player);if not row then return nil,'invalid_player_record' end
        if row.key==self.options.key then
            if row.conn~='connected' then return nil,'local_player_disconnected' end
            row.native=localState;found=true
        elseif row.conn=='connected' then
            local state=self.options.peerState and self.options.peerState(row.key)
            row.native=state and Group.Detach(state)
            if not row.native then return nil,'missing_peer_state:'..row.key end
        end
        out[#out+1]=row
    end
    if not found then return nil,'local_player_missing' end
    return out
end
function P:_local(state)
    if type(state)~='table' or #state<1 or #state>Capacity then return nil,'invalid_players' end
    local target,seen=nil,{}
    for _,row in ipairs(state) do
        if type(row)~='table' or not Identity.Parse(row.key) or seen[row.key] then return nil,'invalid_player_identity' end
        seen[row.key]=true
        if row.key==self.options.key then
            if row.conn~='connected' then return nil,'local_player_disconnected' end
            target=row.native
        end
    end
    if type(target)~='table' then return nil,'missing_local_native_state' end
    return target
end
function P:ValidateRestore(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    return self.localSlices:ValidateRestore(target,manifest)
end
function P:RestoreStep(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    local accepted,reason=self.localSlices:RestoreStep(target,manifest)
    if accepted==false then self.failureDetail=self.localSlices.failureDetail end
    return accepted,reason
end
function P:Restore(state,manifest) return self:RestoreStep(state,manifest) end
function P:VerifyRestore(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    if self.localSlices.VerifyRestore then return self.localSlices:VerifyRestore(target,manifest) end
    return false,'missing_player_readback'
end
return P
