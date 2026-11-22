module flint.actuator.spans;

import core.atomic : atomicLoad, atomicOp;
import core.sync.mutex : Mutex;
import flint.actuator.types : TraceContext;
import flint.arena : Error, Result, Status;
import flint.conc : fillSecureRandom;

@safe:

package(flint.actuator) struct SpanRecord
{
    char[128] name;
    uint bytes;
    TraceContext context;
    ubyte[8] parent;
    long start;
    long finish;
    bool failed;
}

/// A single bounded span lifetime, including copies of an opaque handle.
struct Span
{
    private Spans owner;
    private ulong generation;
    private uint id;
    private TraceContext identity;

    /// Correlation data for owned child requests and their logs.
    TraceContext context() const pure nothrow @nogc
    {
        return identity;
    }

    /// Mark the bounded slot complete and queue it for the exporter.
    Error finish(long monotonicNanos, bool failed) nothrow @nogc
    {
        return owner is null ? Error.init : owner.finish(id, generation, monotonicNanos, failed);
    }
}

private enum SlotPhase : ubyte
{
    free,
    started,
    ready
}

private struct Slot
{
    SpanRecord entry;
    uint next;
    ulong generation;
    SlotPhase phase;
}

package(flint.actuator) final class Spans
{
    private Slot[] slots;
    private Mutex gate;
    private uint available = 1;
    private uint readyHead;
    private uint readyTail;
    private uint readyCount;
    private ulong sequence;
    private shared ulong drops;
    private bool closed;

    this(uint capacity)
    {
        gate = new Mutex;
        slots = new Slot[capacity + 1];
        foreach (i; 1 .. capacity)
            slots[i].next = i + 1;
    }

    Result!Span begin(string name, TraceContext parent, long monotonicNanos) nothrow @nogc
    {
        if (name.length == 0 || name.length > 128 || monotonicNanos < 0)
            return Result!Span(Span.init, Error(Status.invalidArgument, "invalid span name or clock"));
        // Draw identifiers before taking the shared registry lock; the system call needs no shared state.
        TraceContext trace;
        const outcome = makeContext(parent, trace);
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        if (closed)
            return Result!Span(Span.init, Error(Status.unavailable, "span registry has closed"));
        if (available == 0 || sequence == ulong.max)
        {
            atomicOp!"+="(drops, 1UL);
            return Result!Span(Span(null, 0, 0, parent));
        }
        if (outcome.code != Status.ok)
            return Result!Span(Span.init, outcome);
        const id = available;
        auto slot = &slots[id];
        available = slot.next;
        slot.entry.name[0 .. name.length] = name[];
        slot.entry.bytes = cast(uint) name.length;
        slot.entry.context = trace;
        slot.entry.parent = parent.spanId;
        slot.entry.start = monotonicNanos;
        slot.generation = ++sequence;
        slot.phase = SlotPhase.started;
        slot.next = 0;
        return Result!Span(Span(this, slot.generation, id, trace));
    }

    private Error finish(uint id, ulong generation, long end, bool failed) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        auto slot = &slots[id];
        if (slot.generation != generation || slot.phase != SlotPhase.started)
            return Error(Status.notFound, "span generation has retired");
        if (end < slot.entry.start)
            return Error(Status.invalidArgument, "span completion precedes its start");
        slot.entry.finish = end;
        slot.entry.failed = failed;
        slot.phase = SlotPhase.ready;
        if (readyTail == 0)
            readyHead = id;
        else
            slots[readyTail].next = id;
        readyTail = id;
        ++readyCount;
        return Error.init;
    }

    uint pending() nothrow @nogc
    {
        gate.lock_nothrow();
        const result = readyCount;
        gate.unlock_nothrow();
        return result;
    }

    size_t snapshot(scope SpanRecord[] output) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        size_t used;
        for (auto id = readyHead; id != 0 && used < output.length; id = slots[id].next)
            output[used++] = slots[id].entry;
        return used;
    }

    void retire(size_t count, bool dropped) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        foreach (_; 0 .. count)
        {
            const current = readyHead;
            assert(current != 0);
            auto slot = &slots[current];
            readyHead = slot.next;
            slot.phase = SlotPhase.free;
            slot.next = available;
            available = current;
            --readyCount;
        }
        if (readyHead == 0)
            readyTail = 0;
        if (dropped)
            atomicOp!"+="(drops, cast(ulong) count);
    }

    ulong dropped() const nothrow @nogc
    {
        return atomicLoad(drops);
    }

    void close() nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        closed = true;
        ulong discarded;
        foreach (ref slot; slots[1 .. $])
        {
            if (slot.phase != SlotPhase.free)
                ++discarded;
            slot.phase = SlotPhase.free;
        }
        readyHead = 0;
        readyTail = 0;
        readyCount = 0;
        atomicOp!"+="(drops, discarded);
    }
}

package(flint.actuator) bool hasBytes(scope const(ubyte)[] input) pure nothrow @nogc
{
    foreach (value; input)
        if (value != 0)
            return true;
    return false;
}

private Error makeContext(TraceContext parent, out TraceContext output) nothrow @nogc
{
    output.traceId = parent.traceId;
    if (!hasBytes(output.traceId[]))
    {
        // A root span draws both identifiers with one request to the operating system.
        ubyte[24] identities;
        auto result = fillSecureRandom(identities[]);
        if (result.code != Status.ok)
            return result;
        output.traceId = identities[0 .. 16];
        output.spanId = identities[16 .. 24];
        if (!hasBytes(output.traceId[]))
            return Error(Status.unavailable, "trace entropy unavailable");
        output.flags = 1;
    }
    else
    {
        output.flags = parent.flags;
        auto result = fillSecureRandom(output.spanId[]);
        if (result.code != Status.ok)
            return result;
    }
    return hasBytes(output.spanId[]) ? Error.init : Error(Status.unavailable, "span entropy unavailable");
}
