module betterc_bridge;
import flint.arena : Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle, TagName;

@safe:

private uint word(scope const(ubyte)[] bytes, size_t offset) nothrow @nogc
{
    uint value;
    foreach_reverse (digit; bytes[offset .. offset + 4])
        value = (value << 8) | digit;
    return value;
}

/// Encodes and inspects a real native command batch with every v1 opcode.
private int behaviorTest() nothrow @nogc
{
    ubyte[512] storage;
    auto buffer = CommandBuffer.fromStorage(storage[]);
    assert(buffer.ok());
    assert(buffer.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "hi").code == Status.ok);
    assert(buffer.value.usedBytes() == 56);
    const checked = buffer.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
        assert(bytes.length == 56 && bytes[0] == 'F' && bytes[1] == 'L');
    });
    assert(checked.code == Status.ok);

    // Regression: the attribute allowlist must not need a C library comparison routine in
    // a freestanding wasm32 build, so every opcode is linked and executed here unoptimized.
    immutable node = NodeHandle(1, 1);
    immutable surface = NodeHandle(2, 1);
    buffer.value.clear();
    assert(buffer.value.createElement(node, TagName.span).code == Status.ok);
    assert(buffer.value.setAttribute(node, cast(const(ubyte)[]) "title", cast(const(ubyte)[]) "t").code == Status.ok);
    assert(buffer.value.setAttribute(node, cast(const(ubyte)[]) "data-x", null).code == Status.ok);
    assert(buffer.value.setAttribute(node, cast(const(ubyte)[]) "onclick", null).code == Status.invalidArgument);
    assert(buffer.value.setAttribute(node, cast(const(ubyte)[]) "datax-y", null).code == Status.invalidArgument);
    assert(buffer.value.appendChild(NodeHandle(0, 1), node).code == Status.ok);
    assert(buffer.value.createElement(surface, TagName.canvas).code == Status.ok);
    const ubyte[24] rectangle = [
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 44, 1, 0, 0, 150, 0, 0, 0, 255, 0, 0, 255
    ];
    assert(buffer.value.canvas(surface, rectangle[]).code == Status.ok);
    const ubyte[20] clear = [1, 0, 0, 0, 0, 0, 128, 63, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 63];
    assert(buffer.value.webgpu(surface, clear[]).code == Status.ok);
    assert(buffer.value.remove(node).code == Status.ok);
    assert(buffer.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(word(bytes, 12) == 8 && word(bytes, 16) == 1 && word(bytes, 8) == bytes.length);
        }).code == Status.ok);
    return 0;
}

version (WebAssembly)
{
    /// Execute the real package assertions from a freestanding wasm32 host.
    extern (C) export int flint_test() nothrow @nogc
    {
        return behaviorTest();
    }
}
else
{
    extern (C) int main() nothrow @nogc
    {
        return behaviorTest();
    }
}
