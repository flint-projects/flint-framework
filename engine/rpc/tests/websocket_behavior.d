/// Exercises fragmented text, control interleaving, framing and the pinned handshake primitive.
module flint.rpc.websocket_behavior;

import flint.arena : RequestArena, Status;
import flint.rpc.ffi.websocket : websocketAccept;
import flint.rpc.websocket : WsDecoder, WsOpcode, serverHeader;

@safe:

unittest
{
    immutable ubyte[23] wire = [
        0x01, 0x82, 1, 2, 3, 4, 0xf1, 0x9d, 0x89, 0x81, 1, 2, 3, 4, 0x79, 0x80, 0x82, 1, 2, 3, 4, 0x9b,
        0x82
    ];
    foreach (split; 0 .. wire.length + 1)
    {
        ubyte[16] backing;
        auto arena = RequestArena(backing[]);
        WsDecoder decoder;
        uint seen;
        foreach (chunk; [wire[0 .. split], wire[split .. $]])
        {
            size_t read;
            while (read < chunk.length)
            {
                const result = decoder.feed(chunk[read .. $], arena);
                assert(result.consumed > 0 && result.error.code == Status.ok);
                read += result.consumed;
                if (!result.complete)
                    continue;
                ++seen;
                if (seen == 1)
                    assert(result.opcode == WsOpcode.ping && result.controlLength == 1 && result.control[0] == 'x');
                else
                {
                    assert(result.opcode == WsOpcode.text);
                    assert(arena.read(result.payload, (scope const(ubyte)[] payload) @safe nothrow @nogc {
                            assert(cast(const(char)[]) payload == "🚀");
                        }) == Status.ok);
                }
            }
        }
        assert(seen == 2);
        assert(decoder.end().code == Status.ok);
    }
}

unittest
{
    ubyte[16] backing;
    auto arena = RequestArena(backing[]);
    immutable ubyte[2] unmasked = [0x81, 0x00];
    immutable ubyte[6] fragment = [0x80, 0x80, 0, 0, 0, 0];
    immutable ubyte[8] noncanonical = [0x81, 0xfe, 0, 0, 0, 0, 0, 0];
    immutable ubyte[6] control = [0x09, 0x80, 0, 0, 0, 0];
    immutable ubyte[8] overlong = [0x81, 0x82, 0, 0, 0, 0, 0xc0, 0x80];
    immutable ubyte[6] limit = [0x82, 0x84, 0, 0, 0, 0];
    immutable ubyte[7] badClose = [0x88, 0x81, 0, 0, 0, 0, 0xff];
    immutable ubyte[8] reservedClose = [0x88, 0x82, 0, 0, 0, 0, 3, 237];
    immutable ubyte[7] truncatedUtf8 = [0x81, 0x81, 0, 0, 0, 0, 0xc2];

    WsDecoder decoder;
    assert(decoder.feed(unmasked[], arena).closeCode == 1002);
    assert(decoder.feed(fragment[], arena).consumed == 0);
    decoder = WsDecoder.init;
    assert(decoder.feed(fragment[], arena).closeCode == 1002);
    decoder = WsDecoder.init;
    assert(decoder.feed(noncanonical[], arena).closeCode == 1002);
    decoder = WsDecoder.init;
    assert(decoder.feed(control[], arena).closeCode == 1002);
    decoder = WsDecoder.init;
    assert(decoder.feed(overlong[], arena).closeCode == 1007);
    decoder = WsDecoder.init;
    assert(decoder.feed(limit[], arena, 3).closeCode == 1009);
    decoder = WsDecoder.init;
    assert(decoder.feed(badClose[], arena).closeCode == 1002);
    decoder = WsDecoder.init;
    assert(decoder.feed(reservedClose[], arena).closeCode == 1002);
    decoder = WsDecoder.init;
    assert(decoder.feed(truncatedUtf8[], arena).closeCode == 1007);

    decoder = WsDecoder.init;
    decoder.expectMasked = false;
    assert(decoder.feed(unmasked[], arena).complete);
    auto header = serverHeader(WsOpcode.binary, 65_536);
    assert(header.ok() && header.value.length == 10);
    assert(header.value.bytes == [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0]);
    assert(serverHeader(WsOpcode.ping, 126).error.code == Status.invalidArgument);
}

version (FlintNativeOpenssl) unittest
{
    const accept = websocketAccept("dGhlIHNhbXBsZSBub25jZQ==");
    assert(accept.ok() && accept.value[] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    assert(websocketAccept("dGhlIHNhbXBsZSBub25jZR==").error.code == Status.invalidArgument);
    assert(websocketAccept("dGhlIHNhbXBsZSBub25jZQ=").error.code == Status.invalidArgument);
    assert(websocketAccept("dGhlIHNhbXBsZSBub25\0ZQ==").error.code == Status.invalidArgument);
}
