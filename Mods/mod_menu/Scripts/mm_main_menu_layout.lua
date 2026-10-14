-- One layout owner for native controls and all addon entries. Dimensions are
-- UMG logical units; the minimum gap is converted from physical pixels.
local L={};L.__index=L
local function finite(n)return type(n)=='number' and n==n and n>0 and n<math.huge end
local function valid(o)return o and o:IsValid()end
local function name(o)return o:GetFullName()end
local function nativeChild(root,shortName,className)
 local queue={{widget=root,depth=0}};local seen={};local found;local cursor=1
 while cursor<=#queue do
  assert(cursor<=512,'Native widget tree exceeds lookup bound')
  local node=queue[cursor];cursor=cursor+1;local o=node.widget
  if valid(o)then
   local key=name(o)
   if not seen[key]then
    seen[key]=true
    local class=o:GetClass():GetFullName()
    if key:match('[%.:]'..shortName..'$')and (class==className or class:match('[%.:]'..className..'$'))then
     assert(not found,'Ambiguous native footer widget: '..shortName);found=o
    end
    local panel,count=pcall(function()return o:GetChildrenCount()end)
    if panel then
     assert(type(count)=='number'and count>=0 and count%1==0 and count<=256,'Native widget child count invalid')
     assert(node.depth<32 or count==0,'Native widget depth exceeds lookup bound')
     assert(#queue+count<=512,'Native widget tree exceeds lookup bound')
     for i=0,count-1 do queue[#queue+1]={widget=o:GetChildAt(i),depth=node.depth+1}end
    end
   end
  end
 end
 return found
end
local function padding(p)return {Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom}end
local function equalPad(a,b)return a and b and a.Left==b.Left and a.Top==b.Top and a.Right==b.Right and a.Bottom==b.Bottom end
local function envelope(o,p)
 local size=o:GetDesiredSize();assert(finite(size.Y),'Awaiting native button layout')
 local height=size.Y+p.Top+p.Bottom
 if valid(o.t_text)then
  local text=o.t_text:GetDesiredSize();local scale=o.t_text.RenderTransform.Scale.Y
  assert(finite(scale),'Invalid styled button scale')
  if finite(text.Y)then height=math.max(height,text.Y*scale)end
 end
 return height,size.Y
end
function L.Plan(width,height,dpi,rows,footer,columnWidth)
 assert(finite(width) and finite(height) and finite(dpi),'Invalid viewport')
 assert(type(rows)=='table' and #rows>0 and #rows<=256,'Invalid button count')
 local gap=10/dpi;local margin=20/dpi;local fh=0;local fw=0
 for _,s in ipairs(footer)do assert(finite(s.X) and finite(s.Y),'Footer not measured');fh=fh+s.Y;fw=math.max(fw,s.X)end
 fh=fh+math.max(0,#footer-1)*gap
 assert(fw<=width/dpi-2*margin,'Footer exceeds viewport width')
 if columnWidth then assert(finite(columnWidth)and columnWidth<=width/dpi-2*margin,'Button column exceeds viewport width')end
 local bottom=height/dpi-margin;local top=bottom-fh
 local start=margin;local available=top-gap-start;assert(available>=40/dpi,'Viewport cannot contain footer and menu')
 local natural=0;for _,h in ipairs(rows)do assert(finite(h),'Button not measured');natural=natural+h end
 local minHeight=natural+math.max(0,#rows-1)*gap
 local scroll=minHeight>available
 local spacing=scroll and gap or (#rows>1 and math.max(gap,(available-natural)/(#rows-1)) or 0)
 return {gap=spacing,minGap=gap,scroll=scroll,menuTop=start,menuHeight=available,
  footerX=math.max(margin,width/dpi-margin-fw),footerY=top,footerWidth=fw,footerHeight=fh,
  contentHeight=natural+math.max(0,#rows-1)*spacing}
end
local function slotCopy(s)
 local kind=s:GetClass():GetFullName()
 if kind:find('CanvasPanelSlot',1,true)then
  local d=s.LayoutData;local a=d.Anchors;local o=d.Offsets;local v=d.Alignment
  return {kind='canvas',anchors={Minimum={X=a.Minimum.X,Y=a.Minimum.Y},Maximum={X=a.Maximum.X,Y=a.Maximum.Y}},
   offsets={Left=o.Left,Top=o.Top,Right=o.Right,Bottom=o.Bottom},align={X=v.X,Y=v.Y},auto=s.bAutoSize,z=s.ZOrder}
 end
 assert(kind:find('VerticalBoxSlot',1,true)or kind:find('HorizontalBoxSlot',1,true)or kind:find('OverlaySlot',1,true),'Unsupported native parent slot')
 local p=s.Padding;local v={kind='panel',pad={Left=p.Left,Top=p.Top,Right=p.Right,Bottom=p.Bottom},h=s.HorizontalAlignment,v=s.VerticalAlignment}
 if not kind:find('OverlaySlot',1,true)then v.size={SizeRule=s.Size.SizeRule,Value=s.Size.Value}end
 return v
end
local function slotApply(s,v)
 if v.kind=='canvas'then s:SetMinimum(v.anchors.Minimum);s:SetMaximum(v.anchors.Maximum);s:SetOffsets(v.offsets);s:SetAlignment(v.align);s:SetAutoSize(v.auto);s:SetZOrder(v.z)
 else s:SetPadding(v.pad);s:SetHorizontalAlignment(v.h);s:SetVerticalAlignment(v.v);if v.size then s:SetSize(v.size)end end
end
local function ancestor(o,root)
 for _=1,32 do if not valid(o)then return false end;if name(o)==name(root)then return true end;o=o:GetParent()end
 return false
end
local function dimensions(G,menu,root)
 local lib=G.StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
 local viewport=lib:GetViewportSize(menu)
 local slate=G.StaticFindObject('/Script/UMG.Default__SlateBlueprintLibrary')
 local geometry=root:GetCachedGeometry();local size=slate:GetLocalSize(geometry)
 assert(finite(size.X)and finite(size.Y)and finite(viewport.X)and finite(viewport.Y),'Awaiting native root geometry')
 -- Measure the actual Slate transform, including DPI and letterboxing. Root
 -- local height need not span the viewport, so viewport/local is insufficient.
 local origin=slate:LocalToAbsolute(geometry,{X=0,Y=0})
 local x=slate:LocalToAbsolute(geometry,{X=1,Y=0})
 local y=slate:LocalToAbsolute(geometry,{X=0,Y=1})
 local sx,sy=x.X-origin.X,y.Y-origin.Y
 assert(finite(sx)and finite(sy)and math.abs(x.Y-origin.Y)<0.001 and math.abs(y.X-origin.X)<0.001,'Unsupported rotated root geometry')
 return size.X*sy,size.Y*sy,sy,sx
end
function L.Bind(G,w,menu)
 local column=menu.Play:GetParent()
 local root=menu.WidgetTree.RootWidget
 assert(valid(root)and root:GetClass():GetFullName():find('CanvasPanel',1,true),'Main-menu root is not a verified CanvasPanel')
 -- Some designer widgets are not IsVariable and have no UserWidget field.
 -- Locate only the pinned exact native name/class; never create a replacement.
 local version=menu.versionnumber
 if not valid(version)then version=nativeChild(root,'versionnumber','HorizontalBox')end
 local footer={menu.WBP_Leaderboard and menu.WBP_Leaderboard.button_toggleLeaderboard,menu.wishlistnewgame,version}
 for i=1,3 do assert(valid(footer[i]),'Native footer controls unavailable: '..i)end
 assert(valid(column)and ancestor(column,root),'Main-menu column hierarchy changed')
 local snapshots,seen={},{}
 local function capture(o)
  assert(valid(o)and ancestor(o,root),'Footer hierarchy unavailable')
  local parent=o:GetParent();assert(valid(parent),'Native parent missing')
  local key=name(parent);if seen[key]then return end;seen[key]=true
  local rows={};for i=0,parent:GetChildrenCount()-1 do local child=parent:GetChildAt(i);rows[#rows+1]={widget=child,slot=slotCopy(child.Slot)}end
  snapshots[#snapshots+1]={parent=parent,rows=rows}
 end
 capture(column);for _,o in ipairs(footer)do capture(o)end
 for _,o in ipairs(footer)do local s=o:GetDesiredSize();assert(finite(s.X)and finite(s.Y),'Awaiting native footer measurement')end
 for i=0,column:GetChildrenCount()-1 do assert(finite(column:GetChildAt(i):GetDesiredSize().Y),'Awaiting native button measurement')end
 local vpw,vph,scale=dimensions(G,menu,root)
 local rowSizes,footerSizes={},{}
 for i=0,column:GetChildrenCount()-1 do rowSizes[#rowSizes+1]=column:GetChildAt(i):GetDesiredSize().Y end
 for _,o in ipairs(footer)do local s=o:GetDesiredSize();footerSizes[#footerSizes+1]={X=s.X,Y=s.Y}end
 L.Plan(vpw,vph,scale,rowSizes,footerSizes,column:GetDesiredSize().X)
 -- All original hierarchy/slot checks precede construction and native writes.
 local self=setmetatable({G=G,w=w,menu=menu,root=root,column=column,footer=footer,snapshots=snapshots,rows={},active=false},L)
 function self:Restore()
  self.active=false;local errors={};local function attempt(fn)local ok,e=pcall(fn);if not ok then errors[#errors+1]=tostring(e)end end
  if not valid(self.menu)then self.restored=true;return true end
  -- Preserve addon changes made after binding: only reparent the moved widgets.
  for _,o in ipairs({column,footer[1],footer[2],footer[3]})do attempt(function()if valid(o)then o:RemoveFromParent()end end)end
  for _,snapshot in ipairs(self.snapshots)do
   for _,row in ipairs(snapshot.rows)do attempt(function()if valid(row.widget)then row.widget:RemoveFromParent()end end)end
   for _,row in ipairs(snapshot.rows)do attempt(function()if valid(snapshot.parent)and valid(row.widget)then snapshot.parent:AddChild(row.widget)end end)end
   for _,row in ipairs(snapshot.rows)do attempt(function()if valid(snapshot.parent)and valid(row.widget)then slotApply(row.widget.Slot,row.slot)end end)end
  end
  for _,row in pairs(self.rows)do attempt(function()if valid(row.widget)then row.widget.Slot:SetPadding(row.pad)end end)end
  for _,o in ipairs({self.scroll,self.footerBox})do if o then attempt(function()o:RemoveFromParent()end)end end
  if #errors>0 then error(table.concat(errors,'; '))end;self.restored=true;return true
 end
 local ok,why=pcall(function()
  self.scroll=w:create('ScrollBox');self.scroll:SetClipping(1)
  self.footerBox=w:create('VerticalBox')
  root:AddChildToCanvas(self.scroll);root:AddChildToCanvas(self.footerBox)
  column:RemoveFromParent();self.scroll:AddChild(column)
  for _,o in ipairs(footer)do o:RemoveFromParent();local s=self.footerBox:AddChildToVerticalBox(o);s:SetHorizontalAlignment(2);s:SetSize({SizeRule=0,Value=1})end
  self.active=true
 end)
 if not ok then local restored,e=pcall(self.Restore,self);return nil,tostring(why),not restored and self or nil,e end
 return self
end
function L:Tick()
 assert(self.active,'Layout inactive')
 local vpw,vph,dpi,sx=dimensions(self.G,self.menu,self.root)
 local heights,children={},{}
 for i=0,self.column:GetChildrenCount()-1 do
  local o=self.column:GetChildAt(i);local key=name(o);local row=self.rows[key]
  local current=padding(o.Slot.Padding)
  if not row then row={widget=o,pad=current};self.rows[key]=row
  elseif not equalPad(current,row.applied)then row.pad=current end
  -- Desired button content is independent of our outer slot padding.
  local height,native=envelope(o,row.pad);row.nativeHeight=native
  children[#children+1]=o;heights[#heights+1]=height
 end
 local sizes={};for _,o in ipairs(self.footer)do local s=o:GetDesiredSize();if not finite(s.X)or not finite(s.Y)then return false,'Awaiting native footer layout'end;sizes[#sizes+1]={X=s.X,Y=s.Y}end
 local width=self.column:GetDesiredSize().X;assert(finite(width),'Column not measured')
 local plan=L.Plan(vpw,vph,dpi,heights,sizes,width)
 local ss=self.scroll.Slot;ss:SetMinimum({X=0,Y=0});ss:SetMaximum({X=0,Y=0});ss:SetAlignment({X=0,Y=0})
 ss:SetPosition({X=20/dpi,Y=plan.menuTop});ss:SetSize({X=width,Y=plan.menuHeight})
 local fs=self.footerBox.Slot;fs:SetMinimum({X=0,Y=0});fs:SetMaximum({X=0,Y=0});fs:SetAlignment({X=0,Y=0})
 fs:SetPosition({X=plan.footerX,Y=plan.footerY});fs:SetSize({X=plan.footerWidth,Y=plan.footerHeight})
 for i,o in ipairs(children)do
  local row=self.rows[name(o)];local p=row.pad
  local extra=math.max(0,heights[i]-row.nativeHeight-p.Top-p.Bottom)/2
  local applied={Left=p.Left,Right=p.Right,Top=p.Top+extra,Bottom=p.Bottom+extra+(i<#children and plan.gap or 0)}
  o.Slot:SetPadding(applied);row.applied=applied
 end
 for i,o in ipairs(self.footer)do o.Slot:SetPadding({Left=0,Right=0,Top=0,Bottom=i<#self.footer and plan.minGap or 0})end
 plan.scaleX=sx;plan.scaleY=dpi;plan.rootWidth=vpw/dpi;plan.rootHeight=vph/dpi
 self.plan=plan;return true
end
return L
