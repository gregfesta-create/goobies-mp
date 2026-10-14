-- Host-authenticated boss/miniboss presentation contract. Backend handles are
-- mod-owned components, never gameplay BP_Boss/BP_MiniBoss actors. Removal must
-- not invoke BossDeath/BossDead/UpdateHP/DestroyActor or local rewards/XP.
local V={};V.__index=V
local function finite(n,b)return type(n)=='number' and n==n and math.abs(n)<=b end
local function text(s,max)return type(s)=='string' and #s>0 and #s<=max end
function V.new(backend,options)
 options=options or {}
 for _,name in ipairs({'Context','Ready','TemplateAllowed','CreateVisual','UpdateVisual','RemoveVisual'})do
  assert(type(backend[name])=='function','missing_actor_view_backend:'..name)
 end
 local budget=options.budget or 16;assert(finite(budget,64) and budget>=1 and budget%1==0,'invalid_actor_budget')
 return setmetatable({backend=backend,budget=budget,tracks={},order={},cursor=1,revision=0,state='idle'},V)
end
function V:Bind(context,host)
 if self.state~='idle' or not text(context,256) or not text(host,64) then return false,'invalid_actor_binding' end
 if self.backend:Context()~=context or self.backend:Ready(context)~=true then return false,'actor_backend_unverified' end
 self.context,self.host,self.state=context,host,'active';return true
end
function V:Apply(sender,context,revision,rows)
 if self.state~='active' or sender~=self.host or context~=self.context or self.backend:Context()~=context
  then return false,'unauthenticated_actor_state' end
 if not finite(revision,2147483647) or revision%1~=0 or revision<=self.revision
  or type(rows)~='table' or #rows>256 then return false,'invalid_actor_revision' end
 for key in pairs(rows)do if type(key)~='number' or key%1~=0 or key<1 or key>#rows then return false,'invalid_actor_array' end end
 local validated,order={},{}
 for _,r in ipairs(rows)do
  if type(r)~='table' or not text(r.id,32) or not r.id:match('^%d+:%d+$') or r.context~=context
   or not text(r.classPath,512) or not text(r.meshPath,512) or validated[r.id]
   or not finite(r.hp,1e12) or r.hp<0 or not finite(r.damage,1e12) or r.damage<0
   or type(r.dead)~='boolean' or r.dead~=(r.hp<=0) or not finite(r.x,2000000) or not finite(r.y,2000000)
   or not finite(r.z,2000000) or not finite(r.pitch,360000) or not finite(r.yaw,360000) or not finite(r.roll,360000)
   or self.backend:TemplateAllowed(context,r.classPath,r.meshPath)~=true then return false,'invalid_actor_row' end
  local old=self.tracks[r.id]
  if old and (old.row.classPath~=r.classPath or old.row.meshPath~=r.meshPath) then return false,'actor_lifetime_template_changed' end
  local row={};for _,k in ipairs({'id','context','classPath','meshPath','hp','damage','dead','x','y','z','pitch','yaw','roll'})do row[k]=r[k]end
  validated[r.id]={row=row,handle=old and old.handle,remove=old and old.remove};order[#order+1]=r.id
 end
 -- Keep missing lifetimes until their owned visual cleanup is confirmed.
 for id,old in pairs(self.tracks)do
  if not validated[id] then validated[id]={row=old.row,handle=old.handle,remove=true};order[#order+1]=id end
 end
 if #order>256 then return false,'actor_cleanup_backpressure' end
 self.tracks,self.order,self.cursor,self.revision=validated,order,1,revision;return true
end
function V:Tick()
 if self.state~='active' then return false,self.state end
 local b=self.backend
 if b:Context()~=self.context or b:Ready(self.context)~=true then self.state='held';return false,'actor_binding_lost' end
 local count=0
 while count<self.budget and count<#self.order do
  if self.cursor>#self.order then self.cursor=1 end
  local id=self.order[self.cursor];self.cursor=self.cursor+1;count=count+1
  local track=self.tracks[id]
  if track then
   local ok,result,handle
   if track.remove or track.row.dead then
    if track.handle then ok,result=pcall(b.RemoveVisual,b,self.context,track.handle)
    else ok,result=true,true end
    if ok and result==true then self.tracks[id]=nil end
   elseif not track.handle then
    ok,result,handle=pcall(b.CreateVisual,b,self.context,track.row)
    if ok and result==true and handle~=nil then track.handle=handle
    else result=false end
   else ok,result=pcall(b.UpdateVisual,b,self.context,track.handle,track.row) end
   if not ok or result~=true then
    -- A partial create/update/remove must retain backend ownership and stop,
    -- never retry gameplay writes or fabricate an actor death notification.
    self.state='held';return false,'actor_visual_result_uncertain'
   end
  end
 end
 local compact={};for _,id in ipairs(self.order)do if self.tracks[id] then compact[#compact+1]=id end end
 self.order=compact;if self.cursor>#compact then self.cursor=1 end
 return true,count
end
return V
