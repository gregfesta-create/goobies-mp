-- Engine-independent registry and startup policy. No native loader claims.
local Ini = require('mm_ini')
local M = {}; M.__index = M
M.VERSION = '1.0.1'
function M.identifier(s) return type(s) == 'string' and s:match('^[%w_%-]+$') ~= nil end
function M.safeId(s)
    if not M.identifier(s) then return false end
    local k=s:lower()
    if k=='mods' or k=='modlist' or k=='mod_menu' or (k=='modmenu' and s~='ModMenu') then return false end
    return not (k=='con' or k=='prn' or k=='aux' or k=='nul' or k:match('^com[0-9]$') or k:match('^lpt[0-9]$'))
end
function M.version(s)
    return type(s)=='string' and (s:match('^%d+%.%d+%.%d+$') or s:match('^%d+%.%d+%.%d+[-+][%w%.%+%-]+$'))~=nil
end
function M.manifest(text)
    local ini = Ini.read(text); local p = ini.Package
    if not p or not M.safeId(p.Id) or not M.version(p.Version) then
        return nil, 'Invalid package Id or Version'
    end
    if p.Entry and p.Entry ~= 'Package/main.lua' then return nil, 'Entry must be Package/main.lua' end
    if p.LiveToggle and p.LiveToggle~='true' and p.LiveToggle~='false' then return nil,'LiveToggle must be true or false' end
    if p.InternalService and p.InternalService~='true' and p.InternalService~='false' then return nil,'InternalService must be true or false' end
    if p.InternalService=='true' and p.Entry then return nil,'InternalService cannot hide a managed mod entry' end
    local dependencies,optional={},{ }
    local section,seen='',{}
    for _,line in ipairs(Ini.lines(text)) do
        local header=Ini.header(line)
        if header then section=header
        elseif (section=='Dependencies' or section=='OptionalDependencies') and not line:match('^%s*[;#]') and not line:match('^%s*$') then
            local id,version=line:match('^%s*([%w_%-]+)%s*=%s*(.-)%s*$')
            if not id or not M.safeId(id) or (version~='*' and not M.version(version)) then
                return nil,p.Id..': invalid dependency declaration in '..section
            end
            if seen[id:lower()] then return nil,p.Id..': duplicate dependency '..id end
            seen[id:lower()]=true
            local target=section=='Dependencies' and dependencies or optional
            target[#target+1]={id=id,version=version}
        end
    end
    return { id = p.Id, name = p.Name or p.Id, version = p.Version,
        updatedDate=Ini.date(p.Updated) and p.Updated or '?',
        entry = p.Entry, default = p.DefaultEnabled == 'true', liveToggle=p.LiveToggle=='true', internalService=p.InternalService=='true', dependencies=dependencies,optionalDependencies=optional }
end
function M.new(fs, path, log, options)
    options=options or {}
    local self = setmetatable({fs=fs, path=path, log=log or print, mods={}, byId={}, providers={}, dirtyProviders={}}, M)
    local err
    self.diskText,err=fs.read(path)
    if err and err~='missing' then self.blocked='Cannot safely read ModList.ini: '..err end
    self.text=self.diskText
    if not self.text and not self.blocked and options.legacyPath then
        local old,why=fs.read(options.legacyPath)
        if why and why~='missing' then self.blocked='Cannot safely read legacy registry: '..why
        elseif old then
            self.text=old; self.legacyPath=options.legacyPath; self.legacyText=old
            self.log('Migrating legacy registry to ModList.ini; the legacy file will not be edited.')
        end
    end
    self.text=self.text or options.defaultText or '[Mods]\n'
    if self.text:find('\0',1,true) then self.blocked='Unsupported registry encoding (NUL bytes); preserve and repair the file.' end
    local issues
    self.records,issues=Ini.registry(self.text,M.version)
    self.suppressDefaults=self.blocked~=nil or #issues>0
    self.warning=self.blocked or (#issues>0 and table.concat(issues,'; ') or nil)
    if self.blocked then self.log(self.blocked) end
    for _,issue in ipairs(issues) do self.log(issue) end
    return self
end
function M:add(package)
    if not M.safeId(package.id) then return nil,'Invalid or reserved package id: '..tostring(package.id) end
    for id in pairs(self.byId) do if id:lower()==package.id:lower() then return nil,'Duplicate package id: '..package.id end end
    local record=self.records[package.id:lower()]
    package.installedDate=record and record.metadata and record.metadata.installed or '?'
    if not Ini.date(package.installedDate) then package.installedDate=os.date('%Y-%m-%d') end
    package.updatedDate=Ini.date(package.updatedDate) and package.updatedDate or '?'
    package.registryExtras=record and record.metadata and record.metadata.extras or {}
    package.registryComment=record and record.metadata and record.metadata.comment
    local enabled=false
    if not self.blocked then
        if record then enabled=record.on
        elseif not self.suppressDefaults then enabled=package.default==true end
    end
    package.configWarning=record and record.problem or self.blocked
    if package.id == 'ModMenu' then enabled = true; package.locked = true end
    package.enabled, package.startEnabled = enabled, enabled
    package.active = nil -- External packages have unknown runtime state.
    if package.managed or package.locked then package.active=false end
    self.byId[package.id] = package; self.mods[#self.mods + 1] = package
    return package
end
-- Reload saved choices, then activate opted-in entries once; startup state stays intact.
function M:refresh()
    local disk,err=self.fs.read(self.path)
    if not disk then return nil,'Cannot refresh ModList.ini: '..tostring(err or 'missing') end
    if disk:find('\0',1,true) then return nil,'Cannot refresh unsupported registry encoding.' end
    local records,issues=Ini.registry(disk,M.version)
    if #issues>0 then return nil,'Cannot refresh ModList.ini: '..table.concat(issues,'; ') end
    local changed=disk~=self.diskText
    local loadedBefore=0
    for _,p in ipairs(self.mods) do if p.active then loadedBefore=loadedBefore+1 end end
    self.text,self.diskText,self.records=disk,disk,records
    self.blocked,self.warning,self.legacyPath=nil,nil,nil
    self.suppressDefaults=false; self.reportedUnknown=nil
    for _,p in ipairs(self.mods) do
        local r=records[p.id:lower()]
        p.enabled=p.locked or (r and r.on==true) or false
        p.configWarning=nil
        if r and r.metadata then
            if Ini.date(r.metadata.installed) then p.installedDate=r.metadata.installed end
            p.registryExtras=r.metadata.extras or {}
            p.registryComment=r.metadata.comment
        end
    end
    local ok,why=self:activateLive()
    if not ok then return nil,why end
    local alreadyApplied=self.liveChoicesApplied
    self.liveChoicesApplied=nil
    local loadedAfter=0
    for _,p in ipairs(self.mods) do if p.active then loadedAfter=loadedAfter+1 end end
    local activated=loadedAfter-loadedBefore
    if activated>0 then return true,'Refresh complete. '..activated..(activated==1 and ' mod activated.' or ' mods activated.') end
    return true,changed and 'Refresh complete. Mod list reloaded.' or (alreadyApplied and 'Refresh complete. All changes already applied.' or 'Refresh complete. No changes found.')
end
function M:activateLive()
    local visiting,errors={},{}
    local function activate(p)
        if p.active or not p.enabled or not p.managed or not p.liveToggle then return end
        if visiting[p.id] then return end
        visiting[p.id]=true
        local problem=self:dependencyProblem(p)
        if not problem then
            for _,dep in ipairs(p.dependencies or {}) do
                local target
                for id,q in pairs(self.byId) do if id:lower()==dep.id:lower() then target=q; break end end
                if target then activate(target) end
                if not target or not target.active then problem=p.id..': dependency not active; refresh its live-capable package or restart'; break end
            end
        end
        visiting[p.id]=nil
        if problem then p.dependencyError=problem; errors[#errors+1]=problem; return end
        if p.liveAttempted then errors[#errors+1]=p.id..': activation previously failed; restart before retrying'; return end
        if not self.loadPackage or not self.context then errors[#errors+1]=p.id..': runtime activation unavailable'; return end
        p.liveAttempted=true
        local ok,result=pcall(function() return self.loadPackage(p,self.context(p)) end)
        p.active=ok
        if ok then p.error=nil; p.dependencyError=nil; self.log(p.id..': activated by Refresh')
        else
            self.providers[p.id]=nil; self.dirtyProviders[p.id]=nil
            local described,message=pcall(tostring,result)
            p.error=described and type(message)=='string' and message or 'Unable to describe activation error'
            errors[#errors+1]=p.id..': activation failed: '..p.error
        end
    end
    for _,p in ipairs(self.mods) do activate(p) end
    return #errors==0 or nil,#errors>0 and table.concat(errors,'; ') or nil
end
function M:save(changes)
    if self.blocked then return nil,self.blocked end
    local disk,err = self.fs.read(self.path)
    if err and err~='missing' then return nil,'Cannot read ModList.ini: '..err end
    if self.legacyPath then
        local old,why=self.fs.read(self.legacyPath)
        if old~=self.legacyText or (why and why~='missing') then return nil,'Legacy registry changed during migration; restart before editing.' end
    end
    local nextText = self.text
    for _, p in ipairs(self.mods) do
        local enabled = changes and changes[p.id]
        if enabled == nil then enabled = p.enabled end
        if p.locked then enabled = true end
        if p.version then
            local value=tostring(enabled)..'|Ver:'..p.version..'|Inst:'..(p.installedDate or '?')..'|Upd:'..(p.updatedDate or '?')
            for _,extra in ipairs(p.registryExtras or {}) do value=value..'|'..extra end
            if p.registryComment then value=value..' '..p.registryComment end
            nextText=Ini.set(nextText,'Mods',p.id,value,true)
        end
    end
    if disk ~= self.diskText then
        -- Game windows sharing one install boot together: another window may have just written exactly this registry.
        if disk == nil or disk ~= nextText then return nil, 'ModList.ini changed externally. Refresh before editing.' end
        self.text, self.diskText, self.legacyPath = disk, disk, nil
    end
    if not self.reportedUnknown then
        for id in pairs(self.records) do
            local known=false
            for registered in pairs(self.byId) do if registered:lower()==id then known=true end end
            if not known then self.log('Unregistered registry entry preserved without execution: '..id) end
        end
        self.reportedUnknown=true
    end
    if nextText ~= self.diskText then
        local ok, err = self.fs.replace(self.path, nextText)
        if not ok then return nil, err end
        self.text = nextText
        self.diskText = nextText
        self.legacyPath=nil
    end
    for _, p in ipairs(self.mods) do
        if changes and changes[p.id] ~= nil then
            if p.liveToggle and p.active and p.enabled~=changes[p.id] then self.liveChoicesApplied=true end
            p.enabled = changes[p.id]
        end
        if p.locked then p.enabled = true end
    end
    return true
end
-- Resolve required edges against installed manifest versions and requested state.
-- Optional declarations are advisory and never make a package mandatory.
function M:dependencyProblem(package,changes,running,visiting)
    if package.locked then return nil end
    visiting=visiting or {}
    if visiting[package.id] then return package.id..': required dependency cycle' end
    visiting[package.id]=true
    for _,dep in ipairs(package.dependencies or {}) do
        local target
        for id,p in pairs(self.byId) do if id:lower()==dep.id:lower() then target=p; break end end
        local prefix=package.id..': requires '..dep.id..' ('..dep.version..'): '
        if not target then visiting[package.id]=nil; return prefix..'not installed' end
        local enabled=changes and changes[target.id]
        if enabled==nil then if running then enabled=target.startEnabled else enabled=target.enabled end end
        if not enabled then visiting[package.id]=nil; return prefix..'disabled' end
        if not target.locked and not target.managed then visiting[package.id]=nil; return prefix..'external loader state cannot be verified' end
        if dep.version~='*' and dep.version~=target.version then visiting[package.id]=nil; return prefix..'installed version '..tostring(target.version) end
        local problem=self:dependencyProblem(target,changes,running,visiting)
        if problem then visiting[package.id]=nil; return prefix..problem end
    end
    visiting[package.id]=nil
end
function M:changeProblem(changes)
    for _,p in ipairs(self.mods) do
        local nextEnabled=changes[p.id]
        if nextEnabled==nil then nextEnabled=p.enabled end
        if p.managed and not p.locked and nextEnabled then
            local problem=self:dependencyProblem(p,changes)
            -- Unrelated pre-existing failures do not forbid unrelated repairs.
            if problem and (changes[p.id]==true or not self:dependencyProblem(p)) then return problem end
        end
    end
end
function M:setEnabled(id, on)
    local p = self.byId[id]
    if not p or type(on) ~= 'boolean' then return nil, 'Invalid enabled state' end
    if p.locked and not on then return nil, 'The mod manager is permanently enabled.' end
    if not p.locked and not p.managed then return nil, p.reason or 'This package is not controlled by ModList.ini.' end
    local changes={[id]=on}
    local problem=self:changeProblem(changes)
    if problem then return nil,problem..'. Change not saved; disable affected dependents first.' end
    return self:save(changes)
end
function M:disableAll()
    local changes = {}
    for _, p in ipairs(self.mods) do if p.managed and not p.locked then changes[p.id] = false end end
    local problem=self:changeProblem(changes)
    if problem then return nil,problem..'. Change not saved.' end
    return self:save(changes)
end
function M:enableAll()
    local changes={}
    for _,p in ipairs(self.mods) do if p.managed and not p.locked then changes[p.id]=true end end
    local problem=self:changeProblem(changes)
    if problem then return nil,problem..'. Change not saved.' end
    return self:save(changes)
end
function M:restartRequired()
    local pending=false
    local errors={}
    for _, p in ipairs(self.mods) do
        if p.managed and ((p.liveToggle and p.enabled and not p.active and p.error~=nil) or (not p.liveToggle and p.enabled ~= p.startEnabled)) then pending=true end
    end
    for id, provider in pairs(self.providers) do
        local ok, required = pcall(function()
            local package=self.byId[id]
            if package and package.liveToggle and not package.enabled then return false end
            if provider.restartRequired==nil then return false end
            assert(type(provider.restartRequired)=='function','Expected restartRequired callback')
            local value=provider.restartRequired()
            assert(type(value)=='boolean','restartRequired must return a boolean')
            return value
        end)
        if not ok then errors[#errors+1]=id..': restart requirement unknown; check the settings provider.'
        elseif required then pending=true end
    end
    table.sort(errors)
    return pending,#errors>0 and table.concat(errors,' ') or nil
end
function M:query(id)
    local p = self.byId[id]
    if not p and type(id)=='string' then
        for registered,package in pairs(self.byId) do
            if registered:lower()==id:lower() then p=package; break end
        end
    end
    if not p then return {installed=false} end
    if p.unknown then return {installed=true,managed=false} end
    return {installed=true, version=p.version, enabled=p.enabled, active=p.active,
        startupEnabled=p.startEnabled, managed=p.managed == true, error=p.error, dependencyError=p.dependencyError}
end
function M:provider(id, provider)
    assert(self.byId[id], 'Register a package before its settings provider')
    assert(type(provider) == 'table' and type(provider.build) == 'function', 'Provider requires build(ui, panel)')
    self.providers[id] = provider
end
function M:start(loadPackage, context)
    self.loadPackage,self.context=loadPackage,context
    local visited,visiting={},{}
    local function start(p)
        if visited[p.id] then return end
        if p.locked then p.active=true; visited[p.id]=true; return end
        if not p.managed or not p.startEnabled then visited[p.id]=true; return end
        local problem=self:dependencyProblem(p,nil,true)
        if problem then
            p.active=false; p.dependencyError=problem; p.error=problem
            pcall(self.log,problem); visited[p.id]=true; return
        end
        if visiting[p.id] then return end
        visiting[p.id]=true
        for _,dep in ipairs(p.dependencies or {}) do
            for id,target in pairs(self.byId) do
                if id:lower()==dep.id:lower() then
                    start(target)
                    if not target.active then problem=p.id..': required dependency '..target.id..' failed startup' end
                    break
                end
            end
            if problem then break end
        end
        visiting[p.id]=nil; visited[p.id]=true
        if problem then p.active=false; p.dependencyError=problem; p.error=problem; pcall(self.log,problem); return end
        p.liveAttempted=true
        local ok,result=pcall(function() return loadPackage(p,context(p)) end)
        p.active=ok
        if not ok then
            -- A provider registered by an entry that then failed is incomplete.
            -- Discard its callbacks, preserving disk configuration and other providers.
            self.providers[p.id]=nil; self.dirtyProviders[p.id]=nil
            local described,text=pcall(tostring,result)
            p.error=described and type(text)=='string' and text or 'Unable to describe startup error'
            pcall(self.log,p.id..': startup failed: '..p.error)
        end
    end
    for _,p in ipairs(self.mods) do start(p) end
end
return M
