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
