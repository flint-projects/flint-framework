/// A borrowed RPC stream cannot be retained past the call.
module escaped_stream;

import flint.engine.rpc : RpcStream;

@safe:

private RpcStream retained;

/// Assigning a scoped stream to a persistent slot must fail.
void escape(ref scope RpcStream stream) nothrow @nogc
{
    retained = stream;
}
