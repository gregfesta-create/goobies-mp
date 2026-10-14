-- Candidate adapter for the typed controller bridge. No raw addresses/userdata
-- cross its native boundary. Normal activation refuses partial coverage.
local A={};A.__index=A
local function finite(n,limit)return type(n)=='number' and n==n and math.abs(n)<=limit end
function A.new(api,presentation,options)
    assert(type(api)=='table' and type(api.configure)=='function' and type(api.status)=='function','missing_authority_bridge')
    assert(type(presentation)=='table' and type(presentation.SetEnemy)=='function'
        and type(presentation.RemoveEnemy)=='function','missing_enemy_presentation')
    return setmetatable({api=api,presentation=presentation,options=options or {}},A)
end
function A:Bind(context,generation,worldPath,controllerPath)
    if self.context then return false,'already_bound' end
    if type(context)~='string' or context=='' or #context>256 or not finite(generation,2^53-1)
        or generation<1 or generation%1~=0 then return false,'invalid_authority_context' end
    for _,path in ipairs({worldPath,controllerPath}) do
        if type(path)~='string' or path=='' or #path>512 or path:find('[^ -~]') then return false,'invalid_canonical_path' end
    end
    if type(worldPath)~='string' or type(controllerPath)~='string' then return false,'missing_canonical_path' end
    self.context,self.generation,self.worldPath,self.controllerPath=context,generation,worldPath,controllerPath
    return true
end
function A:SuppressLocalSimulation(context,enable)
    if context~=self.context or type(enable)~='boolean' then return false,'changed_context' end
    if enable and self.options.controllerOnlyDevelopmentTest~=true then
        -- Current bridge explicitly reports incomplete actor/projectile/reward
        -- coverage. Reject before mutation, rather than treating installed
        -- controller hooks as full multiplayer authority.
        return false,'production_coverage_incomplete'
    end
    if not enable and not self.attempted then return true end
    if enable and type(self.presentation.Bind)=='function' and not self.presentationBound then
        local bound,why=self.presentation:Bind(context)
        if bound~=true then return false,'presentation_binding_failed:'..tostring(why) end
        self.presentationBound=true
    end
    if not enable and type(self.presentation.Clear)=='function' then
        -- Retain native fences until owned graphics are removed and original
        -- visibility restored. An uncertain cleanup must remain held.
        local clean,why=self.presentation:Clear()
        if clean~=true then return false,'presentation_cleanup_failed:'..tostring(why) end
        self.presentationBound=false
    end
    self.attempted=true
    local ok,why=self.api.configure(self.generation,self.worldPath,self.controllerPath,enable)
    if ok==true then
        self.enabled=enable
        if enable and type(self.presentation.SuppressLocalMeshes)=='function' then
            local called,hidden,detail=pcall(self.presentation.SuppressLocalMeshes,self.presentation,true)
            if not called then detail=hidden;hidden=false end
            if hidden~=true then
                -- Caller receives failure and holds. Try restoring the exact
                -- visibility ledger and native slots; never claim enable.
                local restoreCall,restored=pcall(self.presentation.SuppressLocalMeshes,self.presentation,false)
                restored=restoreCall and restored
                local called,disabled=pcall(self.api.configure,self.generation,self.worldPath,self.controllerPath,false)
                if called and disabled==true then self.enabled=false end
                if restored==true and called and disabled==true then self.attempted=false end
                return false,'presentation_suppression_failed:'..tostring(detail)
            end
        elseif not enable then self.attempted=false end
    end
    return ok==true,why
end
-- Test 11: one proof per apply (BeginFrame .. EndFrame) instead of one per native write and drawn row (a native status
-- call plus an IsVisible read per original mesh each time). The game cannot run between the writes of one apply.
function A:BeginFrame(context)
    self.frameProof=nil
    if context==self.context then self.frameProof=self:LocalSimulationSuppressed(context) end
    return self.frameProof==true
end
function A:EndFrame() self.frameProof=nil end
function A:LocalSimulationSuppressed(context)
    if context~=self.context or not self.enabled then return false end
    if self.frameProof~=nil then return self.frameProof end
    local active,complete=self.api.status()
    local hidden=true
    if type(self.presentation.LocalMeshesSuppressed)=='function' then
        local ok,result=pcall(self.presentation.LocalMeshesSuppressed,self.presentation);hidden=ok and result==true
    end
    return active==true and hidden and (complete==true or self.options.controllerOnlyDevelopmentTest==true)
end
function A:SetEnemy(id,row)
    if not self:LocalSimulationSuppressed(self.context) then return false,'suppression_lost' end
    -- Host damage/HP are retained in the authoritative replica, never converted
    -- to a local attack or reward. Presentation may not run enemy game logic.
    return self.presentation:SetEnemy(id,row)
end
function A:RemoveEnemy(id)return self.presentation:RemoveEnemy(id)end
function A:HostSpawn(context,row)
    if context~=self.context or not self:LocalSimulationSuppressed(context) then return false,'suppression_lost' end
    if type(self.api.spawn)~='function' or type(row)~='table' or type(row.id)~='string'
        or #row.id>32 or not row.id:match('^%d+:%d+$') or not finite(row.x,2000000)
        or not finite(row.y,2000000) or row.z~=0 or not finite(row.enemyType,63)
        or row.enemyType<0 or row.enemyType%1~=0 or not finite(row.damage,1e12) or row.damage<0
        or not finite(row.hp,1e12) or row.hp<=0 then return false,'invalid_host_row' end
    return self.api.spawn(self.generation,row.id,row.x,row.y,row.enemyType,row.damage,row.hp)
end
function A:HostUpdate(context,slot,row)
    if context~=self.context or not self:LocalSimulationSuppressed(context) then return false,'suppression_lost' end
    if type(self.api.update)~='function' or not finite(slot,4095) or slot<0 or slot%1~=0
        or type(row)~='table' or type(row.id)~='string' or #row.id>32 or not row.id:match('^%d+:%d+$')
        or not finite(row.x,2000000) or not finite(row.y,2000000) or row.z~=0
        or not finite(row.enemyType,63) or row.enemyType<0 or row.enemyType%1~=0
        or not finite(row.damage,1e12) or row.damage<0 or not finite(row.hp,1e12) or row.hp<0
        then return false,'invalid_host_update' end
    return self.api.update(self.generation,row.id,slot,row.enemyType,row.x,row.y,row.damage,row.hp)
end
return A
