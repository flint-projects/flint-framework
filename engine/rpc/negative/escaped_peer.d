/// A borrowed WebSocket peer cannot be retained after its route.
module escaped_peer;

import flint.engine.rpc : WebSocketPeer;

@safe:

private WebSocketPeer retained;

/// Assigning the scoped peer to a persistent slot must fail.
void escape(ref scope WebSocketPeer peer) nothrow @nogc
{
    retained = peer;
}
