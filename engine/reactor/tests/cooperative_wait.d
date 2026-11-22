module flint.reactor.cooperative_wait_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.lifetime : move;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.conc.wait : waitUntil;
import flint.reactor : Backend, Reactor, ReactorOptions;

@safe:

private bool turned;

private void parker() nothrow @nogc
{
    turned = false;
    assert(waitUntil(Deadline.afterMillis(10)).code == Status.ok);
    assert(turned);
    auto owner = Reactor.current();
    owner.stop();
}

private void ticker() nothrow @nogc
{
    turned = true;
}

unittest
{
    ReactorOptions options;
    options.backend = Backend.epoll;
    options.cores = 1;
    options.fiberPoolSize = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &parker).code == Status.ok);
    assert(owner.value.post(0, &ticker).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
}

private enum napRounds = 20;
// Worker threads publish results to the test thread; module variables are otherwise thread-local.
private shared long napElapsed;
private shared uint relayRounds;
private shared long relayStarted;
private shared long relayElapsed;

private long monotonicNow() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

private void napper() nothrow @nogc
{
    auto owner = Reactor.current();
    const started = monotonicNow();
    foreach (_; 0 .. napRounds)
        assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
    atomicStore(napElapsed, monotonicNow() - started);
    owner.stop();
}

@("an idle owner loop resumes a sleeping fiber at its deadline rather than after its polling budget")
unittest
{
    foreach (backend; [Backend.automatic, Backend.epoll])
    {
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        options.fiberPoolSize = 1;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        assert(owner.value.post(0, &napper).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        // Each 1 ms nap previously lasted the full 5 ms loop wait budget (about 100 ms in total).
        assert(atomicLoad(napElapsed) > 0);
        assert(atomicLoad(napElapsed) < napRounds * 3_000_000, "fiber deadline overslept by the loop wait budget");
    }
}

private void relayTask() nothrow @nogc
{
    auto owner = Reactor.current();
    if (atomicOp!"+="(relayRounds, 1) == napRounds)
    {
        atomicStore(relayElapsed, monotonicNow() - atomicLoad(relayStarted));
        owner.stop();
        return;
    }
    assert(owner.schedule(Deadline.afterMillis(0), &relayTimer).ok);
}

private void relayTimer() nothrow @nogc
{
    assert(Reactor.current().post(0, &relayTask).code == Status.ok);
}

@("a task posted by a loop callback starts without waiting for unrelated I/O")
unittest
{
    foreach (backend; [Backend.automatic, Backend.epoll])
    {
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        options.fiberPoolSize = 1;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        atomicStore(relayRounds, 0);
        atomicStore(relayStarted, monotonicNow());
        assert(owner.value.post(0, &relayTask).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(atomicLoad(relayRounds) == napRounds);
        // Each timer-to-task hop previously waited the full 5 ms budget (about 100 ms in total).
        assert(atomicLoad(relayElapsed) < napRounds * 2_000_000,
                "owner loop slept while its mailbox held runnable work");
    }
}

private enum sleepers = 8;

private final class Sleepers
{
    import flint.conc : CancelSource, Context;

    CancelSource source;
    uint wokenMask;
    uint[sleepers] order;
    uint woken;
    uint cancelledWakes;

    void sleep() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        const task = owner.currentTask();
        assert(task.ok);
        const index = cast(uint) task.value.requestId;
        // Later slots wake first, so terminating fibers leave the suspended list out of slot order.
        const status = owner.yieldUntil(Deadline.afterMillis(3 * (sleepers - index)));
        if (status.code == Status.cancelled)
            ++cancelledWakes;
        else
            assert(status.code == Status.ok);
        order[woken++] = index;
        wokenMask |= 1U << index;
        if (index == 6)
            source.cancel();
        if (index == 0)
            owner.stop();
    }
}

@("suspended fibers leave and rejoin the wait list in any order without losing a wake")
unittest
{
    import flint.conc : CancelSource, Context;
    import flint.reactor : TaskContext;

    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = sleepers;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    auto fixture = new Sleepers;
    auto created = CancelSource.create(Context.init, Deadline.none());
    assert(created.ok());
    move(created.value, fixture.source);
    foreach (uint index; 0 .. sleepers)
    {
        // Odd sleepers below 7 are woken early when sleeper 6 cancels their shared source.
        auto context = TaskContext(index, index % 2 == 1 ? fixture.source.context() : Context.init);
        assert(owner.value.postStartup(0, &fixture.sleep, context).code == Status.ok);
    }
    assert(owner.value.run().code == Status.ok);
    assert(fixture.wokenMask == (1U << sleepers) - 1 && fixture.woken == sleepers);
    assert(fixture.cancelledWakes == 3);
    assert(fixture.order[0] == 7 && fixture.order[1] == 6 && fixture.order[5] == 4);
    assert(fixture.order[6] == 2 && fixture.order[7] == 0);
}
