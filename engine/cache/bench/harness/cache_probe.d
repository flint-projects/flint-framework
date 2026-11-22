module cache_probe;

import core.bitop : bsr;
import core.memory : GC;
import core.stdc.stdio : printf;
import core.thread.osthread : Thread;
import core.time : MonoTime;
import flint.arena : Buffer, RequestArena, Result, Status;

/// One data-path operation on a worker and immutable workload size.
alias Operation = uint delegate(uint worker, uint action, size_t bytes) @safe nothrow @nogc;

/// Measure the local lock acquisition counter when it is available.
alias LockReport = ulong[2]delegate() @safe nothrow @nogc;

/// Reference values served by both workloads.
immutable ubyte[4096] payload = 73;

/// Read the terminal bytes and length to keep each operation observable.
uint inspect(Result!Buffer read, ref scope RequestArena arena) @safe nothrow @nogc
{
    if (!read.ok)
        return 0;
    uint result;
    const status = arena.read(read.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        if (bytes.length != 0)
            result = cast(uint) bytes.length + bytes[0] + bytes[$ - 1];
    });
    return status == Status.ok ? result : 0;
}

private struct Lane
{
    ulong[64] latency;
    ulong operations;
    ulong bytesAllocated;
    bool failed;

    void run(Operation operation, uint index, size_t bytes) @safe nothrow @nogc
    {
        const before = GC.stats.allocatedInCurrentThread;
        const start = MonoTime.currTime;
        const uint[4] expected = [cast(uint) bytes + 146, 2, 3, 4];
        do
        {
            foreach (_; 0 .. 256)
            {
                const action = cast(uint)(operations % 4);
                const begun = MonoTime.currTime;
                if (operation(index, action, bytes) != expected[action])
                    failed = true;
                const interval = (MonoTime.currTime - begun).total!"nsecs";
                const bucket = interval > 0 ? cast(uint) bsr(cast(ulong) interval) : 0;
                ++latency[bucket];
                ++operations;
            }
        }
        while ((MonoTime.currTime - start).total!"msecs" < 150);
        bytesAllocated = GC.stats.allocatedInCurrentThread - before;
    }
}

/// Run the pinned contention matrix and publish bounded latency and allocation samples.
int measure(Operation operation, LockReport locks)
{
    foreach (workers; [1U, 8U, 32U])
        foreach (bytes; [64, 4096])
            if (!trial(operation, locks, workers, bytes))
                return 2;
    return 0;
}

private bool trial(Operation operation, LockReport locks, uint workers, size_t bytes)
{
    auto lanes = new Lane[workers];
    auto jobs = new Thread[workers];
    const initial = locks();
    foreach (index; 0 .. workers)
        jobs[index] = start(&lanes[index], operation, index, bytes);
    foreach (job; jobs)
        job.join();
    const finalLocks = locks();
    ulong[64] latency;
    ulong total;
    foreach (ref lane; lanes)
    {
        if (lane.failed || lane.bytesAllocated != 0)
            return false;
        foreach (index, amount; lane.latency)
            latency[index] += amount;
        total += lane.operations;
    }
    auto threshold = total - total / 100;
    uint index;
    while (threshold > latency[index])
        threshold -= latency[index++];
    const upper = 2UL << index;
    const checksum = cast(ulong) bytes + 146 + 2 + 3 + 4;
    enum format = "threads=%u value_bytes=%zu operations=%llu p99_upper_ns=%llu "
        ~ "lock_count=%llu lock_wait_ns=%llu gc_bytes=0 checksum=%llu\n";
    printf(format, workers, bytes, total, upper, finalLocks[0] - initial[0], finalLocks[1] - initial[1], checksum);
    return true;
}

private Thread start(Lane* lane, Operation operation, uint index, size_t bytes)
{
    return new Thread({ lane.run(operation, index, bytes); }).start();
}
