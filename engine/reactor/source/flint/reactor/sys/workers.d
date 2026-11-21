module flint.reactor.sys.workers;

import core.thread : Thread;

@safe:

version (linux)
{
    import core.sys.linux.sched : CPU_ISSET, CPU_SET, cpu_set_t, sched_getaffinity, sched_setaffinity;
}
else version (Posix)
    import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;
else version (Windows)
    import core.sys.windows.winbase : GetCurrentProcess, GetProcessAffinityMask;

// SAFETY: These platform queries write only to local buffers and retain no pointers.
@trusted package(flint.reactor) uint[] availableCpus()
{
    uint[] cpus;
    version (linux)
    {
        cpu_set_t mask;
        if (sched_getaffinity(0, mask.sizeof, &mask) == 0)
            foreach (cpu; 0 .. cpu_set_t.sizeof * 8)
                if (CPU_ISSET(cpu, &mask))
                    cpus ~= cast(uint) cpu;
    }
    else version (Posix)
    {
        const count = sysconf(_SC_NPROCESSORS_ONLN);
        foreach (cpu; 0 .. count)
            cpus ~= cast(uint) cpu;
    }
    else version (Windows)
    {
        size_t processMask, systemMask;
        if (GetProcessAffinityMask(GetCurrentProcess(), &processMask, &systemMask))
            foreach (cpu; 0 .. size_t.sizeof * 8)
                if (processMask & (cast(size_t) 1 << cpu))
                    cpus ~= cast(uint) cpu;
    }
    return cpus.length == 0 ? [0U] : cpus;
}

// SAFETY: sched_setaffinity refers to the current worker and only borrows its local affinity set.
package(flint.reactor) bool pinWorker(uint cpu) @trusted nothrow @nogc
{
    version (linux)
    {
        if (cpu >= cpu_set_t.sizeof * 8)
            return false;
        cpu_set_t mask;
        CPU_SET(cpu, &mask);
        return sched_setaffinity(0, mask.sizeof, &mask) == 0;
    }
    else
    {
        return false;
    }
}

// SAFETY: A new druntime thread owns this entry and can only invoke its safe nonthrowing delegate.
@trusted package(flint.reactor) Thread startWorker(void delegate() @safe nothrow entry)
{
    return new Thread(entry).start();
}

// SAFETY: Only the run owner joins a thread it started, after setting the stop flag. No live worker is reused.
@trusted package(flint.reactor) Throwable joinWorker(Thread worker)
{
    return worker.join(false);
}

// SAFETY: Yielding discloses no memory and changes only scheduling of the calling thread.
package(flint.reactor) void yieldWorker() @trusted nothrow @nogc
{
    Thread.yield();
}

package(flint.reactor) struct Usage
{
    ulong cpuNanos;
    ulong voluntarySwitches;
    ulong involuntarySwitches;
}

// SAFETY: getrusage writes one local typed result and retains no pointer.
package(flint.reactor) Usage workerUsage() @trusted nothrow @nogc
{
    version (linux)
    {
        import core.sys.posix.sys.resource : RUSAGE_THREAD, getrusage, rusage;

        rusage usage;
        if (getrusage(RUSAGE_THREAD, &usage) != 0)
            return Usage.init;
        const seconds = cast(ulong)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec);
        const micros = cast(ulong)(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec);
        return Usage(seconds * 1_000_000_000 + micros * 1000, usage.ru_nvcsw, usage.ru_nivcsw);
    }
    else
        return Usage.init;
}
