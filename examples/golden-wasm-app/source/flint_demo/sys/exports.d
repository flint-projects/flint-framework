module flint_demo.sys.exports;
import core.lifetime : move;
import flint.arena : Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle;
import flint.ui_signals : SignalGraph, SignalSlot, ObserverSlot, SignalId;

@safe:
version (WebAssembly)
{
    private __gshared ubyte[65_536] output;
    private __gshared SignalSlot[8] signals;
    private __gshared ObserverSlot[8] observers;
    private __gshared uint[8] dirty;
    private __gshared CommandBuffer commands;
    private __gshared SignalGraph graph;
    private __gshared SignalId counter;
    private __gshared bool initialized;

    // SAFETY: Single-thread WASM instance; all borrowed storage is static and outlives graph and commands.
    extern (C) export uint flint_init(uint sessionEpoch) nothrow @nogc @trusted
    {
        if (initialized)
            return cast(uint) Status.conflict;
        auto b = CommandBuffer.fromStorage(output[], sessionEpoch);
        if (!b.ok())
            return cast(uint) b.error.code;
        commands = move(b.value);
        auto g = SignalGraph.fromStorage(signals[], observers[], dirty[]);
        if (!g.ok())
            return cast(uint) g.error.code;
        graph = move(g.value);
        auto s = graph.create(0);
        if (!s.ok())
            return cast(uint) s.error.code;
        counter = s.value;
        auto bound = graph.bindText(counter, NodeHandle(0, 1));
        if (bound.code != Status.ok)
            return cast(uint) bound.code;
        initialized = true;
        return cast(uint) Status.ok;
    }

    // SAFETY: Host invokes one tick at a time; delta is bounded and no borrowed view escapes.
    extern (C) export uint flint_tick(uint delta) nothrow @nogc @trusted
    {
        if (!initialized || delta > 1024)
            return cast(uint) Status.invalidArgument;
        commands.clear();
        auto current = graph.read(counter);
        if (!current.ok())
            return cast(uint) current.error.code;
        if (current.value > int.max - cast(int) delta)
            return cast(uint) Status.resourceExhausted;
        auto changed = graph.set(counter, current.value + cast(int) delta);
        if (changed.code != Status.ok)
            return cast(uint) changed.code;
        return cast(uint) graph.flush(commands).code;
    }

    // SAFETY: wasm32 pointer is represented losslessly; host validates ptr/len on every read.
    extern (C) export uint flint_buffer_ptr() nothrow @nogc @trusted
    {
        static assert(size_t.sizeof == 4);
        return cast(uint) output.ptr;
    }

    // SAFETY: CommandBuffer enforces the static output capacity and single-writer ownership.
    extern (C) export uint flint_buffer_len() nothrow @nogc @trusted
    {
        return commands.usedBytes();
    }
}
