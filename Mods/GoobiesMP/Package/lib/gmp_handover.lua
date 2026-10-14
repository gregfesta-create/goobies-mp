-- Pure checkpoint/claim coordinator. All peers mirror ordered authoritative data.
-- One shared arbiter must own Claim; running one independent arbiter per client
-- would create split authority. No transport roles or Unreal objects change here.
local Identity=require('gmp_identity')
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
local Islands=require('gmp_islands')
local Replica=require('gmp_enemy_replica')
local H={};H.__index=H
local required={'players','enemies','progression','rewards','world','random'}
local function integer(n,lo,hi) return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi end
local function detached(value,depth,budget,seen)
    depth=depth or 0;budget=budget or {count=0};seen=seen or {}
    budget.count=budget.count+1;assert(depth<=20 and budget.count<=100000,'Checkpoint limit exceeded')
    local kind=type(value)
    if kind=='number' then assert(value==value and math.abs(value)<math.huge,'Nonfinite checkpoint');return value end
    if kind=='string' then assert(#value<=4096,'Checkpoint string too large');return value end
    if kind=='boolean' or kind=='nil' then return value end
    assert(kind=='table' and not seen[value] and not getmetatable(value),'Checkpoint must contain plain detached data')
    seen[value]=true;local result={}
    for k,v in pairs(value) do
        assert(type(k)=='string' or (type(k)=='number' and integer(k,1,100000)),'Invalid checkpoint key')
        result[k]=detached(v,depth+1,budget,seen)
    end
    seen[value]=nil;return result
end
local function validate(checkpoint)
    assert(type(checkpoint)=='table' and Islands.Valid(checkpoint.manifest),'Invalid island checkpoint')
    assert(type(checkpoint.coverage)=='table','Missing checkpoint coverage')
    for _,name in ipairs(required) do
        assert(checkpoint.coverage[name]==true and type(checkpoint[name])=='table','Incomplete checkpoint: '..name)
    end
    assert(Replica.new():Apply(checkpoint.enemies),'Invalid enemy checkpoint')
    assert(type(checkpoint.players)=='table' and #checkpoint.players>=1 and #checkpoint.players<=Capacity,'Invalid players')
    local keys,slots,hosts={},{},0
    for _,player in ipairs(checkpoint.players) do
        assert(Identity.Parse(player.key) and not keys[player.key],'Invalid player identity')
        assert(integer(player.slot,1,Capacity) and not slots[player.slot],'Invalid player slot')
        assert(player.role=='host' or player.role=='client','Invalid player role')
        assert(player.conn=='connected' or player.conn=='disconnected','Invalid player connection')
        keys[player.key]=true;slots[player.slot]=true
        if player.role=='host' then hosts=hosts+1 end
    end
    assert(hosts==1,'Checkpoint must contain one host')
    return detached(checkpoint)
end
function H.Validate(checkpoint)
    local ok,state=pcall(validate,checkpoint)
    return ok,ok and state or tostring(state)
end
function H.new(hostKey,session)
    assert(Identity.Parse(hostKey) and type(session)=='string' and #session>0 and #session<=128)
    return setmetatable({hostKey=hostKey,session=session,term=1,sequence=0,phase='running',acks={}},H)
end
-- Capture adapter must explicitly provide each required domain; absence blocks takeover.
function H:Record(key,term,sequence,checkpoint)
    if key~=self.hostKey or term~=self.term or self.phase~='running' then return false,'not_authority' end
    if not integer(sequence,1,9007199254740991) or sequence~=self.sequence+1 then return false,'missing_update' end
    local ok,state=pcall(validate,checkpoint);if not ok then return false,tostring(state) end
    local host
    for _,player in ipairs(state.players) do if player.role=='host' then host=player.key end end
    if host~=self.hostKey then return false,'host_identity_mismatch' end
    self.checkpoint=state;self.sequence=sequence;self.acks={}
    self.acks[key]=sequence;return true
end
function H:Acknowledge(key,term,sequence)
    if term~=self.term or sequence~=self.sequence or not self.checkpoint then return false end
    for _,player in ipairs(self.checkpoint.players) do
        if player.key==key and player.conn=='connected' then self.acks[key]=sequence;return true end
    end
    return false
end
function H:HostLeft(key,term)
    if key~=self.hostKey or term~=self.term then return false end
    self.phase='waiting';return true
end
function H:CanClaim(key,term,sequence)
    if self.phase~='waiting' or term~=self.term or sequence~=self.sequence or not self.checkpoint then return false,'stale_offer' end
    if key==self.hostKey or self.acks[key]~=sequence then return false,'checkpoint_not_confirmed' end
    for _,player in ipairs(self.checkpoint.players) do
        if player.key==key and player.conn=='connected' then return true end
    end
    return false,'not_participant'
end
-- Shared arbiter serializes authenticated claims; first accepted claim is final.
function H:Claim(key,term,sequence)
    local ok,why=self:CanClaim(key,term,sequence);if not ok then return false,why end
    local forced=self.preserveFormer==true;self.preserveFormer=nil
    local former=self.hostKey;self.hostKey=key;self.term=self.term+1;self.phase='claimed'
    self.restoreRequired=nil;self.restoreAcks=nil
    for _,player in ipairs(self.checkpoint.players) do
        player.role=player.key==key and 'host' or 'client'
        if player.key==former and not forced then player.conn='disconnected' end
    end
    return true,{session=self.session,term=self.term,hostKey=key,formerHost=former,sequence=self.sequence,forced=forced}
end
-- Trusted development coordinator entry for F6; never dispatch directly from
-- a packet field. Runtime caller must enforce the dev/test authorization gate.
-- The still-running former host must restore/demote and join the same barrier.
function H:ForceClaim(key,term,sequence)
    if self.phase~='running' then return false,'handover_in_progress' end
    self.phase='waiting';self.preserveFormer=true
    local ok,result=self:Claim(key,term,sequence)
    if not ok then self.phase='running';self.preserveFormer=nil end
    return ok,result
end
function H:Snapshot() return self.checkpoint and detached(self.checkpoint) or nil end
-- The shared arbiter tracks application receipts, not packet-supplied roles.
function H:BeginRestore(key,term)
    if self.phase~='claimed' or key~=self.hostKey or term~=self.term or self.restoreRequired then return false end
    self.restoreRequired={};self.restoreAcks={}
    for _,player in ipairs(self.checkpoint.players) do
        if player.conn=='connected' then self.restoreRequired[player.key]=true end
    end
    return true
end
function H:Applied(key,term,sequence)
    if self.phase~='claimed' or term~=self.term or sequence~=self.sequence
        or not self.restoreRequired or not self.restoreRequired[key] then return false end
    self.restoreAcks[key]=true;return true
end
function H:RestoreReady()
    if self.phase~='claimed' or not self.restoreRequired then return false end
    for key in pairs(self.restoreRequired) do if not self.restoreAcks[key] then return false end end
    return true
end
-- Called from authenticated disconnect handling. Preserve membership/slots,
-- but do not leave the restore barrier waiting on a departed non-host.
function H:ParticipantLeft(key,term)
    if term~=self.term or key==self.hostKey or not self.checkpoint then return false end
    for _,player in ipairs(self.checkpoint.players) do
        if player.key==key then
            player.conn='disconnected';self.acks[key]=nil
            if self.restoreRequired then self.restoreRequired[key]=nil;self.restoreAcks[key]=nil end
            return true
        end
    end
    return false
end
-- Caller supplies the freshly authenticated identity, never a packet claim.
-- Rejoining changes connection state only; it cannot reclaim host authority.
function H:Rejoined(key,term)
    if self.phase~='running' or term~=self.term or not self.checkpoint then return false end
    for _,player in ipairs(self.checkpoint.players) do
        if player.key==key then
            player.conn='connected';player.role=key==self.hostKey and 'host' or 'client'
            self.acks[key]=nil;return true
        end
    end
    return false
end
-- Gameplay remains paused until adapter/transport restoration is confirmed.
function H:Restored(key,term)
    if self.phase~='claimed' or key~=self.hostKey or term~=self.term then return false end
    if not self:RestoreReady() then return false end
    self.phase='running';self.acks={};self.acks[key]=self.sequence;return true
end
return H
