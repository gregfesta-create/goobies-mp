-- Compose native slices into one game-state domain without promoting partial
-- bindings to complete coverage. Each restore/readback consumes one tick.
local G={};G.__index=G
local function copy(value,seen,budget,depth)
    seen=seen or {};budget=budget or {n=0};depth=depth or 0
    budget.n=budget.n+1;assert(depth<=20 and budget.n<=100000,'slice_limit')
    local kind=type(value)
    if kind=='table' then
        assert(not seen[value] and not getmetatable(value),'invalid_slice_table');seen[value]=true
        local out={};for k,v in pairs(value) do
            assert(type(k)=='string' or type(k)=='number','invalid_slice_key')
            out[k]=copy(v,seen,budget,depth+1)
        end;seen[value]=nil;return out
    end
    assert(kind=='number' or kind=='string' or kind=='boolean' or kind=='nil','invalid_slice_value')
    if kind=='number' then assert(value==value and math.abs(value)<math.huge,'nonfinite_slice') end
    if kind=='string' then assert(#value<=4096,'slice_string_limit') end
    return value
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end;return true
end
function G.Detach(value)
    local ok,result=pcall(copy,value)
    return ok and result or nil
end
function G.new(slices)
    assert(type(slices)=='table' and #slices>0 and #slices<=16,'invalid_slice_group')
    local self=setmetatable({slices={},CompleteCapture=true,CompleteRestore=true},G);local seen={}
    for _,row in ipairs(slices) do
        assert(type(row.name)=='string' and not seen[row.name] and row.adapter,'invalid_slice')
        seen[row.name]=true;self.slices[#self.slices+1]={name=row.name,adapter=row.adapter}
        if row.adapter.CompleteCapture~=true then self.CompleteCapture=false end
        if row.adapter.CompleteRestore~=true then self.CompleteRestore=false end
    end
    return self
end
function G:Capture()
    local out={version=1,slices={}}
    for _,row in ipairs(self.slices) do
        local ok,state=pcall(row.adapter.Capture,row.adapter)
        if not ok or type(state)~='table' then return nil,'capture_failed:'..row.name end
        local accepted,detached=pcall(copy,state)
        if not accepted then return nil,'capture_invalid:'..row.name end
        out.slices[row.name]=detached
    end
    return out
end
function G:CancelCapture() self.capturePending=nil end
function G:CaptureStep(context)
    if type(context)~='string' or context=='' then self:CancelCapture();return false,'missing_capture_context' end
    if self.capturePending and self.capturePending.context~=context then
        self:CancelCapture();return false,'capture_context_changed'
    end
    self.capturePending=self.capturePending or {context=context,cursor=1,state={version=1,slices={}}}
    local pending=self.capturePending;local row=self.slices[pending.cursor]
    local ok,state=pcall(row.adapter.Capture,row.adapter)
    local detached=ok and type(state)=='table' and G.Detach(state)
    if not detached then self:CancelCapture();return false,'capture_failed:'..row.name end
    pending.state.slices[row.name]=detached;pending.cursor=pending.cursor+1
    if pending.cursor<=#self.slices then return nil,'capture_pending' end
    self.capturePending=nil;return true,pending.state
end
function G:ValidateRestore(state,manifest)
    if type(state)~='table' or state.version~=1 or type(state.slices)~='table' then return false,'invalid_group' end
    local count=0;for _ in pairs(state.slices) do count=count+1 end
    if count~=#self.slices then return false,'slice_count_changed' end
    for _,row in ipairs(self.slices) do
        local ok,value=pcall(row.adapter.ValidateRestore,row.adapter,state.slices[row.name],manifest)
        if not ok or value~=true then return false,'preflight_failed:'..row.name end
    end
    return true
end
function G:RestoreStep(state,manifest)
    if self.failed then return false,self.failed end
    if not self.pending then
        local ok,why=self:ValidateRestore(state,manifest);if not ok then return false,why end
        local accepted,target=pcall(copy,{state=state,manifest=manifest})
        if not accepted then return false,'invalid_group_target' end
        self.pending={target=target,cursor=1,phase='restore'}
    end
    local pending=self.pending;local row=self.slices[pending.cursor];local adapter=row.adapter
    local target=pending.target.state.slices[row.name]
    local ok,result,reason=pcall(function()
        if pending.phase=='restore' then
            return (adapter.RestoreStep or adapter.Restore)(adapter,target,pending.target.manifest)
        end
        if adapter.VerifyRestore then return adapter:VerifyRestore(target,pending.target.manifest) end
        local current=adapter:Capture()
        if adapter.MatchesCapture then return adapter:MatchesCapture(target,current) end
        return equal(target,current)
    end)
    if ok and result==nil and pending.phase=='restore' and adapter.RestoreStep then return nil,'restore_pending' end
    if not ok or result~=true then
        self.failureDetail=tostring(adapter.failureDetail or (ok and reason or result)):sub(1,650)
        self.failed=pending.phase..'_failed:'..row.name;self.pending=nil;return false,self.failed
    end
    pending.cursor=pending.cursor+1
    if pending.cursor>#self.slices then
        if pending.phase=='restore' then pending.phase='verify';pending.cursor=1
        else self.pending=nil;return true end
    end
    return nil,'restore_pending'
end
function G:Restore(state,manifest) return self:RestoreStep(state,manifest) end
function G:VerifyRestore(state,manifest)
    if self.failed or self.pending then return false,'group_not_restored' end
    if type(state)~='table' or type(state.slices)~='table' then return false,'invalid_group' end
    for _,row in ipairs(self.slices) do
        local adapter=row.adapter;local target=state.slices[row.name]
        local ok,result=pcall(function()
            if adapter.VerifyRestore then return adapter:VerifyRestore(target,manifest) end
            local current=adapter:Capture()
            if adapter.MatchesCapture then return adapter:MatchesCapture(target,current) end
            return equal(target,current)
        end)
        if not ok or result~=true then return false,'readback_failed:'..row.name end
    end
    return true
end
return G
