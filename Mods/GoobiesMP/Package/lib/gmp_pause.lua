-- Shared gameplay pause barrier. Networking/menu ticks run outside this state.
local P={};P.Host={};P.Host.__index=P.Host;P.Client={};P.Client.__index=P.Client
function P.Host.new(participants)
    return setmetatable({participants=participants,revision=0,paused=false,locked=false,hostOnly=false,acks={},required={}},P.Host)
end
function P.Host:Set(key,paused,locked,reason)
    local participants=self.participants()
    if not participants[key] or type(paused)~='boolean' then return false,'not_participant' end
    if self.locked then return false,'handover_locked' end
    if locked and not paused then return false,'invalid_lock' end
    if self.revision>=2147483647 then return false,'revision_exhausted' end
    self.revision=self.revision+1;self.paused=paused;self.locked=locked==true
    self.owner=key;self.reason=reason or 'manual';self.required=participants;self.acks={}
    return true
end
function P.Host:Snapshot()
    return {revision=self.revision,paused=self.paused,locked=self.locked,hostOnly=self.hostOnly,owner=self.owner or '',reason=self.reason or 'manual'}
end
function P.Host:Acknowledge(key,revision,paused)
    if not self.participants()[key] or revision~=self.revision or paused~=self.paused then return false end
    self.acks[key]=revision;return true
end
function P.Host:Ready()
    if not self.paused then return false end
    for key in pairs(self.required) do if self.acks[key]~=self.revision then return false end end
    for key in pairs(self.participants()) do if self.acks[key]~=self.revision then return false end end
    return true
end
function P.Host:ReleaseHandover(key)
    if not self.locked or not self.participants()[key] then return false end
    if self.revision>=2147483647 then return false,'revision_exhausted' end
    self.locked=false;return self:Set(key,false,false,'handover_complete')
end
function P.Client.new() return setmetatable({revision=0,paused=false,locked=false},P.Client) end
function P.Client:Apply(state)
    if type(state)~='table' or type(state.revision)~='number' or state.revision%1~=0 or state.revision<1
        or state.revision>2147483647 or type(state.paused)~='boolean' or type(state.locked)~='boolean' or type(state.hostOnly)~='boolean'
        or type(state.owner)~='string' or #state.owner>128 or type(state.reason)~='string' or #state.reason>64
        or state.revision<self.revision then return false end
    if state.revision==self.revision then
        return state.paused==self.paused and state.locked==self.locked and state.hostOnly==self.hostOnly and state.owner==self.owner and state.reason==self.reason
    end
    self.revision,self.paused,self.locked,self.owner,self.reason=state.revision,state.paused,state.locked,state.owner,state.reason
    self.hostOnly=state.hostOnly
    self.applied=nil;return true
end
return P
