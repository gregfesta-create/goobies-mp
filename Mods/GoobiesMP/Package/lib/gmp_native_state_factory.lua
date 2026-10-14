-- Actual six-domain wiring. Partial native coverage stays visible to Readiness;
-- constructing this factory does not arm F6 or attest a production checkpoint.
local F={}
function F.new(options)
    assert(type(options)=='table' and options.world and options.pauseWorld and options.enemyBackend
        and type(options.players)=='function' and type(options.context)=='function','missing_native_factory_binding')
    local Group=require('gmp_native_slice_group');local rows={}
    local names={'player','inventory','loadout','abilities'}
    for _,name in ipairs(names) do rows[#rows+1]={name=name,adapter=require('gmp_native_'..name).new(options.world)} end
    local group=Group.new(rows)
    local function project(state)
        if type(state)~='table' or type(state.slices)~='table' then return nil end
        local out={version=1,slices={}}
        for _,name in ipairs(names) do
            local value=Group.Detach(state.slices[name]);if type(value)~='table' then return nil end
            out.slices[name]=value
        end
        return out
    end
    local function players()
        local source,why=options.players();if not source then return nil,why end
        local out=Group.Detach(source);if not out then return nil,'invalid_native_players' end
        for _,row in ipairs(out) do
            if row.conn=='connected' then row.native=project(row.native);if not row.native then return nil,'missing_native_player_group' end end
        end
        return out
    end
    local playerAdapter=require('gmp_native_players').new(group,{key=options.key,
        roster=function() local source=players();return source end,
        peerState=function(key) local source=players();for _,row in ipairs(source or {}) do if row.key==key then return row.native end end end})
    function playerAdapter:Capture() return players() end
    local Peer=require('gmp_native_peer_slice')
    local domains={players=playerAdapter,enemies=require('gmp_native_enemy_restore').new(options.enemyBackend),
        progression=Peer.new(require('gmp_native_progression').new(options.world),options.key,'progression',options.players),
        rewards=Peer.new(require('gmp_native_rewards').new(options.world),options.key,'rewards',options.players),
        world=require('gmp_native_world_state').new(options.world,options.pauseWorld,options.context),
        random=require('gmp_native_random').new(options.world)}
    local profile
    if options.experimentalOrdinary==true then
        profile={name='retained_ordinary',domains={players=true,enemies=true,progression=true,rewards=true,world=true,random=true},
            validate=function(state)
                if options.enemyBackend:Paused()~=true then return false,'not_paused' end
                local supported,reason=options.enemyBackend:Preflight()
                if supported~=true then return false,reason or 'enemy_preflight' end
                local wave=require('gmp_native_wave').new(options.world):Capture()
                if not wave or wave.values['BossTime?']~=false then return false,'boss_wave_active' end
                local rewards=require('gmp_native_rewards').new(options.world):Capture()
                if not rewards or rewards.active~=false or #rewards.queue~=0 then
                    return false,'reward_active:active='..tostring(rewards and rewards.active)..';queue='..tostring(rewards and #rewards.queue)
                end
                local rows=options.enemyBackend.capture:_rows(options.world:_enemyController())
                for _,row in ipairs(rows) do
                    if row.hp>0 and (row.enemyType<0 or row.enemyType>12) then return false end
                end
                if state and state.enemies then
                    for _,row in ipairs(state.enemies.enemies) do
                        if not row.dead and (row.enemyType<0 or row.enemyType>12) then return false end
                    end
                end
                return true
            end}
    end
    return require('gmp_game_state').new(domains,{profile=profile}),domains
end
return F
