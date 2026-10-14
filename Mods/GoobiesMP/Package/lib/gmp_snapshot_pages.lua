-- Bounded atomic roster/lobby snapshots; no larger datagrams or partial mirrors.
local Codec=require('gmp_codec');local Messages=require('gmp_messages');local Cap=require('gmp_config').MAX_PLAYERS_LIMIT
local P={}
function P.Build(kind,fields)
 local schema=Messages.Schema[kind];local rows=fields.players
 if not schema or type(rows)~='table' or #rows<1 or #rows>Cap then return nil,'invalid_snapshot'end
 local pages={};local page
 local function fresh()
  local f={part=#pages+1,total=Cap,rowCount=#rows,players={}}
  for _,field in ipairs(schema.fields)do if field.name~='players'then f[field.name]=fields[field.name]end end
  pages[#pages+1]=f;return f
 end
 local function fits(f)return Codec.Encode{type=kind..'_PAGE',ch='R',sid=string.rep('S',128),ep=9007199254740991,seq=9007199254740991,ack=9007199254740991,f=f}~=nil end
 page=fresh()
 for _,row in ipairs(rows)do
  page.players[#page.players+1]=row
  if not fits(page)then
   page.players[#page.players]=nil
   if #page.players==0 then return nil,'snapshot_row_too_large'end
   page=fresh();page.players[1]=row;if not fits(page)then return nil,'snapshot_row_too_large'end
  end
 end
 for _,f in ipairs(pages)do f.total=#pages end
 return pages
end
function P.Receive(cache,kind,f)
 local schema=Messages.Schema[kind];local revision=kind=='ROSTER' and f.rev or f.lrev
 if not schema or type(revision)~='number' or revision%1~=0 or revision<0 or type(f.part)~='number' or type(f.total)~='number'
  or type(f.rowCount)~='number' or f.rowCount%1~=0 or f.rowCount<1 or f.rowCount>Cap
  or f.part%1~=0 or f.total%1~=0 or f.part<1 or f.part>f.total or f.total>Cap or f.total<1
  or type(f.players)~='table' or #f.players>Cap then return nil,'invalid_snapshot_page'end
 local current=cache[kind]
 if current and revision<current.revision then return nil,'stale_snapshot_page'end
 if not current or revision>current.revision then current={revision=revision,total=f.total,rowCount=f.rowCount,parts={},count=0};cache[kind]=current end
 if current.total~=f.total or current.rowCount~=f.rowCount then return nil,'snapshot_context_changed'end
 for _,field in ipairs(schema.fields)do if field.name~='players'then
  if current[field.name]~=nil and current[field.name]~=f[field.name]then return nil,'snapshot_context_changed'end
  current[field.name]=f[field.name]
 end end
 local signature=Codec.Encode{type=kind..'_PAGE',ch='R',sid='',ep=1,seq=0,ack=0,f=f}
 if not signature then return nil,'invalid_snapshot_page'end
 local prior=current.parts[f.part]
 if prior then if prior.signature~=signature then return nil,'conflicting_snapshot_page'end;return nil end
 local rows={};for i,row in ipairs(f.players)do rows[i]={};for name,value in pairs(row)do rows[i][name]=value end end
 current.parts[f.part]={players=rows,signature=signature};current.count=current.count+1
 if current.count~=current.total then return nil end
 local out={players={}};local keys={}
 for _,field in ipairs(schema.fields)do if field.name~='players'then out[field.name]=current[field.name]end end
 for part=1,current.total do for _,row in ipairs(current.parts[part].players)do
  if type(row.key)~='string' or keys[row.key] or #out.players>=Cap then return nil,'invalid_snapshot_identity'end
  keys[row.key]=true;out.players[#out.players+1]=row
 end end
 if #out.players~=current.rowCount then return nil,'incomplete_snapshot_rows'end
 return out
end
return P
