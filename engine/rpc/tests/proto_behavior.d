/// Typed round-trip evidence against pinned generated C descriptors.
module flint.rpc.proto_behavior;

import flint.arena : Buffer, RequestArena, Status, Text;
import flint.rpc.fixture_proto : Detail, Envelope, EnvelopeDetailsEntry, Switch;
import flint.rpc.proto : decodeProto, encodeProto;

@safe:

version (FlintNativeProtobufC) unittest
{
    ubyte[4096] memory;
    auto arena = RequestArena(memory[]);
    Envelope given;
    given.floor = long.min;
    given.ceiling = ulong.max;
    given.status = cast(Switch) 192;
    given.samples.count = 2;
    given.samples.values[0 .. 2] = [int.min, int.max];
    given.choiceCase = Envelope.ChoiceCase.label;
    given.label = Text(arena.copyIn(cast(const(ubyte)[]) "channel").value);
    given.child.present = true;
    given.child.value = Detail(uint.max, Text(arena.copyIn(cast(const(ubyte)[]) "child").value));
    given.details.count = 1;
    given.details.values[0] = EnvelopeDetailsEntry();
    given.details.values[0].key = Text(arena.copyIn(cast(const(ubyte)[]) "lookup").value);
    given.details.values[0].value = given.child;
    immutable ubyte[3] payload = [0, 0xff, 0];
    given.payload = arena.copyIn(payload[]).value;
    given.ratio = -1.25;
    given.active = true;
    const wire = encodeProto(given, arena);
    assert(wire.ok());

    Envelope decoded;
    assert(arena.read(wire.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(decodeProto(bytes, decoded, arena).code == Status.ok);
        }) == Status.ok);
    assert(decoded.floor == long.min && decoded.ceiling == ulong.max && cast(int) decoded.status == 192);
    assert(decoded.samples.count == 2 && decoded.samples.values[0 .. 2] == [int.min, int.max]);
    assert(decoded.choiceCase == Envelope.ChoiceCase.label && decoded.number == 0);
    assert(decoded.child.present && decoded.child.value.id == uint.max);
    assert(decoded.details.count == 1 && decoded.details.values[0].value.present);
    assert(decoded.details.values[0].value.value.id == uint.max);
    assert(decoded.ratio == -1.25 && decoded.active);
    verifyBytes(arena, decoded.details.values[0].key.bytes, cast(const(ubyte)[]) "lookup");
    verifyBytes(arena, decoded.label.bytes, cast(const(ubyte)[]) "channel");
    verifyBytes(arena, decoded.child.value.note.bytes, cast(const(ubyte)[]) "child");
    verifyBytes(arena, decoded.payload, payload[]);
}

version (FlintNativeProtobufC) unittest
{
    ubyte[128] memory;
    auto arena = RequestArena(memory[]);
    Envelope decoded;
    decoded.ceiling = 42;
    immutable ubyte[2] truncated = [0x10, 0x80];
    immutable ubyte[2] unknown = [0x78, 1];
    assert(decodeProto(truncated[], decoded, arena).code == Status.invalidArgument && decoded.ceiling == 42);
    assert(decodeProto(unknown[], decoded, arena).code == Status.ok && decoded.ceiling == 0 && !decoded.active);

    Detail empty;
    assert(encodeProto(empty, arena).value.length == 0);
    const invalid = arena.copyIn(cast(const(ubyte)[]) "x\0y");
    empty.note = Text(invalid.value);
    assert(encodeProto(empty, arena).error.code == Status.invalidArgument);
    assert(arena.reset() == Status.ok);
    assert(encodeProto(empty, arena).error.code == Status.invalidArgument);
}

private void verifyBytes(ref scope RequestArena arena, Buffer value, scope const(ubyte)[] expected) nothrow @nogc
{
    assert(arena.read(value, (scope const(ubyte)[] decoded) @safe nothrow @nogc {
            assert(decoded == expected);
        }) == Status.ok);
}

@("protobuf_roundtrip: generated encoders emit pinned protobuf-c bytes")
version (FlintNativeProtobufC) unittest
{
    ubyte[512] memory;
    auto arena = RequestArena(memory[]);
    Detail detail;
    detail.id = 23;
    detail.note = Text(arena.copyIn(cast(const(ubyte)[]) "hello").value);
    const packed = encodeProto(detail, arena);
    assert(packed.ok());
    // The same bytes protobuf-c's generated flint__rpc__fixture__detail__pack produces (tests/c/provider.c).
    verifyBytes(arena, packed.value, [0x08, 23, 0x12, 5, 'h', 'e', 'l', 'l', 'o']);

    Envelope zigzag;
    zigzag.floor = -1;
    zigzag.samples.count = 2;
    zigzag.samples.values[0 .. 2] = [-1, 1];
    zigzag.choiceCase = Envelope.ChoiceCase.number;
    zigzag.number = 0;
    const wire = encodeProto(zigzag, arena);
    assert(wire.ok());
    // sint64 -1 is zigzag 1; packed sint32 [-1, 1] is [1, 2]; a set oneof member is written even when zero.
    verifyBytes(arena, wire.value, [0x08, 0x01, 0x22, 0x02, 0x01, 0x02, 0x30, 0x00]);
}

@("protobuf_roundtrip: malformed input leaves the destination unchanged")
version (FlintNativeProtobufC) unittest
{
    ubyte[256] memory;
    auto arena = RequestArena(memory[]);
    Envelope decoded;
    decoded.ceiling = 7;
    immutable ubyte[12] overlong = [
        0x10, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01
    ];
    immutable ubyte[3] wrongType = [0x12, 0x01, 0x00];
    immutable ubyte[3] badText = [0x3a, 0x01, 0xff];
    immutable ubyte[3] shortLength = [0x4a, 0x05, 0x00];
    immutable ubyte[1] lonelyTag = [0x10];
    immutable ubyte[2] fieldZero = [0x00, 0x00];
    foreach (malformed; [
            overlong[], wrongType[], badText[], shortLength[], lonelyTag[], fieldZero[]
        ])
    {
        assert(decodeProto(malformed, decoded, arena).code == Status.invalidArgument);
        assert(decoded.ceiling == 7 && decoded.label == Text.init);
    }
}

@("protobuf_roundtrip: an over-capacity repeated field is rejected")
version (FlintNativeProtobufC) unittest
{
    ubyte[256] memory;
    auto arena = RequestArena(memory[]);
    ubyte[19] wire;
    wire[0] = 0x22;
    wire[1] = 17;
    Envelope decoded;
    decoded.ceiling = 9;
    assert(decodeProto(wire[], decoded, arena).code == Status.resourceExhausted);
    assert(decoded.ceiling == 9 && decoded.samples.count == 0);
    wire[1] = 16;
    assert(decodeProto(wire[0 .. 18], decoded, arena).code == Status.ok);
    assert(decoded.samples.count == 16 && decoded.ceiling == 0);
}

@("protobuf_roundtrip: the last oneof member on the wire wins")
version (FlintNativeProtobufC) unittest
{
    ubyte[256] memory;
    auto arena = RequestArena(memory[]);
    immutable ubyte[5] labelLast = [0x30, 0x05, 0x3a, 0x01, 'x'];
    immutable ubyte[5] numberLast = [0x3a, 0x01, 'x', 0x30, 0x05];
    Envelope decoded;
    assert(decodeProto(labelLast[], decoded, arena).code == Status.ok);
    assert(decoded.choiceCase == Envelope.ChoiceCase.label);
    verifyBytes(arena, decoded.label.bytes, cast(const(ubyte)[]) "x");
    assert(decodeProto(numberLast[], decoded, arena).code == Status.ok);
    assert(decoded.choiceCase == Envelope.ChoiceCase.number && decoded.number == 5);
}
