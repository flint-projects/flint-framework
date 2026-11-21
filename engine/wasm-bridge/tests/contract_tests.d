module flint.wasm_bridge.contract_tests;

import flint.arena : Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle, TagName;
import flint.wasm_bridge.internal : read32, write32;

@safe:

@("exact capacity, atomic failure and nested scoped borrows")
unittest
{
    ubyte[56] storage;
    assert(CommandBuffer.fromStorage(storage[0 .. 31]).error.code == Status.invalidArgument);
    assert(CommandBuffer.fromStorage(storage[], 0).error.code == Status.invalidArgument);
    auto frame = CommandBuffer.fromStorage(storage[], 7);
    assert(frame.ok);
    assert(frame.value.usedBytes == 32 && frame.value.capacityBytes == 56);
    immutable mount = NodeHandle(0, 1);
    immutable node = NodeHandle(1, 1);
    assert(frame.value.setText(mount, cast(const(ubyte)[]) "hi").code == Status.ok);
    assert(frame.value.usedBytes == storage.length);
    const before = storage;
    assert(frame.value.createElement(node, TagName.span).code == Status.resourceExhausted);
    assert(storage == before);
    assert(frame.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes[0 .. 4] == cast(const(ubyte)[]) "FLNT");
            assert(read32(bytes, 8) == 56 && read32(bytes, 12) == 1);
            assert(read32(bytes, 16) == 0 && read32(bytes, 20) == 7);
            assert(read32(bytes, 36) == 24 && read32(bytes, 48) == 2);
            assert(bytes[52 .. 54] == cast(const(ubyte)[]) "hi");
            assert(bytes[54 .. 56] == [0, 0]);
            assert(frame.value.remove(node).code == Status.conflict);
            assert(frame.value.visit((scope const(ubyte)[] inner) @safe nothrow @nogc {
                assert(inner == bytes);
            }).code == Status.ok);
            frame.value.clear();
            assert(bytes == before[]);
        }).code == Status.ok);
    frame.value.clear();
    assert(frame.value.usedBytes == 32);
    assert(read32(storage, 12) == 0 && read32(storage, 16) == 1 && read32(storage, 20) == 7);
    assert(frame.value.createElement(node, TagName.span).code == Status.ok);
}

@("bounded UTF-8, handle, attribute and exact graphics payload validation")
unittest
{
    auto storage = new ubyte[256 * 1024];
    auto frame = CommandBuffer.fromStorage(storage);
    assert(frame.ok);
    immutable node = NodeHandle(65_535, 1);
    assert(frame.value.createElement(node, TagName.canvas).code == Status.ok);
    assert(frame.value.createElement(NodeHandle(65_536, 1), TagName.div).code == Status.invalidArgument);
    assert(frame.value.createElement(NodeHandle(1, 0), TagName.div).code == Status.invalidArgument);
    assert(frame.value.remove(NodeHandle(0, 1)).code == Status.invalidArgument);
    assert(frame.value.appendChild(node, node).code == Status.invalidArgument);
    immutable malformed = cast(ubyte[])[0xed, 0xa0, 0x80];
    assert(frame.value.setText(node, malformed).code == Status.invalidArgument);
    auto longText = new ubyte[65_537];
    longText[] = 'a';
    assert(frame.value.setText(node, longText[0 .. $ - 1]).code == Status.ok);
    assert(frame.value.setText(node, longText).code == Status.invalidArgument);
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "onclick", null).code == Status.invalidArgument);
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "data-label", cast(const(ubyte)[]) "🦊").code
            == Status.ok);

    ubyte[24] drawing;
    write32(drawing, 0, 1);
    write32(drawing, 4, 299);
    write32(drawing, 8, 149);
    write32(drawing, 12, 1);
    write32(drawing, 16, 1);
    assert(frame.value.canvas(node, drawing).code == Status.ok);
    write32(drawing, 12, 2);
    assert(frame.value.canvas(node, drawing).code == Status.invalidArgument);
    write32(drawing, 4, 300);
    write32(drawing, 8, 150);
    write32(drawing, 12, 0);
    write32(drawing, 16, 0);
    assert(frame.value.canvas(node, drawing).code == Status.ok);
    assert(frame.value.webgpu(node, drawing[0 .. 19]).code == Status.invalidArgument);
    drawing[4 .. $] = 0;
    write32(drawing, 4, 0x3f800000);
    write32(drawing, 8, 0x80000000);
    assert(frame.value.webgpu(node, drawing[0 .. 20]).code == Status.ok);
    write32(drawing, 4, 0x7fc00000);
    assert(frame.value.webgpu(node, drawing[0 .. 20]).code == Status.invalidArgument);
}
