module flint.reactor.internal.operations;

import flint.arena : Error, Result, Status;
import flint.reactor.types : Completion, ConnectionId;

@safe:

/// Slot indices fit below maxPendingIoPerCore (8192); the remaining token bits carry the generation.
package(flint.reactor) enum operationSlotBits = 13;
private enum slotMask = (1UL << operationSlotBits) - 1;
/// A slot retires only after 2^51 reservations, so one busy slot never exhausts the fixed table.
private enum maxGeneration = ulong.max >> operationSlotBits;

package(flint.reactor) struct OperationId
{
    uint slot = uint.max;
    ulong generation;

    ulong token() const pure nothrow @nogc
    {
        return (generation << operationSlotBits) | slot;
    }

    static OperationId fromToken(ulong token) pure nothrow @nogc
    {
        return OperationId(cast(uint)(token & slotMask), token >> operationSlotBits);
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
    ulong generation;
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
        assert(capacity <= 1U << operationSlotBits);
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
        // Public IoId tickets carry the low 32 bits, and a zero ticket generation means no operation.
        if (cast(uint) slot.generation == 0)
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
        if (slot.generation < maxGeneration - 1)
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

@("operation slots stay reusable after 2^32 reservations and never repeat a kernel token")
unittest
{
    // A worker owns only maxPendingIoPerCore slots and its free list reuses the most recent slot first,
    // so one hot slot passes 2^32 reservations after hours of sustained traffic.
    auto table = OperationTable(1);
    table.slots[0].generation = uint.max - 2;
    const connection = ConnectionId(0, 0, 1);
    OperationId previous;
    foreach (round; 0 .. 4)
    {
        const reserved = table.reserve(connection);
        assert(reserved.ok, "a busy operation slot retired permanently");
        const id = reserved.value;
        assert(id.token != previous.token && OperationId.fromToken(id.token) == id);
        assert(cast(uint) id.generation != 0, "the public ticket generation must stay nonzero");
        assert(table.start(previous) == Status.notFound);
        assert(table.start(id) == Status.ok);
        assert(table.finish(id, Status.ok, 0).ok);
        assert(table.retire(id) == Status.ok);
        previous = id;
    }
}
