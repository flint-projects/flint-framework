module flint.ui_signals.contract_tests;

import flint.arena : Status;
import flint.ui_signals : ComputedSlot, ObserverSlot, SignalGraph, SignalId, SignalSlot;
import flint.wasm_bridge : CommandBuffer, NodeHandle;

@safe:

private uint word(scope const(ubyte)[] bytes, uint index) nothrow @nogc
{
    uint value;
    foreach_reverse (digit; bytes[index .. index + 4])
        value = (value << 8) | digit;
    return value;
}

private alias Frame = CommandBuffer;

private void verifyText(ref scope const Frame frame, uint count, uint first, scope const(char)[] text) nothrow @nogc
{
    assert(frame.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(word(bytes, 12) == count);
            if (count != 0)
            {
                assert(word(bytes, 40) == first);
                const length = word(bytes, 48);
                assert(bytes[52 .. 52 + length] == cast(const(ubyte)[]) text);
            }
        }).code == Status.ok);
}

@("equal values emit no command and repeated changes publish the final value in registration order")
unittest
{
    SignalSlot[4] signals;
    ObserverSlot[4] observers;
    uint[4] queue;
    ubyte[128] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok && frame.ok);
    const first = graph.value.create(1).value;
    const second = graph.value.create(2).value;
    assert(graph.value.bindText(second, NodeHandle(2, 1)).code == Status.ok);
    assert(graph.value.bindText(first, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.bindText(first, NodeHandle(2, 1)).code == Status.conflict);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 2, 2, "2");
    frame.value.clear();
    foreach (_; 0 .. 1000)
        assert(graph.value.set(first, 1).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 0, 0, "");

    assert(graph.value.set(first, 8).code == Status.ok);
    assert(graph.value.set(first, -5).code == Status.ok);
    assert(graph.value.set(first, int.min).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "-2147483648");
    frame.value.clear();
    assert(graph.value.set(first, int.max).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "2147483647");

    assert(graph.value.dispose(first).code == Status.ok);
    const replacement = graph.value.create(0).value;
    assert(replacement.index == first.index && replacement.generation != first.generation);
    assert(graph.value.read(first).error.code == Status.notFound);
    assert(graph.value.bindText(replacement, NodeHandle(1, 2)).code == Status.ok);
    frame.value.clear();
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "0");
}

@("failed queue admission and failed frame preflight preserve state for retry")
unittest
{
    SignalSlot[2] signals;
    ObserverSlot[2] observers;
    uint[1] queue;
    ubyte[56] tiny;
    ubyte[96] enough;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    auto small = CommandBuffer.fromStorage(tiny[]);
    auto frame = CommandBuffer.fromStorage(enough[]);
    assert(graph.ok && small.ok && frame.ok);
    const a = graph.value.create(0).value;
    const b = graph.value.create(0).value;
    assert(graph.value.bindText(a, NodeHandle(0, 1)).code == Status.ok);
    assert(graph.value.bindText(b, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.set(a, 7).code == Status.ok);
    assert(graph.value.set(b, 8).code == Status.resourceExhausted);
    assert(graph.value.read(b).value == 0);
    const before = tiny;
    assert(graph.value.flush(small.value).code == Status.resourceExhausted);
    assert(tiny == before && graph.value.read(a).value == 7);
    assert(graph.value.set(b, 8).code == Status.resourceExhausted);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 2, 0, "7");
    assert(graph.value.set(b, 8).code == Status.ok);
    frame.value.clear();
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "8");
}

private uint firstCalls;
private uint secondCalls;

private int grouped(scope const(int)[] arguments) nothrow @nogc
{
    ++firstCalls;
    return arguments[0] / 10;
}

private int doubled(scope const(int)[] arguments) nothrow @nogc
{
    ++secondCalls;
    return arguments[0] * 2;
}

@("computed generations are evaluated once in topological order and unchanged values stop propagation")
unittest
{
    firstCalls = 0;
    secondCalls = 0;
    SignalSlot[4] signals;
    ObserverSlot[2] observers;
    uint[4] queue;
    ComputedSlot[2] computed;
    SignalId[2] edges;
    ubyte[80] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[], computed[], edges[]);
    assert(graph.ok);
    auto frame = CommandBuffer.fromStorage(storage[]);
    const root = graph.value.create(10).value;
    const group = graph.value.computed([root], &grouped);
    const result = graph.value.computed([group.value], &doubled);
    assert(group.ok && result.ok);
    assert(graph.value.read(result.value).value == 2 && firstCalls == 1 && secondCalls == 1);
    assert(graph.value.bindText(result.value, NodeHandle(0, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 0, "2");
    assert(graph.value.set(result.value, 4).code == Status.invalidArgument);
    assert(graph.value.dispose(root).code == Status.conflict);
    assert(graph.value.set(root, 11).code == Status.ok);
    frame.value.clear();
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 0, 0, "");
    assert(firstCalls == 2 && secondCalls == 1);
    assert(graph.value.set(root, 24).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 0, "4");
    assert(firstCalls == 3 && secondCalls == 2);
    assert(graph.value.dispose(result.value).code == Status.ok);
    assert(graph.value.dispose(group.value).code == Status.ok);
    assert(graph.value.dispose(root).code == Status.ok);
}

@("specification usage fixture: create, set and read one signal")
unittest
{
    SignalSlot[8] signals;
    ObserverSlot[8] observers;
    uint[8] queue;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    assert(graph.ok());
    auto id = graph.value.create(7);
    assert(id.ok());
    assert(graph.value.set(id.value, 8).code == Status.ok);
    assert(graph.value.read(id.value).value == 8);
}

@("SIGNAL-01 equal-value sets never occupy the dirty queue")
unittest
{
    SignalSlot[2] signals;
    ObserverSlot[2] observers;
    uint[1] queue;
    ubyte[128] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok && frame.ok);
    const a = graph.value.create(4).value;
    const b = graph.value.create(0).value;
    assert(graph.value.bindText(a, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "4");
    frame.value.clear();
    foreach (_; 0 .. 1000)
        assert(graph.value.set(a, 4).code == Status.ok);
    assert(queue[0] == 0);
    // The single queue entry is still free for a real change.
    assert(graph.value.set(b, 1).code == Status.ok);
    assert(graph.value.set(a, 5).code == Status.resourceExhausted && graph.value.read(a).value == 4);
    assert(graph.value.flush(frame.value).code == Status.ok);
    assert(frame.value.usedBytes == 32);
}

@("SIGNAL-02 one source updates several bindings once each with the final value")
unittest
{
    SignalSlot[2] signals;
    ObserverSlot[4] observers;
    uint[2] queue;
    ubyte[256] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok && frame.ok);
    const source = graph.value.create(0).value;
    foreach (node; [3U, 1U, 2U])
        assert(graph.value.bindText(source, NodeHandle(node, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    frame.value.clear();
    foreach (value; [10, 20, 30])
        assert(graph.value.set(source, value).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    assert(frame.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(word(bytes, 12) == 3);
            foreach (position, node; [3U, 1U, 2U])
            {
                const start = cast(uint)(32 + position * 24);
                assert(word(bytes, start + 8) == node && word(bytes, start + 16) == 2);
                assert(bytes[start + 20 .. start + 22] == cast(const(ubyte)[]) "30");
            }
        }).code == Status.ok);
}

@("SIGNAL-03 stale handles, double disposal and generation exhaustion retire the slot")
unittest
{
    SignalSlot[1] signals;
    ObserverSlot[1] observers;
    uint[1] queue;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    assert(graph.ok);
    const first = graph.value.create(1).value;
    assert(first.index == 0 && first.generation == 1);
    assert(graph.value.create(2).error.code == Status.resourceExhausted);
    assert(graph.value.dispose(first).code == Status.ok);
    foreach (stale; [first, SignalId(1, 1), SignalId(0, 0), SignalId(uint.max, 1)])
    {
        assert(graph.value.read(stale).error.code == Status.notFound);
        assert(graph.value.set(stale, 3).code == Status.notFound);
        assert(graph.value.bindText(stale, NodeHandle(1, 1)).code == Status.notFound);
        assert(graph.value.dispose(stale).code == Status.notFound);
    }
    // The caller owns the slab; jump the free slot to its last generation instead of 2^32 cycles.
    assert(!signals[0].live && signals[0].generation == 2);
    signals[0].generation = uint.max;
    const last = graph.value.create(5).value;
    assert(last.generation == uint.max && graph.value.read(last).value == 5);
    assert(graph.value.bindText(last, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.dispose(last).code == Status.ok);
    assert(graph.value.read(last).error.code == Status.notFound);
    assert(graph.value.create(6).error.code == Status.resourceExhausted);
    // Retiring the signal still released its binding for reuse.
    assert(observers[0].live == false);
}

private int addOne(scope const(int)[] arguments) nothrow @nogc
{
    return arguments[0] + 1;
}

@("SIGNAL-04 a short or borrowed frame leaves computed values, dirty set and bytes intact")
unittest
{
    SignalSlot[2] signals;
    ObserverSlot[2] observers;
    uint[2] queue;
    ComputedSlot[1] computed;
    SignalId[1] edges;
    ubyte[56] small;
    ubyte[128] enough;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[], computed[], edges[]);
    auto tiny = CommandBuffer.fromStorage(small[]);
    auto frame = CommandBuffer.fromStorage(enough[]);
    assert(graph.ok && tiny.ok && frame.ok);
    const root = graph.value.create(9).value;
    const next = graph.value.computed([root], &addOne).value;
    assert(graph.value.bindText(next, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "10");
    frame.value.clear();

    // "100000" needs a 32-byte record but only 24 bytes remain.
    assert(graph.value.set(root, 99_999).code == Status.ok);
    const empty = small;
    assert(graph.value.flush(tiny.value).code == Status.resourceExhausted);
    assert(small == empty && graph.value.read(next).value == 10 && graph.value.read(root).value == 99_999);
    assert(frame.value.visit((scope const(ubyte)[]) @safe nothrow @nogc {
            assert(graph.value.flush(frame.value).code == Status.conflict);
        }).code == Status.ok);
    assert(frame.value.usedBytes == 32 && graph.value.read(next).value == 10);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "100000");
    assert(graph.value.read(next).value == 100_000);
}

private immutable int[] decimalValues = [
    0, 1, -1, 9, -9, 10, -10, 99, -100, 1_000_000_000, -1_000_000_000, int.max, int.min, int.min + 1,
    int.max - 1
];
private immutable string[] decimalTexts = [
    "0", "1", "-1", "9", "-9", "10", "-10", "99", "-100", "1000000000", "-1000000000",
    "2147483647", "-2147483648", "-2147483647", "2147483646"
];

@("SIGNAL-05 decimal text for zero, signs and both extremes without GC allocation")
nothrow @nogc unittest
{
    SignalSlot[2] signals;
    ObserverSlot[2] observers;
    uint[2] queue;
    ubyte[128] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok && frame.ok);
    const id = graph.value.create(int.min).value;
    assert(graph.value.bindText(id, NodeHandle(4, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 4, "-2147483648");
    foreach (index, value; decimalValues)
    {
        frame.value.clear();
        assert(graph.value.set(id, value == int.min ? int.max : value).code == Status.ok);
        assert(graph.value.set(id, value).code == Status.ok);
        assert(graph.value.flush(frame.value).code == Status.ok);
        verifyText(frame.value, 1, 4, decimalTexts[index]);
    }
}

@("SIGNAL-06 one destination per node: conflicts, invalid handles and rebinding after disposal")
unittest
{
    SignalSlot[3] signals;
    ObserverSlot[3] observers;
    uint[3] queue;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
    assert(graph.ok);
    const a = graph.value.create(1).value;
    const b = graph.value.create(2).value;
    assert(graph.value.bindText(a, NodeHandle(5, 1)).code == Status.ok);
    assert(graph.value.bindText(b, NodeHandle(5, 1)).code == Status.conflict);
    assert(graph.value.bindText(a, NodeHandle(5, 1)).code == Status.conflict);
    assert(graph.value.bindText(b, NodeHandle(5, 7)).code == Status.conflict);
    foreach (node; [NodeHandle(65_536, 1), NodeHandle(6, 0), NodeHandle(0, 2)])
        assert(graph.value.bindText(b, node).code == Status.invalidArgument);
    assert(graph.value.bindText(b, NodeHandle(65_535, 1)).code == Status.ok);
    assert(graph.value.dispose(a).code == Status.ok);
    assert(graph.value.bindText(b, NodeHandle(5, 1)).code == Status.ok);
}

@("storage contract: invalid capacity combinations and reused slabs are rejected")
unittest
{
    SignalSlot[2] signals;
    ObserverSlot[2] observers;
    uint[2] queue;
    uint[3] longQueue;
    ComputedSlot[1] computed;
    SignalId[1] edges;
    assert(SignalGraph.fromStorage(null, observers[], queue[]).error.code == Status.invalidArgument);
    assert(SignalGraph.fromStorage(signals[], observers[], null).error.code == Status.invalidArgument);
    assert(SignalGraph.fromStorage(signals[], observers[], longQueue[]).error.code == Status.invalidArgument);
    assert(SignalGraph.fromStorage(signals[], observers[], queue[], computed[]).error.code == Status.invalidArgument);
    const edgesOnly = SignalGraph.fromStorage(signals[], observers[], queue[], null, edges[]);
    assert(edgesOnly.error.code == Status.invalidArgument);
    {
        SignalSlot[1] fresh;
        uint[1] freshQueue;
        assert(SignalGraph.fromStorage(fresh[], null, freshQueue[]).ok);
    }
    {
        auto graph = SignalGraph.fromStorage(signals[], observers[], queue[]);
        assert(graph.ok && graph.value.create(1).ok);
        assert(graph.value.bindText(SignalId(0, 1), NodeHandle(1, 1)).code == Status.ok);
    }
    assert(SignalGraph.fromStorage(signals[], null, queue[]).error.code == Status.invalidArgument);
    signals[] = SignalSlot.init;
    assert(SignalGraph.fromStorage(signals[1 .. 2], observers[], queue[0 .. 1]).error.code == Status.invalidArgument);
    observers[] = ObserverSlot.init;
    queue[0] = 1;
    assert(SignalGraph.fromStorage(signals[], null, queue[]).error.code == Status.invalidArgument);
}

private int total(scope const(int)[] arguments) nothrow @nogc
{
    int sum;
    foreach (value; arguments)
        sum += value;
    return sum;
}

private uint diamondCalls;

private int countedSum(scope const(int)[] arguments) nothrow @nogc
{
    ++diamondCalls;
    return arguments[0] + arguments[1];
}

@("computed contract: input bounds, storage exhaustion, stale inputs and once-per-flush diamond evaluation")
unittest
{
    SignalSlot[70] signals;
    ObserverSlot[4] observers;
    uint[70] queue;
    ComputedSlot[4] computed;
    SignalId[70] edges;
    ubyte[256] storage;
    auto graph = SignalGraph.fromStorage(signals[], observers[], queue[], computed[], edges[]);
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(graph.ok && frame.ok);
    SignalId[65] inputs;
    foreach (index, ref input; inputs)
        input = graph.value.create(cast(int) index).value;
    assert(graph.value.computed(inputs[], &total).error.code == Status.invalidArgument);
    assert(graph.value.computed(null, &total).error.code == Status.invalidArgument);
    assert(graph.value.computed(inputs[0 .. 1], null).error.code == Status.invalidArgument);
    const wide = graph.value.computed(inputs[0 .. 64], &total);
    assert(wide.ok && graph.value.read(wide.value).value == 63 * 64 / 2);
    assert(graph.value.computed(inputs[0 .. 7], &total).error.code == Status.resourceExhausted);
    assert(graph.value.dispose(wide.value).code == Status.ok);
    assert(graph.value.dispose(inputs[64]).code == Status.ok);
    assert(graph.value.computed([inputs[64]], &total).error.code == Status.notFound);

    diamondCalls = 0;
    const left = graph.value.computed([inputs[1]], &addOne).value;
    const right = graph.value.computed([inputs[1]], &addOne).value;
    const joined = graph.value.computed([left, right], &countedSum).value;
    assert(graph.value.read(joined).value == 4 && diamondCalls == 1);
    assert(graph.value.bindText(joined, NodeHandle(1, 1)).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    frame.value.clear();
    assert(graph.value.set(inputs[1], 10).code == Status.ok);
    assert(graph.value.flush(frame.value).code == Status.ok);
    verifyText(frame.value, 1, 1, "22");
    assert(diamondCalls == 2);
    assert(graph.value.dispose(left).code == Status.conflict);
    assert(graph.value.dispose(joined).code == Status.ok);
    assert(graph.value.dispose(left).code == Status.ok);
    assert(graph.value.dispose(right).code == Status.ok);

    SignalSlot[2] plainSignals;
    uint[1] plainQueue;
    auto plain = SignalGraph.fromStorage(plainSignals[], null, plainQueue[]);
    const base = plain.value.create(1).value;
    assert(plain.value.computed([base], &addOne).error.code == Status.resourceExhausted);
}
