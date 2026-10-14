-- Native delivery wrapper. The capture provider must return complete native
-- lifetime snapshots for every affected domain; a Boolean hit result is never
-- a death/XP receipt. Publication receives both sides even after dispatch fails.
local A={};A.__index=A
local domains={'ordinary','actors','pickups','rewards'}
local function detach(value,maxNodes)
 local nodes=0;local active={}
 local function walk(v,depth)
  nodes=nodes+1;if nodes>maxNodes or depth>8 then error('outcome_snapshot_bound')end
  local kind=type(v)
  if kind=='number' then if v~=v or math.abs(v)==math.huge then error('outcome_nonfinite')end;return v end
  if kind=='boolean' or kind=='nil' then return v end
  if kind=='string' then if #v>256 then error('outcome_string_bound')end;return v end
  if kind~='table' or getmetatable(v)~=nil or active[v] then error('outcome_not_detached_data')end
  active[v]=true;local out={}
  for key,item in pairs(v)do
   if type(key)~='string' and type(key)~='number' then error('outcome_key_type')end
   out[walk(key,depth+1)]=walk(item,depth+1)
  end
  active[v]=nil;return out
 end
 return walk(value,0)
end
local function snapshot(value,context,maxRows)
 if type(value)~='table' or value.context~=context or value.complete~=true
  or type(value.generation)~='string' or value.generation=='' then return false end
 local total=0
 for _,name in ipairs(domains)do
  local part=value[name]
  if type(part)~='table' or part.complete~=true or type(part.rows)~='table'
   then return false end
  total=total+#part.rows;if total>maxRows then return false end
  local count=0
  for key in pairs(part.rows)do
   if type(key)~='number' or key%1~=0 or key<1 or key>#part.rows then return false end
   count=count+1
  end
  if count~=#part.rows then return false end
 end
 return true
end
function A.new(native,capture,sink,options)
 options=options or {}
 local maxRows,maxNodes=options.maxRows or 128,options.maxNodes or 4096
 assert(type(maxRows)=='number' and maxRows%1==0 and maxRows>=1 and maxRows<=512,'damage_audit_row_budget')
 assert(type(maxNodes)=='number' and maxNodes%1==0 and maxNodes>=64 and maxNodes<=16384,'damage_audit_node_budget')
 for _,spec in ipairs({{native,{'Bound','ApplyHostHit'}},{capture,{'Verified','Capture'}},
  {sink,{'Verified','Publish','Hold'}}})do
  assert(type(spec[1])=='table','missing_damage_audit_provider')
  for _,name in ipairs(spec[2])do assert(type(spec[1][name])=='function','missing_damage_audit_method:'..name)end
 end
 return setmetatable({native=native,capture=capture,sink=sink,held={},serial=0,maxRows=maxRows,maxNodes=maxNodes},A)
end
function A:Bound(context)
 return not self.held[context] and self.native:Bound(context)==true
  and self.capture:Verified(context)==true and self.sink:Verified(context)==true
end
function A:_hold(context,reason,receipt)
 self.held[context]=true
 -- Retain evidence even if the external hold callback itself fails.
 self.last=receipt
 pcall(self.sink.Hold,self.sink,context,reason,receipt)
end
function A:ApplyHostHit(context,...)
 if not self:Bound(context) or self.serial>=9007199254740991 then return false end
 local beforeOK,before=pcall(function()return detach(self.capture:Capture(context),self.maxNodes)end)
 if not beforeOK or not snapshot(before,context,self.maxRows) then
  self:_hold(context,'pre_dispatch_capture_failed');return false
 end
 if not self:Bound(context) then return false end
 self.serial=self.serial+1
 -- Reserve and retain before entering native code. Never replay after uncertainty.
 local receipt={context=context,serial=self.serial,before=before,attempted=true}
 self.last=receipt
 local callOK,result=pcall(self.native.ApplyHostHit,self.native,context,...)
 receipt.dispatchSucceeded=callOK and result==true
 local afterOK,after=pcall(function()return detach(self.capture:Capture(context),self.maxNodes)end)
 if not afterOK or not snapshot(after,context,self.maxRows) or after.generation~=before.generation then
  self:_hold(context,'post_dispatch_capture_failed',receipt);return false
 end
 receipt.after=after
 -- A world generation can survive a host/term change. Retain evidence locally,
 -- but never publish it under withdrawn native/session ownership.
 if not self:Bound(context) then self:_hold(context,'post_dispatch_authority_withdrawn',receipt);return false end
 -- Publish actual changes even if native delivery threw after mutating the world.
 local publishOK,published=pcall(self.sink.Publish,self.sink,receipt)
 receipt.published=publishOK and published==true
 if not receipt.dispatchSucceeded or not receipt.published then
  self:_hold(context,not receipt.dispatchSucceeded and 'uncertain_native_dispatch' or 'outcome_publication_failed',receipt)
  return false
 end
 return true
end
return A
