module flint.reactor.offload_test;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : Backend, Reactor, ReactorOptions, TaskContext;
import flint.reactor.test_support : readinessBackend;

@safe:

private enum Status unset = cast(Status)-1;

private long nowNanos() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

// SAFETY: A test stand-in for a blocking C call such as sqlite3_step.
private void blockFor(uint millis) @trusted nothrow
{
    Thread.sleep(msecs(millis));
}

private ReactorOptions offloadOptions(Backend backend, uint threads = 2, uint capacity = 64)
{
    ReactorOptions options;
    options.backend = backend;
    options.cores = 1;
    options.fiberPoolSize = 32;
    options.offloadThreads = threads;
    options.offloadQueueCapacity = capacity;
    return options;
}

private final class Heartbeat
{
    uint beats;
    uint beatsDuringCall;
    bool borrowedWrite;
    Status outcome = unset;
    long elapsed;
    bool done;

    void ticker() nothrow @nogc
    {
        auto owner = Reactor.current();
        while (!done)
        {
            ++beats;
            if (owner.yieldUntil(Deadline.afterMillis(2)).code != Status.ok)
                return;
        }
    }

    void caller() nothrow @nogc
    {
        auto owner = Reactor.current();
        // Let the ticker start first.
        assert(owner.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        uint onFrame;
        const before = beats;
        const started = nowNanos();
        outcome = owner.offload(() { blockFor(200); onFrame = 7; }).code;
        elapsed = nowNanos() - started;
        beatsDuringCall = beats - before;
        borrowedWrite = onFrame == 7;
        done = true;
        owner.stop();
    }
}

@("a blocking call on the offload pool suspends only its fiber while others keep running")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        foreach (watches; [1024u, 0u])
        {
            auto options = offloadOptions(backend);
            // Zero watches makes the fiber poll for completion instead of waiting for the signal.
            options.maxNativeWatchesPerCore = watches;
            auto owner = Reactor.create(options);
            assert(owner.ok);
            auto fixture = new Heartbeat;
            assert(owner.value.postStartup(0, &fixture.ticker).code == Status.ok);
            assert(owner.value.postStartup(0, &fixture.caller).code == Status.ok);
            assert(owner.value.run().code == Status.ok);
            assert(fixture.outcome == Status.ok);
            assert(fixture.borrowedWrite, "the work did not write the suspended fiber's frame");
            assert(fixture.elapsed >= 190_000_000 && fixture.elapsed < 1_000_000_000);
            // About 100 beats at 2 ms; a blocked loop would show none.
            assert(fixture.beatsDuringCall >= 40, "the loop stalled during the blocking call");
        }
    }
}

private final class Crowd
{
    enum callers = 16;
    shared uint inside;
    shared uint peak;
    shared uint ran;
    uint returned;
    uint failures;

    void call() nothrow @nogc
    {
        auto owner = Reactor.current();
        const outcome = owner.offload(() @trusted {
            const now = atomicOp!"+="(inside, 1);
            for (;;)
            {
                const seen = atomicLoad(peak);
                if (now <= seen || cas(&peak, seen, now))
                    break;
            }
            blockFor(15);
            atomicOp!"-="(inside, 1);
            atomicOp!"+="(ran, 1);
        });
        if (outcome.code != Status.ok)
            ++failures;
        if (++returned == callers)
            owner.stop();
    }
}

@("the offload pool runs at most its thread count at once and queues callers beyond its capacity")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        auto owner = Reactor.create(offloadOptions(backend, 2, 3));
        assert(owner.ok);
        auto fixture = new Crowd;
        foreach (_; 0 .. Crowd.callers)
            assert(owner.value.postStartup(0, &fixture.call).code == Status.ok);
        const started = nowNanos();
        assert(owner.value.run().code == Status.ok);
        const elapsed = nowNanos() - started;
        assert(fixture.failures == 0 && atomicLoad(fixture.ran) == Crowd.callers);
        assert(atomicLoad(fixture.peak) == 2, "more calls ran at once than the pool has threads");
        // Sixteen 15 ms calls on two threads take at least eight rounds.
        assert(elapsed >= 8 * 15_000_000);
    }
}

private final class Withdrawn
{
    shared bool secondRan;
    Status secondOutcome = unset;
    long secondElapsed;
    Status firstOutcome = unset;
    uint finished;

    void occupy() nothrow @nogc
    {
        auto owner = Reactor.current();
        firstOutcome = owner.offload(() { blockFor(150); }).code;
        finish(owner);
    }

    void queuedThenCancelled() nothrow @nogc
    {
        auto owner = Reactor.current();
        const started = nowNanos();
        secondOutcome = owner.offload(() @trusted { atomicStore(secondRan, true); }).code;
        secondElapsed = nowNanos() - started;
        finish(owner);
    }

    private void finish(ref Reactor owner) nothrow @nogc
    {
        if (++finished == 2)
            owner.stop();
    }
}

@("cancelling a task withdraws offloaded work that has not started, without waiting for the pool")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        auto owner = Reactor.create(offloadOptions(backend, 1));
        assert(owner.ok);
        auto fixture = new Withdrawn;
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(20));
        assert(source.ok);
        assert(owner.value.postStartup(0, &fixture.occupy).code == Status.ok);
        assert(owner.value.postStartup(0, &fixture.queuedThenCancelled, TaskContext(2,
                source.value.context())).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.firstOutcome == Status.ok);
        assert(fixture.secondOutcome == Status.timedOut || fixture.secondOutcome == Status.cancelled);
        assert(!atomicLoad(fixture.secondRan), "withdrawn work still ran");
        assert(fixture.secondElapsed < 120_000_000, "the withdrawn caller waited for the busy thread");
    }
}

private final class Interrupted
{
    shared bool stopRequested;
    shared bool workReturned;
    bool returnedFirst;
    uint interrupts;
    Status outcome = unset;
    long elapsed;

    void call() nothrow @nogc
    {
        auto owner = Reactor.current();
        const started = nowNanos();
        outcome = owner.offload(() @trusted {
            foreach (_; 0 .. 400)
            {
                if (atomicLoad(stopRequested))
                    break;
                blockFor(5);
            }
            // The fiber must not observe the outcome before the borrowed work is done.
            blockFor(20);
            atomicStore(workReturned, true);
        }, () @trusted { ++interrupts; atomicStore(stopRequested, true); }).code;
        elapsed = nowNanos() - started;
        returnedFirst = atomicLoad(workReturned);
        owner.stop();
    }
}

@("cancelling running offloaded work interrupts it once and waits until the call returns")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        auto owner = Reactor.create(offloadOptions(backend, 1));
        assert(owner.ok);
        auto fixture = new Interrupted;
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(30));
        assert(source.ok);
        assert(owner.value.postStartup(0, &fixture.call, TaskContext(1, source.value.context())).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.outcome == Status.timedOut || fixture.outcome == Status.cancelled);
        assert(fixture.interrupts == 1);
        assert(fixture.returnedFirst, "offload returned while its work still borrowed the frame");
        // Interrupted near 30 ms instead of running its full two seconds.
        assert(fixture.elapsed < 500_000_000);
    }
}

private final class Shutdown
{
    shared bool workReturned;
    bool returnedFirst;
    Status outcome = unset;

    void call() nothrow @nogc
    {
        auto owner = Reactor.current();
        outcome = owner.offload(() @trusted { blockFor(120); atomicStore(workReturned, true); }).code;
        returnedFirst = atomicLoad(workReturned);
    }

    void stopSoon() nothrow @nogc
    {
        auto owner = Reactor.current();
        cast(void) owner.yieldUntil(Deadline.afterMillis(10));
        owner.stop();
    }
}

@("stopping the reactor waits for running offloaded work before its fiber's frame is released")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        auto owner = Reactor.create(offloadOptions(backend, 1));
        assert(owner.ok);
        auto fixture = new Shutdown;
        assert(owner.value.postStartup(0, &fixture.call).code == Status.ok);
        assert(owner.value.postStartup(0, &fixture.stopSoon).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.outcome == Status.cancelled);
        assert(fixture.returnedFirst, "shutdown released the fiber before its work returned");
    }
}

private final class Misuse
{
    Status noWork = unset;
    Status failed = unset;
    Status afterFailure = unset;

    void onFiber() nothrow @nogc
    {
        auto owner = Reactor.current();
        noWork = owner.offload(null).code;
        // A throwable escaping the work is reported instead of stranding the fiber.
        failed = owner.offload(() { throw new Error("blocking call failed"); }).code;
        afterFailure = owner.offload(() {}).code;
        assert(owner.schedule(Deadline.afterMillis(0), &fromLoopCallback).ok);
        cast(void) owner.yieldUntil(Deadline.afterMillis(20));
        owner.stop();
    }
}

private shared Status loopOutcome = unset;

private void fromLoopCallback() nothrow @nogc
{
    atomicStore(loopOutcome, Reactor.current().offload(() {}).code);
}

private shared Status disabledOutcome = unset;

private void withoutPool() nothrow @nogc
{
    auto owner = Reactor.current();
    atomicStore(disabledOutcome, owner.offload(() {}).code);
    owner.stop();
}

@("offload refuses missing work, loop callbacks, foreign threads and a disabled pool")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        auto owner = Reactor.create(offloadOptions(backend, 1));
        assert(owner.ok);
        auto fixture = new Misuse;
        assert(owner.value.postStartup(0, &fixture.onFiber).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.noWork == Status.invalidArgument);
        assert(fixture.failed == Status.ioError);
        assert(fixture.afterFailure == Status.ok, "a failed call broke its pool thread");
        assert(atomicLoad(loopOutcome) == Status.conflict);
        // The test thread is outside the reactor.
        assert(owner.value.offload(() {}).code == Status.notFound);
    }

    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto plain = Reactor.create(options);
    assert(plain.ok);
    assert(plain.value.post(0, &withoutPool).code == Status.ok);
    assert(plain.value.run().code == Status.ok);
    assert(atomicLoad(disabledOutcome) == Status.unavailable);

    options.offloadThreads = 2;
    options.offloadQueueCapacity = 0;
    assert(Reactor.create(options).error.code == Status.invalidArgument);
    options.offloadQueueCapacity = 4;
    options.offloadThreads = 257;
    assert(Reactor.create(options).error.code == Status.invalidArgument);
}

@("a reactor with an offload pool that never runs releases it")
unittest
{
    // The destructor closes the signals of a pool whose threads never started.
    assert(Reactor.create(offloadOptions(Backend.automatic, 4)).ok);
}
