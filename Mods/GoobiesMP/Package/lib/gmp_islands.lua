-- Pure host/client island handoff. Engine generation and reliable transport
-- adapters are separate; no Cheat Mod setting is read or required here.
local I={};I.Host={};I.Host.__index=I.Host;I.Client={};I.Client.__index=I.Client
local function integer(n,lo,hi) return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi end
local function copy(m)
    local r={};for k,v in pairs(m) do if k~='biomeOrder' then r[k]=v end end
    r.biomeOrder={};for i,v in ipairs(m.biomeOrder) do r.biomeOrder[i]=v end;return r
end
function I.Valid(m)
    if type(m)~='table' or not integer(m.epoch,1,2147483647) or not integer(m.island,1,1000000) or
        not integer(m.seed,0,9999999) or not integer(m.stage,1,1000000) or
        not integer(m.chunks,1,1024) or not integer(m.foliage,0,100000) or type(m.artifactBiome)~='boolean' or
        type(m.biomeOrder)~='table' or #m.biomeOrder<1 or #m.biomeOrder>64 then return false end
    local count,seen=0,{}
    for key,name in pairs(m.biomeOrder) do
        if not integer(key,1,#m.biomeOrder) or type(name)~='string' or #name>64 or
            not name:match('^[%w_%-]+$') or seen[name] then return false end
        seen[name]=true;count=count+1
    end
    return count==#m.biomeOrder
end
-- Configuration fingerprint, not a claim that geometry hashes match.
function I.Stamp(m)
    if not I.Valid(m) then return nil end
    return table.concat({m.epoch,m.island,m.seed,m.stage,m.chunks,m.foliage,m.artifactBiome and 1 or 0,table.concat(m.biomeOrder,',')},'|')
end
function I.ToWire(m)
    if not I.Valid(m) then return nil end
    local wire=copy(m);wire.biomeOrder=nil;wire.biomes={}
    for _,name in ipairs(m.biomeOrder) do wire.biomes[#wire.biomes+1]={name=name} end
    return wire
end
function I.FromWire(wire)
    if type(wire)~='table' or type(wire.biomes)~='table' then return nil end
    local m={epoch=wire.epoch,island=wire.island,seed=wire.seed,stage=wire.stage,chunks=wire.chunks,foliage=wire.foliage,artifactBiome=wire.artifactBiome,biomeOrder={}}
    for index,row in pairs(wire.biomes) do
        if type(row)~='table' then return nil end
        m.biomeOrder[index]=row.name
    end
    return I.Valid(m) and m or nil
end
function I.Host.new(participants)
    return setmetatable({participants=participants,epoch=0,island=0,phase='idle',ready={}},I.Host)
end
function I.Host:_participants()
    local result={}
    for key,connected in pairs(self.participants()) do if connected==true then result[key]=true end end
    return result
end
function I.Host:BeginRun()
    assert(self.epoch<2147483647,'Island epoch exhausted')
    self.epoch=self.epoch+1;self.island=0;self.phase='awaiting_manifest';self.pending=nil;self.ready={}
    self.required=self:_participants();return self.epoch
end
-- key must be the caller's session-bound identity, never a packet claim.
function I.Host:Request(key,epoch,island)
    if epoch~=self.epoch or island~=self.island then return false,'stale_island' end
    local participants=self:_participants()
    if participants[key]~=true then return false,'not_participant' end
    if self.phase=='awaiting_manifest' then return true,'already_requested' end
    if self.phase~='playing' then return false,'transition_pending' end
    self.phase='awaiting_manifest';self.required=participants;self.ready={};self.pending=nil
    return true,'end_island'
end
function I.Host:Prepare(manifest)
    if not I.Valid(manifest) or manifest.epoch~=self.epoch or manifest.island~=self.island+1 then return false,'invalid_manifest' end
    if self.phase=='generating' and I.Stamp(self.pending)==I.Stamp(manifest) then return true,'duplicate' end
    if self.phase~='awaiting_manifest' then return false,'wrong_phase' end
    self.pending=copy(manifest);self.ready={};self.phase='generating';return true
end
function I.Host:Ready(key,epoch,island,stamp)
    if self.phase~='generating' or epoch~=self.epoch or island~=self.pending.island then return false,'stale_ready' end
    if self.required[key]~=true or self.participants()[key]~=true then return false,'not_participant' end
    if stamp~=I.Stamp(self.pending) then return false,'generation_mismatch' end
    self.ready[key]=true;return true
end
function I.Host:Commit()
    if self.phase~='generating' then return false,'wrong_phase' end
    for key,required in pairs(self.required) do if required and not self.ready[key] then return false,'waiting_for_players' end end
    self.island=self.pending.island;self.current=copy(self.pending);self.pending=nil;self.phase='playing'
    return true,copy(self.current)
end
-- Explicit session disconnect decision; a timer never silently skips a player.
function I.Host:RemoveParticipant(key)
    if self.participants()[key]==true then return false end
    -- A drop in the lobby (no run begun yet) has no required set to release.
    if self.required then self.required[key]=nil end
    self.ready[key]=nil;return true
end
function I.Host:Manifest() return self.pending and copy(self.pending) or nil end
function I.Client.new() return setmetatable({epoch=0,island=0,phase='idle'},I.Client) end
-- Caller only invokes this for an authenticated, reliable host message.
function I.Client:Prepare(manifest)
    if not I.Valid(manifest) then return false,'invalid_manifest' end
    if self.phase=='idle' and self.epoch>0 and manifest.epoch<=self.epoch then return false,'stale_run' end
    if manifest.epoch<self.epoch or (manifest.epoch==self.epoch and manifest.island<=self.island) then return false,'stale_manifest' end
    if self.pending then
        if I.Stamp(self.pending)==I.Stamp(manifest) then return true,'duplicate' end
        return false,'transition_pending'
    end
    if manifest.epoch>self.epoch and manifest.island~=1 then return false,'missing_run_start' end
    if manifest.epoch==self.epoch and manifest.island~=self.island+1 then return false,'missing_island' end
    self.pending=copy(manifest);self.phase='generating';return true
end
-- Explicit authenticated resume snapshot; normal manifests keep strict sequencing.
function I.Client:Resume(manifest)
    if not I.Valid(manifest) or manifest.epoch<self.epoch then return false end
    if self.phase=='idle' then self.pending=copy(manifest);self.phase='generating';self.resumed,self.taken,self.travel=true,nil,nil;return true end
    -- ODD_INTERACTIONS row 8 (Coder C): a resumed player follows the host to its newer island: before its entry took the
    -- settings (I.Client.taken, set when the generator reads them) it simply loads the newer one; once it has generated
    -- the old one (ready, the host moved on before its commit) it travels on to the newer one (I.Client.travel).
    if self:Refreshable() and I.Stamp(self.pending)~=I.Stamp(manifest) and (manifest.epoch>self.pending.epoch
        or (manifest.epoch==self.pending.epoch and manifest.island>self.pending.island)) then
        if self.phase=='ready' then self.phase='generating';self.travel=true end
        self.pending=copy(manifest);self.taken=nil;return true
    end
    return false
end
function I.Client:Refreshable()
    return self.resumed==true and self.pending~=nil and ((self.phase=='generating' and not self.taken) or self.phase=='ready')
end
function I.Client:Retry()
    if self.phase~='playing' or not self.current then return false end
    self.pending=copy(self.current);self.phase='generating';self.island=0
    return true
end
function I.Client:Generated(stamp)
    if self.phase~='generating' or stamp~=I.Stamp(self.pending) then return false,'generation_mismatch' end
    self.phase='ready';return true
end
function I.Client:Commit(epoch,island,stamp)
    if self.phase=='playing' and epoch==self.epoch and island==self.island and stamp==I.Stamp(self.current) then return true,'duplicate' end
    if self.phase~='ready' or epoch~=self.pending.epoch or island~=self.pending.island or stamp~=I.Stamp(self.pending) then return false,'invalid_commit' end
    self.current=copy(self.pending);self.epoch=epoch;self.island=island;self.pending=nil;self.phase='playing'
    self.resumed,self.taken,self.travel=nil,nil,nil   -- row 8 (Coder C)
    return true
end
return I
