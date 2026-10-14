-- Retained local inventory restoration slice. Never replays AddItem: doing so
-- would duplicate upgrades and attached actors when retaining the same pawn.
-- Item cooldowns/projectiles, artifacts and class state are still incomplete.
local I={};I.__index=I
I.CompleteCapture=false;I.CompleteRestore=false
local fields={
    kills='Kills_4_2CBACF3A486DC27417BFF2BFE23A8451',
    damage='TotalDamageDelt_17_C823B38243634D0166EC8CA2D79203CC',
    count='NumCollected_7_A4C3B001471A3E366A566191AC40FDA9',
    upgrades='UnlockedUpgrades_16_1D25DE86425CD431AED442AD6255BF75',
    index='DT_Index_10_DA87FC3B45CF8A29713D1081E578E10D',
    locked='Locked?_13_01A7AD794E506FB0B4EE0DB948FB01DB',
    itemType='ItemType_21_56354C4641B9F826F82D1DA345F74D80'}
I.Fields=fields
local function integer(v) return type(v)=='number' and v==v and v%1==0 and v>=0 and v<=9007199254740991 end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function I.new(world) return setmetatable({world=world},I) end
function I:Capture()
    local ok,value=pcall(function()
        local world=self.world:_world();local pawn=world and self.world:_pawn(world)
        if not pawn or pawn.PlayerIsDead~=false then return nil end
        local out={version=1,pawn=pawn:GetFullName(),items={},actors={}}
        assert(#pawn.PerItemStats<=256 and #pawn.PlayerItemsActors<=256,'inventory_limit')
        pawn.PerItemStats:ForEach(function(_,element)
            local row=element:get();local item={}
            for key,field in pairs(fields) do
                local v=row[field]
                if key=='locked' then assert(type(v)=='boolean','invalid_locked')
                elseif key=='index' then
                    -- BP_Player initializes its built-in passive item to -1;
                    -- GetItemStats/SaveStats explicitly skip that sentinel.
                    assert(v==-1 or (integer(v) and v<=2147483647),'invalid_item_number:index')
                else assert(integer(v),'invalid_item_number:'..key) end
                item[key]=v
            end
            out.items[#out.items+1]=item
        end)
        pawn.PlayerItemsActors:ForEach(function(_,element)
            local actor=element:get();assert(actor and actor:IsValid(),'missing_item_actor')
            out.actors[#out.actors+1]=actor:GetFullName()
        end)
        local current=self.world:_pawn(world)
        assert(current and current:GetFullName()==out.pawn and current.PlayerIsDead==false,'inventory_context_changed')
        return out
    end)
    if not ok then return nil,'inventory_binding_error:'..tostring(value):gsub('[\r\n]',' '):sub(1,1200) end
    if not value then return nil,'unsupported_inventory_state' end
    return value
end
function I:ValidateRestore(state)
    local current=self:Capture()
    if not current or type(state)~='table' or state.version~=1
        or state.pawn~=current.pawn or not equal(state.actors,current.actors)
        or type(state.items)~='table' or #state.items~=#current.items then
        return false,'inventory_continuity_mismatch'
    end
    for n,item in ipairs(current.items) do
        local saved=state.items[n]
        if type(saved)~='table' or not integer(saved.kills) or not integer(saved.damage) then
            return false,'invalid_item_counters'
        end
        for key in pairs(fields) do
            if key~='kills' and key~='damage' and saved[key]~=item[key] then
                return false,'inventory_continuity_mismatch'
            end
        end
    end
    return true
end
function I:Restore(state)
    local valid,reason=self:ValidateRestore(state)
    if not valid then return false,reason end
    local world=self.world:_world();local statics=self.world:_statics()
    if not world or not statics then return false,'missing_world' end
    local ok,dilation=pcall(statics.GetGlobalTimeDilation,statics,world)
    if not ok or type(dilation)~='number' or dilation~=dilation or dilation<=0 or dilation>.001 then return false,'not_paused' end
    local before=self:Capture()
    if not before then return false,'inventory_capture_changed' end
    local function write(value)
        assert(self:ValidateRestore(value),'inventory_changed')
        local pawn=self.world:_pawn(world)
        local n=0
        pawn.PerItemStats:ForEach(function(_,element)
            n=n+1;local row=element:get();local saved=value.items[n]
            row[fields.kills]=saved.kills;row[fields.damage]=saved.damage
        end)
        assert(equal(self:Capture(),value),'inventory_readback_failed')
    end
    local applied,why=pcall(write,state)
    if applied then self.failure=nil;self.rollbackSucceeded=nil;return true end
    self.failure=tostring(why);self.rollbackSucceeded=pcall(write,before)
    return false,'native_inventory_write_failed'
end
return I
