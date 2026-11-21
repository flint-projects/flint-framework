/// A caller-owned scalar signal graph and deterministic FLNT text binding.
module flint.ui_signals;

import flint.arena : Error, Result, Status;
import flint.ui_signals.internal : decimal;
import flint.wasm_bridge : CommandBuffer, NodeHandle, textCommandBytes;

@safe:
nothrow:
@nogc:

/// A signal index and its generation within a graph.
struct SignalId
{
    /// Index in the caller's signal slab.
    uint index;
    /// Current lifetime of that slot.
    uint generation;
}

/// Zero-initialized storage reserved for one signal.
struct SignalSlot
{
    /// Committed scalar value.
    int value;
    /// Current lifetime of this slot.
    uint generation;
    /// First attached observer, encoded as its index plus one.
    uint firstObserver;
    /// Whether this slot is allocated.
    bool live;
    private uint nextFree;
    private uint queued;
    private uint producer;
    private uint dependants;
}

/// Evaluate a scalar from up to 64 borrowed input values.
alias Compute = int function(scope const(int)[]) @safe nothrow @nogc;

/// Zero-initialized storage reserved for one computed signal.
struct ComputedSlot
{
    /// Output signal.
    SignalId output;
    /// First edge in the caller's edge slab.
    uint firstInput;
    /// Number of consecutive input edges.
    uint inputCount;
    /// Function that computes the next value.
    Compute compute;
    /// Whether this slot is allocated.
    bool live;
    private uint previous;
    private uint next;
    private int proposed;
    private bool changed;
}

/// Zero-initialized storage reserved for one text binding.
struct ObserverSlot
{
    /// Source signal of this binding.
    SignalId source;
    /// Host-registered destination.
    NodeHandle destination;
    /// Next observer of this signal, encoded as its index plus one.
    uint next;
    /// Whether this slot is allocated.
    bool live;
    private uint previousInOrder;
    private uint nextInOrder;
    private bool initial;
}

private Error invalid() pure
{
    return Error(Status.invalidArgument, "invalid signal storage or operation");
}

private Error full() pure
{
    return Error(Status.resourceExhausted, "signal graph capacity reached");
}

private Error stale() pure
{
    return Error(Status.notFound, "stale signal ID");
}

private Error busy() pure
{
    return Error(Status.conflict, "signal graph is flushing");
}

private bool bounded(size_t capacity) pure
{
    return capacity <= uint.max - 1;
}

/// Single-owner signal graph borrowing supplied slabs throughout its lifetime.
struct SignalGraph
{
@safe:
nothrow:
@nogc:

    private SignalSlot[] signals;
    private ObserverSlot[] observers;
    private uint[] queue;
    private ComputedSlot[] computations;
    private SignalId[] edges;

    private uint freeSignal;
    private uint freeObserver;
    private uint freeComputed;
    private uint firstComputed;
    private uint lastComputed;
    private uint firstObserver;
    private uint lastObserver;
    private uint initialObservers;
    private uint dirtyCount;
    private uint edgeCount;
    private bool flushing;

    @disable this(this);
    @disable void opAssign(SignalGraph graph);

    /// Retain storage for signals, observers and an optional computed DAG.
    static Result!SignalGraph fromStorage(return scope SignalSlot[] signals, return scope ObserverSlot[] observers,
            return scope uint[] dirtyQueue, return scope ComputedSlot[] computedStorage = null,
            return scope SignalId[] edgeStorage = null)
    {
        if (signals.length == 0 || dirtyQueue.length == 0 || !bounded(signals.length)
                || !bounded(observers.length) || !bounded(computedStorage.length) || !bounded(edgeStorage.length)
                || dirtyQueue.length > signals.length || ((computedStorage.length == 0) != (edgeStorage.length == 0)))
            return Result!SignalGraph(SignalGraph.init, invalid());
        if (!pristine(signals, observers, dirtyQueue, computedStorage, edgeStorage))
            return Result!SignalGraph(SignalGraph.init, invalid());
        return Result!SignalGraph(SignalGraph(signals, observers, dirtyQueue, computedStorage, edgeStorage));
    }

    private this(return scope SignalSlot[] signals, return scope ObserverSlot[] observers,
            return scope uint[] queue, return scope ComputedSlot[] computations, return scope SignalId[] edges)
    {
        this.signals = signals;
        this.observers = observers;
        this.queue = queue;
        this.computations = computations;
        this.edges = edges;
        for (uint link = 1; link < signals.length; ++link)
            signals[link - 1].nextFree = link + 1;
        for (uint link = 1; link < observers.length; ++link)
            observers[link - 1].next = link + 1;
        for (uint link = 1; link < computations.length; ++link)
            computations[link - 1].next = link + 1;
        freeSignal = 1;
        freeObserver = observers.length != 0 ? 1 : 0;
        freeComputed = computations.length != 0 ? 1 : 0;
    }

    /// A graph cannot move from inside a computation invoking it.
    void opPostMove(scope const ref SignalGraph original) scope
    {
        assert(!original.flushing, "cannot move a flushing signal graph");
    }

    /// Allocate a base signal.
    Result!SignalId create(int initial) scope
    {
        if (flushing)
            return Result!SignalId(SignalId.init, busy());
        if (freeSignal == 0)
            return Result!SignalId(SignalId.init, full());
        return Result!SignalId(allocateSignal(initial));
    }

    private SignalId allocateSignal(int initial) scope
    {
        const index = freeSignal - 1;
        auto slot = &signals[index];
        freeSignal = slot.nextFree;
        slot.nextFree = 0;
        if (slot.generation == 0)
            slot.generation = 1;
        slot.live = true;
        slot.value = initial;
        return SignalId(index, slot.generation);
    }

    /// Create a signal whose inputs already exist.
    Result!SignalId computed(scope const SignalId[] inputs, Compute compute) scope
    {
        if (flushing)
            return Result!SignalId(SignalId.init, busy());
        if (compute is null || inputs.length == 0 || inputs.length > 64)
            return Result!SignalId(SignalId.init, invalid());
        if (freeSignal == 0 || freeComputed == 0 || inputs.length > edges.length - edgeCount)
            return Result!SignalId(SignalId.init, full());
        int[64] values;
        foreach (pos, input; inputs)
        {
            if (!has(input))
                return Result!SignalId(SignalId.init, stale());
            values[pos] = signals[input.index].value;
        }
        const initial = evaluate(compute, values[0 .. inputs.length]);
        const output = allocateSignal(initial);
        const link = freeComputed;
        auto slot = &computations[link - 1];
        freeComputed = slot.next;
        *slot = ComputedSlot(output, edgeCount, cast(uint) inputs.length, compute, true, lastComputed);
        if (lastComputed == 0)
            firstComputed = link;
        else
            computations[lastComputed - 1].next = link;
        lastComputed = link;
        signals[output.index].producer = link;
        foreach (input; inputs)
        {
            edges[edgeCount++] = input;
            ++signals[input.index].dependants;
        }
        return Result!SignalId(output);
    }

    private int evaluate(Compute compute, scope const(int)[] arguments) scope
    {
        flushing = true;
        scope (exit)
            flushing = false;
        return compute(arguments);
    }

    /// Read the most recently committed value.
    Result!int read(SignalId id) scope const
    {
        return has(id) ? Result!int(signals[id.index].value) : Result!int(0, stale());
    }

    /// Set a base signal and mark it dirty once for the next flush.
    Error set(SignalId id, int value) scope
    {
        if (flushing)
            return busy();
        if (!has(id))
            return stale();
        auto slot = &signals[id.index];
        if (slot.producer != 0)
            return invalid();
        if (slot.value == value)
            return Error.init;
        if (slot.queued == 0)
        {
            if (dirtyCount == queue.length)
                return full();
            queue[dirtyCount++] = id.index;
            slot.queued = dirtyCount;
        }
        slot.value = value;
        return Error.init;
    }

    /// Bind a unique destination to the base or computed signal.
    Error bindText(SignalId id, NodeHandle node) scope
    {
        if (flushing)
            return busy();
        if (!has(id))
            return stale();
        if (node.index > 65_535 || node.generation == 0 || (node.index == 0 && node.generation != 1))
            return invalid();
        for (auto link = firstObserver; link != 0; link = observers[link - 1].nextInOrder)
            if (observers[link - 1].destination.index == node.index)
                return Error(Status.conflict, "node already has a text binding");
        if (freeObserver == 0)
            return full();
        const link = freeObserver;
        auto observer = &observers[link - 1];
        freeObserver = observer.next;
        auto source = &signals[id.index];
        *observer = ObserverSlot(id, node, source.firstObserver, true, lastObserver, 0, true);
        source.firstObserver = link;
        if (lastObserver == 0)
            firstObserver = link;
        else
            observers[lastObserver - 1].nextInOrder = link;
        lastObserver = link;
        ++initialObservers;
        return Error.init;
    }

    /// Remove bindings and retire the signal unless another computation still needs it.
    Error dispose(SignalId id) scope
    {
        if (flushing)
            return busy();
        if (!has(id))
            return stale();
        auto slot = &signals[id.index];
        if (slot.dependants != 0)
            return Error(Status.conflict, "computed signal still needs this input");
        while (slot.firstObserver != 0)
        {
            const link = slot.firstObserver;
            slot.firstObserver = observers[link - 1].next;
            unlinkObserver(link);
        }
        if (slot.producer != 0)
            unlinkComputed(slot.producer);
        if (slot.queued != 0)
        {
            const position = slot.queued - 1;
            const tail = queue[--dirtyCount];
            if (position != dirtyCount)
            {
                queue[position] = tail;
                signals[tail].queued = position + 1;
            }
            queue[dirtyCount] = 0;
        }
        const generation = slot.generation;
        *slot = SignalSlot.init;
        slot.generation = generation;
        if (generation != uint.max)
        {
            ++slot.generation;
            slot.nextFree = freeSignal;
            freeSignal = id.index + 1;
        }
        return Error.init;
    }

    private void unlinkObserver(uint link) scope
    {
        auto slot = &observers[link - 1];
        if (slot.initial)
            --initialObservers;
        if (slot.previousInOrder == 0)
            firstObserver = slot.nextInOrder;
        else
            observers[slot.previousInOrder - 1].nextInOrder = slot.nextInOrder;
        if (slot.nextInOrder == 0)
            lastObserver = slot.previousInOrder;
        else
            observers[slot.nextInOrder - 1].previousInOrder = slot.previousInOrder;
        *slot = ObserverSlot.init;
        slot.next = freeObserver;
        freeObserver = link;
    }

    private void unlinkComputed(uint link) scope
    {
        auto slot = &computations[link - 1];
        const begin = slot.firstInput;
        const end = begin + slot.inputCount;
        foreach (dependency; edges[begin .. end])
            --signals[dependency.index].dependants;
        foreach (destination; begin .. edgeCount - slot.inputCount)
            edges[destination] = edges[destination + slot.inputCount];
        edgeCount -= slot.inputCount;
        edges[edgeCount .. edgeCount + slot.inputCount] = SignalId.init;
        if (slot.previous == 0)
            firstComputed = slot.next;
        else
            computations[slot.previous - 1].next = slot.next;
        if (slot.next == 0)
            lastComputed = slot.previous;
        else
            computations[slot.next - 1].previous = slot.previous;
        foreach (ref remaining; computations)
            if (remaining.live && remaining.firstInput > begin)
                remaining.firstInput -= slot.inputCount;
        *slot = ComputedSlot.init;
        slot.next = freeComputed;
        freeComputed = link;
    }

    private bool has(SignalId id) scope const
    {
        return id.index < signals.length && signals[id.index].live && signals[id.index].generation == id.generation;
    }

    private bool changed(uint index) scope const
    {
        const slot = &signals[index];
        return slot.producer != 0 ? computations[slot.producer - 1].changed : slot.queued != 0;
    }

    private int prospective(uint index) scope const
    {
        const slot = &signals[index];
        return slot.producer != 0 ? computations[slot.producer - 1].proposed : slot.value;
    }

    private void propagate() scope
    {
        int[64] values;
        for (auto link = firstComputed; link != 0; link = computations[link - 1].next)
        {
            auto slot = &computations[link - 1];
            bool affected;
            foreach (pos, input; edges[slot.firstInput .. slot.firstInput + slot.inputCount])
            {
                values[pos] = prospective(input.index);
                affected = affected || changed(input.index);
            }
            const previous = signals[slot.output.index].value;
            slot.proposed = affected ? slot.compute(values[0 .. slot.inputCount]) : previous;
            slot.changed = slot.proposed != previous;
        }
    }

    /// Preflight a complete text patch batch, then publish values and retire dirty entries.
    Error flush(ref scope CommandBuffer output) scope
    {
        if (flushing)
            return busy();
        if (dirtyCount == 0 && initialObservers == 0)
            return output.checkRoom(0);
        flushing = true;
        scope (exit)
            flushing = false;
        propagate();
        const ready = plan(output);
        if (ready.code != Status.ok)
            return ready;
        foreach (ref slot; computations)
            if (slot.live)
                signals[slot.output.index].value = slot.proposed;
        ubyte[11] bytes;
        for (auto link = firstObserver; link != 0; link = observers[link - 1].nextInOrder)
        {
            auto slot = &observers[link - 1];
            const source = slot.source.index;
            if (slot.initial || changed(source))
            {
                const start = decimal(signals[source].value, bytes);
                const recorded = output.setText(slot.destination, bytes[start .. $]);
                assert(recorded.code == Status.ok);
                slot.initial = false;
            }
        }
        foreach (index; queue[0 .. dirtyCount])
            signals[index].queued = 0;
        initialObservers = 0;
        queue[0 .. dirtyCount] = 0;
        dirtyCount = 0;
        return Error.init;
    }

    private Error plan(ref scope const CommandBuffer output) scope const
    {
        size_t bytes;
        const room = output.capacityBytes - output.usedBytes;
        ubyte[11] text;
        for (uint link = firstObserver; link != 0; link = observers[link - 1].nextInOrder)
        {
            const slot = &observers[link - 1];
            if (!slot.initial && !changed(slot.source.index))
                continue;
            const start = decimal(prospective(slot.source.index), text);
            const next = textCommandBytes(text.length - start);
            if (next > room - bytes)
                return full();
            bytes += next;
        }
        return output.checkRoom(bytes);
    }
}

private bool pristine(scope const(SignalSlot)[] signals, scope const(ObserverSlot)[] observers,
        scope const(uint)[] queue, scope const(ComputedSlot)[] computations, scope const(SignalId)[] edges)
{
    foreach (ref slot; signals)
        if (!pristineSlot(slot))
            return false;
    foreach (ref slot; observers)
        if (!pristineSlot(slot))
            return false;
    foreach (entry; queue)
        if (entry != 0)
            return false;
    foreach (ref slot; computations)
        if (!pristineSlot(slot))
            return false;
    foreach (entry; edges)
        if (entry.index != 0 || entry.generation != 0)
            return false;
    return true;
}

// Compare fields so freestanding builds do not require a C struct comparison.
private bool pristineSlot(scope const ref SignalSlot slot)
{
    return slot.value == 0 && slot.generation == 0 && slot.firstObserver == 0 && !slot.live
        && slot.nextFree == 0 && slot.queued == 0 && slot.producer == 0 && slot.dependants == 0;
}

private bool pristineSlot(scope const ref ObserverSlot slot)
{
    return slot.source.index == 0 && slot.source.generation == 0 && slot.destination.index == 0
        && slot.destination.generation == 0 && slot.next == 0 && !slot.live
        && slot.previousInOrder == 0 && slot.nextInOrder == 0 && !slot.initial;
}

private bool pristineSlot(scope const ref ComputedSlot slot)
{
    return slot.output.index == 0 && slot.output.generation == 0 && slot.firstInput == 0
        && slot.inputCount == 0 && slot.compute is null && !slot.live && slot.previous == 0
        && slot.next == 0 && slot.proposed == 0 && !slot.changed;
}
