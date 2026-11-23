module flint.engine.reactor.fiber_pool_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.engine.reactor : Reactor, ReactorOptions;

private enum uint poolSize = 1024;
private enum uint tasks = 300;

private size_t residentBefore;
private shared size_t residentInside;
private shared uint finished;

private size_t residentBytes() @trusted nothrow @nogc
{
    version (linux)
    {
        import core.stdc.stdio : fclose, fopen, fscanf;
        import core.memory : pageSize;

        auto file = fopen("/proc/self/statm", "r");
        if (file is null)
            return 0;
        scope (exit)
            fclose(file);
        ulong size, resident;
        if (fscanf(file, "%llu %llu", &size, &resident) != 2)
            return 0;
        return cast(size_t) resident * pageSize;
    }
    else version (OSX)
    {
        // <mach/task_info.h> MACH_TASK_BASIC_INFO: virtual, resident and maximum resident sizes first.
        enum int machTaskBasicInfo = 20;
        ulong[6] info;
        uint count = info.sizeof / uint.sizeof;
        if (task_info(mach_task_self_, machTaskBasicInfo, info.ptr, &count) != 0)
            return 0;
        return cast(size_t) info[1];
    }
    else
        return 0;
}

version (OSX)
{
    private extern (C) extern __gshared uint mach_task_self_;
    private extern (C) int task_info(uint task, int flavor, ulong* info, uint* count) @system nothrow @nogc;
}

private void measure() @safe nothrow @nogc
{
    atomicStore(residentInside, residentBytes());
    auto reactor = Reactor.current();
    foreach (i; 0 .. tasks)
        assert(reactor.post(0, &yieldOnce).code == Status.ok);
}

private void yieldOnce() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
    if (atomicOp!"+="(finished, 1) == tasks)
        reactor.stop();
}

@("a preallocated fiber pool keeps unused stacks out of resident memory and still runs every task")
unittest
{
    import core.memory : pageSize;

    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = poolSize;
    options.maxTimersPerCore = tasks;
    options.mailboxCapacity = tasks + 4;
    auto server = Reactor.create(options);
    assert(server.ok, server.error.message);
    residentBefore = residentBytes();
    assert(server.value.post(0, &measure).code == Status.ok);
    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    assert(atomicLoad(finished) == tasks);
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.gcAllocated == 0);
    version (linux)
    {
        // Eagerly written initial frames made one page per pooled fiber resident.
        const inside = atomicLoad(residentInside);
        assert(inside > residentBefore);
        assert(inside - residentBefore < poolSize * pageSize / 2);
    }
    else version (OSX)
    {
        // Darwin's task resident size can also shrink between the samples, as the kernel compresses
        // or reclaims pages, so only the growth bound is checked.
        const inside = atomicLoad(residentInside);
        assert(inside <= residentBefore || inside - residentBefore < poolSize * pageSize / 2);
    }
}
