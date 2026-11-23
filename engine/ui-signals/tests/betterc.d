module betterc_signals;
import flint.arena : Status;
import flint.engine.ui_signals : SignalGraph, SignalSlot, ObserverSlot;
import flint.engine.wasm_bridge : CommandBuffer, NodeHandle;

@safe:
/// Exercises graph state and bridge output without a GC/runtime dependency.
private int behaviorTest() nothrow @nogc
{
    SignalSlot[4] slots;
    ObserverSlot[4] observers;
    uint[4] queue;
    ubyte[256] storage;
    auto graph = SignalGraph.fromStorage(slots[], observers[], queue[]);
    auto buffer = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok() && buffer.ok());
    auto value = graph.value.create(0);
    assert(value.ok());
    assert(graph.value.bindText(value.value, NodeHandle(0, 1)).code == Status.ok);
    assert(graph.value.set(value.value, 7).code == Status.ok);
    assert(graph.value.read(value.value).value == 7);
    assert(graph.value.flush(buffer.value).code == Status.ok);
    assert(buffer.value.usedBytes() > 32);
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
