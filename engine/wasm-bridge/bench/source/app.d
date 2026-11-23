module app;

import bridge_probe : measure, observe;
import flint.engine.wasm_bridge : CommandBuffer, NodeHandle;

@safe:

int main()
{
    import flint.arena : Status;

    auto storage = new ubyte[32 + 4096 * 24];
    auto frame = CommandBuffer.fromStorage(storage);
    if (!frame.ok)
        return 1;
    const success = measure((uint count) @safe nothrow @nogc {
        frame.value.clear();
        foreach (_; 0 .. count)
            if (frame.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "42").code != Status.ok)
                return 0U;
        uint checksum;
        if (frame.value.visit((scope const(ubyte)[] data)@safe nothrow @nogc {
                checksum = observe(data, count);
            }).code != Status.ok)
            return 0U;
        return checksum;
    });
    return success ? 0 : 1;
}
