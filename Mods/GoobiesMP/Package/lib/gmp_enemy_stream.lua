-- Authenticated host snapshots only. Bounded fragments, atomic visible replacement.
-- Engine enemy spawning/damage remain outside this transport adapter.
local Registry=require('gmp_enemies')
local Replica=require('gmp_enemy_replica')
local Codec=require('gmp_codec')
local Stream={};Stream.__index=Stream
Stream.ROWS=8
Stream.MAX_CHUNKS=math.ceil(Registry.MAX_RECORDS/Stream.ROWS)
local function integer(n,lo,hi) return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi end
local function round(n) return math.floor(n+0.5) end
function Stream.Packets(snapshot,sid,version)
    version=version or 1
    if version~=1 and version~=2 then return nil,'unsupported_enemy_version' end
    -- Validate complete data before producing any transport fragments.
    local check=Replica.new()
    local ok,why=check:Apply(snapshot);if not ok then return nil,why end
    if version==1 then
        for _,row in ipairs(snapshot.enemies) do
            if row.damage~=nil then return nil,'damage_requires_v2' end
        end
    end
    local total=math.max(1,math.ceil(#snapshot.enemies/Stream.ROWS));local packets={}
    for index=1,total do
        local packet={epoch=snapshot.epoch,revision=snapshot.revision,index=index,total=total,count=#snapshot.enemies,enemies={}}
        if version==2 then packet.version=2 end
        for i=(index-1)*Stream.ROWS+1,math.min(index*Stream.ROWS,#snapshot.enemies) do
            local r=snapshot.enemies[i]
            packet.enemies[#packet.enemies+1]={id=r.id,slot=r.slot,enemyType=r.enemyType,
                x=round(r.x),y=round(r.y),z=round(r.z),hp=string.format('%.17g',r.hp),dead=r.dead}
            if version==2 then
                packet.enemies[#packet.enemies].damage=r.damage~=nil and string.format('%.17g',r.damage) or ''
            end
        end
        -- Largest legal link counters; actual framing must fit, not an estimate.
        local wire=Codec.Encode({type=version==2 and 'ENEMY_SNAPSHOT_V2' or 'ENEMY_SNAPSHOT',ch='R',sid=sid or 'Sffffffff',
            ep=2147483647,seq=9007199254740991,ack=9007199254740991,f=packet})
        if not wire or #wire>1380 then return nil,'packet_budget' end
        packets[index]=packet
    end
    return packets
end
function Stream.new()
    return setmetatable({replica=Replica.new(),pending=nil},Stream)
end
function Stream:Receive(f,version)
    version=version or (type(f)=='table' and f.version or 1)
    if version~=1 and version~=2 then return false,'unsupported_enemy_version' end
    if type(f)~='table' or (version==2 and f.version~=2) or (version==1 and f.version~=nil) then
        return false,'unsupported_enemy_version'
    end
    if type(f)~='table' or not integer(f.epoch,1,2147483647)
        or not integer(f.revision,0,9007199254740991) or not integer(f.count,0,Registry.MAX_RECORDS)
        or not integer(f.total,1,Stream.MAX_CHUNKS) or not integer(f.index,1,f.total)
        or f.total~=math.max(1,math.ceil(f.count/Stream.ROWS)) or type(f.enemies)~='table' then return false,'invalid_fragment' end
    local expected=math.min(Stream.ROWS,math.max(0,f.count-(f.index-1)*Stream.ROWS))
    if #f.enemies~=expected then return false,'invalid_fragment' end
    local keys=0
    for key in pairs(f.enemies) do keys=keys+1;if not integer(key,1,expected) then return false,'invalid_fragment' end end
    if keys~=expected then return false,'invalid_fragment' end
    local r=self.replica
    if f.epoch<r.epoch or (f.epoch==r.epoch and f.revision<=r.revision) then return false,'stale_snapshot' end
    local pending=self.pending
    if pending and (f.epoch<pending.epoch or (f.epoch==pending.epoch and f.revision<pending.revision)) then return false,'stale_fragment' end
    local rows={}
    for _,row in ipairs(f.enemies) do
        if type(row)~='table' or type(row.hp)~='string' or #row.hp>32 then return false,'invalid_enemy' end
        rows[#rows+1]={id=row.id,epoch=f.epoch,slot=row.slot,enemyType=row.enemyType,
            x=row.x,y=row.y,z=row.z,hp=tonumber(row.hp),dead=row.dead}
        if version==2 then
            if type(row.damage)~='string' or #row.damage>32 then return false,'invalid_enemy' end
            if row.damage~='' then
                local damage=tonumber(row.damage)
                if not damage or damage~=damage or damage<0 or damage>1e12 then return false,'invalid_enemy' end
                rows[#rows].damage=damage
            end
        elseif row.damage~=nil then return false,'invalid_enemy' end
    end
    -- Validate each fragment independently before it occupies assembly memory.
    local valid=Replica.new():Apply({epoch=f.epoch,revision=f.revision,enemies=rows})
    if not valid then return false,'invalid_enemy' end
    if not pending or f.epoch>pending.epoch or f.revision>pending.revision then
        pending={version=version,epoch=f.epoch,revision=f.revision,count=f.count,total=f.total,parts={},received=0};self.pending=pending
    end
    if pending.version~=version or pending.count~=f.count or pending.total~=f.total then return false,'fragment_conflict' end
    local old=pending.parts[f.index]
    if old then
        for i,row in ipairs(rows) do
            for key,value in pairs(row) do if old[i][key]~=value then return false,'fragment_conflict' end end
            for key,value in pairs(old[i]) do if row[key]~=value then return false,'fragment_conflict' end end
        end
        return true,'duplicate'
    end
    pending.parts[f.index]=rows;pending.received=pending.received+1
    if pending.received<pending.total then return true,'pending' end
    local all={}
    for i=1,pending.total do for _,row in ipairs(pending.parts[i]) do all[#all+1]=row end end
    local ok,why=r:Apply({epoch=pending.epoch,revision=pending.revision,enemies=all})
    self.pending=nil
    return ok,ok and 'applied' or why
end
function Stream:Snapshot() return self.replica:Snapshot() end
return Stream
