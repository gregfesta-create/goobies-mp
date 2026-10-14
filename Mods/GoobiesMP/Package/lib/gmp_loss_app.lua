-- Actual App/Steam/native survivor transaction. Unsupported capture never starts an election.
local A={}
function A.CheckPolicy(app,policy)
 local session=app.role=='host' and app.host or app.client
 if type(app.LobbyAchievementBinding)~='function' then return false,'achievement_protection_binding_missing' end
 local ok,binding=pcall(app.LobbyAchievementBinding,app,policy)
 if not ok then return false,'achievement_protection_binding_failed' end
 return require('gmp_lobby_achievement_binding').Check(policy,binding,session)
end
function A.Release(app,driver,policy,commit)
 local protected,why=A.CheckPolicy(app,policy)
 if not protected then return false,why end
 return driver:Resume(commit)
end
local function begin(app)
 if app.lossRecovery then return false,'loss_transaction_exists' end
 local c=app.client;local game=app.handoverGame;local authority=app.steamAuthority
 if app.cfg.MODE~='production' or app.cfg.AUTH_MODE~='steam' or app.role~='client' or not c
  or c:State()~='disconnected' then return false,'host_loss_not_observed' end
 if not game or type(game.Readiness)~='function' or not authority or not authority.committed then
  return false,'native_loss_restoration_unavailable'
 end
 local ready=game:Readiness();if not ready.ready then return false,ready.reason or 'native_state_incomplete' end
 local stream=c.checkpointStream;local state=stream and stream:Snapshot()
 local sid,term=c.sid,c.authorityTerm or 1;local ctx=authority.context
 if not state or c.checkpointSession~=sid or stream.term~=term or not ctx
  or authority.committed.session~=sid or authority.committed.term~=term
  or authority.committed.hostKey~=c.authenticatedHostKey then return false,'authenticated_loss_checkpoint_missing' end
 if not state.sessionPolicy or state.sessionPolicy.locked~=true then return false,'locked_session_policy_missing' end
 if math.type(state.sessionPolicy.runGeneration)~='integer' or state.sessionPolicy.runGeneration<1 or state.sessionPolicy.runGeneration>9007199254740991 then return false,'invalid_run_generation' end
 local protected,protectionReason=A.CheckPolicy(app,state.sessionPolicy)
 if not protected then return false,protectionReason end
 local survivors={};for _,player in ipairs(state.players)do if player.role~='host' and player.conn=='connected' then survivors[#survivors+1]=player.key end end
 local mesh,loss,driver
 local function current(seal)
  local a=app.steamAuthority
  if a~=authority or a.retired or a.context~=ctx then return false end
  local ok,generation,lobby=app.bridge.G.GMP_Lob_Status()
  if ok~=true or generation~=ctx.generation or lobby~=ctx.lobbyId then return false end
  local session=app.role=='host' and app.host or app.client
  if not session then return false end
  local pending=seal and session.sid==nil and session.expectedHandoverSession==sid
   and loss and loss.commit and session.expectedHandoverHost==loss.commit.hostKey
   and session.expectedAuthorityTerm==term+1
  if session.sid~=sid and not pending then return false end
  local actual=session.authorityTerm or 1
  return actual==term or seal and app.lossRecovery==loss and loss and loss:TrustedCommit(loss.commit)
   and seal.session==sid and seal.term==term and seal.nextTerm==term+1 and actual==term+1
 end
 mesh=select(1,require('gmp_survivor_mesh').new{G=app.bridge.G,cfg=app.cfg,identity=app.identity,
  provider=app.bridge.authProvider,sid=sid,term=term,survivors=survivors,current=current,
  clock=function()return app.clockNow end,rng=app.rng or math.random,
  verifySeal=function(commit)return loss and loss:TrustedCommit(commit)==true end})
 if not mesh then return false,'native_survivor_auth_unavailable' end
 app.lossConstructionMesh=mesh
 local function hold()return game:SetPaused(true)end
 local function restore(commit,checkpoint)
  local ok,why
  if driver.phase=='idle' then ok,why=driver:Apply(commit,checkpoint)else ok,why=driver:Step()end
  if not ok and why=='restore_pending' then return nil end
  return ok,why
 end
 loss=select(1,require('gmp_loss_recovery').new{mesh=mesh,checkpoint=state,key=app.identity.key,
  sid=sid,term=term,sequence=stream.sequence,digest=stream.hash,current=function()return current(mesh.sealed)end,
  clock=function()return app.clockNow end,paused=function()return app:_testPhysicalPause()end,hold=hold,
  rng=app.rng or math.random,
  prepare=function(commit)
   local ok,why=authority:PrepareLoss(commit)
   if ok==false and why=='authority_stage_pending'then return nil end
   return ok,why
  end,
  ready=function()return game:Readiness().ready end,restore=restore,
  activate=function(commit)
   if driver.phase=='waiting' then
    local rebound,why=A.TransferPolicy(app,state.sessionPolicy,commit,function(c)return loss:TrustedCommit(c)==true end)
    if rebound~=true then return rebound,why end
   end
   local protected,why=A.CheckPolicy(app,state.sessionPolicy)
   if not protected then return false,why end
   if not mesh:Seal(commit)then return false,'survivor_seal_refused'end
   local ok,why
   if driver.phase=='waiting' then ok,why=driver:ConfirmApplied()else ok,why=driver:ActivateRestored()end
   if not ok and (why=='activation_pending' or why=='application_receipt_pending') then return nil end
   if ok then
    local rebound,reason=A.TransferPolicy(app,state.sessionPolicy,commit,function(c)return loss:TrustedCommit(c)==true end)
    if rebound~=true then return rebound,reason end
    return A.CheckPolicy(app,state.sessionPolicy)
   end
   return ok,why
  end,
  release=function(commit)
   local ok,why=A.Release(app,driver,state.sessionPolicy,commit)
   if not ok and why=='release_pending' then return nil end
   return ok,why
  end})
 if not loss then pcall(mesh.Close,mesh);app.lossConstructionMesh=nil;return false,'native_loss_hold_unavailable'end
 driver=require('gmp_handover_driver').new{key=app.identity.key,session=sid,term=term,game=game,
  transport=app.transport,deferActivation=true,verifyCommit=function(commit)return loss:SelectedCommit(commit)==true end,
  beforeActivate=function(commit)return authority:StageLoss(commit)end,
  activate=function(role,checkpoint,commit)return app:_activateHandover(role,checkpoint,commit)end,
  applied=function()local session=app.role=='host' and app.host or app.client
   return app.role=='host' and session and session.started==true or session and session:State()=='joined'end,
  verifyRelease=function(commit)return loss.releaseRequested==true and loss:TrustedCommit(commit)==true end,
  beforeRelease=function(commit)local session=app.role=='host' and app.host or app.client;return authority:Finish(session,commit)end}
 app.lossPreviousVerifySwitch=app.transport.verifySwitch
 app.transport.verifySwitch=function(role,nextTerm,commit)
  if app.lossRecovery==loss and nextTerm==term+1 and loss:TrustedCommit(commit)==true
   and role==(app.identity.key==commit.hostKey and 'host' or 'client')then return true end
  local prior=app.lossPreviousVerifySwitch;return type(prior)=='function' and prior(role,nextTerm,commit)==true
 end
 app.lossRecovery=loss;app.lossMesh=mesh;app.lossConstructionMesh=nil;app.lossDriver=driver;app.handoverRuntimeHold=true
 return true
end
function A.Begin(app)
 local ok,result,why=pcall(begin,app)
 if ok then return result,why end
 local mesh=app.lossConstructionMesh or app.lossMesh;if mesh then pcall(mesh.Close,mesh)end
 app.lossConstructionMesh=nil
 local held,verified=pcall(function()return app.handoverGame:SetPaused(true)==true and app:_testPhysicalPause()==true end)
 app.lossBeginHoldVerified=held and verified==true
 return false,'loss_begin_failed:'..tostring(result):sub(1,200)
end
function A.TransferPolicy(app,policy,commit,verify)
 local session=app.role=='host' and app.host or app.client
 local adapter=app.achievementProtection
 if not adapter or type(adapter.Transfer)~='function'then return false,'protection_transfer_unavailable'end
 local ok,accepted,why=pcall(adapter.Transfer,adapter,session,commit.term,policy,commit,verify)
 if not ok then return false,'protection_transfer_failed'end
 return accepted,why
end
function A.WithdrawGameplay(app,loss)
 if loss.commit and app.steamAuthority and type(app.steamAuthority.HoldGameplay)=='function'then
  local ok,held,why=pcall(app.steamAuthority.HoldGameplay,app.steamAuthority,loss.commit)
  app.lossGameplayWithdrawn=ok and held==true;app.lossGameplayWithdrawReason=ok and why or 'gameplay_withdrawal_failed'
 end
end
function A.Tick(app)
 local loss=app.lossRecovery;if not loss then return false end
 local ok,err=pcall(function()
 if app.lossDriver.phase=='waiting' or loss.localActivated then
  local session=app.role=='host' and app.host or app.client;session:Poll();session:Tick()
  if app.lossDriver.phase=='waiting' then app.lossDriver:ConfirmApplied()end
 end
 loss:Tick()
 end)
 if not ok then
  local reason='loss_runtime_error:'..tostring(err):sub(1,200)
  local recorded=pcall(loss._fail,loss,reason)
  if not recorded then loss.failed=loss.failed or reason;loss.phase='failed'end
 end
 if loss.failed then
  A.WithdrawGameplay(app,loss)
  if loss.commit and not app.lossPendingWithdrawn and app.steamAuthority and type(app.steamAuthority.AbortLoss)=='function'then
   local ok,withdrawn,why=pcall(app.steamAuthority.AbortLoss,app.steamAuthority,loss.commit)
   app.lossPendingWithdrawn=ok and withdrawn==true
   app.lossPendingWithdrawReason=ok and why or 'loss_abort_failed'
  end
  local held,accepted=pcall(function()return loss.o.hold(true)==true and app:_testPhysicalPause()==true end)
  accepted=held and accepted==true
  app.lossHoldVerified=accepted
  local world=app.islandFlow and app.islandFlow.world
  if world and world.SetPauseNotice then pcall(world.SetPauseNotice,world,accepted and 'Host recovery failed. Game held paused.' or 'Host recovery failed. Pause could not be applied.')end
 elseif loss.phase=='finished' then
  local finalized,reason=pcall(function()
   local session=app.role=='host' and app.host or app.client
   session.handoverHold=nil
   if app.role=='host' and session.sharedPause then session.sharedPause:ReleaseHandover(app.identity.key);session:PublishPause()end
   app.lossMesh:Close()
  end)
  if not finalized then
   loss.failed='loss_finalize_error:'..tostring(reason):sub(1,200);loss.phase='failed'
   A.WithdrawGameplay(app,loss)
   local held,verified=pcall(function()return loss.o.hold(true)==true and app:_testPhysicalPause()==true end)
   app.lossHoldVerified=held and verified==true
   return true
  end
  app.transport.verifySwitch=app.lossPreviousVerifySwitch;app.lossPreviousVerifySwitch=nil
  app.lossRecovery=nil;app.lossMesh=nil;app.lossDriver=nil;app.handoverRuntimeHold=nil
 end
 return true
end
return A
