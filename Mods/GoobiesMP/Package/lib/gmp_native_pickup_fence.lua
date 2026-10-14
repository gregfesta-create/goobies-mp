-- Exact canonical-path bridge. Partial fence is dev-only until pickup removal,
-- shared progression and every actor/native reward route are actually bound.
local F={};F.__index=F
local function path(v)return type(v)=='string' and #v>0 and #v<=512 and not v:find('[^ -~]')end
function F.new(api,options)
 assert(type(api.configure)=='function' and type(api.status)=='function','missing_pickup_bridge')
 return setmetatable({api=api,options=options or {}},F)
end
function F:Bind(context,generation,world,controller,pawn,component)
 if self.context then return false,'already_bound' end
 if type(context)~='string' or #context==0 or #context>256 or type(generation)~='number'
  or generation~=generation or generation<1 or generation>9007199254740991 or generation%1~=0
  or not path(world) or not path(controller) or not path(pawn) or not path(component) then return false,'invalid_pickup_context' end
 self.context=context;self.arguments={generation,world,controller,pawn,component};return true
end
function F:SetEnabled(context,enable)
 if context~=self.context or type(enable)~='boolean' then return false,'context_changed' end
 if enable and self.options.partialDevelopmentTest~=true then return false,'pickup_production_coverage_incomplete' end
 if enable and self.attempted then return false,'already_attempted' end
 if not enable and not self.attempted then return true end
 self.attempted=true
 local a=self.arguments
 local ok,result,reason=pcall(self.api.configure,a[1],a[2],a[3],a[4],a[5],enable)
 if not ok or result~=true then self.held=true;return false,ok and reason or 'pickup_bridge_exception' end
 self.enabled=enable;self.held=false
 if not enable then self.attempted=false end
 return true,reason
end
function F:Status(context)
 if context~=self.context or not self.enabled or self.held then return false,false end
 local ok,active,coverage,component,consumable,award=pcall(self.api.status)
 if not ok or active~=true then self.held=true;return false,false end
 -- Never promote current bridge's partial coverage to production readiness.
 return true,false,{component=component,consumable=consumable,award=award}
end
return F
