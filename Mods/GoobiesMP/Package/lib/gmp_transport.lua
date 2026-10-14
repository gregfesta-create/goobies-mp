-- GoobiesMP production: peer-aware transport CONTRACT (no implementation here).
-- A transport moves opaque text packets between a host and N peers. It is deliberately dumb:
--   * it provides NO reliability, ordering or identity (the upper layers do; see gmp_link / gmp_host);
--   * peerId is an opaque value valid only for the lifetime of one connection. It is NEVER player identity;
--   * it may be unreliable (UDP relay, Steam unreliable messages) - upper layers must tolerate loss/duplication/reordering.
-- Implementations planned: in-memory (tests/dev, gmp_memory_transport.lua), UDP sidecar relay (M3/M4), Steam (spike S4).
--
-- Required methods (all return values listed):
--   t:Name()                 -> string
--   t:IsAuthenticated()      -> bool   true only if the transport itself proves the peer's identity (Steam); false => identity is a claim
--   t:Listen()               -> true | nil,err            host side: start accepting peers
--   t:Connect(address)       -> true | nil,err            client side: connect to the host (address meaning is transport specific)
--   t:Send(peerId, data)     -> true | nil,err            queue one packet to a peer (client: peerId of the host connection)
--   t:Poll()                 -> events[]                  drain events since last Poll:
--        { kind="peer_connected",    peerId=P }
--        { kind="peer_disconnected", peerId=P, reason=string }
--        { kind="message",           peerId=P, data=string }
--   t:Close(peerId)          -> nil                       drop one peer (nil peerId = close everything)
local Transport = {}

Transport.REQUIRED = { "Name", "IsAuthenticated", "Listen", "Connect", "Send", "Poll", "Close" }

function Transport.Check(t)
    local missing = {}
    for _, m in ipairs(Transport.REQUIRED) do
        if type(t) ~= "table" or type(t[m]) ~= "function" then missing[#missing + 1] = m end
    end
    return #missing == 0, missing
end

return Transport
