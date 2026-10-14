-- Host-owned pickup lifetimes. Register only verified host spawns; never client amounts.
-- Engine observation, position validation and shared level progression are adapters.
local P={};P.__index=P
P.MAX_RECORDS=8192
local function integer(n,lo,hi)
    return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi
end
function P.new()
    return setmetatable({epoch=0,island=0,nextId=0,records={},count=0,total=0,revision=0},P)
end
function P:BeginRun()
    assert(self.epoch<2147483647,'Pickup epoch exhausted')
    self.epoch=self.epoch+1;self.island=0;self.nextId=0
    self.records={};self.count=0;self.total=0;self.revision=0
    return self.epoch
end
function P:BeginIsland(island)
    if self.epoch==0 or not integer(island,1,1000000) or island~=self.island+1 then return false,'invalid_island' end
    self.island=island;self.records={};self.count=0
    -- Run-wide IDs and total survive islands; stale claims cannot hit new orbs.
    self.revision=self.revision+1;return true
end
function P:Register(amount)
    if self.island==0 then return nil,'no_island' end
    if not integer(amount,1,1000000) then return nil,'invalid_amount' end
    if self.count>=P.MAX_RECORDS or self.nextId>=2147483647 then return nil,'capacity' end
    self.nextId=self.nextId+1
    local id=self.epoch..':'..self.nextId
    self.records[id]={amount=amount,claimed=false};self.count=self.count+1
    return id
end
-- Caller supplies identity bound by the authenticated connection and host-verified
-- eligibility (e.g. pickup radius or Magnet). Return delta=0 for duplicate delivery.
function P:Claim(epoch,island,id,key,eligible)
    if epoch~=self.epoch or island~=self.island or self.island==0 then return false,'stale_island' end
    if type(key)~='string' or #key==0 or #key>128 or eligible~=true then return false,'ineligible' end
    local record=self.records[id]
    if not record then return false,'unknown_pickup' end
    if record.claimed then return true,0,self:Snapshot() end
    if self.total>9007199254740991-record.amount then return false,'total_exhausted' end
    record.claimed=true;record.key=key
    self.total=self.total+record.amount;self.revision=self.revision+1
    return true,record.amount,self:Snapshot()
end
function P:Snapshot()
    return {epoch=self.epoch,island=self.island,total=self.total,revision=self.revision}
end
-- Only retire after the adapter has removed the world pickup and confirmed its
-- terminal state was delivered. Unknown retired IDs remain rejected forever.
function P:Retire(id)
    local record=self.records[id]
    if not record or not record.claimed then return false end
    self.records[id]=nil;self.count=self.count-1;return true
end
-- Full registry state for the progression/world checkpoint adapters. Snapshot
-- alone omits pickup lifetimes and cannot prevent duplicate XP after takeover.
function P:Capture()
    local state={version=1,epoch=self.epoch,island=self.island,nextId=self.nextId,
        total=self.total,revision=self.revision,records={}}
    for id,record in pairs(self.records) do
        state.records[#state.records+1]={id=id,amount=record.amount,claimed=record.claimed,key=record.key}
    end
    table.sort(state.records,function(a,b) return a.id<b.id end)
    return state
end
local function prepare(state)
    assert(type(state)=='table' and state.version==1,'Invalid pickup checkpoint version')
    assert(integer(state.epoch,0,2147483647) and integer(state.island,0,1000000),'Invalid pickup generation')
    assert(integer(state.nextId,0,2147483647) and integer(state.total,0,9007199254740991)
        and integer(state.revision,0,9007199254740991),'Invalid pickup counters')
    assert(type(state.records)=='table' and #state.records<=P.MAX_RECORDS,'Invalid pickup records')
    local result={epoch=state.epoch,island=state.island,nextId=state.nextId,
        total=state.total,revision=state.revision,records={},count=0}
    local claimedTotal,claimedCount=0,0
    for index in pairs(state.records) do
        assert(integer(index,1,#state.records),'Pickup records must be a dense list')
    end
    for _,row in ipairs(state.records) do
        assert(type(row)=='table' and type(row.id)=='string','Invalid pickup identity')
        local epoch,sequence=row.id:match('^(%d+):(%d+)$')
        epoch,sequence=tonumber(epoch),tonumber(sequence)
        assert(epoch==state.epoch and integer(sequence,1,state.nextId)
            and row.id==epoch..':'..sequence and not result.records[row.id],'Invalid pickup lifetime')
        assert(integer(row.amount,1,1000000) and type(row.claimed)=='boolean','Invalid pickup value')
        if row.claimed then
            assert(type(row.key)=='string' and #row.key>0 and #row.key<=128,'Missing pickup collector')
            claimedTotal=claimedTotal+row.amount;claimedCount=claimedCount+1
        else assert(row.key==nil,'Unclaimed pickup has a collector') end
        result.records[row.id]={amount=row.amount,claimed=row.claimed,key=row.key}
        result.count=result.count+1
    end
    assert(result.count==#state.records,'Sparse pickup records')
    assert(claimedTotal<=state.total and state.revision>=state.island+claimedCount,'Inconsistent pickup accounting')
    if state.epoch==0 then
        assert(state.island==0 and state.nextId==0 and state.total==0 and state.revision==0 and result.count==0,'Invalid empty run')
    elseif state.island==0 then
        assert(state.nextId==0 and state.total==0 and state.revision==0 and result.count==0,'Invalid unstarted island')
    end
    return result
end
function P:ValidateRestore(state)
    local ok,why=pcall(prepare,state)
    return ok,ok and nil or tostring(why)
end
function P:Restore(state)
    local ok,prepared=pcall(prepare,state)
    if not ok then return false,tostring(prepared) end
    -- Commit only after complete validation; never retain caller-owned tables.
    for key,value in pairs(prepared) do self[key]=value end
    return true
end
return P
