/// The version 13 handshake uses the pinned OpenSSL provider.
module flint.rpc.ffi.websocket;

import flint.arena : Error, Result, Status;

@safe:

version (FlintNativeOpenssl)
{
    private extern (C) int flint_rpc_websocket_accept(const(char)*, size_t, char*, size_t) @system nothrow @nogc;
}

/// Compute the HTTP upgrade field value from a canonical version 13 request key.
// SAFETY: The result is a local 28-byte array. The synchronous OpenSSL shim checks the exact key length,
// writes within the supplied capacity, and does not retain either pointer or call D.
@trusted package(flint.rpc) Result!(char[28]) websocketAccept(scope const(char)[] key) nothrow @nogc
{
    version (FlintNativeOpenssl)
    {
        char[28] output;
        const result = flint_rpc_websocket_accept(key.ptr, key.length, output.ptr, output.length);
        if (result == 0)
            return Result!(char[28])(output);
        return Result!(char[28])(output, result == -1 ? Error(Status.invalidArgument,
                "invalid WebSocket handshake key") : Error(Status.unavailable, "WebSocket handshake provider failed"));
    }
    else
        return Result!(char[28])(Result!(char[28]).init.value, Error(Status.unsupported,
                "pinned OpenSSL is unavailable"));
}
