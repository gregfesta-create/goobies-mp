-- Authenticated attack intents, never client damage or health assignments.
-- The injected host resolver validates weapon/cooldown/range against host state
-- and applies the game's native damage path. This queue cannot synthesize kills.
local C={};C.__index=C
local function uint(n) return type(n)=='number' and n%1==0 and n>=1 and n<=2147483647 end
function C.new(options)
    assert(type(options)=='table' and type(options.resolve)=='function'
        and type(options.context)=='function' and type(options.connected)=='function'
        and type(options.enemy)=='function' and type(options.paused)=='function')
    assert(uint(options.budget or 8) and (options.budget or 8)<=64,'invalid_combat_budget')
    assert(uint(options.capacity or 128) and (options.capacity or 128)<=1024,'invalid_combat_capacity')
    assert(uint(options.perPeer or 16) and (options.perPeer or 16)<=128,'invalid_peer_capacity')
    return setmetatable({options=options,queue={},head=1,last={},pending=0,peerPending={}},C)
end
function C:Reset(context)
    assert(context==nil or (type(context)=='string' and #context>0 and #context<=256),'invalid_combat_context')
    self.context=context;self.queue={};self.head=1;self.last={};self.pending=0;self.peerPending={}
end
function C:Submit(peer,intent)
    local o=self.options
    if not self.context or o.context()~=self.context then return false,'context_changed' end
    if type(peer)~='string' or #peer>64 or not o.connected(peer) then return false,'unauthenticated_peer' end
    if type(intent)~='table' or intent.context~=self.context or not uint(intent.sequence)
        or type(intent.enemyId)~='string' or #intent.enemyId>32 or not uint(intent.attack)
        then return false,'invalid_intent' end
    -- Reject unknown fields: a caller cannot smuggle a damage/HP value into a resolver.
    for key in pairs(intent) do
        if key~='context' and key~='sequence' and key~='enemyId' and key~='attack' then return false,'invalid_intent' end
    end
    if intent.sequence<=(self.last[peer] or 0) then return false,'replayed_intent' end
    local row=o.enemy(intent.enemyId)
    if not row or row.dead then return false,'stale_enemy' end
    if self.pending>=(o.capacity or 128) or (self.peerPending[peer] or 0)>=(o.perPeer or 16) then return false,'backpressure' end
    self.last[peer]=intent.sequence
    self.queue[#self.queue+1]={peer=peer,sequence=intent.sequence,enemyId=intent.enemyId,attack=intent.attack}
    self.pending=self.pending+1;self.peerPending[peer]=(self.peerPending[peer] or 0)+1;return true
end
function C:Tick()
    local o=self.options
    if o.context()~=self.context then self:Reset(o.context());return 0 end
    if o.paused() then return 0 end
    local consumed=0
    while self.pending>0 and consumed<(o.budget or 8) do
        local item=self.queue[self.head];self.queue[self.head]=false;self.head=self.head+1
        self.pending=self.pending-1;consumed=consumed+1
        self.peerPending[item.peer]=self.peerPending[item.peer]-1
        local row=o.enemy(item.enemyId)
        if o.connected(item.peer) and row and not row.dead then
            -- A resolver failure is contained; no retries that could duplicate native damage.
            local ok,result=pcall(o.resolve,item.peer,item.enemyId,item.attack,item.sequence,self.context)
            if o.result then pcall(o.result,item.peer,item.sequence,ok and result==true) end
        end
    end
    if self.pending==0 then self.queue={};self.head=1
    elseif self.head>(o.capacity or 128) then
        -- A continuously busy queue may never empty. Drop consumed prefixes
        -- so bounded pending intents also imply bounded retained storage.
        local compact={};for i=self.head,#self.queue do compact[#compact+1]=self.queue[i] end
        self.queue=compact;self.head=1
    end
    return consumed
end
return C

