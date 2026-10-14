-- Validate the shared owner's explicit world-entry capability. Transport
-- authentication is necessary but does not imply native gameplay is bound.
local B={}
function B.Check(binding,session,role)
    if type(binding)~='table' or binding.available~=true then
        return false,type(binding)=='table' and binding.reason or 'world_binding_unavailable'
    end
    if not session or not session.identity or not session.sid then return false,'session_unavailable' end
    if binding.session~=session or binding.role~=role then return false,'world_binding_session_changed' end
    if binding.term~=(session.authorityTerm or session.term or 1) then return false,'world_binding_term_changed' end
    if type(binding.flow)~='table' or binding.flow.failed then return false,'world_controller_unavailable' end
    if role=='client' and (type(session.State)~='function' or session:State()~='joined') then return false,'session_not_authenticated' end
    if role~='host' and role~='client' then return false,'invalid_session_role' end
    return true
end
function B.Message(reason)
    if reason=='production_native_authority_unavailable' or reason=='production_capabilities_missing'
        or reason=='production_world_entry_unimplemented' then return 'Shared gameplay is not ready in this build.' end
    if reason=='session_not_authenticated' then return 'Waiting for session authentication.' end
    return 'Shared world entry is unavailable. Keep the lobby open and try again when it is ready.'
end
return B
