-- A native per-player slice inside a shared checkpoint domain. Every peer
-- restores its own retained state; the host's native object names are not local.
local Group=require('gmp_native_slice_group');local Identity=require('gmp_identity')
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
local S={};S.__index=S;S.CompleteCapture=false;S.CompleteRestore=false
function S.new(adapter,key,name,players)
    assert(adapter and Identity.Parse(key) and type(name)=='string' and type(players)=='function','invalid_peer_slice')
    return setmetatable({adapter=adapter,key=key,name=name,players=players},S)
end
function S:Capture()
    local players,why=self.players();if not players then return nil,why end
    if type(players)~='table' or #players<1 or #players>Capacity then return nil,'invalid_peer_roster' end
    local out={version=1,players={}};local seen={}
    for _,row in ipairs(players) do
        if not Identity.Parse(row.key) or seen[row.key] then return nil,'invalid_peer_identity' end
        seen[row.key]=true
        if row.conn=='connected' then
            local state=row.native and row.native.slices and row.native.slices[self.name]
            local detached=state and Group.Detach(state)
            if type(detached)~='table' then return nil,'missing_peer_slice:'..row.key end
            out.players[#out.players+1]={key=row.key,state=detached}
        end
    end
    local localPresent=false
    for _,row in ipairs(out.players) do if row.key==self.key then localPresent=true end end
    if not localPresent then return nil,'local_player_missing' end
    return out
end
function S:_local(state)
    if type(state)~='table' or state.version~=1 or type(state.players)~='table'
        or #state.players<1 or #state.players>Capacity then return nil,'invalid_peer_slice' end
    local found,seen=nil,{}
    for _,row in ipairs(state.players) do
        if type(row)~='table' or not Identity.Parse(row.key) or seen[row.key]
            or type(row.state)~='table' then return nil,'invalid_peer_identity' end
        seen[row.key]=true;if row.key==self.key then found=row.state end
    end
    return found,found and nil or 'missing_local_slice'
end
function S:ValidateRestore(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    return self.adapter:ValidateRestore(target,manifest)
end
function S:RestoreStep(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    return (self.adapter.RestoreStep or self.adapter.Restore)(self.adapter,target,manifest)
end
function S:Restore(state,manifest) return self:RestoreStep(state,manifest) end
function S:VerifyRestore(state,manifest)
    local target,why=self:_local(state);if not target then return false,why end
    local group=Group.new({{name=self.name,adapter=self.adapter}})
    return group:VerifyRestore({version=1,slices={[self.name]=target}},manifest)
end
return S
