-- Read-only runtime eligibility, independent of development diagnostics.
-- This authorizes bounded personal capture, never restoration or combat.
local L={}
function L.Check(app,paused,preparation)
 local session=app.role=='host' and app.host or app.client
 if app.cfg.MODE~='production' or app.cfg.AUTH_MODE~='steam' then return nil,'production_session_required' end
 if app.handoverRuntimeHold or app.nativeRestoreHold or app.lossRecovery then return nil,'native_transaction_hold' end
 local identity=app.identity
 if not session or not identity or identity.kind~='steam' or session.identity~=identity
  or type(session.sid)~='string' or session.sid=='' then return nil,'authenticated_session_required' end
 local authority=app.steamAuthority;local committed=authority and authority.committed
 local term=session.authorityTerm or 1
 if not committed or committed.session~=session.sid or committed.term~=term then return nil,'committed_session_required' end
 local nativeContext=authority.context
 if not nativeContext or type(authority.Read)~='function' then return nil,'native_committed_context_required' end
 local current
 if preparation then
  if not app.gracefulControl or not app.gracefulControl:Ready() or not app:_trustedGracefulStage(preparation)
   or type(authority.ReadPreparation)~='function'then return nil,'untrusted_native_preparation'end
  current=authority:ReadPreparation(nativeContext,preparation)
 else current=authority:Read(nativeContext)end
 if not current or current.session~=committed.session or current.term~=committed.term
  or current.hostKey~=committed.hostKey then return nil,'native_committed_context_changed' end
 if app.role=='host' then
  if committed.hostKey~=identity.key then return nil,'committed_host_mismatch' end
 elseif app.role=='client' then
  if session:State()~='joined' or session.authenticatedHostKey~=committed.hostKey
   or session.authenticatedAuthorityTerm~=term then return nil,'authenticated_host_required' end
 else return nil,'network_role_required' end
 local islands=session.islands
 if not islands or islands.phase~='playing' or not islands.current then return nil,'verified_island_required' end
 local policy=session.sessionPolicy
 if not policy or policy.locked~=true then return nil,'locked_session_policy_required' end
 local binding=app:LobbyAchievementBinding(policy)
 local accepted,why=require('gmp_lobby_achievement_binding').Check(policy,binding,session)
 if accepted~=true then return nil,why end
 local world=app.nativeStateWorld or (app.presenceDriver and app.presenceDriver.world)
 if not world or not world:ReadLocal() then return nil,'native_pawn_unavailable' end
 local nativeWorld=world:_world();local pawn=nativeWorld and world:_pawn(nativeWorld)
 if not nativeWorld or nativeWorld:IsValid()~=true or not pawn or pawn:IsValid()~=true then return nil,'native_pawn_unavailable' end
 local manager=world:_enemyController()
 if not manager or manager:IsValid()~=true then return nil,'native_controller_unavailable' end
 local worldAddress,pawnAddress,controllerAddress=nativeWorld:GetAddress(),pawn:GetAddress(),manager:GetAddress()
 for _,address in ipairs{worldAddress,pawnAddress,controllerAddress} do
  if type(address)~='number' or address~=address or address<=0 or address==math.huge then return nil,'native_object_identity_unavailable' end
 end
 if paused and (not session.sharedPause or session.sharedPause.paused~=true
  or require('gmp_native_timers').new(world):_paused()~=true) then return nil,'native_shared_pause_required' end
 return {session=session,world=world,term=term,lobbyId=nativeContext.lobbyId,generation=nativeContext.generation,
  nativeWorld=worldAddress,pawn=pawnAddress,controller=controllerAddress,
  context=table.concat({session.sid,term,islands.epoch,islands.island,policy.revision,
   tostring(policy.locked)},':')}
end
function L.Read(app,paused,preparation)
 local ok,report,why=pcall(L.Check,app,paused,preparation)
 if not ok then return nil,'native_lifecycle_read_failed' end
 return report,why
end
return L
