module flint.schedule.close_join_test;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Error, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : Backend, Reactor, ReactorOptions;
import flint.schedule : Scheduled, Scheduler;

@safe:

// Reactor tasks are `@nogc`, while `Scheduler.open` and `add` allocate on the owner thread. A
// thread-local module constructor runs on the reactor worker before any task, so it opens a
// worker-owned scheduler there. It is armed only while one of these tests runs a reactor.
private shared bool armed;
private shared bool stubborn;
private shared bool released;
private shared bool sawCancel;
private shared uint runs;
private shared Status firstClose;
private shared Status finalClose;
private shared long waitedNanos;
private Scheduler workerScheduler;

private long zero() nothrow @nogc
{
    return 0;
}

private long monotonic() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

static this()
{
    if (!atomicLoad(armed))
        return;
    assert(workerScheduler.open(2, 1, &zero).code == Status.ok);
    assert(workerScheduler.add("cooperative", Scheduled(null, 10), (ref Context context) @safe nothrow @nogc {
            atomicStore(runs, atomicLoad(runs) + 1);
            auto loop = Reactor.current();
            for (;;)
            {
                if (context.check().code == Status.cancelled)
                    atomicStore(sawCancel, true);
                if (atomicLoad(sawCancel) && (!atomicLoad(stubborn) || atomicLoad(released)))
                    return Error.init;
                assert(loop.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
            }
        }).ok);
}

private void admit() nothrow @nogc
{
    assert(workerScheduler.poll(0, 0).code == Status.ok);
    assert(workerScheduler.poll(0, 10).code == Status.ok);
}

private Status closeWithin(uint millis) nothrow @nogc
{
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(millis));
    assert(source.ok);
    auto context = source.value.context();
    return workerScheduler.close(context).code;
}

private void closer() nothrow @nogc
{
    const started = monotonic();
    atomicStore(firstClose, closeWithin(atomicLoad(stubborn) ? 30 : 5_000));
    atomicStore(waitedNanos, monotonic() - started);
    atomicStore(released, true);
    atomicStore(finalClose, closeWithin(5_000));
    auto loop = Reactor.current();
    loop.stop();
}

private void runOnReactor(bool ignoreCancellation) @system
{
    atomicStore(stubborn, ignoreCancellation);
    atomicStore(released, false);
    atomicStore(sawCancel, false);
    atomicStore(runs, 0);
    atomicStore(armed, true);
    scope (exit)
        atomicStore(armed, false);
    ReactorOptions options;
    options.backend = Backend.epoll;
    options.cores = 1;
    options.fiberPoolSize = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &admit).code == Status.ok);
    assert(owner.value.post(0, &closer).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
}

@("close on a separate owner task cancels an admitted job and joins it before returning")
@system unittest
{
    runOnReactor(false);
    assert(atomicLoad(runs) == 1 && atomicLoad(sawCancel));
    assert(atomicLoad(firstClose) == Status.ok && atomicLoad(finalClose) == Status.ok);
}

@("close returns timedOut at its deadline while an admitted job ignores cancellation, then joins later")
@system unittest
{
    runOnReactor(true);
    assert(atomicLoad(runs) == 1 && atomicLoad(sawCancel));
    assert(atomicLoad(firstClose) == Status.timedOut);
    assert(atomicLoad(waitedNanos) >= 30_000_000 && atomicLoad(waitedNanos) < 2_000_000_000);
    assert(atomicLoad(finalClose) == Status.ok);
}
