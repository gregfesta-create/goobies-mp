-- Authenticated caller supplies the identity and island context. The digest
-- protects assembly only; it never establishes who a player is.
local Stream=require('gmp_checkpoint_stream');local Group=require('gmp_native_slice_group')
local Identity=require('gmp_identity');local P={}
function P.Validator(key,epoch,island,pauseRevision)
    return function(value)
        if type(value)~='table' or value.key~=key or not Identity.Parse(key)
            or value.epoch~=epoch or value.island~=island or value.pauseRevision~=(pauseRevision or 0) or type(value.native)~='table'
            or value.native.version~=1 or type(value.native.slices)~='table' then
            return false,'invalid_peer_native_state'
        end
        local detached=Group.Detach(value)
        if not detached then return false,'invalid_peer_native_data' end
        return true,detached
    end
end
function P.Packets(key,epoch,island,native,term,sequence,sid,pauseRevision)
    return Stream.ValidatedPackets({key=key,epoch=epoch,island=island,pauseRevision=pauseRevision or 0,native=native},
        term,sequence,sid,P.Validator(key,epoch,island,pauseRevision),'PLAYER_STATE_CHUNK')
end
function P.Receiver(key,epoch,island,term,pauseRevision)
    return Stream.new(term,P.Validator(key,epoch,island,pauseRevision))
end
return P
