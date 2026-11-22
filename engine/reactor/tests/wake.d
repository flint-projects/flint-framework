module flint.reactor.wake_test;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.reactor : Backend, Reactor, ReactorOptions, TaskContext, TaskWaker;

@safe:

private enum wakeRounds = 200;
private enum farMillis = 10_000;
// Worker threads publish results to the test thread; module variables are otherwise thread-local.
private shared long callbackElapsed;
private shared uint callbackRounds;
private TaskWaker pendingWaker;

private long monotonicNow() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

private void wakeFromTimer() nothrow @nogc
{
    auto owner = Reactor.current();
    // A loop callback has no active fiber of its own.
    assert(owner.currentWaker().error.code == Status.notFound);
    assert(owner.wake(pendingWaker).code == Status.ok);
    // A second wake of an already due fiber is harmless.
    assert(owner.wake(pendingWaker).code == Status.ok);
}

private void timerWaited() nothrow @nogc
{
    auto owner = Reactor.current();
    const waker = owner.currentWaker();
    assert(waker.ok && waker.value.valid && waker.value.ownerCore == 0);
    const started = monotonicNow();
    uint rounds;
    foreach (_; 0 .. wakeRounds)
    {
        pendingWaker = waker.value;
        assert(owner.schedule(Deadline.afterMillis(0), &wakeFromTimer).ok);
        assert(owner.yieldUntil(Deadline.afterMillis(farMillis)).code == Status.ok);
        ++rounds;
    }
    atomicStore(callbackElapsed, monotonicNow() - started);
    atomicStore(callbackRounds, rounds);
    owner.stop();
}

@("a loop callback resumes a suspended fiber on the next pass instead of at its deadline")
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
        atomicStore(callbackRounds, 0);
        assert(owner.value.post(0, &timerWaited).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(atomicLoad(callbackRounds) == wakeRounds);
        // Without a wake each round sleeps its 10 s deadline; a millisecond poll would take 200 ms.
        assert(atomicLoad(callbackElapsed) < wakeRounds * 500_000, "woken fiber waited for a poll");
    }
}

private enum pingRounds = 1_000;

private final class PingPong
{
    TaskWaker[2] wakers;
    uint[2] turns;
    uint ball;
    long elapsed;

    void play() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        const self = cast(uint) owner.currentTask().value.requestId;
        wakers[self] = owner.currentWaker().value;
        const started = monotonicNow();
        while (turns[self] < pingRounds)
        {
            if (ball == self)
            {
                ++turns[self];
                ball = 1 - self;
                // The partner may not have registered yet, and a finished partner's handle is stale.
                const woken = owner.wake(wakers[1 - self]);
                if (!wakers[1 - self].valid)
                    assert(woken.code == Status.invalidArgument);
                else if (turns[1 - self] == pingRounds)
                    assert(woken.code == Status.notFound);
                else
                    assert(woken.code == Status.ok);
                continue;
            }
            // Waking the running fiber itself changes nothing.
            assert(owner.wake(wakers[self]).code == Status.ok);
            assert(owner.yieldUntil(Deadline.afterMillis(farMillis)).code == Status.ok);
        }
        if (self == 1)
        {
            elapsed = monotonicNow() - started;
            owner.stop();
        }
    }
}

@("two fibers hand control back and forth through wakes without a loop poll per turn")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    auto fixture = new PingPong;
    assert(owner.value.postStartup(0, &fixture.play, TaskContext(0)).code == Status.ok);
    assert(owner.value.postStartup(0, &fixture.play, TaskContext(1)).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(fixture.turns[0] == pingRounds && fixture.turns[1] == pingRounds);
    assert(fixture.elapsed > 0 && fixture.elapsed < 200_000_000, "wake handoff was paced by deadlines");
}

private final class Stale
{
    TaskWaker retired;
    bool checked;

    void finishEarly() @safe nothrow @nogc
    {
        retired = Reactor.current().currentWaker().value;
    }

    void inspect() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        // The first task ended and its slot now hosts this one under a new generation.
        const TaskWaker current = owner.currentWaker().value;
        assert(current.slot == retired.slot && current.generation != retired.generation);
        assert(owner.wake(retired).code == Status.notFound);
        assert(owner.wake(TaskWaker.init).code == Status.invalidArgument);
        TaskWaker empty = current;
        empty.generation = 0;
        assert(owner.wake(empty).code == Status.notFound);
        TaskWaker foreign = current;
        foreign.ownerCore = 1;
        assert(owner.wake(foreign).code == Status.invalidArgument);
        TaskWaker outside = current;
        outside.slot = 7;
        assert(owner.wake(outside).code == Status.notFound);
        checked = true;
        owner.stop();
    }
}

@("a handle outliving its task, or naming another loop, is rejected")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    auto fixture = new Stale;
    assert(owner.value.postStartup(0, &fixture.finishEarly, TaskContext(1)).code == Status.ok);
    assert(owner.value.postStartup(0, &fixture.inspect, TaskContext(2)).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(fixture.checked);
    // Off the loop there is neither a fiber nor an owner.
    assert(owner.value.currentWaker().error.code == Status.notFound);
    assert(owner.value.wake(TaskWaker(0, 0, 1)).code == Status.invalidArgument);
}

private final class Watched
{
    import flint.conc : CancelSource;

    CancelSource source;
    long elapsed;
    bool resumed;

    void wait() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        auto context = source.context();
        const started = monotonicNow();
        // The caller's context is unrelated to the task's own, and no wake is ever sent.
        assert(owner.yieldUntil(Deadline.afterMillis(farMillis), context).code == Status.cancelled);
        elapsed = monotonicNow() - started;
        resumed = true;
        // Once cancelled, the watched context ends a later yield before it suspends.
        assert(owner.yieldUntil(Deadline.afterMillis(farMillis), context).code == Status.cancelled);
        owner.stop();
    }

    void cancel() @safe nothrow @nogc
    {
        source.cancel();
    }
}

@("a yield that watches a caller context resumes once that context is cancelled")
unittest
{
    import core.lifetime : move;
    import flint.conc : CancelSource, Context;

    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    auto fixture = new Watched;
    auto created = CancelSource.create(Context.init, Deadline.none());
    assert(created.ok());
    move(created.value, fixture.source);
    assert(owner.value.postStartup(0, &fixture.wait, TaskContext(1)).code == Status.ok);
    assert(owner.value.postStartup(0, &fixture.cancel, TaskContext(2)).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(fixture.resumed && fixture.elapsed < 50_000_000, "watched cancellation waited for the deadline");
}
