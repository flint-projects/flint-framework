/// Scalar-only entry point to the control's generated protobuf-c operation.
module ffi.codec;

@safe:

version (FlintNativeProtobufC)
{
    private extern (C) ulong flint_rpc_probe(uint payloadBytes) @system nothrow @nogc;
}

/// Return the verified checksum from the direct native codec.
// SAFETY: The fixture passes a scalar size and receives a scalar checksum. The C probe bounds its storage.
ulong trial(uint payloadBytes) @trusted nothrow @nogc
{
    version (FlintNativeProtobufC)
        return flint_rpc_probe(payloadBytes);
    else
        return 0;
}
