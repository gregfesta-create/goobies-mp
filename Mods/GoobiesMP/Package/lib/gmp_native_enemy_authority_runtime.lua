-- Explicit source-only ordinary-horde candidate wiring. The outer authority
-- authenticates host/context and validates snapshots before renderer updates.
-- Controller-only opt-in remains required; actor/projectile/reward gaps refuse
-- normal production activation. No shared App mutation or implicit global enable.
local Adapter=require('gmp_native_enemy_authority_adapter')
local Instances=require('gmp_native_enemy_instances')
local Authority=require('gmp_enemy_authority')
local R={}
function R.Create(world,options)
    options=options or {}
    assert(type(world)=='table' and type(world.G)=='table','missing_candidate_world')
    local G=world.G
    local api={configure=G.GMPAuthorityControllerConfigure,status=G.GMPAuthorityControllerStatus,
        spawn=G.GMPAuthorityHostSpawn,update=G.GMPAuthorityHostUpdate}
    local presentation=Instances.new(world,{cap=options.cap or 4096,log=options.log})
    local adapter=Adapter.new(api,presentation,{controllerOnlyDevelopmentTest=options.controllerOnlyDevelopmentTest==true})
    local authority=Authority.new(adapter,{budget=options.budget or 64,interval=options.interval or .1,failClosed=true})
    return {adapter=adapter,authority=authority,presentation=presentation,
        coverage={ordinaryPresentationImplemented=true,controllerRuntimeVerified=false,bosses=false,projectiles=false,pickups=false,rewards=false,production=false}}
end
return R
