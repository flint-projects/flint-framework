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
    assert(header.value.bytes[0 .. header.value.length] == [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0]);
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

private ubyte[] maskedFrame(ubyte first, scope const(ubyte)[] payload) pure
{
    assert(payload.length < 126);
    static immutable ubyte[4] mask = [9, 8, 7, 6];
    ubyte[] wire = [first, cast(ubyte)(0x80 | payload.length), 9, 8, 7, 6];
    foreach (index, value; payload)
        wire ~= cast(ubyte)(value ^ mask[index & 3]);
    return wire;
}

private ushort closeCodeOf(scope const(ubyte)[] wire, size_t limit = 4 * 1024 * 1024)
{
    ubyte[256] backing;
    auto arena = RequestArena(backing[]);
    WsDecoder decoder;
    size_t read;
    while (read < wire.length)
    {
        const result = decoder.feed(wire[read .. $], arena, limit);
        if (result.closeCode != 0)
        {
            assert(result.error.code != Status.ok);
            // The failure is sticky.
            assert(decoder.feed(wire[], arena).closeCode == result.closeCode);
            assert(decoder.end().code != Status.ok);
            return result.closeCode;
        }
        assert(result.consumed != 0);
        read += result.consumed;
    }
    return 0;
}

@("websocket_autobahn: reserved bits, opcodes, control limits, interleaving and close payloads fail with RFC codes")
unittest
{
    // RSV1, RSV2 and RSV3 require a negotiated extension; none is negotiated by default.
    assert(closeCodeOf(maskedFrame(0xc1, cast(const(ubyte)[]) "a")) == 1002);
    assert(closeCodeOf(maskedFrame(0xa1, cast(const(ubyte)[]) "a")) == 1002);
    assert(closeCodeOf(maskedFrame(0x91, cast(const(ubyte)[]) "a")) == 1002);
    // Reserved data and control opcodes.
    static immutable ubyte[] reserved = [3, 4, 5, 6, 7, 11, 12, 13, 14, 15];
    foreach (opcode; reserved)
        assert(closeCodeOf(maskedFrame(cast(ubyte)(0x80 | opcode), null)) == 1002);
    // A control frame payload above 125 bytes is invalid even when final.
    immutable ubyte[8] longPing = [0x89, 0xfe, 0, 126, 0, 0, 0, 0];
    assert(closeCodeOf(longPing[]) == 1002);
    // A new data frame cannot start inside a fragmented message.
    immutable ubyte[1] a = ['a'];
    immutable ubyte[1] b = ['b'];
    assert(closeCodeOf(maskedFrame(0x01, a[]) ~ maskedFrame(0x81, b[])) == 1002);
    assert(closeCodeOf(maskedFrame(0x02, a[]) ~ maskedFrame(0x82, b[])) == 1002);
    // A pong may interleave fragments; the fragmented binary message still completes.
    assert(closeCodeOf(maskedFrame(0x02, a[]) ~ maskedFrame(0x8a, null) ~ maskedFrame(0x80, b[])) == 0);
    // A 64-bit length with the most significant bit set is invalid.
    immutable ubyte[14] huge = [0x82, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    assert(closeCodeOf(huge[]) == 1002);
    // Close codes: allowed ranges pass, reserved and out-of-range values fail, reasons must be UTF-8.
    static immutable ushort[] allowed = [
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 3000, 4999
    ];
    foreach (code; allowed)
        assert(closeCodeOf(maskedFrame(0x88, [cast(ubyte)(code >> 8), cast(ubyte) code])) == 0);
    static immutable ushort[] refused = [0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000];
    foreach (code; refused)
        assert(closeCodeOf(maskedFrame(0x88, [cast(ubyte)(code >> 8), cast(ubyte) code])) == 1002);
    assert(closeCodeOf(maskedFrame(0x88, [3, 232, 0xc3, 0x28])) == 1007);
    assert(closeCodeOf(maskedFrame(0x88, null)) == 0);
}

@("websocket_autobahn: fragmented messages are capped in aggregate and UTF-8 is checked across fragments")
unittest
{
    // Three fragments of two bytes each exceed a five-byte aggregate limit on the third fragment.
    const fragments = maskedFrame(0x02, [1, 2]) ~ maskedFrame(0x00, [3, 4]) ~ maskedFrame(0x80, [
        5, 6
    ]);
    assert(closeCodeOf(fragments, 6) == 0);
    assert(closeCodeOf(fragments, 5) == 1009);
    // The 4 MiB aggregate cap applies even when a caller passes a larger limit, before any payload is stored.
    immutable ubyte[14] declared = [0x82, 0xff, 0, 0, 0, 0, 0, 0x40, 0, 1, 0, 0, 0, 0];
    assert(closeCodeOf(declared[], size_t.max) == 1009);
    immutable ubyte[14] exact = [0x82, 0xff, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0];
    assert(closeCodeOf(exact[], size_t.max) == 0);
    // A code point split across fragments is valid; an invalid continuation in the second fragment is not.
    assert(closeCodeOf(maskedFrame(0x01, [0xe2, 0x82]) ~ maskedFrame(0x80, [0xac])) == 0);
    assert(closeCodeOf(maskedFrame(0x01, [0xe2, 0x82]) ~ maskedFrame(0x80, [0x28])) == 1007);
    // A text message ending inside a code point fails when its final fragment arrives.
    assert(closeCodeOf(maskedFrame(0x01, [0xf0, 0x9f]) ~ maskedFrame(0x80, [0x9a])) == 1007);
    // Surrogates and code points above U+10FFFF are rejected.
    assert(closeCodeOf(maskedFrame(0x81, [0xed, 0xa0, 0x80])) == 1007);
    assert(closeCodeOf(maskedFrame(0x81, [0xf4, 0x90, 0x80, 0x80])) == 1007);
    // An end of input inside a fragmented message is truncated.
    ubyte[16] backing;
    auto arena = RequestArena(backing[]);
    WsDecoder decoder;
    const partial = maskedFrame(0x01, cast(const(ubyte)[]) "a");
    assert(decoder.feed(partial, arena).consumed == partial.length);
    assert(decoder.end().code == Status.invalidArgument);
}

@("websocket_autobahn: client frames carry a mask and a client decoder rejects masked server frames")
unittest
{
    import flint.rpc.websocket : clientHeader;

    const header = clientHeader(WsOpcode.text, 300, [1, 2, 3, 4]);
    assert(header.ok() && header.value.length == 8);
    assert(header.value.bytes[0 .. 8] == [0x81, 0x80 | 126, 1, 44, 1, 2, 3, 4]);
    const small = clientHeader(WsOpcode.close, 2, [5, 6, 7, 8]);
    assert(small.ok() && small.value.bytes[0 .. small.value.length] == [0x88, 0x82, 5, 6, 7, 8]);
    assert(clientHeader(WsOpcode.pong, 126, [0, 0, 0, 0]).error.code == Status.invalidArgument);
    assert(serverHeader(WsOpcode.binary, 4 * 1024 * 1024 + 1).error.code == Status.invalidArgument);
    assert(serverHeader(WsOpcode.close, 2, false).error.code == Status.invalidArgument);

    ubyte[16] backing;
    auto arena = RequestArena(backing[]);
    WsDecoder client;
    client.expectMasked = false;
    assert(client.feed(maskedFrame(0x81, cast(const(ubyte)[]) "a"), arena).closeCode == 1002);
}
