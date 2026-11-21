module observe_probe;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.thread : Thread;
import core.time : MonoTime;

/// Record one counter and histogram observation for this worker.
alias Update = void delegate(uint worker) @safe nothrow @nogc;
/// Check the complete observed totals once every worker has joined.
alias Verify = bool delegate(ulong observations) @safe;

private struct Worker
{
    ulong calls;
    ulong allocated;

    void run(Update update, uint index) @safe nothrow @nogc
    {
        const before = GC.stats.allocatedInCurrentThread;
        const started = MonoTime.currTime;
        do
        {
            foreach (_; 0 .. 1024)
                update(index);
            calls += 1024;
        }
        while ((MonoTime.currTime - started).total!"msecs" < 150);
        allocated = GC.stats.allocatedInCurrentThread - before;
    }
}

/// Run one measured group and verify its aggregated observations.
bool measure(uint cores, Update update, Verify verify)
{
    auto workers = new Worker[cores];
    auto threads = new Thread[cores];
    const started = MonoTime.currTime;
    foreach (index; 0 .. cores)
        threads[index] = launch(&workers[index], update, index);
    foreach (thread; threads)
        thread.join();
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    ulong calls;
    foreach (ref worker; workers)
    {
        if (worker.allocated != 0)
            return false;
        calls += worker.calls;
    }
    if (!verify(calls))
        return false;
    printf("cores=%u updates=%llu elapsed_ns=%lld gc_bytes=0 checksum=%llu\n", cores, calls, elapsed, calls);
    return true;
}

private Thread launch(Worker* worker, Update update, uint index)
{
    return new Thread({ worker.run(update, index); }).start();
}
