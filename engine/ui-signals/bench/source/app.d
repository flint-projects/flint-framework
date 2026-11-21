module app;

import flint.arena : Error, Status;
import flint.ui_signals : ObserverSlot, SignalGraph, SignalId, SignalSlot;
import flint.wasm_bridge : CommandBuffer, NodeHandle;
import signals_probe : measure;

@safe:

private bool run(uint count)
{
    auto signals = new SignalSlot[count];
    auto observers = new ObserverSlot[count];
    auto queue = new uint[count];
    auto ids = new SignalId[count];
    auto graph = SignalGraph.fromStorage(signals, observers, queue);
    if (!graph.ok)
        return false;
    const width = count == 1 ? 1 : count / 10;
    auto initialization = new ubyte[32 + width * 24];
    auto frame = CommandBuffer.fromStorage(initialization);
    for (uint chunk; chunk < count; chunk += width)
    {
        foreach (index; chunk .. chunk + width)
        {
            const id = graph.value.create(0);
            if (!id.ok || graph.value.bindText(id.value, NodeHandle(index + 1, 1)).code != Status.ok)
                return false;
            ids[index] = id.value;
        }
        frame.value.clear();
        if (graph.value.flush(frame.value).code != Status.ok)
            return false;
    }
    return measure(count, (uint first, uint changes, int value) @safe nothrow @nogc {
        foreach (index; first .. first + changes)
        {
            auto updated = graph.value.set(ids[index], value);
            if (updated.code != Status.ok)
                return updated;
        }
        return Error.init;
    }, (ref scope CommandBuffer output) @safe nothrow @nogc { return graph.value.flush(output); });
}

int main()
{
    foreach (count; [1U, 1000U, 10_000U])
        if (!run(count))
            return 1;
    return 0;
}
