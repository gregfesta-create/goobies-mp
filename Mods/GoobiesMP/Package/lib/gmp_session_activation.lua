-- Session activation after trusted commit/native restore/transport switch.
-- Builds fresh links and authenticates again; never regenerates an island.
local A={}
function A.Activate(options,role,state,commit)
    if role~='host' and role~='client' then return false,'invalid_role' end
    if type(commit)~='table' or (options.identity.key==commit.hostKey)~=(role=='host') then return false,'role_mismatch' end
    if options.cfg.AUTH_MODE=='off' then return false,'fresh_auth_required' end
    local constructor=role=='host' and require('gmp_host') or require('gmp_client')
    local session,why=constructor.new(options);if not session then return false,why end
    local ok,reason
    if role=='host' then
        ok,reason=session:StartHandover(state,commit.session,commit.term)
        if ok then
            session.checkpointSequence=commit.sequence
            local pause=session:EnablePause()
            if type(options.pauseHostOnly)=='boolean' then pause.hostOnly=options.pauseHostOnly end
            session:PauseForHandover(options.identity.key)
            session.handoverHold=true
        end
    else ok,reason=session:StartHandover(state,commit,options.address or 'relay') end
    if not ok then return false,reason end
    return true,session
end
return A
