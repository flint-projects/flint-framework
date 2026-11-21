module flint.reactor.internal.operations;

import flint.arena : Error, Result, Status;
import flint.reactor.types : Completion, ConnectionId;

@safe:

package(flint.reactor) struct OperationId
{
    uint slot = uint.max;
    uint generation;

    ulong token() const pure nothrow @nogc
    {
        return (cast(ulong) generation << 32) | slot;
    }

    static OperationId fromToken(ulong token) pure nothrow @nogc
    {
        return OperationId(cast(uint) token, cast(uint)(token >> 32));
    }
}

private enum Phase : ubyte
{
    free,
    queued,
    inFlight,
    ready
}

private struct Operation
{
    ConnectionId connection;
    uint generation;
    uint next;
    Phase phase;
    Status cancellation;
}

/// Owner-thread only. The OS token remains valid through callback delivery.
package(flint.reactor) struct OperationTable
{
    private Operation[] slots;
    private uint nextFree = uint.max;

    @disable this(this);

    this(uint capacity)
    {
        slots = new Operation[capacity];
        if (capacity == 0)
            return;
        nextFree = 0;
        foreach (index, ref slot; slots)
            slot.next = cast(uint)(index + 1);
        slots[$ - 1].next = uint.max;
    }

    Result!OperationId reserve(ConnectionId connection) nothrow @nogc
    {
        if (connection.generation == 0)
            return Result!OperationId(OperationId.init, Error(Status.invalidArgument, "invalid connection"));
        if (nextFree == uint.max)
            return Result!OperationId(OperationId.init, Error(Status.resourceExhausted, "operation table full"));

        const index = nextFree;
        auto slot = &slots[index];
        nextFree = slot.next;
        ++slot.generation;
        slot.connection = connection;
        slot.phase = Phase.queued;
        slot.cancellation = Status.ok;
        return Result!OperationId(OperationId(index, slot.generation));
    }

    Status start(OperationId id) nothrow @nogc
    {
        if (!contains(id))
            return Status.notFound;
        auto slot = &slots[id.slot];
        if (slot.phase != Phase.queued)
            return Status.conflict;
        if (slot.cancellation != Status.ok)
            return slot.cancellation;
        slot.phase = Phase.inFlight;
        return Status.ok;
    }

    Status requestCancellation(OperationId id, Status reason) nothrow @nogc
    {
        if (reason != Status.cancelled && reason != Status.timedOut)
            return Status.invalidArgument;
        if (!contains(id))
            return Status.notFound;
        auto slot = &slots[id.slot];
        if (slot.phase == Phase.ready)
            return Status.conflict;
        if (slot.cancellation == Status.ok)
            slot.cancellation = reason;
        return Status.ok;
    }

    Result!Completion finish(OperationId id, Status status, size_t bytes) nothrow @nogc
    {
        if (!contains(id))
            return Result!Completion(Completion.init, Error(Status.notFound, "invalid operation"));
        auto slot = &slots[id.slot];
        if (slot.phase != Phase.inFlight && !(slot.phase == Phase.queued && slot.cancellation != Status.ok))
            return Result!Completion(Completion.init, Error(Status.conflict, "unexpected final completion"));
        slot.phase = Phase.ready;
        if (slot.cancellation != Status.ok)
            status = slot.cancellation;
        return Result!Completion(Completion(slot.connection, status, bytes));
    }

    Status retire(OperationId id) nothrow @nogc
    {
        if (!contains(id))
            return Status.notFound;
        auto slot = &slots[id.slot];
        if (slot.phase != Phase.ready)
            return Status.conflict;
        slot.phase = Phase.free;
        if (slot.generation != uint.max)
        {
            slot.next = nextFree;
            nextFree = id.slot;
        }
        return Status.ok;
    }

    private bool contains(OperationId id) const nothrow @nogc
    {
        return id.slot < slots.length && slots[id.slot].phase != Phase.free && slots[id.slot].generation
            == id.generation;
    }
}
