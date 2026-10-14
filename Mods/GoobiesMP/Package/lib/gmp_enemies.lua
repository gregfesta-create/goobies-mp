-- Host-only lifecycle registry. No Unreal, transport or client calls.
-- The adapter must supply spawn/death events: polling alone can miss slot reuse.
local E={};E.__index=E
E.MAX_SLOTS=4096
E.MAX_RECORDS=8192
local function finite(n,limit) return type(n)=='number' and n==n and math.abs(n)<=limit end
local function integer(n,lo,hi) return finite(n,hi) and n%1==0 and n>=lo end
local function copy(record)
    local result={};for key,value in pairs(record) do result[key]=value end;return result
end
function E.new()
    return setmetatable({epoch=0,nextId=0,revision=0,slots={},records={},count=0},E)
end
function E:BeginRun()
    assert(self.epoch<2147483647,'Enemy epoch exhausted')
    self.epoch=self.epoch+1;self.nextId=0;self.revision=0
    self.slots={};self.records={};self.count=0
    return self.epoch
end
local function position(event)
    return finite(event.x,2000000) and finite(event.y,2000000) and finite(event.z,100000)
end
-- Whole batches validate on a private copy; a failed event commits nothing.
-- Update/death events reference the host-issued ID, not an untrusted slot alone.
function E:Apply(events)
    if self.epoch==0 then return false,'no_run' end
    if type(events)~='table' or #events>256 then return false,'invalid_batch' end
    local keys=0
    for key in pairs(events) do
        keys=keys+1
        if not integer(key,1,#events) then return false,'invalid_batch' end
    end
    if keys~=#events then return false,'invalid_batch' end
    local slots,records={},{}
    for slot,id in pairs(self.slots) do slots[slot]=id end
    for id,record in pairs(self.records) do records[id]=copy(record) end
    local nextId,count=self.nextId,self.count
    local spawned={}
    for _,event in ipairs(events) do
        if type(event)~='table' then return false,'invalid_event' end
        if event.kind=='spawn' then
            if not integer(event.slot,0,E.MAX_SLOTS-1) or not integer(event.enemyType,0,255) or
                not position(event) or not finite(event.hp,1000000000000) or event.hp<=0
                or (event.damage~=nil and (not finite(event.damage,1e12) or event.damage<0)) then return false,'invalid_spawn' end
            local old=slots[event.slot]
            if old and not records[old].dead then return false,'slot_alive' end
            if count>=E.MAX_RECORDS or nextId>=2147483647 then return false,'capacity' end
            nextId=nextId+1;count=count+1
            local id=tostring(self.epoch)..':'..tostring(nextId)
            records[id]={id=id,epoch=self.epoch,slot=event.slot,enemyType=event.enemyType,
                x=event.x,y=event.y,z=event.z,hp=event.hp,dead=false,damage=event.damage}
            slots[event.slot]=id;spawned[#spawned+1]={slot=event.slot,id=id}
        elseif event.kind=='update' or event.kind=='death' then
            local record=records[event.id]
            if not record or record.dead or slots[record.slot]~=event.id then return false,'stale_entity' end
            if event.kind=='update' then
                if not position(event) or not finite(event.hp,1000000000000) or event.hp<=0
                or (event.damage~=nil and (not finite(event.damage,1e12) or event.damage<0)) then return false,'invalid_update' end
                record.x,record.y,record.z,record.hp=event.x,event.y,event.z,event.hp
                if event.damage~=nil then record.damage=event.damage end
            else
                -- Retain final visible position; the game's dead-slot sentinel is
                -- not the location where a client should play the death effect.
                if event.x~=nil or event.y~=nil or event.z~=nil then
                    if not position(event) then return false,'invalid_death' end
                    record.x,record.y,record.z=event.x,event.y,event.z
                end
                record.hp=0;record.dead=true
            end
        else return false,'unknown_event' end
    end
    self.slots,self.records,self.nextId,self.count=slots,records,nextId,count
    if #events>0 then self.revision=self.revision+1 end
    return true,spawned
end
function E:IdForSlot(slot) return self.slots[slot] end
-- Reconstructed native slots are bindings, never new enemy lifetimes.
-- Require exactly one binding for every living record; commit only after all
-- identities and slots validate. Dead history and nextId remain unchanged.
function E:Rebind(bindings)
    if self.epoch==0 or type(bindings)~='table' or #bindings>E.MAX_SLOTS then return false,'invalid_bindings' end
    local slots,seen,changes={},{},{};local count=0
    for key,b in pairs(bindings) do
        count=count+1
        if not integer(key,1,#bindings) or type(b)~='table' or not integer(b.slot,0,E.MAX_SLOTS-1) then return false,'invalid_binding' end
        local record=self.records[b.id]
        if not record or record.dead or seen[b.id] or slots[b.slot] then return false,'invalid_identity_binding' end
        seen[b.id]=true;slots[b.slot]=b.id;changes[b.id]=b.slot
    end
    if count~=#bindings then return false,'invalid_bindings' end
    for id,record in pairs(self.records) do
        if not record.dead and not seen[id] then return false,'missing_alive_binding' end
    end
    for id,slot in pairs(changes) do self.records[id].slot=slot end
    self.slots=slots
    if count>0 then self.revision=self.revision+1 end
    return true
end
function E:Restore(snapshot)
    local replica=require('gmp_enemy_replica').new()
    local ok,why=replica:Apply(snapshot);if not ok then return false,why end
    local records,slots,count={},{},0
    for _,row in ipairs(replica:Snapshot().enemies) do
        records[row.id]=copy(row);count=count+1
        if not row.dead then slots[row.slot]=row.id end
    end
    self.epoch,self.revision,self.nextId=replica.epoch,replica.revision,replica.highId
    self.records,self.slots,self.count=records,slots,count;return true
end
-- Caller may retire a death only after all relevant clients received it.
function E:RetireDead(id)
    local record=self.records[id]
    if not record or not record.dead then return false end
    if self.slots[record.slot]==id then self.slots[record.slot]=nil end
    self.records[id]=nil;self.count=self.count-1;self.revision=self.revision+1
    return true
end
function E:Snapshot()
    local result={epoch=self.epoch,revision=self.revision,enemies={}}
    for _,record in pairs(self.records) do result.enemies[#result.enemies+1]=copy(record) end
    table.sort(result.enemies,function(a,b)
        if a.slot~=b.slot then return a.slot<b.slot end
        return a.id<b.id
    end)
    return result
end
return E
