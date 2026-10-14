-- Pure-data menu registry (Menu_Options/BUTTON_HIERARCHY_DESIGN.md §2, §4.1, §5; WU1).
-- No UObject or widget work: engine-touching handle methods delegate to an adapter set by
-- the framework (WU2). There are no module-level tables: every table lives inside one
-- registry instance created by R.new, so require('mm_menu_registry') exposes no state.
-- Trust model: protects against buggy or colliding packages, not malicious ones.
local R={}

local function defaultNatives()
    return {
        main={{id='Play',label='Play'},{id='upgrades',label='Upgrades'},{id='encyclopedia',label='Encyclopedia'},
            {id='Settings',label='Settings'},{id='credits_new',label='Credits'},{id='quit',label='Quit'}},
        -- The game's "End Run" control is named restart (gmp_island_world.lua:319-321).
        esc={{id='resume',label='Resume'},{id='settings',label='Settings'},{id='restart',label='End Run'}},
    }
end
local function limits()
    return {buttons=16,labels=8,resolvers=4,surfaces=4,perKind=32,undeclaredKinds=4,held=32,
        id=32,label=64,text=128,logged=256,pending=4096,
        groups=32,members=256,path=64,depth=6,member=64}
end
local function styleKeys()
    local keys={}
    for _,k in ipairs({'fontSize','size','color','x','y','padding','styleRole','font','fontFamily','scale','width',
        'height','margin','position','align','opacity','slot','offset'}) do keys[k]=true end
    return keys
end
-- Mod Menu's own Mods button is a registered entry, not a native; design §4.1 lists it as
-- the main-menu anchor 'mods', so that name aliases this key.
local function modsKey() return 'ModMenu:mods' end
local function set(list) local s={} for _,v in ipairs(list) do s[v]=true end return s end
local function validId(id,max) return type(id)=='string' and #id>=1 and #id<=max and id:match('^[%w_%-]+$')~=nil end
local function validKind(kind) return type(kind)=='string' and #kind<=32 and kind:match('^%a[%w_]*$')~=nil end
-- Strips C0, DEL and C1 controls and the bidi embedding/override/isolate controls
-- U+202A-U+202E and U+2066-U+2069 until stable (removing one can expose another).
local function clean(value)
    local text=value
    repeat
        local before=text
        text=text:gsub('[\0-\31\127]','')
        text=text:gsub('\194[\128-\159]','')
        text=text:gsub('\226\128[\170-\174]','')
        text=text:gsub('\226\129[\166-\169]','')
    until text==before
    return text
end
-- Keeps only complete, well-formed UTF-8 sequences (no overlongs, surrogates or values above
-- U+10FFFF); stray continuation bytes, which include raw C1 bytes 0x80-0x9F, and invalid or
-- truncated lead bytes are dropped. Concatenated valid sequences stay valid.
local function validUtf8(text)
    local out={}
    local i,n=1,#text
    while i<=n do
        local c=text:byte(i)
        local size,low,high=0,0x80,0xBF
        if c<0x80 then size=1
        elseif c>=0xC2 and c<=0xDF then size=2
        elseif c>=0xE0 and c<=0xEF then
            size=3
            if c==0xE0 then low=0xA0 elseif c==0xED then high=0x9F end
        elseif c>=0xF0 and c<=0xF4 then
            size=4
            if c==0xF0 then low=0x90 elseif c==0xF4 then high=0x8F end
        end
        local ok=size>0 and i+size-1<=n
        for k=1,size-1 do
            if not ok then break end
            local nb=text:byte(i+k)
            if k==1 then ok=nb>=low and nb<=high else ok=nb>=0x80 and nb<=0xBF end
        end
        if ok then out[#out+1]=text:sub(i,i+size-1); i=i+size else i=i+1 end
    end
    return table.concat(out)
end
-- Diagnostics never echo raw text beyond a sanitized key name of at most 32 bytes, cut
-- back so it never ends inside a UTF-8 sequence (the next byte must not be a continuation).
local function keyName(key)
    if type(key)~='string' then return '<'..type(key)..'>' end
    local text=clean(validUtf8(key))
    if #text<=32 then return text end
    local cut=32
    while cut>0 do
        local nextByte=text:byte(cut+1)
        if nextByte<128 or nextByte>=192 then break end
        cut=cut-1
    end
    return text:sub(1,cut)
end
-- Returns sanitized text or nil,reason. Lengths count UTF-8 characters. Surrogates are
-- refused explicitly because Lua 5.3's utf8.len accepts them and 5.4's rejects them.
local function sanitize(value,limit,allowEmpty)
    if type(value)~='string' then return nil,'must be a string' end
    local text=clean(value)
    local length
    if utf8 then length=utf8.len(text) else length=#text end
    if not length or text:find('\237[\160-\191]') then return nil,'is not valid UTF-8' end
    if length==0 and not allowEmpty then return nil,'is empty' end
    if length>limit then return nil,'longer than '..limit..' characters' end
    return text
end
local function normalized(text) return text:match('^%s*(.-)%s*$'):lower() end
local function sortedKeys(t)
    local keys={}
    for k in pairs(t) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    return keys
end
local function bySeq(a,b) return a.seq<b.seq end
-- Group paths (WU1b): lowercase segments [a-z0-9_]+ joined by '/', bounded depth and length.
local function validSegment(s) return type(s)=='string' and s:match('^[a-z0-9_]+$')~=nil end
local function validPath(path,maxLength,maxDepth)
    if type(path)~='string' or #path<1 or #path>maxLength then return false end
    local depth=0
    for segment in (path..'/'):gmatch('([^/]*)/') do
        if not validSegment(segment) then return false end
        depth=depth+1
    end
    return depth<=maxDepth
end
local function parentPath(path) return path:match('^(.*)/[^/]+$') end
local function underPath(path,prefix) return path==prefix or path:sub(1,#prefix+1)==prefix..'/' end
local function currentThread() return coroutine.running() or 'main' end

function R.new(options)
    options=options or {}
    local log=type(options.log)=='function' and options.log or function() end
    local L=limits(); local STYLE=styleKeys()
    if type(options.pendingLimit)=='number' and options.pendingLimit>=1 then L.pending=options.pendingLimit end
    local BUTTON_KEYS=set({'id','label','onClick','after','before','region','replaces','enabled','visible','tooltip'})
    local LABEL_KEYS=set({'id','text','color','order','when','visible'})
    local SURFACE_KEYS=set({'kind','axis','allow','host','open'})
    local PRESENTER_KEYS=set({'attach','tick','detach'})
    local WHEN=set({'escOpen','overlay','always'})
    local GROUP_KEYS=set({'allow'})
    local RESERVED_ROOTS=set({'buttons','labels'}) -- built-in groups derived from this registry
    local DATA_TYPES=set({'nil','table','string','number','boolean'})
    local natives={}
    local source=defaultNatives()
    for kind,list in pairs(type(options.natives)=='table' and options.natives or {}) do source[kind]=list end
    for kind,list in pairs(source) do
        local entry={list={},byId={}}
        for i,n in ipairs(list) do
            assert(validId(n.id,L.id) and type(n.label)=='string','Invalid native descriptor for '..tostring(kind))
            entry.list[i]={id=n.id,label=n.label}; entry.byId[n.id]=entry.list[i]
        end
        natives[kind]=entry
    end

    local pending={}       -- ordered operations, applied only by merge()
    local live={}          -- record -> true for every registration not unregistered/refused
    local present={}       -- kind -> key -> button record merged into a declared kind
    local held={}          -- hosted kind -> key -> button record waiting for its surface
    local labels={}        -- kind -> key -> label record
    local surfaces={}      -- hosted kind -> surface record
    local declared={}      -- hosted kind -> its live surface record (merged or pending); one per kind
    local resolvers={}     -- merged click-resolver records
    local presenterRecord
    local revisions={}
    local retained={}      -- kind..'\0'..key -> framework cleanup pending
    local removing={}      -- kind..'\0'..key -> merged button removals not yet applied
    local disabled={}      -- package id -> true after a live disable, until enablePackage
    local logged={}; local loggedCount=0
    local sections=setmetatable({},{__mode='k'}) -- coroutine -> game-thread section depth
    -- Group tree. Groups are logical: named lists of references, never widgets.
    local groupDeclared={} -- path -> live group record (merged or pending); one owner per path
    local groupPresent={}  -- path -> merged group record
    local builtin={}       -- path -> {members, sig}: buttons/<kind>, labels/<kind>, rebuilt at merge
    local groupRevs={}     -- path -> integer; persists across removal and redeclare
    local dirtyGroups={}   -- path -> true while a merge runs
    local touchedGroups={} -- declared group record -> its member list before this merge changed it
    local builtinRebuildCount=0
    local serial=0; local adapter
    local self={}

    local function isNative(kind) return kind=='main' or kind=='esc' end
    local function bucket(map,kind) map[kind]=map[kind] or {}; return map[kind] end
    local function bump(kind) revisions[kind]=(revisions[kind] or 0)+1 end
    local function inSection() return (sections[currentThread()] or 0)>0 end
    -- Log once per key; the table is bounded so hostile refusal floods cannot grow it.
    local function logOnce(once,message)
        if logged[once] then return end
        if loggedCount>=L.logged then
            if not logged['\0limit'] then
                logged['\0limit']=true
                pcall(log,'menu registry: further refusal diagnostics suppressed (log-once table full)')
            end
            return
        end
        logged[once]=true; loggedCount=loggedCount+1; pcall(log,message)
    end
    local function refuse(pkg,api,key,reason,id)
        local subject=id and (' for '..pkg..':'..id) or ''
        local why=pkg..': '..api..' refused key '..keyName(key)..subject..' ('..reason..')'
        logOnce(pkg..'\0'..api..'\0'..keyName(key)..'\0'..reason,why)
        return nil,why
    end
    local function threadRefusal(rec,method)
        logOnce(rec.owner..'\0thread',rec.owner..': '..method..' refused for '..rec.key..' (not_game_thread)')
        return nil,'not_game_thread'
    end
    local function liveCount(predicate)
        local n=0
        for rec in pairs(live) do if predicate(rec) then n=n+1 end end
        return n
    end
    local function liveFind(predicate) for rec in pairs(live) do if predicate(rec) then return rec end end end
    local function allowed(surface,pkg) return surface.owner==pkg or surface.data.allow[pkg]==true end
    -- The declaring surface of a hosted kind: its live surface record, merged or pending.
    -- Indexed (maintained by newRecord/markDead) so cap checks that call this per live
    -- record stay O(live) per registration instead of O(live^2).
    local function knownSurface(kind) return declared[kind] end
    -- Everything registerMenuButton's synchronous checks need, gathered in ONE pass over the
    -- live records with no per-record function calls (O(live) per registration).
    -- Hosted records count toward kind-wide caps (corner, 32 entries) only once their owner
    -- is known to be allowed by the kind's surface, so packages that will fail the owner
    -- check cannot exhaust a kind or its corner. `surface` is knownSurface(kind) or nil.
    local function buttonCensus(pkg,kind,key,replaces,surface)
        local c={duplicate=false,corner=false,replaced=false,own=0,kindTotal=0,held=0,heldKinds={},heldKindCount=0}
        local native=kind=='main' or kind=='esc'
        for r in pairs(live) do
            local rtype,rkind=r.type,r.kind
            if rtype=='button' or rtype=='label' then
                if rkind==kind then
                    local counts=native or (surface~=nil and (surface.owner==r.owner or surface.data.allow[r.owner]==true))
                    if counts then c.kindTotal=c.kindTotal+1 end
                    if rtype=='button' then
                        if r.key==key then c.duplicate=true end
                        if r.owner==pkg then c.own=c.own+1 end
                        if counts and r.data.region=='corner' then c.corner=true end
                        if replaces~=nil and r.data.replaces==replaces then c.replaced=true end
                    end
                end
                if rtype=='button' and r.owner==pkg and rkind~='main' and rkind~='esc' and not declared[rkind] then
                    c.held=c.held+1
                    if not c.heldKinds[rkind] then c.heldKinds[rkind]=true; c.heldKindCount=c.heldKindCount+1 end
                end
            end
        end
        return c
    end
    local function checkKeys(pkg,api,d,allowedKeys,id)
        for _,key in ipairs(sortedKeys(d)) do
            if not allowedKeys[key] then
                if STYLE[key] then return refuse(pkg,api,key,'style belongs to Menu Options',id) end
                return refuse(pkg,api,key,'unknown key',id)
            end
        end
        return true
    end
    local function collision(pkg,api,kind,label,replaces,id)
        local wanted=normalized(label)
        for _,n in ipairs(natives[kind] and natives[kind].list or {}) do
            if normalized(n.label)==wanted and replaces~=n.id then
                return refuse(pkg,api,'label','matches native label of '..kind..':'..n.id,id)
            end
        end
        return true
    end
    local function snapshot(rec)
        local out={key=rec.key,id=rec.id,owner=rec.owner,kind=rec.kind,source='registered'}
        for k,v in pairs(rec.data) do if k~='allow' and k~='allowList' then out[k]=v end end
        if rec.type=='button' and not isNative(rec.kind) then out.region=rec.data.region else out.region=nil end
        return out
    end

    -- Pending operations -------------------------------------------------------------------
    local function room(pkg,api,id)
        if #pending>=L.pending then return refuse(pkg,api,'pending','pending operation limit '..L.pending..' reached',id) end
        return true
    end
    local function queue(op) pending[#pending+1]=op end
    local function newRecord(kind,type,owner,id,data)
        serial=serial+1
        local rec={kind=kind,type=type,owner=owner,id=id,key=id and owner..':'..id or owner..'#'..serial,
            seq=serial,data=data,status='pending',sets={}}
        live[rec]=true
        if type=='surface' then declared[kind]=rec end
        if type=='group' then groupDeclared[kind]=rec end
        queue({op='add',rec=rec})
        return rec
    end
    local function markDead(rec,reason)
        rec.dead=true; rec.deadReason=reason; live[rec]=nil
        if rec.type=='surface' and declared[rec.kind]==rec then declared[rec.kind]=nil end
        if rec.type=='group' and groupDeclared[rec.kind]==rec then groupDeclared[rec.kind]=nil end
    end
    local function cancelPending(rec)
        for i=#pending,1,-1 do if pending[i].rec==rec then table.remove(pending,i) end end
    end
    -- Synchronous membership bookkeeping (caps, duplicates) for one contributor of a group.
    local function dropContributor(group,pkg)
        local mine=group.intended.by[pkg]
        if mine then group.intended.count=group.intended.count-mine.n; group.intended.by[pkg]=nil end
    end
    local function unregister(rec)
        if rec.dead then return false,rec.deadReason end
        markDead(rec,'unregistered')
        if rec.type=='group' then
            -- Joins are capabilities on this group record: they die with it. The group's own
            -- removal clears every member, so their queued operations are dropped.
            for j in pairs(rec.joins) do
                if not j.dead then markDead(j,'unregistered'); cancelPending(j); j.status='gone' end
            end
        elseif rec.type=='join' then
            dropContributor(rec.group,rec.owner); rec.group.joins[rec]=nil
        end
        if rec.status=='pending' then
            -- Never merged: cancel its own queued operations instead of queueing a removal.
            cancelPending(rec)
            rec.status='gone'
            return true
        end
        if rec.type=='button' and rec.status=='present' then
            rec.removalKey=rec.kind..'\0'..rec.key
            removing[rec.removalKey]=(removing[rec.removalKey] or 0)+1
        end
        queue({op='remove',rec=rec}) -- always allowed: bounded by the number of merged records
        return true
    end
    -- Setters coalesce per (record, field), last value wins, so they never grow the list.
    local function setter(rec,field,value)
        local op=rec.sets[field]
        if op then op.value=value; return true end
        local ok,why=room(rec.owner,'set',rec.id); if not ok then return nil,why end
        op={op='set',rec=rec,field=field,value=value}
        rec.sets[field]=op; queue(op)
        return true
    end

    -- Validation ------------------------------------------------------------------------
    local function validateButton(pkg,api,kind,d)
        if not validKind(kind) then return refuse(pkg,api,'kind','invalid kind') end
        if type(d)~='table' then return refuse(pkg,api,'descriptor','expected a table') end
        local id=validId(d.id,L.id) and d.id or nil
        local ok,why=checkKeys(pkg,api,d,BUTTON_KEYS,id); if not ok then return nil,why end
        if not id then return refuse(pkg,api,'id','id must match [A-Za-z0-9_-] and be at most '..L.id..' characters') end
        local label,problem=sanitize(d.label,L.label,false)
        if not label then return refuse(pkg,api,'label','label '..problem,id) end
        if type(d.onClick)~='function' then return refuse(pkg,api,'onClick','onClick must be a function',id) end
        for _,key in ipairs({'enabled','visible'}) do
            if d[key]~=nil and type(d[key])~='boolean' then return refuse(pkg,api,key,key..' must be a boolean',id) end
        end
        local tooltip
        if d.tooltip~=nil then
            tooltip,problem=sanitize(d.tooltip,L.text,true)
            if not tooltip then return refuse(pkg,api,'tooltip','tooltip '..problem,id) end
        end
        local region
        if isNative(kind) then
            if d.region~=nil then return refuse(pkg,api,'region','region is for hosted kinds only',id) end
        else
            region=d.region or 'row'
            if region~='row' and region~='corner' then return refuse(pkg,api,'region','region must be row or corner',id) end
        end
        if d.replaces~=nil then
            if kind~='esc' then return refuse(pkg,api,'replaces','replaces is supported on esc only',id) end
            if type(d.replaces)~='string' or not natives.esc.byId[d.replaces] then
                return refuse(pkg,api,'replaces','replaces must name a native esc control',id)
            end
        end
        -- A replacing entry takes its native slot and ordering ignores its after/before, so
        -- those anchors are neither checked nor kept.
        local after,before=d.after,d.before
        if d.replaces~=nil then after,before=nil,nil end
        for _,pair in ipairs({{'after',after},{'before',before}}) do
            local key,anchor=pair[1],pair[2]
            if anchor~=nil then
                local native=type(anchor)=='string' and natives[kind] and natives[kind].byId[anchor]
                local alias=kind=='main' and anchor=='mods'
                local packaged=type(anchor)=='string' and anchor:match('^[%w_%-]+:[%w_%-]+$')~=nil
                if not native and not alias and not packaged then return refuse(pkg,api,key,'unresolved anchor',id) end
            end
        end
        if isNative(kind) and d.replaces==nil and d.after==nil and d.before==nil then
            return refuse(pkg,api,'after','at least one anchor (after or before) is required',id)
        end
        ok,why=collision(pkg,api,kind,label,d.replaces,id); if not ok then return nil,why end
        return {id=id,label=label,onClick=d.onClick,after=after,before=before,region=region,replaces=d.replaces,
            enabled=d.enabled~=false,visible=d.visible~=false,tooltip=tooltip}
    end
    local function validateLabelFields(pkg,api,id,d,fields)
        local out={}
        if fields.text then
            local text,problem=sanitize(d.text,L.text,true)
            if not text then return refuse(pkg,api,'text','text '..problem,id) end
            out.text=text
        end
        if fields.color then
            local color=d.color -- required (design §4.1): nil is refused, never defaulted
            if type(color)~='string' or not color:match('^#%x%x%x%x%x%x$') then
                return refuse(pkg,api,'color','color must match #RRGGBB',id)
            end
            out.color=color
        end
        if fields.order and d.order~=nil then
            if type(d.order)~='number' or d.order~=math.floor(d.order) or math.abs(d.order)>1000 then
                return refuse(pkg,api,'order','order must be an integer within -1000..1000',id)
            end
            out.order=d.order
        end
        if fields.when then
            local when=d.when -- required (design §4.1): nil is refused, never defaulted
            if when==nil or not WHEN[when] then return refuse(pkg,api,'when','when must be escOpen, overlay or always',id) end
            out.when=when
        end
        if fields.visible then
            local visible=d.visible
            if visible==nil and api=='registerMenuLabel' then visible=true end
            if type(visible)~='boolean' then return refuse(pkg,api,'visible','visible must be a boolean',id) end
            out.visible=visible
        end
        return out
    end

    -- Handles: real methods; a dot call (handle.Method(x)) is a programming error -----------
    local function method(h,name,body)
        h[name]=function(handle,...)
            if handle~=h then error('menu registry handles require colon syntax: handle:'..name..'(...)',2) end
            return body(...)
        end
    end
    local function engine(rec,name,body)
        if rec.dead then return false,rec.deadReason end
        if not inSection() then return threadRefusal(rec,name) end
        return body()
    end
    local function buttonState(rec,instance)
        local state=snapshot(rec)
        state.present=rec.status=='present'
        if adapter and type(adapter.state)=='function' then
            for k,v in pairs(adapter.state(snapshot(rec),instance) or {}) do if k~='present' then state[k]=v end end
        end
        return state
    end
    local function buttonHandle(rec)
        local h={}
        method(h,'SetLabel',function(text)
            if rec.dead then return false,rec.deadReason end
            local label,problem=sanitize(text,L.label,false)
            if not label then return refuse(rec.owner,'SetLabel','label','label '..problem,rec.id) end
            local ok,why=collision(rec.owner,'SetLabel',rec.kind,label,rec.data.replaces,rec.id)
            if not ok then return nil,why end
            return setter(rec,'label',label)
        end)
        method(h,'SetTooltip',function(text)
            if rec.dead then return false,rec.deadReason end
            local tooltip,problem
            if text~=nil then
                tooltip,problem=sanitize(text,L.text,true)
                if not tooltip then return refuse(rec.owner,'SetTooltip','tooltip','tooltip '..problem,rec.id) end
            end
            return setter(rec,'tooltip',tooltip)
        end)
        for name,field in pairs({SetEnabled='enabled',SetVisible='visible'}) do
            method(h,name,function(value)
                if rec.dead then return false,rec.deadReason end
                if type(value)~='boolean' then return refuse(rec.owner,name,field,field..' must be a boolean',rec.id) end
                return setter(rec,field,value)
            end)
        end
        method(h,'Unregister',function() return unregister(rec) end)
        method(h,'Ensure',function(instance)
            return engine(rec,'Ensure',function()
                if not adapter or type(adapter.ensure)~='function' then return false,'no_adapter' end
                return adapter.ensure(snapshot(rec),instance)
            end)
        end)
        method(h,'Widget',function(instance)
            return engine(rec,'Widget',function()
                if not adapter or type(adapter.widget)~='function' then return nil,'no_adapter' end
                return adapter.widget(snapshot(rec),instance)
            end)
        end)
        method(h,'State',function(instance) return engine(rec,'State',function() return buttonState(rec,instance) end) end)
        return h
    end
    local function labelHandle(rec)
        local h={}
        for name,key in pairs({SetText='text',SetColor='color',SetVisible='visible',SetWhen='when'}) do
            method(h,name,function(value)
                if rec.dead then return false,rec.deadReason end
                if key=='text' and value==nil then value='' end
                local out,why=validateLabelFields(rec.owner,name,rec.id,{[key]=value},{[key]=true})
                if not out then return nil,why end
                return setter(rec,key,out[key])
            end)
        end
        method(h,'Unregister',function() return unregister(rec) end)
        return h
    end
    local function simpleHandle(rec)
        local h={}
        method(h,'Unregister',function() return unregister(rec) end)
        return h
    end
    local function surfaceSnapshot(rec)
        local allow={}
        for i,v in ipairs(rec.data.allowList) do allow[i]=v end
        return {kind=rec.kind,owner=rec.owner,axis=rec.data.axis,allow=allow,host=rec.data.host,open=rec.data.open}
    end
    -- allow = optional list of package ids -> set,list | nil,why (shared by surfaces and groups).
    local function parseAllow(pkg,api,value)
        local allow,allowList={},{}
        if value~=nil then
            if type(value)~='table' then return refuse(pkg,api,'allow','allow must be a table') end
            for i,v in ipairs(value) do
                if not validId(v,64) then return refuse(pkg,api,'allow','allow entries must be package ids') end
                allow[v]=true; allowList[i]=v
            end
        end
        return allow,allowList
    end
    -- Group handles: the declaring package's record (type 'group') or an allowlisted
    -- package's join record (type 'join'). Members are opaque references: an id string or a
    -- table the package owns, plus optional data; neither is ever inspected or called.
    local function groupOf(rec) return rec.type=='group' and rec or rec.group end
    local function validMember(id)
        return type(id)=='table' or (type(id)=='string' and #id>=1 and #id<=L.member and id:match('^[%w_%-%.:]+$')~=nil)
    end
    local function memberHandle(rec)
        local h={}
        local group=groupOf(rec); local path=group.kind
        method(h,'Add',function(id,data)
            if rec.dead then return false,rec.deadReason end
            if not validMember(id) then
                return refuse(rec.owner,'Add','member','member must be a table or an id string ([A-Za-z0-9_.:-], at most '..L.member..' characters)')
            end
            if not DATA_TYPES[type(data)] then return refuse(rec.owner,'Add','data','data must be a table, string, number or boolean') end
            local intended=group.intended
            local mine=intended.by[rec.owner]
            if mine and mine.ids[id] then return refuse(rec.owner,'Add','member','duplicate member in group '..path) end
            if intended.count>=L.members then return refuse(rec.owner,'Add','member',L.members..' members in group '..path) end
            local ok,why=room(rec.owner,'Add'); if not ok then return nil,why end
            if not mine then mine={n=0,ids={}}; intended.by[rec.owner]=mine end
            mine.ids[id]=true; mine.n=mine.n+1; intended.count=intended.count+1
            queue({op='member',rec=rec,field='add',value={id=id,data=data}})
            return true
        end)
        method(h,'Remove',function(id)
            if rec.dead then return false,rec.deadReason end
            local mine=group.intended.by[rec.owner]
            if id==nil or not (mine and mine.ids[id]) then return refuse(rec.owner,'Remove','member','not a member of group '..path) end
            local ok,why=room(rec.owner,'Remove'); if not ok then return nil,why end
            mine.ids[id]=nil; mine.n=mine.n-1; group.intended.count=group.intended.count-1
            queue({op='member',rec=rec,field='remove',value={id=id}})
            return true
        end)
        method(h,'Unregister',function() return unregister(rec) end)
        return h
    end

    -- Merge -------------------------------------------------------------------------------
    local function mergeRefuse(rec,key,reason)
        markDead(rec,'refused'); rec.status='refused'
        refuse(rec.owner,'registerMenuButton',key,reason,rec.id)
    end
    local function presentKindCount(kind)
        local n=0
        for _ in pairs(present[kind] or {}) do n=n+1 end
        for _ in pairs(labels[kind] or {}) do n=n+1 end
        return n
    end
    local function admit(rec)
        local kind=rec.kind
        if not isNative(kind) then
            local surface=surfaces[kind]
            if not allowed(surface,rec.owner) then
                return mergeRefuse(rec,'kind','kind '..kind..' is owned by '..surface.owner)
            end
            if rec.data.region=='corner' then
                for _,other in pairs(bucket(present,kind)) do
                    if other.data.region=='corner' then return mergeRefuse(rec,'region','second corner for kind '..kind) end
                end
            end
            if presentKindCount(kind)>=L.perKind then return mergeRefuse(rec,'cap',L.perKind..' entries for kind '..kind) end
        end
        -- Anchors are checked on first admission only. An entry demoted to held (its surface
        -- was unregistered) and re-admitted keeps its place rule: an anchor that has since
        -- gone puts it at the tail, exactly as ordered() does for live entries.
        for _,key in ipairs(rec.admitted and {} or {'after','before'}) do
            local anchor=rec.data[key]
            local alias=kind=='main' and anchor=='mods'
            if anchor and not alias and not (natives[kind] and natives[kind].byId[anchor]) and not bucket(present,kind)[anchor] then
                return mergeRefuse(rec,key,'unresolved anchor')
            end
        end
        bucket(present,kind)[rec.key]=rec; rec.status='present'; rec.admitted=true; bump(kind)
    end
    local apply={}
    function apply.add(rec)
        if rec.dead then return end
        if rec.type=='button' then
            if not isNative(rec.kind) and not surfaces[rec.kind] then
                bucket(held,rec.kind)[rec.key]=rec; rec.status='held'; return
            end
            return admit(rec)
        elseif rec.type=='label' then
            bucket(labels,rec.kind)[rec.key]=rec; rec.status='present'; bump(rec.kind)
        elseif rec.type=='surface' then
            surfaces[rec.kind]=rec; rec.status='present'
            local waiting={}
            -- A record unregistered while held stays in held until its queued removal runs
            -- later in this merge: it must not take a corner or a kind slot, nor be refused.
            for _,h in pairs(held[rec.kind] or {}) do if not h.dead then waiting[#waiting+1]=h end end
            table.sort(waiting,bySeq); held[rec.kind]=nil
            for _,h in ipairs(waiting) do admit(h) end
        elseif rec.type=='presenter' then
            presenterRecord=rec; rec.status='present'
        elseif rec.type=='resolver' then
            resolvers[#resolvers+1]=rec; rec.status='present'
        elseif rec.type=='group' then
            groupPresent[rec.kind]=rec; rec.status='present'; rec.members={}; dirtyGroups[rec.kind]=true
        elseif rec.type=='join' then
            rec.status='present'
        end
    end
    -- A declared group's member list as it was before this merge first changed it; merge()
    -- compares it with the final list so only a net change bumps the revision.
    local function touchGroup(group)
        if touchedGroups[group] then return end
        local before={}
        for i,m in ipairs(group.members) do before[i]=m end
        touchedGroups[group]=before
    end
    local function sameMembers(a,b)
        if #a~=#b then return false end
        for i=1,#a do
            if a[i].pkg~=b[i].pkg or not rawequal(a[i].id,b[i].id) then return false end
        end
        return true
    end
    -- Member operations of a dead contributor are skipped: its queued removal (or the group's)
    -- clears whatever it had added, so skipping never leaves a stale member behind.
    function apply.member(rec,action,member)
        local group=groupOf(rec)
        if rec.dead or group.dead or group.status~='present' then return end
        touchGroup(group)
        local list=group.members
        if action=='add' then
            list[#list+1]={pkg=rec.owner,id=member.id,data=member.data,native=false}
        else
            for i,m in ipairs(list) do
                if m.pkg==rec.owner and rawequal(m.id,member.id) then table.remove(list,i); break end
            end
        end
    end
    function apply.remove(rec)
        local was=rec.status; rec.status='gone'
        if rec.removalKey then
            -- Keyed by record, so a removal applied after demotion to held still clears it.
            local k=rec.removalKey; rec.removalKey=nil
            removing[k]=(removing[k] or 1)-1; if removing[k]<=0 then removing[k]=nil end
        end
        if rec.type=='button' then
            if was=='present' then bucket(present,rec.kind)[rec.key]=nil; bump(rec.kind)
            elseif was=='held' and held[rec.kind] then held[rec.kind][rec.key]=nil end
        elseif rec.type=='label' and was=='present' then
            bucket(labels,rec.kind)[rec.key]=nil; bump(rec.kind)
        elseif rec.type=='surface' and was=='present' then
            surfaces[rec.kind]=nil
            local demoted=false
            for key,entry in pairs(present[rec.kind] or {}) do
                bucket(held,rec.kind)[key]=entry; entry.status='held'; demoted=true
            end
            present[rec.kind]=nil
            if demoted then bump(rec.kind) end
        elseif rec.type=='presenter' and presenterRecord==rec then
            presenterRecord=nil
        elseif rec.type=='resolver' then
            for i,r in ipairs(resolvers) do if r==rec then table.remove(resolvers,i); break end end
        elseif rec.type=='group' and was=='present' then
            if groupPresent[rec.kind]==rec then groupPresent[rec.kind]=nil end
            dirtyGroups[rec.kind]=true
        elseif rec.type=='join' and was=='present' then
            local group=rec.group
            if not group.dead and group.status=='present' then
                local kept={}
                for _,m in ipairs(group.members) do if m.pkg~=rec.owner then kept[#kept+1]=m end end
                if #kept~=#group.members then touchGroup(group); group.members=kept end
            end
        end
    end
    function apply.set(rec,field,value,op)
        if rec.sets[field]==op then rec.sets[field]=nil end
        if rec.status=='gone' or rec.status=='refused' then return end
        if rec.data[field]~=value then
            rec.data[field]=value
            if rec.status=='present' then bump(rec.kind) end
        end
    end

    -- Ordering ----------------------------------------------------------------------------
    local function nativeItem(n)
        return {key=n.id,id=n.id,label=n.label,source='native',enabled=true,visible=true}
    end
    local function ordered(kind)
        local result={}
        local records={}
        for _,rec in pairs(present[kind] or {}) do records[#records+1]=rec end
        table.sort(records,bySeq)
        local replacing={}
        for _,rec in ipairs(records) do if rec.data.replaces then replacing[rec.data.replaces]=rec end end
        -- An anchor naming a replacing entry resolves to the native slot it replaces.
        local replacedBy={}
        for native,rec in pairs(replacing) do replacedBy[rec.key]=native end
        local function node(anchor)
            if kind=='main' and anchor=='mods' then return modsKey() end
            return anchor and replacedBy[anchor] or anchor
        end
        local regions=isNative(kind) and {false} or {'row','corner'}
        for _,region in ipairs(regions) do
            local nodes,after,before,tail,visited={}, {}, {}, {}, {}
            local members={}
            local nativeList=region==false and natives[kind] and natives[kind].list or {}
            for _,n in ipairs(nativeList) do nodes[n.id]=true end
            for _,rec in ipairs(records) do
                if not rec.data.replaces and (region==false or rec.data.region==region) then
                    members[#members+1]=rec; nodes[rec.key]=true
                end
            end
            for _,rec in ipairs(members) do
                local a,b=node(rec.data.after),node(rec.data.before)
                if a and nodes[a] and a~=rec.key then after[a]=after[a] or {}; table.insert(after[a],rec)
                elseif b and nodes[b] and b~=rec.key then before[b]=before[b] or {}; table.insert(before[b],rec)
                else tail[#tail+1]=rec end -- anchor absent (unregistered, or 'mods' not yet registered)
            end
            local function emit(key,item)
                if visited[key] then return end
                visited[key]=true
                for _,child in ipairs(before[key] or {}) do emit(child.key,snapshot(child)) end
                result[#result+1]=item
                for _,child in ipairs(after[key] or {}) do emit(child.key,snapshot(child)) end
            end
            for _,n in ipairs(nativeList) do
                emit(n.id,replacing[n.id] and snapshot(replacing[n.id]) or nativeItem(n))
            end
            for _,rec in ipairs(tail) do emit(rec.key,snapshot(rec)) end
            for _,rec in ipairs(members) do emit(rec.key,snapshot(rec)) end
        end
        return result
    end
    local function sortedLabelRecords(kind)
        local list={}
        for _,rec in pairs(labels[kind] or {}) do list[#list+1]=rec end
        table.sort(list,function(a,b) if a.data.order~=b.data.order then return a.data.order<b.data.order end return a.seq<b.seq end)
        return list
    end

    -- Group tree (WU1b) ---------------------------------------------------------------------
    -- Built-in groups are derived from merged registry state: buttons/<kind> (natives as
    -- anchors plus registered entries, in resolved order; hosted kinds also get /row and
    -- /corner) and labels/<kind>. Kinds that are not lowercase segments get no group.
    local function builtinMembers()
        local out={buttons={},labels={}}
        local kinds={'main','esc'}
        for _,kind in ipairs(sortedKeys(surfaces)) do if validSegment(kind) then kinds[#kinds+1]=kind end end
        for _,kind in ipairs(kinds) do
            local hosted=not isNative(kind)
            local all,regions={},{row={},corner={}}
            for _,e in ipairs(ordered(kind)) do
                local m
                if e.source=='native' then m={pkg='native',id=e.id,kind=kind,native=true}
                else m={pkg=e.owner,id=e.id,kind=kind,native=false,region=e.region,replaces=e.replaces} end
                all[#all+1]=m
                if hosted and regions[e.region] then local list=regions[e.region]; list[#list+1]=m end
            end
            out['buttons/'..kind]=all
            if hosted then out['buttons/'..kind..'/row']=regions.row; out['buttons/'..kind..'/corner']=regions.corner end
        end
        local labelKinds={esc=true}
        for kind in pairs(labels) do if validSegment(kind) then labelKinds[kind]=true end end
        for kind in pairs(labelKinds) do
            local list={}
            for i,rec in ipairs(sortedLabelRecords(kind)) do list[i]={pkg=rec.owner,id=rec.id,kind=kind,native=false} end
            out['labels/'..kind]=list
        end
        return out
    end
    -- Membership and order only: labels, enabled, visible and tooltips never change it.
    local function signature(list)
        local parts={}
        for i,m in ipairs(list) do parts[i]=m.native and ('!'..m.id) or (m.pkg..':'..m.id) end
        return table.concat(parts,'\n')
    end
    local function refreshBuiltins(markChanges)
        builtinRebuildCount=builtinRebuildCount+1
        local fresh=builtinMembers()
        for path in pairs(builtin) do
            if not fresh[path] then builtin[path]=nil; if markChanges then dirtyGroups[path]=true end end
        end
        for path,list in pairs(fresh) do
            local sig=signature(list)
            if markChanges and (not builtin[path] or builtin[path].sig~=sig) then dirtyGroups[path]=true end
            builtin[path]={members=list,sig=sig}
        end
    end
    -- One increment per merge for every changed path and each of its ancestors. A declared
    -- group still present counts as changed only if its (pkg, id) sequence differs.
    local function flushGroupRevisions()
        for group,before in pairs(touchedGroups) do
            if not group.dead and group.status=='present' and not sameMembers(before,group.members) then
                dirtyGroups[group.kind]=true
            end
        end
        touchedGroups={}
        local bumped={}
        for path in pairs(dirtyGroups) do
            local p=path
            while p and not bumped[p] do bumped[p]=true; p=parentPath(p) end
        end
        for p in pairs(bumped) do groupRevs[p]=(groupRevs[p] or 0)+1 end
        dirtyGroups={}
    end
    local function copyMembers(list)
        local out={}
        for i,m in ipairs(list) do
            local c={}
            for k,v in pairs(m) do c[k]=v end
            out[i]=c
        end
        return out
    end
    -- Pure reads over merged state: no pending operation is visible and nothing is mutated.
    local function listGroups(prefix)
        if prefix~=nil and not validPath(prefix,L.path,L.depth) then return {} end
        local seen={}
        for path in pairs(builtin) do seen[path]=true end
        for path in pairs(groupPresent) do
            local p=path
            while p and not seen[p] do seen[p]=true; p=parentPath(p) end -- implicit ancestors
        end
        local out={}
        for path in pairs(seen) do if prefix==nil or underPath(path,prefix) then out[#out+1]=path end end
        table.sort(out)
        return out
    end
    local function groupMembers(path)
        if type(path)~='string' then return nil,'unknown_group' end
        if builtin[path] then return copyMembers(builtin[path].members) end
        if groupPresent[path] then return copyMembers(groupPresent[path].members) end
        for p in pairs(groupPresent) do if underPath(p,path) then return {} end end
        return nil,'unknown_group'
    end
    local function groupRevision(path) return type(path)=='string' and groupRevs[path] or 0 end
    local function groupSlots(pkg)
        return liveCount(function(r) return (r.type=='group' or r.type=='join') and r.owner==pkg end)
    end
    local function invalidPath(pkg,api)
        return refuse(pkg,api,'path','invalid group path (lowercase [a-z0-9_] segments joined by /, depth at most '..
            L.depth..', at most '..L.path..' characters)')
    end

    -- Package-bound API -------------------------------------------------------------------
    function self.menuAnchors(_,kind)
        local out={}
        if kind=='main' and present.main and present.main[modsKey()] then
            for _,e in ipairs(ordered('main')) do
                if e.source=='native' then out[#out+1]=e.id elseif e.key==modsKey() then out[#out+1]='mods' end
            end
            return out
        end
        for i,n in ipairs(natives[kind] and natives[kind].list or {}) do out[i]=n.id end
        return out
    end
    -- Sections are tracked per coroutine: a callback that yields leaves only its own
    -- (suspended) coroutine inside the section, never the thread that resumed it.
    function self.gameThread(_,fn,...)
        assert(type(fn)=='function','Expected game-thread function')
        local co=currentThread()
        sections[co]=(sections[co] or 0)+1
        local results=table.pack(pcall(fn,...))
        local depth=(sections[co] or 1)-1
        sections[co]=depth>0 and depth or nil
        if not results[1] then error(results[2],0) end
        return table.unpack(results,2,results.n)
    end
    function self.forPackage(_,pkg)
        assert(validId(pkg,64),'Invalid package id')
        local api={}
        local function gate(name,id)
            if disabled[pkg] then return refuse(pkg,name,'package','package is disabled',id) end
            return room(pkg,name,id)
        end
        function api.registerMenuButton(kind,d)
            local name='registerMenuButton'
            local data,why=validateButton(pkg,name,kind,d)
            if not data then return nil,why end
            local id=data.id; local key=pkg..':'..id
            local ok,problem=gate(name,id); if not ok then return nil,problem end
            local surface=not isNative(kind) and knownSurface(kind) or nil
            local c=buttonCensus(pkg,kind,key,data.replaces,surface)
            if c.duplicate then return refuse(pkg,name,'id','duplicate id in kind '..kind,id) end
            if removing[kind..'\0'..key] then return refuse(pkg,name,'id','retained: removal not merged',id) end
            if retained[kind..'\0'..key] then return refuse(pkg,name,'id','retained: framework cleanup pending',id) end
            if surface and not allowed(surface,pkg) then
                return refuse(pkg,name,'kind','kind '..kind..' is owned by '..surface.owner,id)
            end
            if not isNative(kind) and not surface then
                if not c.heldKinds[kind] and c.heldKindCount>=L.undeclaredKinds then
                    return refuse(pkg,name,'cap',L.undeclaredKinds..' undeclared hosted kinds per package',id)
                end
                if c.held>=L.held then return refuse(pkg,name,'cap',L.held..' held registrations per package',id) end
            end
            if data.region=='corner' and c.corner then return refuse(pkg,name,'region','second corner for kind '..kind,id) end
            if c.replaced then return refuse(pkg,name,'replaces','native '..data.replaces..' is already replaced',id) end
            if c.own>=L.buttons then return refuse(pkg,name,'cap',L.buttons..' buttons per package for kind '..kind,id) end
            if c.kindTotal>=L.perKind then return refuse(pkg,name,'cap',L.perKind..' entries for kind '..kind,id) end
            return buttonHandle(newRecord(kind,'button',pkg,id,data))
        end
        function api.registerMenuLabel(kind,d)
            local name='registerMenuLabel'
            if not validKind(kind) then return refuse(pkg,name,'kind','invalid kind') end
            if kind~='esc' then return refuse(pkg,name,'kind','kind '..kind..' does not support labels (esc only)') end
            if type(d)~='table' then return refuse(pkg,name,'descriptor','expected a table') end
            local id=validId(d.id,L.id) and d.id or nil
            local ok,why=checkKeys(pkg,name,d,LABEL_KEYS,id); if not ok then return nil,why end
            if not id then return refuse(pkg,name,'id','id must match [A-Za-z0-9_-] and be at most '..L.id..' characters') end
            local data,problem=validateLabelFields(pkg,name,id,d,{text=true,color=true,order=true,when=true,visible=true})
            if not data then return nil,problem end
            data.order=data.order or 0; data.id=id
            ok,why=gate(name,id); if not ok then return nil,why end
            local key=pkg..':'..id
            if liveFind(function(r) return r.type=='label' and r.kind==kind and r.key==key end) then
                return refuse(pkg,name,'id','duplicate id in kind '..kind,id)
            end
            if liveCount(function(r) return r.type=='label' and r.kind==kind and r.owner==pkg end)>=L.labels then
                return refuse(pkg,name,'cap',L.labels..' labels per package for kind '..kind,id)
            end
            -- Design §4.1: 32 entries per kind in total, labels and buttons together.
            if liveCount(function(r) return (r.type=='button' or r.type=='label') and r.kind==kind end)>=L.perKind then
                return refuse(pkg,name,'cap',L.perKind..' entries for kind '..kind,id)
            end
            return labelHandle(newRecord(kind,'label',pkg,id,data))
        end
        function api.registerMenuSurface(d)
            local name='registerMenuSurface'
            if type(d)~='table' then return refuse(pkg,name,'descriptor','expected a table') end
            local ok,why=checkKeys(pkg,name,d,SURFACE_KEYS); if not ok then return nil,why end
            local kind=d.kind
            if not validKind(kind) then return refuse(pkg,name,'kind','invalid kind') end
            if isNative(kind) then return refuse(pkg,name,'kind',kind..' is a native menu kind') end
            local axis=d.axis or 'horizontal'
            if axis~='horizontal' and axis~='vertical' then return refuse(pkg,name,'axis','axis must be horizontal or vertical') end
            if type(d.host)~='function' then return refuse(pkg,name,'host','host must be a function') end
            if type(d.open)~='function' then return refuse(pkg,name,'open','open must be a function') end
            local allow,allowList=parseAllow(pkg,name,d.allow)
            if not allow then return nil,allowList end
            ok,why=gate(name); if not ok then return nil,why end
            if declared[kind] then
                return refuse(pkg,name,'kind','surface kind '..kind..' is already declared')
            end
            if liveCount(function(r) return r.type=='surface' and r.owner==pkg end)>=L.surfaces then
                return refuse(pkg,name,'cap',L.surfaces..' surfaces per package')
            end
            local rec=newRecord(kind,'surface',pkg,nil,{axis=axis,allow=allow,allowList=allowList,host=d.host,open=d.open})
            local h=simpleHandle(rec)
            method(h,'Instantiate',function()
                return engine(rec,'Instantiate',function()
                    if rec.status~='present' then return nil,'pending' end
                    if not adapter or type(adapter.instantiate)~='function' then return nil,'no_adapter' end
                    return adapter.instantiate(surfaceSnapshot(rec))
                end)
            end)
            return h
        end
        function api.registerMenuPresenter(p)
            local name='registerMenuPresenter'
            if type(p)~='table' then return refuse(pkg,name,'descriptor','expected a table') end
            local ok,why=checkKeys(pkg,name,p,PRESENTER_KEYS); if not ok then return nil,why end
            for _,key in ipairs({'attach','tick','detach'}) do
                if type(p[key])~='function' then return refuse(pkg,name,key,key..' must be a function') end
            end
            ok,why=gate(name); if not ok then return nil,why end
            if liveFind(function(r) return r.type=='presenter' end) then
                return refuse(pkg,name,'presenter','a presenter is already registered')
            end
            return simpleHandle(newRecord(nil,'presenter',pkg,nil,{attach=p.attach,tick=p.tick,detach=p.detach}))
        end
        function api.registerClickResolver(fn)
            local name='registerClickResolver'
            if type(fn)~='function' then return refuse(pkg,name,'resolver','resolver must be a function') end
            local ok,why=gate(name); if not ok then return nil,why end
            if liveCount(function(r) return r.type=='resolver' and r.owner==pkg end)>=L.resolvers then
                return refuse(pkg,name,'cap',L.resolvers..' click resolvers per package')
            end
            return simpleHandle(newRecord(nil,'resolver',pkg,nil,{fn=fn}))
        end
        -- Groups: the declarer owns the path; only it (or a package in allow, via joinGroup)
        -- adds members. A child path needs the nearest declared ancestor's owner or allow.
        function api.declareGroup(path,opts)
            local name='declareGroup'
            if not validPath(path,L.path,L.depth) then return invalidPath(pkg,name) end
            if opts~=nil and type(opts)~='table' then return refuse(pkg,name,'options','options must be a table') end
            opts=opts or {}
            local ok,why=checkKeys(pkg,name,opts,GROUP_KEYS); if not ok then return nil,why end
            local allow,allowList=parseAllow(pkg,name,opts.allow)
            if not allow then return nil,allowList end
            local root=path:match('^[^/]+')
            if RESERVED_ROOTS[root] then return refuse(pkg,name,'path','group root '..root..' is reserved for Mod Menu') end
            ok,why=gate(name); if not ok then return nil,why end
            local existing=groupDeclared[path]
            if existing then return refuse(pkg,name,'path','group '..path..' is already declared by '..existing.owner) end
            local ancestor=parentPath(path)
            while ancestor and not groupDeclared[ancestor] do ancestor=parentPath(ancestor) end
            if ancestor and not allowed(groupDeclared[ancestor],pkg) then
                return refuse(pkg,name,'path','group '..ancestor..' is owned by '..groupDeclared[ancestor].owner)
            end
            -- No implicit-ancestor takeover: a path above another package's group stays undeclared.
            local blocker
            for other,rec in pairs(groupDeclared) do
                if rec.owner~=pkg and underPath(other,path) and (not blocker or other<blocker) then blocker=other end
            end
            if blocker then
                return refuse(pkg,name,'path','descendant owned by '..groupDeclared[blocker].owner..': '..blocker)
            end
            if groupSlots(pkg)>=L.groups then return refuse(pkg,name,'cap',L.groups..' groups and joins per package') end
            local rec=newRecord(path,'group',pkg,nil,{allow=allow,allowList=allowList})
            rec.joins={}; rec.intended={count=0,by={}}
            return memberHandle(rec)
        end
        function api.joinGroup(path)
            local name='joinGroup'
            if not validPath(path,L.path,L.depth) then return invalidPath(pkg,name) end
            local ok,why=gate(name); if not ok then return nil,why end
            local group=groupDeclared[path]
            if not group then return refuse(pkg,name,'path','unknown group '..path) end
            if group.owner==pkg then return refuse(pkg,name,'path',pkg..' is the owner of group '..path..'; use its declareGroup handle') end
            if not allowed(group,pkg) then return refuse(pkg,name,'path','group '..path..' is owned by '..group.owner) end
            for j in pairs(group.joins) do
                if j.owner==pkg and not j.dead then return refuse(pkg,name,'path','already joined group '..path) end
            end
            if groupSlots(pkg)>=L.groups then return refuse(pkg,name,'cap',L.groups..' groups and joins per package') end
            local rec=newRecord(path,'join',pkg,nil,{})
            rec.group=group; group.joins[rec]=true
            return memberHandle(rec)
        end
        function api.groups(prefix) return listGroups(prefix) end
        function api.groupMembers(path) return groupMembers(path) end
        function api.groupRevision(path) return groupRevision(path) end
        function api.menuAnchors(kind) return self.menuAnchors(self,kind) end
        function api.gameThread(fn,...) return self.gameThread(self,fn,...) end
        return api
    end

    -- Framework-side API (Mod_Menu only; never placed on a package ctx) --------------------
    function self.merge()
        local batch=pending; pending={}
        -- Built-in groups derive only from buttons, labels and surfaces, so a batch of group,
        -- join, presenter or resolver operations skips their rebuild.
        local registryChanged=false
        for _,op in ipairs(batch) do
            local t=op.rec.type
            if t=='button' or t=='label' or t=='surface' then registryChanged=true end
            apply[op.op](op.rec,op.field,op.value,op)
        end
        if registryChanged then refreshBuiltins(true) end
        if #batch>0 then flushGroupRevisions() end
        return #batch
    end
    self.tick=self.merge
    function self.pending() return #pending end
    -- Diagnostics: how many times the built-in groups were rebuilt (construction counts once).
    function self.builtinRebuilds() return builtinRebuildCount end
    -- Live disable: unregisters everything the package owns and refuses new registrations
    -- from it until enablePackage (a later live re-enable).
    function self.disablePackage(_,pkg)
        disabled[pkg]=true
        local owned={}
        for rec in pairs(live) do if rec.owner==pkg then owned[#owned+1]=rec end end
        table.sort(owned,bySeq)
        for _,rec in ipairs(owned) do unregister(rec) end
        return #owned
    end
    function self.enablePackage(_,pkg) disabled[pkg]=nil end
    function self.inGameThread() return inSection() end
    function self.setAdapter(_,value) adapter=value end
    function self.setRetained(_,kind,key,flag) retained[tostring(kind)..'\0'..tostring(key)]=flag and true or nil end
    function self.revision(_,kind) return revisions[kind] or 0 end
    function self.entries(_,kind) return ordered(kind) end
    function self.labels(_,kind)
        local list=sortedLabelRecords(kind)
        for i,rec in ipairs(list) do list[i]=snapshot(rec) end
        return list
    end
    function self.groups(_,prefix) return listGroups(prefix) end
    function self.groupMembers(_,path) return groupMembers(path) end
    function self.groupRevision(_,path) return groupRevision(path) end
    function self.surface(_,kind) return surfaces[kind] and surfaceSnapshot(surfaces[kind]) or nil end
    function self.presenter()
        if not presenterRecord then return nil end
        local d=presenterRecord.data
        return {owner=presenterRecord.owner,attach=d.attach,tick=d.tick,detach=d.detach}
    end
    function self.clickResolvers()
        local out={}
        for i,rec in ipairs(resolvers) do out[i]=rec.data.fn end
        return out
    end
    refreshBuiltins(false) -- native-only built-in groups exist from the start, at revision 0
    return self
end

return R
