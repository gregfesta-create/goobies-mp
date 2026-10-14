-- Host-owned inventory/weapon state resolves authenticated attack intents.
-- The native backend must prove its reflected damage schema before Ready is true;
-- this module never accepts a client damage value or guesses DamageInfo fields.
local R={};R.__index=R
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function position(p) return type(p)=='table' and finite(p.x) and finite(p.y) and finite(p.z) end
local function uint(n) return finite(n) and n%1==0 and n>=1 and n<=2147483647 end
function R.new(backend,options)
    options=options or {}
    assert(type(options.clock)=='function','missing_host_clock')
    assert(uint(options.maxPeers or 64) and (options.maxPeers or 64)<=256,'invalid_host_peer_capacity')
    for _,name in ipairs({'Context','Ready','PeerPawn','AttackState','Enemy','ApplyHit'}) do
        assert(type(backend[name])=='function','missing_host_attack_backend:'..name)
    end
    return setmetatable({backend=backend,clock=assert(options.clock),states={},context=nil,
        peers=0,maxPeers=options.maxPeers or 64},R)
end
function R:Reset(context)
    self.context=context;self.states={};self.peers=0
end
function R:Resolve(peer,id,attack,sequence,context)
    local b=self.backend
    if type(context)~='string' or #context==0 or #context>256 or b:Context()~=context then return false,'context_changed' end
    if self.context~=context then self:Reset(context) end
    if type(peer)~='string' or #peer==0 or #peer>64 or type(id)~='string'
        or #id>32 or not id:match('^%d+:%d+$') or not uint(attack) or attack>1024 or not uint(sequence)
        then return false,'invalid_intent' end
    if b:Ready(context)~=true then return false,'native_damage_binding_unverified' end
    local now=self.clock()
    if not finite(now) then return false,'invalid_host_clock' end
    local pawn=b:PeerPawn(peer,context)
    local enemy=b:Enemy(id,context)
    local state=b:AttackState(peer,attack,context)
    -- Detached state must identify its actual host inventory owner and generation.
    if type(pawn)~='table' or pawn.context~=context or pawn.peer~=peer or not position(pawn.position)
        or type(pawn.identity)~='string' or pawn.identity=='' then return false,'stale_pawn' end
    if type(enemy)~='table' or enemy.context~=context or enemy.id~=id or enemy.dead~=false
        or not position(enemy.position) or not finite(enemy.hp) or enemy.hp<=0 then return false,'stale_enemy' end
    if type(state)~='table' or state.context~=context or state.peer~=peer or state.attack~=attack
        or state.pawnIdentity~=pawn.identity or type(state.weaponIdentity)~='string' or state.weaponIdentity==''
        or state.inventoryVerified~=true or not finite(state.damage) or state.damage<=0 or state.damage>1e12
        or not finite(state.range) or state.range<0 or state.range>1e7
        or not finite(state.cooldown) or state.cooldown<.001 or state.cooldown>3600
        then return false,'unverified_host_weapon' end
    local dx=pawn.position.x-enemy.position.x;local dy=pawn.position.y-enemy.position.y
    local dz=pawn.position.z-enemy.position.z
    if dx*dx+dy*dy+dz*dz>state.range*state.range then return false,'out_of_range' end
    local peerState=self.states[peer]
    if not peerState then
        if self.peers>=self.maxPeers then return false,'peer_capacity' end
        peerState={};self.states[peer]=peerState;self.peers=self.peers+1
    end
    local prior=peerState[attack]
    if prior and (sequence<=prior.sequence or now<prior.time or now<prior.readyAt) then return false,'cooldown_or_replay' end
    -- Recheck generation after host reads. Reserve before native dispatch: uncertain
    -- engine errors must never cause automatic duplicate damage on retry/reentry.
    if b:Context()~=context or b:Ready(context)~=true then return false,'context_changed' end
    peerState[attack]={sequence=sequence,time=now,readyAt=now+state.cooldown}
    local ok,result=pcall(b.ApplyHit,b,context,pawn,enemy,state,sequence)
    if not ok or result~=true then return false,'native_hit_failed' end
    return true
end
return R
