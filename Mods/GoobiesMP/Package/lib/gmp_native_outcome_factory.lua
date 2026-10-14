-- Production adapter construction. Unlinked native proof/apply endpoints refuse.
-- No Lua role flag is sufficient to create native authority or acknowledge XP.
local F={}
function F.Bind(app,session,role)
 local native=app and app.nativeOutcomeBridge
 if type(native)~='table' or type(native.BindOutcomeContext)~='function' then
  return nil,'native_outcome_bridge_unlinked'
 end
 if role~='host' and role~='client' then return nil,'native_outcome_role_invalid' end
 local ok,bound=pcall(native.BindOutcomeContext,native,app,session,role)
 if not ok or type(bound)~='table' then return nil,'native_outcome_binding_refused' end
 local names=role=='host' and {'Authorize','PeerEpoch','PeekOutcome','RetireOutcome','Hold','Close'}
  or {'Authorize','ApplyOutcome','Hold','Close'}
 for _,name in ipairs(names)do if type(bound[name])~='function' then
  if type(bound.Close)=='function' then pcall(bound.Close,bound)end
  return nil,'native_outcome_endpoint_missing:'..name
 end end
 local adapter={binding=bound}
 adapter.authorize=function(batch,sid)return bound:Authorize(batch,sid)==true end
 adapter.hold=function(reason)return bound:Hold(reason)end
 adapter.close=function()return bound:Close()end
 if role=='host' then
  adapter.peerEpoch=function(peer)return bound:PeerEpoch(peer)end
  adapter.PeekOutcome=function()return bound:PeekOutcome()end
  -- RetireOutcome must read typed424B unanimous native receipt, never ACK bool.
  adapter.RetireOutcome=function(batch)return bound:RetireOutcome(batch)end
 else adapter.apply=function(batch)return bound:ApplyOutcome(batch)==true end end
 return adapter
end
return F
