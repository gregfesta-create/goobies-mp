-- Host-owned enemy presentation through an injected adapter. No engine access.
-- Health/death remain authoritative; interpolation changes only displayed position.
local Replica=require('gmp_enemy_replica')
local V={};V.__index=V
local function copy(row) local out={};for k,v in pairs(row) do out[k]=v end;return out end
function V.new(adapter,options)
    options=options or {}
    assert(type(options.budget or 64)=='number' and (options.budget or 64)%1==0
        and (options.budget or 64)>=1 and (options.budget or 64)<=4096,'invalid_enemy_view_budget')
    return setmetatable({adapter=adapter,cache=Replica.new(),tracks={},failed={},
        interval=options.interval or .1,teleport=options.teleport or 2000,
        budget=options.budget or 64,order={},cursor=1,failClosed=options.failClosed==true},V)
end
function V:_remove(id)
    local ok,result=pcall(self.adapter.RemoveEnemy,self.adapter,id)
    if self.failClosed and (not ok or result~=true) then self.held='enemy_remove_failed';return false end
    self.tracks[id]=nil;self.failed[id]=nil
    return true
end
function V:_position(track,now)
    local alpha=math.min(1,math.max(0,(now-track.at)/self.interval))
    local row=copy(track.target)
    for _,axis in ipairs({'x','y','z'}) do row[axis]=track.from[axis]+(row[axis]-track.from[axis])*alpha end
    return row
end
function V:Apply(snapshot,now)
    if self.held then return false,self.held end
    if type(now)~='number' or now~=now or math.abs(now)==math.huge then return false,'invalid_time' end
    local oldEpoch=self.cache.epoch
    local ok,why=self.cache:Apply(snapshot);if not ok then return false,why end
    if oldEpoch~=snapshot.epoch then
        local ids={};for id in pairs(self.tracks) do ids[#ids+1]=id end
        for _,id in ipairs(ids) do if not self:_remove(id) then return false,self.held end end
    end
    local live={}
    for _,row in ipairs(self.cache:Snapshot().enemies) do
        if not row.dead then
            live[row.id]=true
            local track=self.tracks[row.id]
            local from=track and self:_position(track,now) or copy(row)
            local distance=(from.x-row.x)^2+(from.y-row.y)^2+(from.z-row.z)^2
            if distance>self.teleport^2 then from=copy(row) end
            self.tracks[row.id]={from=from,target=copy(row),at=now}
        end
    end
    local gone={};for id in pairs(self.tracks) do if not live[id] then gone[#gone+1]=id end end
    for _,id in ipairs(gone) do if not self:_remove(id) then return false,self.held end end
    self.order={};for id in pairs(self.tracks) do self.order[#self.order+1]=id end
    table.sort(self.order);self.cursor=math.min(self.cursor,math.max(1,#self.order))
    return true
end
function V:Tick(now)
    if self.held then return false,self.held end
    if type(now)~='number' or now~=now or math.abs(now)==math.huge then return end
    for _=1,math.min(self.budget,#self.order) do
        local id=self.order[self.cursor];self.cursor=self.cursor%#self.order+1
        local track=self.tracks[id]
        if (self.failed[id] or 0)<3 then
            local ok,result=pcall(self.adapter.SetEnemy,self.adapter,id,self:_position(track,now))
            if not ok or result~=true then
                self.failed[id]=(self.failed[id] or 0)+1
                -- Adapter must discard partially created visuals on RemoveEnemy.
                pcall(self.adapter.RemoveEnemy,self.adapter,id)
                if self.failClosed then self.held='enemy_present_failed';return false,self.held end
            else self.failed[id]=0 end
        end
    end
end
function V:Clear()
    local ids={};for id in pairs(self.tracks) do ids[#ids+1]=id end
    for _,id in ipairs(ids) do if not self:_remove(id) then return false,self.held end end
    self.cache=Replica.new()
    self.order={};self.cursor=1;self.held=nil
    return true
end
return V
