-- Partial diagnostic only. One scalar read/log per tick; no resume backlog.
local D={};D.__index=D
local fields={'HP_Current','HP_MAX','XP_Current','XP_Target','XP_Buffer','Level',
    'TotalXPPickedUp','CurrentLevelNorm','MovementSpeed','DamageMultiplier',
    'CritChance','CritDamage','TimeDialation','PlayerIsDead','PresentTime?','IsGamePaused?'}
function D.new(read,log) return setmetatable({read=read,log=log,lines=0},D) end
function D:Emit(line)
    -- Per-driver lifetime ceiling: repeated pause spam cannot grow output forever.
    if self.lines>=256 then self:Cancel();return false end
    self.lines=self.lines+1;self.log(line);return true
end
function D:Cancel() self.active=nil end
function D:Tick(paused,key)
    if not paused then self:Cancel();return end
    if self.lines>=256 then self:Cancel();return end
    if self.key~=key then self.key=key;self.active={index=0} end
    local a=self.active;if not a then return end
    if a.index==0 then
        self:Emit('PAUSEDUMP begin '..key..' complete=false coverage=local_scalars');a.index=1;return
    end
    local field=fields[a.index]
    if not field then self.active=nil;self:Emit('PAUSEDUMP end '..key..' complete=false');return end
    a.index=a.index+1
    local ok,value=pcall(self.read,field)
    if not ok or (type(value)~='boolean' and type(value)~='number')
        or (type(value)=='number' and (value~=value or math.abs(value)==math.huge)) then value='unavailable' end
    self:Emit('PAUSEDUMP '..key..' '..field..'='..tostring(value))
end
return D
