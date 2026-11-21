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
