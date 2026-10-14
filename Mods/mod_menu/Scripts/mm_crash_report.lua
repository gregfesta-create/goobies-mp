-- Automatic crash reports. A few seconds after the game starts, run the shipped collector hidden with -AutoCrash:
-- CollectCrashReport.ps1 decides everything (webhook, consent ask|auto|off, new crashes of this game copy, daily
-- limit) and exits silently when there is nothing to do. Nothing here blocks the game thread: the run is deferred
-- (UE4SS ExecuteWithDelay) and started with "start /b", which returns at once. Same launch pattern as mm_restart.
local FS=require('mm_platform')
local C={}
C.DELAY_MS=8000
C.SCRIPT='CollectCrashReport.ps1'
function C.command(script)
    return 'start "" /b powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '..
        FS.shellPath(script)..' -AutoCrash'
end
-- paths: FS.paths result (mod = Mods/mod_menu). effects (tests): exists(path), launch(command), delay(ms, fn).
-- Returns true when the run was scheduled, else nil and why (logged).
function C.start(paths,log,effects,G)
    G=G or _G
    effects=effects or {
        exists=function(p) return FS.read(p)~=nil end,
        launch=os.execute,
        delay=type(G.ExecuteWithDelay)=='function' and function(ms,fn) G.ExecuteWithDelay(ms,fn) end or nil}
    local ok,result=pcall(function()
        local script=paths.mod..'/'..C.SCRIPT
        assert(script:match('^%a:[/\\]') and not script:find('..',1,true),'Invalid collector path')
        assert(effects.exists(script),C.SCRIPT..' missing next to Mod Menu; automatic crash reports are off')
        local command=C.command(script)
        assert(type(effects.delay)=='function','No deferred execution available; automatic crash reports are off')
        local done=false
        effects.delay(C.DELAY_MS,function()
            if done then return end
            done=true
            local called,launched=pcall(effects.launch,command)
            log('Crash report check started: '..tostring(called)..'; result='..tostring(launched))
        end)
        return true
    end)
    if not ok then
        local why='Crash report check not started: '..tostring(result)
        log(why); return nil,why
    end
    return true
end
return C
