/// Owned full-D command worker boundaries.
module flint.tui.sys.worker;

import core.atomic : atomicLoad, atomicOp, casWeak;
import core.sync.condition : Condition;
import core.thread : Thread;

@safe:

private enum maximumWorkers = 16;
private shared uint workers;

private bool reserve() nothrow @nogc
{
    for (;;)
    {
        const current = atomicLoad(workers);
        if (current >= maximumWorkers)
            return false;
        if (casWeak(&workers, current, current + 1))
            return true;
    }
}

// SAFETY: The queue owns the safe delegate and druntime roots it through the worker's return.
// No terminal or borrowed frame storage enters the thread. Daemon workers can finish after teardown.
@trusted package(flint.tui) bool launch(void delegate() @safe nothrow entry)
{
    if (entry is null || !reserve())
        return false;
    try
    {
        auto worker = new Thread(() @safe nothrow{
            scope (exit)
                atomicOp!"-="(workers, 1U);
            entry();
        });
        worker.isDaemon = true;
        worker.start();
        return true;
    }
    catch (Exception)
    {
        atomicOp!"-="(workers, 1U);
        return false;
    }
}

// SAFETY: The queue holds the condition's own mutex and roots it through the worker's return.
// The wait releases and reacquires that mutex and returns only with the same queue ownership.
@trusted package(flint.tui) bool park(Condition ready) nothrow
{
    try
    {
        ready.wait();
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

// SAFETY: The queue holds the condition's own mutex during notification. The condition is
// retained for all waiters, and druntime contains the platform synchronization call.
@trusted package(flint.tui) void wake(Condition ready) nothrow
{
    try
        ready.notifyAll();
    catch (Exception)
    {
        // Allocation and retirement remain guarded by the queue's ownership.
    }
}
