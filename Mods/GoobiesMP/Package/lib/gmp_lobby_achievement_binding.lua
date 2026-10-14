-- Validate a proof-bearing lease from the shared runtime. PE exports alone
-- do not establish Lua bindings or real award interception readiness.
-- Achievements are always blocked during multiplayer (D16): entry needs a verified, active lease.
local Messages=require('gmp_messages')
local B={}
function B.Check(policy,binding,session)
    if not Messages.ValidatePolicy(policy) then return false,'achievement_policy_missing' end
    if type(binding)~='table' or binding.available~=true then
        return false,type(binding)=='table' and binding.reason or 'achievement_protection_binding_missing'
    end
    local term=session and (session.authorityTerm or session.term or 1)
    if type(term)~='number' or term%1~=0 or term<1 or term>9007199254740991 or not session or binding.session~=session or binding.term~=term then return false,'achievement_protection_session_changed' end
    local proof=binding.policy
    if type(proof)~='table' or proof.revision~=policy.revision
        or proof.runGeneration~=policy.runGeneration or proof.locked~=policy.locked then return false,'achievement_protection_policy_changed' end
    if binding.verified~=true or binding.active~=true then return false,'achievement_protection_unverified' end
    return true
end
function B.Message(reason)
    if reason=='achievement_policy_missing' then return 'Waiting for the host session policy.' end
    if reason=='achievement_protection_restart_required' then return 'Restart the game before starting another multiplayer session.' end
    if reason=='dev_legacy_proxy_requires_dev_mode' or reason=='dev_legacy_proxy_with_production_slice_test' then
        return 'The development achievement blocker is accepted only in development test runs. World entry is blocked.'
    end
    return 'Steam achievement blocking is not verified. World entry is blocked.'
end
return B
