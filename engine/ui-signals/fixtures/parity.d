module flint.ui_signals.parity;

import flint.arena : Status;
import flint.ui_signals : ComputedSlot, ObserverSlot, SignalGraph, SignalId, SignalSlot;
import flint.wasm_bridge : CommandBuffer, NodeHandle;

@safe:

private int doubleValue(scope const(int)[] inputs) nothrow @nogc
{
    return inputs[0] * 2;
}

private size_t copyFrame(ref scope const CommandBuffer frame, scope ubyte[] output) nothrow @nogc
{
    const length = frame.usedBytes;
    if (length > output.length)
        return 0;
    const copied = frame.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
        foreach (index, value; bytes)
            output[index] = value;
    });
    return copied.code == Status.ok ? length : 0;
}

private uint run(scope ubyte[] output) nothrow @nogc
{
    SignalSlot[3] signals;
    ObserverSlot[3] observers;
    uint[3] dirty;
    ComputedSlot[1] computations;
    SignalId[1] edges;
    ubyte[512] commands;
    auto graph = SignalGraph.fromStorage(signals[], observers[], dirty[], computations[], edges[]);
    auto frame = CommandBuffer.fromStorage(commands[], 47);
    if (output.length < 4 || !graph.ok || !frame.ok)
        return 0;
    const root = graph.value.create(3);
    const child = graph.value.computed([root.value], &doubleValue);
    if (!root.ok || !child.ok || graph.value.bindText(child.value, NodeHandle(0, 1)).code != Status.ok)
        return 0;
    output[0] = cast(ubyte) graph.value.set(child.value, 7).code;
    output[1] = cast(ubyte) graph.value.dispose(root.value).code;
    output[2] = cast(ubyte) graph.value.flush(frame.value).code;
    size_t used = 4;
    used += copyFrame(frame.value, output[used .. $]);
    frame.value.clear();
    if (graph.value.set(root.value, -11).code != Status.ok || graph.value.flush(frame.value).code != Status.ok)
        return 0;
    used += copyFrame(frame.value, output[used .. $]);
    if (graph.value.dispose(child.value).code != Status.ok || graph.value.dispose(root.value).code != Status.ok)
        return 0;
    output[3] = cast(ubyte) graph.value.read(root.value).error.code;
    return cast(uint) used;
}

version (WebAssembly)
{
    private __gshared ubyte[1024] transcript;

    // SAFETY: The single-threaded guest owns the output storage for the whole fixture.
    extern (C) export uint signal_trace() @trusted nothrow @nogc
    {
        return run(transcript[]);
    }

    // SAFETY: The host validates the wasm32 offset and length against current linear memory.
    extern (C) export uint signal_trace_ptr() @trusted nothrow @nogc
    {
        static assert(size_t.sizeof == uint.sizeof);
        return cast(uint) transcript.ptr;
    }
}
else
{
    import core.stdc.stdio : fwrite, stdout;

    @system extern (C) int main()
    {
        ubyte[1024] bytes;
        const used = run(bytes[]);
        return used > 4 && fwrite(bytes.ptr, 1, used, stdout) == used ? 0 : 1;
    }
}
