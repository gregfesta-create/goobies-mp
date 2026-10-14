-- Detached lifecycle bridge: explicit spawn observations plus bounded native reads.
-- Polling is never allowed to silently invent a replacement enemy lifetime.
local E=require('gmp_enemies')
local O={};O.__index=O
-- Shared pause uses tiny nonzero time dilation. Native positions can drift by
-- sub-unit distances during multi-frame rebuilding; HP/type remain exact.
O.RESTORE_POSITION_TOLERANCE=.1
local function samePosition(a,b) return math.abs(a-b)<=O.RESTORE_POSITION_TOLERANCE end
local function integer(n,lo,hi) return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi end
local function finite(n,limit) return type(n)=='number' and n==n and math.abs(n)<=limit end
local function normalize(rows)
    if type(rows)~='table' or #rows>E.MAX_SLOTS then return nil,'record_limit' end
    local bySlot={};local count=0
    for key,row in pairs(rows) do
        count=count+1
        if not integer(key,1,#rows) or type(row)~='table' or not integer(row.index,0,E.MAX_SLOTS-1)
            or not integer(row.enemyType,0,255) or not finite(row.hp,1000000000000)
            or not finite(row.x,2000000) or not finite(row.y,2000000)
            or not finite(row.z or 0,100000)
            or (row.damage~=nil and (not finite(row.damage,1e12) or row.damage<0)) or bySlot[row.index] then return nil,'invalid_record' end
        bySlot[row.index]={slot=row.index,enemyType=row.enemyType,hp=row.hp,x=row.x,y=row.y,z=row.z or 0,damage=row.damage}
    end
    if count~=#rows then return nil,'invalid_list' end
    return bySlot
end
function O.new(registry)
    return setmetatable({registry=registry,failed=false,bootstrapped=false,stats={spawns=0,updates=0,deaths=0}},O)
end
function O:_fail(why) self.failed=true;self.reason=why;return false,why end
function O:_apply(events)
    -- Registry validates each batch atomically. Admission checks here prevent
    -- capacity failures part-way through a multi-batch capture.
    local spawns=0
    for _,event in ipairs(events) do if event.kind=='spawn' then spawns=spawns+1 end end
    if self.registry.count+spawns>E.MAX_RECORDS then return self:_fail('capacity') end
    for start=1,#events,256 do
        local batch={};for i=start,math.min(start+255,#events) do batch[#batch+1]=events[i] end
        local ok,why=self.registry:Apply(batch);if not ok then return self:_fail(why) end
    end
    return true
end
function O:Bootstrap(rows)
    if self.failed then return false,self.reason end
    if self.bootstrapped then return false,'already_bootstrapped' end
    if self.registry.epoch==0 or self.registry.count~=0 then return self:_fail('registry_not_empty') end
    local bySlot,why=normalize(rows);if not bySlot then return self:_fail(why) end
    local events={}
    for slot=0,E.MAX_SLOTS-1 do
        local r=bySlot[slot]
        if r and r.hp>0 then events[#events+1]={kind='spawn',slot=slot,enemyType=r.enemyType,hp=r.hp,x=r.x,y=r.y,z=r.z,damage=r.damage} end
    end
    local ok,err=self:_apply(events)
    if ok then self.bootstrapped=true;self.stats.spawns=self.stats.spawns+#events end
    return ok,err
end
-- Read back every reconstructed living row before adopting imported IDs.
-- An incomplete rebuild leaves the registry entirely untouched.
function O:Adopt(bindings,rows)
    if self.failed then return false,self.reason end
    if self.bootstrapped then return false,'already_bootstrapped' end
    local native,why=normalize(rows);if not native then return self:_fail(why) end
    if type(bindings)~='table' then return self:_fail('invalid_bindings') end
    local used={}
    for _,binding in ipairs(bindings) do
        if type(binding)~='table' then return self:_fail('invalid_binding') end
        local record=self.registry.records[binding.id];local row=native[binding.slot]
        if not record or record.dead or not row or row.hp<=0 or used[binding.slot]
            or row.enemyType~=record.enemyType or row.hp~=record.hp
            or (record.damage~=nil and row.damage~=record.damage)
            or not samePosition(row.x,record.x) or not samePosition(row.y,record.y)
            or not samePosition(row.z,record.z) then
            local detail='restore_readback_mismatch id='..tostring(binding.id)..' slot='..tostring(binding.slot)
            if record and row then
                for _,field in ipairs({'enemyType','hp','x','y','z','damage'}) do
                    if row[field]~=record[field] then
                        detail=detail..' '..field..' expected='..tostring(record[field])..' actual='..tostring(row[field])
                    end
                end
            else detail=detail..' missing='..(record and 'native_row' or 'record') end
            return self:_fail(detail:sub(1,900))
        end
        used[binding.slot]=true
    end
    for slot,row in pairs(native) do
        if row.hp>0 and not used[slot] then return self:_fail('unbound_native_enemy') end
    end
    local ok,err=self.registry:Rebind(bindings);if not ok then return self:_fail(err) end
    self.bootstrapped=true;return true
end
function O:Spawn(slots,rows)
    if self.failed then return false,self.reason end
    if not self.bootstrapped then return false,'not_bootstrapped' end
    if type(slots)~='table' or #slots>256 then return self:_fail('spawn_limit') end
    local bySlot,why=normalize(rows);if not bySlot then return self:_fail(why) end
    local events,seen={},{}
    for key,slot in pairs(slots) do
        if not integer(key,1,#slots) or not integer(slot,0,E.MAX_SLOTS-1) or seen[slot] then return self:_fail('invalid_spawn_slots') end
        seen[slot]=true
    end
    local count=0;for _ in pairs(slots) do count=count+1 end
    if count~=#slots then return self:_fail('invalid_spawn_slots') end
    for _,slot in ipairs(slots) do
        local row=bySlot[slot];if not row or row.hp<=0 then return self:_fail('spawn_record_unavailable') end
        local id=self.registry:IdForSlot(slot);local old=id and self.registry.records[id]
        -- A confirmed spawn in an occupied slot proves that lifetime retired,
        -- even if its death and reuse both occurred between polling frames.
        if old and not old.dead then events[#events+1]={kind='death',id=id} end
        events[#events+1]={kind='spawn',slot=slot,enemyType=row.enemyType,hp=row.hp,x=row.x,y=row.y,z=row.z,damage=row.damage}
    end
    local ok,err=self:_apply(events)
    if ok then self.stats.spawns=self.stats.spawns+#slots end
    return ok,err
end
function O:Poll(rows)
    if self.failed then return false,self.reason end
    if not self.bootstrapped then return false,'not_bootstrapped' end
    local bySlot,why=normalize(rows);if not bySlot then return self:_fail(why) end
    local events={}
    for slot,row in pairs(bySlot) do
        local id=self.registry:IdForSlot(slot);local old=id and self.registry.records[id]
        if row.hp>0 then
            if not old or old.dead or old.enemyType~=row.enemyType then return self:_fail('unobserved_spawn') end
            if old.x~=row.x or old.y~=row.y or old.z~=row.z or old.hp~=row.hp or old.damage~=row.damage then
                events[#events+1]={kind='update',id=id,hp=row.hp,x=row.x,y=row.y,z=row.z,damage=row.damage}
            end
        elseif old and not old.dead then
            -- Keep the last visible position instead of the native dead sentinel.
            events[#events+1]={kind='death',id=id}
        end
    end
    for slot,id in pairs(self.registry.slots) do
        if not self.registry.records[id].dead and not bySlot[slot] then return self:_fail('missing_native_record') end
    end
    local ok,err=self:_apply(events)
    if ok then for _,event in ipairs(events) do
        if event.kind=='death' then self.stats.deaths=self.stats.deaths+1 else self.stats.updates=self.stats.updates+1 end
    end end
    return ok,err
end
return O
