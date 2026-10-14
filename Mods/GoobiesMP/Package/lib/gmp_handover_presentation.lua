-- Read-only handover status. Actual role is owned by authenticated activation;
-- presentation never predicts election results or mutates session state.
local P={}
function P.Format(status)
    if type(status)~='table' or status.active~=true then return nil end
    if status.failed then return 'Host handover failed. Check session status.' end
    local phase=status.phase
    if phase=='finished' then return nil end
    if status.activated==true then
        if phase=='released' then return 'Host handover: completing the session transfer...' end
        return 'Host handover: reconnecting players...'
    end
    if status.restorePhase=='verifying' then return 'Host handover: verifying restored game state...' end
    if status.restorePhase=='restoring' then return 'Host handover: restoring game state...' end
    if phase=='applied' then return 'Host handover: waiting for all players to restore state...' end
    if phase=='staged' then return 'Host handover: preparing game state...' end
    return 'Host handover in progress...'
end
return P
