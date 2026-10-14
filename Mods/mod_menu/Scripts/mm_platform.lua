local M = {}
-- Config transactions (several game windows can share ONE install and its Configs folder, so writers can overlap):
--   <path>.mm-lock          the per-file lock: "<token> <os.time()>". Taken by renaming the writer's own
--                           <path>.mm-lock-<token> onto it; a rename onto an existing name fails on Windows, so
--                           exactly one writer holds it.
--   <path>.mm-new-<token>   the writer's new content (written and verified before anything is renamed)
--   <path>.mm-bak-<token>   the previous live file while the new one is promoted
--   <path>.mm-brk-<token>   a dead writer's lock while this writer recovers it
-- token: per process (per writer in tests), 1-8 letters or digits; suffixes stay at most 17 characters so names stay
-- under Windows MAX_PATH even for long settings backups. A reader that finds <path> missing (a writer between its two
-- renames, or one that died there) reads the lock holder's backup, so a registry never turns into defaults.
-- A lock older than STALE_SECONDS belongs to a dead writer (a transaction takes milliseconds): the next writer
-- restores the dead writer's backup when <path> is missing, then removes only the dead writer's own files, named by
-- its lock. Nothing else is ever deleted. Older Mod Menu names (.modmenu-new / .modmenu-backup, and .modmenu-lock with
-- .modmenu-backup-<token>) are still read for recovery and block writes ('Unfinished config transaction').
M.SUFFIX = { lock = '.mm-lock', new = '.mm-new-', bak = '.mm-bak-', brk = '.mm-brk-' }
M.MAX_SUFFIX = 17   -- the longest: '.mm-lock-' or '.mm-brk-' plus an 8-character token
M.STALE_SECONDS = 30
M.WAIT_ATTEMPTS = 100   -- lock retries before 'busy' (each pause is about 5 ms)
local function validToken(t) return type(t)=='string' and #t>=1 and #t<=8 and t:match('^[%w]+$')~=nil end
-- 8 base-36 characters mixed from the time, this process's table address (ASLR) and the clock and random state.
local function newToken()
    local digits='0123456789abcdefghijklmnopqrstuvwxyz'
    local address=tonumber(tostring({}):match('(%x+)$') or '0',16) or 0
    local seed=(os.time()*1000003+address+math.floor(os.clock()*1000000))%2147483648
    local out={}
    for i=1,8 do
        seed=(seed*1103515245+12345+math.random(0,32767))%2147483648
        local k=math.floor(seed%36)+1
        out[i]=digits:sub(k,k)
    end
    return table.concat(out)
end
M.newToken = newToken
M.token = newToken()
local function rawRead(path)
    local f,err,code = io.open(path, 'rb')
    if not f then
        if code~=2 and err~=nil then return nil,'Read failed: '..tostring(err) end
        return nil,'missing'
    end
    local s,why = f:read('*a'); local closed,closeError=f:close()
    if s==nil or not closed then return nil,'Read failed: '..tostring(why or closeError) end
    return s
end
-- The lock file's holder: token, time, text | nil, problem ('missing' when there is no lock).
-- legacy: the .modmenu-lock of the previous Mod Menu build, whose tokens were up to 48 characters (read-only use).
local function lockHolder(path,lockName,legacy)
    local text,err=rawRead(path..(lockName or M.SUFFIX.lock))
    if not text then return nil,err end
    local token,at=text:match('^([%w]+) (%d+)\n?$')
    if not (validToken(token) or (legacy and token and #token<=48)) then return nil,'unrecognized' end
    return token,tonumber(at),text
end
function M.read(path)
    local s,err=rawRead(path)
    if s or err~='missing' then return s,err end
    -- A writer between its two renames (or one that died there) keeps the previous file as its backup.
    for _,form in ipairs({{M.SUFFIX.lock,M.SUFFIX.bak},{'.modmenu-lock','.modmenu-backup-',true}}) do
        local holder,at=lockHolder(path,form[1],form[3])
        if holder then
            local backup,why=rawRead(path..form[2]..holder)
            if backup then
                if os.time()-at>M.STALE_SECONDS then print('[mod_menu] Using preserved configuration backup for '..path..'; the next save restores it.\n') end
                return backup
            end
            if why~='missing' then return nil,'Backup read failed: '..tostring(why) end
            s,err=rawRead(path)   -- that writer has just finished
            if s or err~='missing' then return s,err end
        end
    end
    -- A power loss in an older Mod Menu between the two renames must not turn an existing registry into defaults.
    local legacy,legacyError=rawRead(path .. '.modmenu-backup')
    if legacy then print('[mod_menu] Using preserved configuration backup for ' .. path .. '; manual recovery required.\n'); return legacy end
    if legacyError~='missing' then return nil,'Backup read failed: '..tostring(legacyError) end
    return nil,'missing'
end
function M.absent(path)
    local text,err=M.read(path)
    return text==nil and (err==nil or err=='missing')
end
local function busyPause()
    local start=os.clock()
    while os.clock()-start<0.005 do end
end
-- A dead writer's lock: move it aside (only one breaker wins), finish or undo its transaction, remove its own files.
-- -> true (broken) | false (someone else acted; retry) | nil, problem
local function breakStale(path,token,holder,content)
    local lock=path..M.SUFFIX.lock
    local aside=path..M.SUFFIX.brk..token
    if not os.rename(lock,aside) then return false end
    if rawRead(aside)~=content then
        -- Someone took the lock in between: give it back untouched.
        if not os.rename(aside,lock) then return nil,'Config lock changed while recovering: '..path end
        return false
    end
    local backup,temp=path..M.SUFFIX.bak..holder,path..M.SUFFIX.new..holder
    local live=rawRead(path)
    if live==nil and rawRead(backup)~=nil then
        -- It died between its renames: the previous version comes back (its new content was never committed).
        if not os.rename(backup,path) then os.rename(aside,lock); return nil,'Cannot restore preserved backup: '..path end
    elseif live~=nil then
        os.remove(backup)   -- it died after promoting: the backup is the old version
    end
    if rawRead(path)~=nil then os.remove(temp) end
    os.remove(aside)
    return true
end
local function acquire(path,token,pause)
    local lock=path..M.SUFFIX.lock
    local mine=lock..'-'..token
    local stamp=token..' '..os.time()..'\n'
    for attempt=1,M.WAIT_ATTEMPTS+1 do
        local f,err=io.open(mine,'wb'); if not f then return nil,err end
        local wrote=f:write(stamp); local closed=f:close()
        if not wrote or not closed or rawRead(mine)~=stamp then os.remove(mine); return nil,'Config lock write failed: '..path end
        if os.rename(mine,lock) then return stamp end
        os.remove(mine)
        local holder,at,content=lockHolder(path)
        if holder==nil and at=='unrecognized' then return nil,'Unrecognized config lock (left for manual recovery): '..lock end
        if holder and holder~=token and os.time()-at>M.STALE_SECONDS then
            local broken,why=breakStale(path,token,holder,content)
            if broken==nil then return nil,why end
        elseif (holder~=nil or at~='missing') and attempt<=M.WAIT_ATTEMPTS then
            pause()
        end
    end
    return nil,'Config busy: another game window is writing '..path
end
local function release(path,stamp)
    if rawRead(path..M.SUFFIX.lock)==stamp then os.remove(path..M.SUFFIX.lock) end
end
local function transact(path,text,onlyMissing,expected,token)
    local temp, backup = path .. M.SUFFIX.new..token, path .. M.SUFFIX.bak..token
    local old,readError=rawRead(path)
    if readError and readError~='missing' then return nil,readError end
    if onlyMissing and old~=nil then return true end
    if old==text then return true end   -- unchanged (or another window already wrote exactly this): no rewrite
    if expected~=nil and old~=expected then return nil,'Settings changed during default merge' end
    local f, err = io.open(temp, 'wb'); if not f then return nil, err end
    local wrote, why = f:write(text); local closed = f:close()
    if not wrote or not closed or rawRead(temp) ~= text then os.remove(temp); return nil, why or 'Config verification failed' end
    if old then
        local ok, e = os.rename(path, backup)
        if not ok then os.remove(temp); return nil, e end
    end
    local ok, e = os.rename(temp, path)
    if not ok then
        if old then os.rename(backup, path) end
        os.remove(temp); return nil, e
    end
    if old then os.remove(backup) end
    return true
end
-- A writer with its own token. opts.pause() waits between lock attempts (tests make it yield).
function M.writer(token,opts)
    assert(validToken(token),'Config writer token must be 1-8 letters or digits')
    local pause=(opts and opts.pause) or busyPause
    local w={}
    function w:replace(path, text, onlyMissing, expected)
        -- Same-directory replacement. Never truncate the previous live file.
        if rawRead(path .. '.modmenu-new')~=nil or rawRead(path .. '.modmenu-backup')~=nil or rawRead(path .. '.modmenu-lock')~=nil then
            return nil, 'Unfinished config transaction: ' .. path
        end
        -- Unchanged content (or a kept existing file) and no lock to recover: nothing is written, not even a lock.
        local current=rawRead(path)
        if current~=nil and (current==text or onlyMissing) and select(2,lockHolder(path))=='missing' then return true end
        local stamp,why=acquire(path,token,pause)
        if not stamp then return nil,why end
        local ok,result,problem=pcall(transact,path,text,onlyMissing,expected,token)
        release(path,stamp)
        if not ok then return nil,tostring(result) end
        return result,problem
    end
    return w
end
local default
function M.replace(path, text, onlyMissing, expected)
    default=default or M.writer(M.token)
    return default:replace(path, text, onlyMissing, expected)
end
-- Settings backups before a default merge: <path>.bd-<base-36 os.time()>-<n>.bak (short, for MAX_PATH margin).
-- Older Mod Menu versions wrote <path>.before-defaults-<os.time()>-<n>.bak; those are still found by the lookup.
local function base36(n)
    local digits,out='0123456789abcdefghijklmnopqrstuvwxyz',''
    n=math.floor(n)
    repeat local d=n%36; out=digits:sub(d+1,d+1)..out; n=n//36 until n==0
    return out
end
function M.settingsBackupName(path,time,index) return path..'.bd-'..base36(time)..'-'..index..'.bak' end
function M.legacySettingsBackupName(path,time,index) return path..'.before-defaults-'..time..'-'..index..'.bak' end
-- The settings backup holding exactly text, made at most `seconds` (default 5) ago, in either naming; or nil.
function M.findSettingsBackup(path,text,seconds)
    local now=os.time()
    for t=now,now-(seconds or 5),-1 do
        for i=1,100 do
            for _,name in ipairs({M.settingsBackupName(path,t,i),M.legacySettingsBackupName(path,t,i)}) do
                if rawRead(name)==text then return name end
            end
        end
    end
    return nil
end
function M.prepareSettings(path,defaults)
    local existing,err=M.read(path)
    if err and err~='missing' then return nil,err end
    if existing==nil then return M.replace(path,defaults or '[Settings]\n',true) end
    if not defaults then return true end
    local merged,why=require('mm_ini').mergeDefaults(existing,defaults)
    if not merged then return nil,why end
    if merged==existing then return true end
    local backup
    local now=os.time()
    for i=1,100 do
        local candidate=M.settingsBackupName(path,now,i)
        if M.absent(candidate) and M.absent(M.legacySettingsBackupName(path,now,i)) then backup=candidate; break end
    end
    if not backup then return nil,'Cannot allocate settings backup' end
    local ok,problem=M.replace(backup,existing,true)
    if not ok then return nil,problem end
    if M.read(backup)~=existing then return nil,'Settings backup verification failed' end
    return M.replace(path,merged,false,existing)
end
function M.norm(path) return path:gsub('\\', '/'):gsub('/+$', '') end
function M.paths(source, directories)
    local dir = M.norm(source:gsub('^@', '')):match('^(.*)/[Ss][Cc][Rr][Ii][Pp][Tt][Ss]/main%.lua$')
    assert(dir, 'Cannot resolve mod_menu script path')
    if not dir:match('^%a:/') and not dir:match('^//') then
        local found
        local function walk(t)
            if type(t) ~= 'table' then return end
            local p = t.__absolute_path and M.norm(t.__absolute_path)
            if p and p:lower():match('/mods/mod_menu$') then
                assert(not found or found == p, 'Ambiguous mod_menu directories'); found = p
            end
            for k, v in pairs(t) do if type(v) == 'table' and k ~= '__files' then walk(v) end end
        end
        walk(directories); dir = assert(found, 'Absolute script location unavailable')
    end
    local root = dir:match('^(.*)/[Mm][Oo][Dd][Ss]/mod_menu$')
    assert(root and root:lower():match('/win64$'), 'Run only from a build-local Win64/Mods/mod_menu installation')
    return {mod=dir, root=root, mods=root .. '/Mods', configs=root .. '/Configs'}
end
function M.folders(tree, root)
    local found = {}
    local function walk(t)
        if type(t) ~= 'table' then return end
        if t.__absolute_path and M.norm(t.__absolute_path):lower() == root:lower() then
            for k, v in pairs(t) do
                if k ~= '__files' and type(v) == 'table' and v.__name then found[#found+1] = v.__name end
            end
            return
        end
        for k,v in pairs(t) do if k ~= '__files' and type(v) == 'table' then walk(v) end end
    end
    walk(tree); table.sort(found); return found
end
-- Reject cmd metacharacters before using Windows' mkdir/start builtins.
function M.shellPath(path)
    assert(not path:find('["%%!&|<>%^\r\n]'), 'Path cannot safely be passed to the Windows shell')
    return '"' .. path:gsub('/', '\\') .. '"'
end
function M.ensureConfigs(path)
    local ok = os.execute('if not exist ' .. M.shellPath(path) .. ' mkdir ' .. M.shellPath(path))
    return ok == true or ok == 0
end
return M
