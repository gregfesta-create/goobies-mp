-- Only affirmative UI actions start this bounded handshake. Never force-kill.
local FS=require('mm_platform')
local R={}; R.__index=R
local function exists(path)
    local f,e=io.open(path,'rb'); if not f then return nil,e end
    f:close(); return true
end
function R.new(G,paths,log,effects)
    return setmetatable({G=G,paths=paths,log=log,e=effects or {
        now=os.time,read=FS.read,write=FS.replace,exists=exists,launch=os.execute,
        defer=function(fn) assert(type(G.ExecuteAsync)=='function','Asynchronous restart unavailable'); G.ExecuteAsync(fn) end,
        token=function() return tostring(os.time())..'-'..tostring(math.random(100000,999999)) end
    }},R)
end
function R:fail(message)
    local p=self.waiting
    if p then
        local called,ok,err=pcall(self.e.write,p.receipt..'.cancel','CANCEL')
        if not called or not ok then message=message..'; cancellation file failed: '..tostring(err or ok)..'. Helper deadline still applies.' end
    end
    self.waiting=nil; self.status=tostring(message)..' Restart manually or retry after the helper deadline (15 seconds).'
    self.log(self.status); return nil,self.status
end
function R:cancel()
    if not self.waiting then return true end
    return self:fail('Restart canceled.')
end
function R:request()
    if self.waiting then return nil,'A restart is already pending.' end
    local ok,result,message=pcall(function()
        local helper=self.paths.mod..'/Restart.ps1'
        local exe=self.paths.root..'/Shooter-Win64-Shipping.exe'
        for _,path in ipairs({helper,exe}) do
            FS.shellPath(path)
            assert(path:match('^%a:[/\\]') and not path:find('..',1,true),'Invalid absolute restart path')
            local found,why=self.e.exists(path); assert(found,'Missing or unreadable restart file: '..path..': '..tostring(why))
        end
        local receipt=self.paths.configs..'/ModMenu.restart-'..self.e.token()
        for _,suffix in ipairs({'.ready','.armed','.commit','.cancel','.error','.started','.identity','.exited','.remaining'}) do
            local old,why=self.e.read(receipt..suffix)
            assert(not old and (not why or why=='missing'),'Stale or unreadable restart receipt; retry.')
        end
        local command='start "" /b powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File '..
            FS.shellPath(helper)..' -Win64 '..FS.shellPath(self.paths.root)..' -Receipt '..FS.shellPath(receipt)
        local pending={receipt=receipt,started=self.e.now()}
        self.waiting=pending
        local function launch()
            if self.waiting~=pending then return end
            local called,launched=pcall(self.e.launch,command)
            self.log('Restart helper launch returned: '..tostring(called)..'; result='..tostring(launched))
            if not called or (launched~=true and launched~=0) then pending.launchError='Could not start restart helper.' end
        end
        if self.e.defer then self.e.defer(launch) else launch() end -- synchronous injected mock effects only
        if pending.launchError then return self:fail(pending.launchError) end
        self.status='Restart preparation pending.'; return true,self.status
    end)
    if not ok then return self:fail('Restart failed: '..tostring(result)) end
    return result,message
end
function R:tick(menu)
    if not self.waiting then return self.status end
    local ok,err=pcall(function()
        local p=self.waiting
        if p.launchError then error(p.launchError) end
        local failure=self.e.read(p.receipt..'.error')
        if failure then error(failure) end
        if self.e.now()-p.started>(p.committed and 6 or 10) then error('Restart timed out; game left running.') end
        local ready=self.e.read(p.receipt..'.ready')
        if not p.committed and ready then
            assert(ready=='READY','Invalid restart acknowledgement')
            local wrote,why=self.e.write(p.receipt..'.commit',tostring(self.e.now()))
            assert(wrote,why)
            p.committed=true; p.started=self.e.now()
            self.log('Restart commit published; awaiting ARMED')
            self.status='Restart prepared; waiting for helper authorization to exit.'
        end
        if p.committed and not p.quitRequested and not p.armReadTraced then
            p.armReadTraced=true
            self.log('Restart before ARMED receipt read')
        end
        if p.committed and not p.quitRequested and self.e.read(p.receipt..'.armed') then
            self.log('Restart ARMED receipt observed')
            assert(self.e.read(p.receipt..'.armed')=='ARMED','Invalid exit acknowledgement')
            assert(self.e.now()-p.started<3,'Exit authorization expired')
            local function trace(stage)
                self.log('Restart exit trace: '..stage)
                local wrote,why=self.e.write(p.receipt..'.quit-stage',tostring(self.e.now())..' '..stage)
                assert(wrote,'Cannot preserve quit diagnostic: '..tostring(why))
            end
            trace('before quit-library lookup')
            local lib=self.G.StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
            trace('before owning-player lookup')
            local pc=menu and menu:GetOwningPlayer()
            assert(lib and lib:IsValid() and pc and pc:IsValid(),'Cannot safely quit without owning player and quit API')
            p.quitRequested=true
            self.status='Exit requested; waiting for the helper to verify exit and launch.'
            trace('before QuitGame')
            lib:QuitGame(menu,pc,0,false)
            trace('QuitGame returned')
        end
    end)
    if not ok then self:fail('Restart failed: '..tostring(err)) end
    return self.status
end
return R
