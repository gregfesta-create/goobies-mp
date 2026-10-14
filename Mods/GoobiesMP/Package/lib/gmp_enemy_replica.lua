-- Detached client copy of complete, validated host enemy snapshots.
-- Transport must authenticate the host before calling Apply. No engine writes.
local E=require('gmp_enemies');local R={};R.__index=R
local function integer(n,lo,hi) return type(n)=='number' and n==n and n%1==0 and n>=lo and n<=hi end
local function finite(n,limit) return type(n)=='number' and n==n and math.abs(n)<=limit end
local function copy(record) local t={};for k,v in pairs(record) do t[k]=v end;return t end
function R.new() return setmetatable({epoch=0,revision=-1,highId=0,records={}},R) end
function R:Apply(snapshot)
    if type(snapshot)~='table' or not integer(snapshot.epoch,1,2147483647)
        or not integer(snapshot.revision,0,9007199254740991) or type(snapshot.enemies)~='table'
        or #snapshot.enemies>E.MAX_RECORDS then return false,'invalid_snapshot' end
    if snapshot.epoch<self.epoch or (snapshot.epoch==self.epoch and snapshot.revision<=self.revision) then return false,'stale_snapshot' end
    local count=0
    for key in pairs(snapshot.enemies) do count=count+1;if not integer(key,1,#snapshot.enemies) then return false,'invalid_list' end end
    if count~=#snapshot.enemies then return false,'invalid_list' end
    local same=snapshot.epoch==self.epoch;local records,liveSlots={},{}
    local highId=same and self.highId or 0
    for _,row in ipairs(snapshot.enemies) do
        if type(row)~='table' or type(row.id)~='string' then return false,'invalid_enemy' end
        local epoch,id=row.id:match('^(%d+):(%d+)$');epoch=tonumber(epoch);id=tonumber(id)
        if epoch~=snapshot.epoch or not integer(id,1,2147483647) or row.id~=epoch..':'..id
            or row.epoch~=epoch or not integer(row.slot,0,E.MAX_SLOTS-1) or not integer(row.enemyType,0,255)
            or not finite(row.x,2000000) or not finite(row.y,2000000) or not finite(row.z,100000)
            or not finite(row.hp,1000000000000) or type(row.dead)~='boolean'
            or (row.damage~=nil and (not finite(row.damage,1e12) or row.damage<0))
            or (row.dead and row.hp~=0) or (not row.dead and row.hp<=0) then return false,'invalid_enemy' end
        if records[row.id] or (not row.dead and liveSlots[row.slot]) then return false,'duplicate_enemy' end
        local old=same and self.records[row.id]
        if same and not old and id<=self.highId then return false,'retired_enemy' end
        -- Native slots may change during authoritative reconstruction. The
        -- host-issued ID, type and terminal death state define the lifetime.
        if old and (old.enemyType~=row.enemyType or (old.dead and not row.dead)) then return false,'lifetime_changed' end
        records[row.id]=copy(row);if not row.dead then liveSlots[row.slot]=row.id end
        highId=math.max(highId,id)
    end
    -- Validate the entire snapshot before replacing the visible cache.
    self.epoch,self.revision,self.highId,self.records=snapshot.epoch,snapshot.revision,highId,records
    return true
end
function R:Snapshot()
    local rows={};for _,row in pairs(self.records) do rows[#rows+1]=copy(row) end
    table.sort(rows,function(a,b) return a.id<b.id end)
    return {epoch=self.epoch,revision=self.revision,enemies=rows}
end
return R
