module betterc_bridge;
import flint.arena : Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle;

@safe:
/// Encodes and inspects a real native command batch.
private int behaviorTest() nothrow @nogc
{
    ubyte[256] storage;
    auto buffer = CommandBuffer.fromStorage(storage[]);
    assert(buffer.ok());
    assert(buffer.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "hi").code == Status.ok);
    assert(buffer.value.usedBytes() == 56);
    const checked = buffer.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
        assert(bytes.length == 56 && bytes[0] == 'F' && bytes[1] == 'L');
    });
    assert(checked.code == Status.ok);
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
