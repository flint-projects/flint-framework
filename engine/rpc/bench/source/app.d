/// Typed Flint Protobuf codec exercised at the approved nominal message sizes.
module app;

import codec_probe : runProbe;
import flint.arena : RequestArena, Status;
import flint.engine.rpc : decodeProto, encodeProto;
import flint.engine.rpc.fixture_proto : Envelope;

@safe:

private ulong trial(uint payloadBytes) nothrow @nogc
{
    ubyte[3 * 65_536 + 256] backing;
    auto arena = RequestArena(backing[]);
    const payload = arena.allocate(payloadBytes, 1);
    if (!payload.ok())
        return 0;
    const filled = arena.write(payload.value, (scope ubyte[] bytes) @safe nothrow @nogc {
        foreach (index, ref value; bytes)
            value = cast(ubyte)(index * 17 + 3);
    });
    if (filled != Status.ok)
        return 0;
    Envelope message;
    message.floor = -7;
    message.ceiling = 43;
    message.payload = payload.value;
    const wire = encodeProto(message, arena);
    if (!wire.ok())
        return 0;
    Envelope returned;
    Status decoded;
    const available = arena.read(wire.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        decoded = decodeProto(bytes, returned, arena).code;
    });
    if (available != Status.ok || decoded != Status.ok || returned.floor != -7
            || returned.ceiling != 43 || returned.payload.length != payloadBytes)
        return 0;
    ulong checksum;
    const checked = arena.read(returned.payload, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        checksum = wire.value.length + 17 * bytes[0] + 31 * bytes[$ - 1] + returned.ceiling;
    });
    return checked == Status.ok ? checksum : 0;
}

/// Run and validate the fixed native codec corpus.
int main()
{
    return runProbe(&trial);
}
