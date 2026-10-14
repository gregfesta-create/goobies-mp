-- Frozen-participant development runtime; incomplete native adapters cannot arm.
local R={};R.__index=R
local Capacity=require('gmp_config').MAX_PLAYERS_LIMIT
function R.new(options,commit,checkpoint,nonce)
    local production=options.mode=='production' and options.normalDeparture==true and options.controlTransport
        and options.controlTransport.ProductionGracefulControl==true and type(options.productionAuthorization)=='function'
        and options.productionAuthorization()==true
    if (options.mode~='dev' and not production) or not options.game or type(options.game.Readiness)~='function'
        or not options.game:Readiness().ready then return nil,'native_state_incomplete' end
    local ok,state=require('gmp_handover').Validate(checkpoint);if not ok then return nil,state end
    if type(commit)~='table' or type(commit.session)~='string' or #commit.session<1 or #commit.session>128 then return nil,'unsupported_commit' end
    local members=0;local participants={};local host,former,localMember
    for _,player in ipairs(state.players) do
        if player.conn=='connected' then
            members=members+1;participants[player.key]=true
            if player.key==options.key then localMember=true end
            if player.key==commit.formerHost then former=true end
        end
        if player.role=='host' then host=player.key end
    end
    if members<2 or members>math.min(options.maxPlayers or Capacity,Capacity) or not former or not localMember or host~=commit.hostKey
        or not (commit.forced==true or (options.normalDeparture==true and commit.forced==false and commit.kind=='graceful'))
        or commit.hostKey==commit.formerHost
        or type(commit.term)~='number' or commit.term%1~=0 or commit.term<2
        or type(commit.sequence)~='number' or commit.sequence%1~=0 or commit.sequence<1 then return nil,'unsupported_commit' end
    if type(options.verifyStage)~='function' or options.verifyStage(commit)~=true then return nil,'untrusted_stage' end
    local controlTransport=options.controlTransport or options.transport
    if members>2 and controlTransport.HandoverControlAttribution~=true then return nil,'attributed_control_required' end
    if members>2 and (type(commit.digest)~='string' or #commit.digest<1)then return nil,'checkpoint_digest_required'end
    local context={nonce=nonce,session=commit.session,term=commit.term,sequence=commit.sequence,digest=commit.digest,
        localKey=options.key,masterKey=commit.formerHost,participants=participants}
    if not controlTransport:BindHandoverControl(nonce,context) then return nil,'control_binding_failed' end
    local self=setmetatable({},R);local frozen={session=commit.session,term=commit.term,
        sequence=commit.sequence,hostKey=commit.hostKey,formerHost=commit.formerHost,forced=commit.forced,kind=commit.kind,digest=commit.digest,nonce=nonce}
    local function same(c)
        return c.session==frozen.session and c.term==frozen.term and c.sequence==frozen.sequence and c.hostKey==frozen.hostKey
            and c.digest==frozen.digest and c.formerHost==frozen.formerHost and c.forced==frozen.forced and c.kind==frozen.kind
    end
    self.driver=require('gmp_handover_driver').new({key=options.key,session=frozen.session,term=frozen.term-1,
        game=options.game,transport=options.transport,activate=options.activate,beforeActivate=function(c,s)
            if production then
                if not self.control:_all(self.control.applied)then return false,'transport_pending'end
                local ok,why=controlTransport:Seal(c);if not ok then return false,why end
                if type(controlTransport.ActivationReady)=='function' and not controlTransport:ActivationReady()then return false,'transport_pending'end
            end
            if options.beforeActivate then return options.beforeActivate(c,s)end;return true
        end,
        beforeRelease=options.beforeRelease,deferActivation=true,
        verifyCommit=same,applied=options.activationReady or function() return true end,verifyRelease=same})
    self.controlTransport=controlTransport
    self.control=require('gmp_handover_control').new({mode='dev',master=options.key==frozen.formerHost,key=options.key,masterKey=frozen.formerHost,
        participants=participants,context=context,allPeerReceipts=production,allowAnonymousPair=members==2 and controlTransport.HandoverControlAttribution~=true,
        send=function(message) return controlTransport:SendHandoverControl(message) end,
        poll=function() return controlTransport:PollHandoverControl() end,
        execute=function()
            local ok,why
            if self.driver.phase=='restoring' then ok,why=self.driver:Step()else ok,why=self.driver:Apply(frozen,state)end
            if production and ok==true then controlTransport:SendHandoverControl('APPLIED')end
            return ok,why
        end,
        activate=function()
            local ok,why
            if self.driver.phase=='waiting' then ok,why=self.driver:ConfirmApplied()else ok,why=self.driver:ActivateRestored()end
            if not ok and why=='application_receipt_pending' then return false,'activation_pending'end
            if production and ok==true then controlTransport:SendHandoverControl('ACTIVATED')end
            return ok,why
        end,
        release=function() local ok,why=self.driver:Resume(frozen)
            if production and ok==true then controlTransport:SendHandoverControl('RELEASED')end
            return ok,why end})
    return self
end
function R:Start() return self.control:Start() end
function R:Tick(now)
    self.control:Tick(now)
    if self.control.phase=='finished' and not self.controlRetired then
        self.controlRetired=true
        local transport=self.controlTransport
        if type(transport.ClearHandoverControl)=='function'then pcall(transport.ClearHandoverControl,transport)end
    end
end
return R
