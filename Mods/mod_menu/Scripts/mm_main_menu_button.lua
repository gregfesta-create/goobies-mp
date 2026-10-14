-- Shared native main-menu entry construction. Blueprint Construct consumes
-- ButtonText/FontSize; addons never copy a live Slate Font or effect widget.
local B={}
local function valid(o)return o and o:IsValid()end
local function copy(s)local p=s.Padding;return {pad={Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom},h=s.HorizontalAlignment,v=s.VerticalAlignment,size={SizeRule=s.Size.SizeRule,Value=s.Size.Value}}end
local function apply(s,v)s:SetPadding(v.pad);s:SetHorizontalAlignment(v.h);s:SetVerticalAlignment(v.v);s:SetSize(v.size)end
function B.Create(G,Widgets,menu,d)
 assert(type(d)=='table' and type(d.id)=='string' and d.id:match('^[%w_%-]+$') and type(d.label)=='string' and #d.label>0 and #d.label<=64 and type(d.onClick)=='function','Invalid main-menu button descriptor')
 assert(d.styleRole=='secondary' or d.styleRole=='primary','Unknown main-menu style role')
 local after,before=menu[d.after],menu[d.before]
 assert(valid(after) and valid(before),'Main-menu placement anchors unavailable')
 local column=after:GetParent();local tail,found={},false
 for i=0,column:GetChildrenCount()-1 do local child=column:GetChildAt(i)
  if found then tail[#tail+1]={widget=child,slot=copy(child.Slot)}end
  if child:GetFullName()==after:GetFullName()then found=true end
 end
 local beforeFound=false;for _,row in ipairs(tail)do if row.widget:GetFullName()==before:GetFullName()then beforeFound=true end end
 assert(found and beforeFound,'Main-menu anchor order unavailable')
 local reference=d.styleRole=='primary' and menu.Play or menu.upgrades
 assert(valid(reference) and valid(reference.t_text),'Native button style unavailable')
 local fontSize=reference.t_text.Font.Size
 assert(type(fontSize)=='number' and fontSize>=1 and fontSize<=256,'Native button font unavailable')
 local lib=G.StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
 local entry=lib:Create(menu,G.StaticFindObject('/Game/UI/WBP_Button.WBP_Button_C'),nil)
 assert(valid(entry),'Main-menu button creation failed')
 local handle={widget=entry,id=d.id,menu=menu,active=false,styleRole=d.styleRole,baseFontSize=fontSize}
 handle.onClick=function()if not handle.active or not valid(entry)then return false end;return d.onClick()end
 function handle:Restore()
  if not self.restore then return true end
  self.restore();self.restore=nil;return true
 end
 function handle:Remove()
  self.active=false;self.cleanupPending=true;self:Restore();entry:RemoveFromParent();self.cleanupPending=false;return true
 end
 function handle:Tick(log)
  self:Restore()
  if not self.geometryPending or not self.active then return end
  local ok,line=pcall(function()
   local a,b=entry.t_text,reference.t_text;local x,y=a:GetDesiredSize(),b:GetDesiredSize()
   if x.Y<=0 or y.Y<=0 then return end
   return 'Main-menu button '..d.id..': font='..a.Font.Size..'/'..b.Font.Size..'; desiredY='..x.Y..'/'..y.Y..'; stretch='..entry.WidgetTree.RootWidget.Stretch
  end)
  if ok and line then self.geometryPending=false;if type(log)=='function'then pcall(log,line)end end
 end
 local ok,why=pcall(function()
  entry.FontSize=fontSize;entry.ButtonText=G.FText(d.label);Widgets.buttonText(G,entry,d.label)
  entry.WidgetTree.RootWidget:SetStretch(0)
  apply(column:AddChildToVerticalBox(entry),copy(reference.Slot))
  for _,row in ipairs(tail)do row.widget:RemoveFromParent()end
  for _,row in ipairs(tail)do apply(column:AddChildToVerticalBox(row.widget),row.slot)end
 end)
 if not ok then
  handle.restore=function()
   local errors={};local function attempt(fn)local good,err=pcall(fn);if not good then errors[#errors+1]=tostring(err)end end
   attempt(function()entry:RemoveFromParent()end)
   for _,row in ipairs(tail)do attempt(function()row.widget:RemoveFromParent()end)end
   for _,row in ipairs(tail)do attempt(function()
    local parent=row.widget:GetParent()
    if not valid(parent)or parent:GetFullName()~=column:GetFullName()then local added=pcall(function()column:AddChild(row.widget)end);if not added then column:AddChildToVerticalBox(row.widget)end end
   end)end
   for _,row in ipairs(tail)do attempt(function()apply(row.widget.Slot,row.slot)end)end
   if #errors>0 then error(table.concat(errors,'; '))end
  end
  local restored,err;for _=1,2 do restored,err=pcall(handle.Restore,handle);if restored then break end end
  handle.cleanupPending=not restored
  return nil,'Main-menu insertion canceled: '..tostring(why)..(restored and '; restored' or '; restoration pending: '..tostring(err)),handle
 end
 handle.active=true;handle.geometryPending=true;return handle
end
return B
