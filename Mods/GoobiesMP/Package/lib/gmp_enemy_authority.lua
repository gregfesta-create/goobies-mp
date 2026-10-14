-- Fail-closed client authority lifecycle. The runtime adapter must suppress
-- local spawn/AI/damage/rewards before host visuals are accepted. No engine
-- binding is guessed here: Enable requires verified adapter readback.
local View=require('gmp_enemy_view')
local A={};A.__index=A
function A.new(adapter,options)
    options=options or {}
    return setmetatable({adapter=adapter,view=View.new(adapter,options),state='idle'},A)
end
function A:Enable(context,host)
    if type(context)~='string' or context=='' or #context>256 or type(host)~='string' or host=='' or #host>64 then return false,'invalid_context' end
    if self.state~='idle' then return false,'already_enabled' end
    -- Retain the attempted context even if a native write partially succeeds;
    -- Disable must restore that exact controller rather than a nil/new world.
    self.context,self.host=context,host
    local ok,result=pcall(self.adapter.SuppressLocalSimulation,self.adapter,context,true)
    if not ok or result~=true then self.state='held';return false,'suppression_failed' end
    ok,result=pcall(self.adapter.LocalSimulationSuppressed,self.adapter,context)
    if not ok or result~=true then self.state='held';return false,'suppression_unverified' end
    self.context,self.host,self.state=context,host,'waiting';return true
end
function A:Apply(authenticatedHost,context,snapshot,now)
    if self.state~='waiting' and self.state~='active' then return false,'not_enabled' end
    if authenticatedHost~=self.host or context~=self.context then return false,'wrong_authority' end
    local ok,result=pcall(self.adapter.LocalSimulationSuppressed,self.adapter,context)
    if not ok or result~=true then self.state='held';return false,'suppression_lost' end
    local accepted,why=self.view:Apply(snapshot,now)
    if accepted then self.state='active' elseif self.view.held then self.state='held' end
    return accepted,why
end
function A:Tick(now)
    if self.state~='active' then return end
    local ok,result=pcall(self.adapter.LocalSimulationSuppressed,self.adapter,self.context)
    if not ok or result~=true then self.state='held';return false,'suppression_lost' end
    local updated,why=self.view:Tick(now)
    if updated==false then self.state='held';return false,why end
    return true
end
function A:Disable()
    if self.state=='idle' then return true end
    if self.view:Clear()==false then self.state='held';return false,'presentation_cleanup_failed' end
    local ok,result=pcall(self.adapter.SuppressLocalSimulation,self.adapter,self.context,false)
    if not ok or result~=true then self.state='held';return false,'restoration_failed' end
    self.context,self.host,self.state=nil,nil,'idle';return true
end
return A
