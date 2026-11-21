module signals_probe;

import core.memory : GC;
import core.time : MonoTime;
import flint.arena : Error, Status;
import flint.wasm_bridge : CommandBuffer;
import std.stdio : writeln;

@safe:

/// Submit a fixed set of scalar changes from the retained trace.
alias SetRange = Error delegate(uint first, uint changes, int value) @safe nothrow @nogc;

/// Emit the pending range into the caller's frame.
alias Render = Error delegate(ref scope CommandBuffer) @safe nothrow @nogc;

private uint word(scope const(ubyte)[] input, size_t offset) pure nothrow @nogc
{
    uint result;
    foreach_reverse (byteValue; input[offset .. offset + 4])
        result = (result << 8) | byteValue;
    return result;
}

private ulong observe(ref scope CommandBuffer frame, uint first, uint count, ubyte expected) nothrow @nogc
{
    ulong output;
    const visited = frame.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
        if (bytes.length != 32 + count * 24 || word(bytes, 12) != count)
            return;
        ulong verified;
        foreach (index; 0 .. count)
        {
            const start = 32 + index * 24;
            const node = word(bytes, start + 8);
            if (word(bytes, start) != 2 || word(bytes, start + 16) != 1 || node != first + index + 1
                || bytes[start + 20] != expected)
                return;
            verified += node + expected;
        }
        output = verified;
    });
    return visited.code == Status.ok ? output : 0;
}

/// Retain every render result over complete fixed-size trials.
bool measure(uint signals, scope SetRange setRange, scope Render render)
{
    const width = signals == 1 ? 1 : signals / 10;
    auto storage = new ubyte[32 + 24 * width];
    auto frame = CommandBuffer.fromStorage(storage);
    if (!frame.ok)
        return false;
    uint rounds;
    long setTime;
    long flushTime;
    ulong total;
    const allocated = GC.stats.allocatedInCurrentThread;
    const timer = MonoTime.currTime;
    do
    {
        ulong sample;
        for (uint changed; changed < 100_000; changed += width)
        {
            const first = changed % signals;
            const value = cast(int)(1 + ((changed / signals) & 1));
            frame.value.clear();
            const began = MonoTime.currTime;
            if (setRange(first, width, value).code != Status.ok)
                return false;
            const setDone = MonoTime.currTime;
            if (render(frame.value).code != Status.ok)
                return false;
            setTime += (setDone - began).total!"nsecs";
            flushTime += (MonoTime.currTime - setDone).total!"nsecs";
            const result = observe(frame.value, first, width, cast(ubyte)('0' + value));
            if (result == 0)
                return false;
            sample += result;
        }
        total += sample;
        ++rounds;
    }
    while ((MonoTime.currTime - timer).total!"msecs" < 150);
    const budget = cast(ulong) rounds * 100_000;
    const equalStart = MonoTime.currTime;
    frame.value.clear();
    if (setRange(0, width, 2).code != Status.ok || render(frame.value).code != Status.ok)
        return false;
    const equalNanos = (MonoTime.currTime - equalStart).total!"nsecs";
    if (GC.stats.allocatedInCurrentThread != allocated || frame.value.usedBytes != 32)
        return false;
    writeln("signals=", signals, " rounds=", rounds, " sets=", budget, " patches=", budget,
            " ns_per_set=", cast(double) setTime / budget, " ns_per_observer=", cast(double) flushTime / budget,
            " equal_frame_ns=", equalNanos, " gc_bytes=0 checksum=", total);
    return true;
}
