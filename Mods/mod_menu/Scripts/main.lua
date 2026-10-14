-- UE4SS entry: this is the only auto-started Lua mod in the managed-package design.
local source=debug.getinfo(1,'S').source
local scripts=assert(source:match('^@(.*)[/\\]main%.lua$'),'Cannot locate mod_menu Scripts')
package.path=scripts .. '/?.lua;' .. package.path
local function log(message) print('[mod_menu] ' .. tostring(message) .. '\n') end
local ok,err=pcall(function()
    -- D57: Mod Menu's achievement block (native ModMenuGuard); one MMGUARD line now, the notice on the main menu
    local guard=require('mm_guard').new(_G,log)
    guard:start()
    local FS=require('mm_platform'); local Core=require('mm_core')
    local tree=IterateGameDirectories()
    local paths=FS.paths(source,tree)
    assert(FS.ensureConfigs(paths.configs),'Cannot create build-local Configs directory')
    local core=Core.new(FS,paths.configs .. '/ModList.ini',log,{
        legacyPath=paths.configs .. '/mods.ini',
        defaultText=FS.read(paths.mod .. '/Defaults/Configs/ModList.ini') or '[Mods]\nModMenu=true|Ver:'..Core.VERSION..'|Inst:?|Upd:?\n'})
    local own=assert(Core.manifest(assert(FS.read(paths.mod .. '/mod_menu.ini'),'Manager manifest missing')))
    assert(own.id=='ModMenu' and own.version==Core.VERSION,'Manager manifest does not match implementation')
    core:add(own)
    for _,folder in ipairs(FS.folders(tree,paths.mods)) do
        if folder:lower()~='mod_menu' and Core.identifier(folder) then
            local base=paths.mods .. '/' .. folder
            local text=FS.read(base .. '/mod_menu.ini')
            if text then
                local p,problem=Core.manifest(text)
                if p then
                    p.folder=base
                    p.managed=p.entry~=nil and FS.absent(base .. '/Scripts/main.lua') and FS.absent(base .. '/dlls/main.dll')
                    if not p.managed then p.reason='External UE4SS/native package: ModList.ini cannot prevent its loading.' end
                    local added,why=core:add(p); if not added then log(why) end
                else log(folder .. ': ' .. problem) end
            elseif FS.read(base .. '/Scripts/main.lua') or FS.read(base .. '/dlls/main.dll') then
                core:add({id=folder,name=folder,managed=false,unknown=true,
                    reason='No mod_menu manifest: version and enabled state are unknown. Managed-package conversion is required.'})
            end
        end
    end
    local saved,why=core:save()
    if not saved then
        log('Registry save failed; optional managed startup suppressed: ' .. tostring(why))
        core.warning=tostring(why)
        for _,p in ipairs(core.mods) do if not p.locked then p.startEnabled=false end end
    end
    local ui
    local menuStyles={}
    local gameMenuStyles={}
    local menuBackHandlers={}
    local mainMenuButtons={}
    local navigationSerial=0
    local escapePreference
    local function context(p)
        local config=paths.configs .. '/' .. p.id .. '.ini'
        -- Context is requested only for enabled packages during startup.
        local initial,defaultError=FS.read(p.folder..'/Defaults/Configs/'..p.id..'.ini')
        if defaultError and defaultError~='missing' then error(defaultError) end
        local prepared,problem=FS.prepareSettings(config,initial)
        assert(prepared,problem)
        return {id=p.id,packagePath=p.folder,configPath=config,Widgets=require('mm_widgets'),readConfig=function() return FS.read(config) end,
            writeConfig=function(text) return FS.replace(config,text) end,
            query=function(id) return core:query(id) end,
            requestMenuBack=function() if ui then ui:requestBack() end end,
            registerMenuBack=function(callback)
                assert(type(callback)=='function','Expected menu back callback')
                menuBackHandlers[p.id]=callback
                return function() if menuBackHandlers[p.id]==callback then menuBackHandlers[p.id]=nil end end
            end,
            registerMenuNavigation=function(descriptor)
                assert(type(descriptor)=='table' and type(descriptor.id)=='string' and type(descriptor.isVisible)=='function'
                    and type(descriptor.back)=='function','Expected menu navigation descriptor')
                local key=p.id..':'..descriptor.id
                assert(menuBackHandlers[key]==nil,'Duplicate menu navigation id')
                navigationSerial=navigationSerial+1
                local item={owner=p.id,id=descriptor.id,isVisible=descriptor.isVisible,back=descriptor.back,
                    canBack=descriptor.canBack,priority=descriptor.priority or 0,serial=navigationSerial,generation=1}
                assert(type(item.priority)=='number' and item.priority==math.floor(item.priority) and math.abs(item.priority)<=1000,'Invalid menu navigation priority')
                menuBackHandlers[key]=item
                return function() if menuBackHandlers[key]==item then menuBackHandlers[key]=nil end end,
                    function()
                        if menuBackHandlers[key]~=item then return false end
                        navigationSerial=navigationSerial+1;item.serial=navigationSerial;item.generation=item.generation+1;return true
                    end
            end,
            registerMainMenuButton=function(menu,descriptor)
                local key=p.id..':'..tostring(descriptor and descriptor.id)
                local old=mainMenuButtons[key]
                assert(not old or (not old.active and not old.restore and not old.cleanupPending),'Duplicate or retained main-menu button id')
                local handle,why,retained=require('mm_main_menu_button').Create(_G,require('mm_widgets'),menu,descriptor)
                mainMenuButtons[key]=handle or retained
                return handle,why,retained
            end,
            mainMenuButtonStyle=function(button)
                for _,handle in pairs(mainMenuButtons) do
                    if handle.active and handle.widget:IsValid() and button and button:IsValid()
                        and handle.widget:GetFullName()==button:GetFullName() then
                        return {styleRole=handle.styleRole,baseFontSize=handle.baseFontSize}
                    end
                end
            end,
            registerEscapePreference=function(callback)
                assert(type(callback)=='function','Expected Escape preference callback')
                escapePreference=callback
            end,
            registerMainMenuStyle=function(callback)
                assert(type(callback)=='function','Expected main menu style callback')
                menuStyles[p.id]=callback
            end,
            registerGameMenuStyle=function(callback,cleanup)
                assert(type(callback)=='function' and type(cleanup)=='function','Expected game menu style and cleanup')
                local previous=gameMenuStyles[p.id]
                if previous then pcall(previous.cleanup) end
                local item={tick=callback,cleanup=cleanup};gameMenuStyles[p.id]=item
                return function()
                    if gameMenuStyles[p.id]==item then gameMenuStyles[p.id]=nil;pcall(cleanup) end
                end
            end,
            registerSettings=function(provider) core:provider(p.id,provider) end,
            invalidate=function() core.dirtyProviders[p.id]=true end,
            log=function(message) log(p.id .. ': ' .. tostring(message)) end}
    end
    -- Enabled packages run before UI initialization, so a UI failure does not prevent startup.
    -- Package/main.lua avoids UE4SS's Scripts/dlls discovery and duplicate execution.
    core:start(function(p,ctx)
        local environment=setmetatable({ModMenu=ctx},{__index=_G})
        environment._G=environment
        local chunk=assert(loadfile(p.folder .. '/' .. p.entry,'t',environment))
        return chunk(ctx)
    end,context)
    local UI=require('mm_ui'); local Restart=require('mm_restart')
    ui=UI.new(_G,core,paths,log,Restart.new(_G,paths,log))
    ui.menuStyles=menuStyles
    ui.gameMenuStyles=gameMenuStyles
    ui.menuBackHandlers=menuBackHandlers
    if Key and Key.ESCAPE and type(RegisterKeyBind)=='function' then
        RegisterKeyBind(Key.ESCAPE,function()
            local allow=true
            if escapePreference then local success,value=pcall(escapePreference);allow=success and value==true end
            ui:requestBack(allow)
        end)
    end
    ui.status=core.warning
    ui.guardNotice=guard:notice()
    if type(LoopAsync)=='function' then LoopAsync(10000,function() pcall(guard.tick,guard); return false end) end
    ui:start()
    -- State-local inspection handle; not an inter-mod-Lua-state communication claim.
    ModMenuManager={registry=core,ui=ui,paths=paths,guard=guard}
    -- Automatic crash reports (hidden collector run, deferred a few seconds); never allowed to break startup.
    local crashOk,crashStarted=pcall(function() return require('mm_crash_report').start(paths,log,nil,_G) end)
    if not crashOk then log('Crash report check failed: '..tostring(crashStarted)) end
    ModMenuManager.crashReport=crashOk and crashStarted==true
    log('Initialized standalone manager ' .. Core.VERSION)
end)
if not ok then log('Initialization failed: ' .. tostring(err)) end
