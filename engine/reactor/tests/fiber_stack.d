module flint.reactor.fiber_stack_test;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.reactor : Reactor, ReactorOptions, TaskContext;

@safe:

@("task fibers reserve 256 KiB stacks above 16 KiB of guard pages by default")
unittest
{
    ReactorOptions options;
    assert(options.fiberStackBytes == 262_144);
    assert(options.fiberGuardBytes == 16_384);
    options.fiberStackBytes = 8_192;
    assert(Reactor.create(options).error.code == Status.invalidArgument);
    options.fiberStackBytes = 262_144;
    options.fiberGuardBytes = 2_097_152;
    assert(Reactor.create(options).error.code == Status.invalidArgument);
}

// Each frame keeps 1 KiB live, so 180 frames need about 190 KiB: past the old 64 KiB, within 256 KiB.
private uint descend(uint depth) nothrow @nogc
{
    ubyte[1024] frame;
    frame[depth % frame.length] = cast(ubyte) depth;
    if (depth == 0)
        return frame[0];
    return descend(depth - 1) + frame[depth % frame.length];
}

private shared uint deepResult = uint.max;

private void deepTask() nothrow @nogc
{
    atomicStore(deepResult, descend(180));
    Reactor.current().stop();
}

@("a task can use most of its 256 KiB stack")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &deepTask).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(atomicLoad(deepResult) != uint.max);
}

version (linux)
{
    private final class IdleFibers
    {
        uint parked;
        uint total;
        size_t residentAtPeak;

        void idle() nothrow @nogc
        {
            auto owner = Reactor.current();
            if (++parked == total)
            {
                residentAtPeak = residentBytes();
                owner.stop();
                return;
            }
            cast(void) owner.yieldUntil(Deadline.afterMillis(10_000));
        }
    }

    // SAFETY: Reads this process's statm into a bounded local buffer.
    private size_t residentBytes() @trusted nothrow @nogc
    {
        import core.stdc.stdio : FILE, fclose, fopen, fscanf;
        import core.sys.posix.unistd : _SC_PAGESIZE, sysconf;

        FILE* file = fopen("/proc/self/statm", "r");
        if (file is null)
            return 0;
        scope (exit)
            fclose(file);
        size_t size, resident;
        if (fscanf(file, "%zu %zu", &size, &resident) != 2)
            return 0;
        return resident * cast(size_t) sysconf(_SC_PAGESIZE);
    }

    private size_t idleGrowth(size_t stackBytes)
    {
        enum count = 1_024;
        ReactorOptions options;
        options.cores = 1;
        options.fiberPoolSize = count;
        options.mailboxCapacity = count;
        options.fiberStackBytes = stackBytes;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        auto fixture = new IdleFibers;
        fixture.total = count;
        foreach (index; 0 .. count)
            assert(owner.value.postStartup(0, &fixture.idle, TaskContext(index)).code == Status.ok);
        const before = residentBytes();
        assert(owner.value.run().code == Status.ok);
        assert(fixture.parked == count && fixture.residentAtPeak > 0);
        return fixture.residentAtPeak > before ? fixture.residentAtPeak - before : 0;
    }

    @("1,024 idle fibers cost the same resident memory with 256 KiB stacks as with 64 KiB")
    unittest
    {
        import core.stdc.stdio : fprintf, stderr;

        size_t small = size_t.max, large = size_t.max;
        // Alternate and keep the smaller sample, so heap reuse between runs favors neither size.
        foreach (_; 0 .. 2)
        {
            const smallRun = idleGrowth(65_536);
            const largeRun = idleGrowth(262_144);
            small = smallRun < small ? smallRun : small;
            large = largeRun < large ? largeRun : large;
        }
        () @trusted {
            fprintf(stderr, "fiber RSS, 1024 idle fibers: 64 KiB stacks +%zu KiB, 256 KiB stacks +%zu KiB\n",
                    small / 1024, large / 1024);
        }();
        // Reserving 192 MiB more address space may add at most 2 MiB of resident pages.
        assert(large <= small + 2 * 1024 * 1024, "untouched stack pages became resident");
        assert(large < 64 * 1024 * 1024);
    }
}

version (Posix)
{
    import core.sys.posix.signal : SA_ONSTACK, SA_SIGINFO, SIGBUS, SIGSEGV, sigaction, sigaction_t,
        sigaltstack, siginfo_t, stack_t;
    import core.sys.posix.unistd : _exit;

    private enum overflowVariable = "FLINT_REACTOR_OVERFLOW_CHILD";
    private enum exitInGuard = 42;
    private enum exitElsewhere = 43;
    private enum exitNoFault = 44;

    private __gshared size_t stackTop;
    private __gshared ubyte[65_536] alternateStack;

    // SAFETY: Runs on its own alternate stack after the fiber stack is exhausted and only calls _exit.
    private extern (C) void onFault(int, siginfo_t* info, void*) @trusted nothrow @nogc
    {
        const fault = cast(size_t) info.si_addr;
        const below = stackTop - fault;
        // The guard is the 16 KiB below the 256 KiB stack; the first fiber frame sits a little under its top.
        _exit(fault < stackTop && below >= 262_144 - 8_192 && below <= 262_144 + 16_384 ? exitInGuard : exitElsewhere);
    }

    // Unbounded recursion with 512-byte frames, well under the guard, so it cannot step over it.
    private uint overflow(uint depth) nothrow @nogc
    {
        ubyte[512] frame;
        frame[depth % frame.length] = cast(ubyte) depth;
        return overflow(depth + 1) + frame[(depth * 7) % frame.length];
    }

    // SAFETY: Records the address of a local as an integer, which the handler only compares, and gives this
    // worker thread a static alternate signal stack: the alternate stack is per thread.
    private void overflowTask() @trusted nothrow @nogc
    {
        stack_t alternate;
        alternate.ss_sp = alternateStack.ptr;
        alternate.ss_size = alternateStack.length;
        sigaltstack(&alternate, null);
        ubyte marker;
        stackTop = cast(size_t)&marker;
        cast(void) overflow(0);
    }

    // SAFETY: Installs the fault handler in the child process only.
    private void runOverflowChild() @trusted
    {
        sigaction_t action;
        action.sa_sigaction = &onFault;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigaction(SIGSEGV, &action, null);
        sigaction(SIGBUS, &action, null);

        ReactorOptions options;
        options.cores = 1;
        options.fiberPoolSize = 1;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        assert(owner.value.post(0, &overflowTask).code == Status.ok);
        owner.value.run();
        _exit(exitNoFault);
    }

    // The test binary re-executes itself with the variable set; the child overflows before any test runs.
    shared static this()
    {
        import core.stdc.stdlib : getenv;

        if ((()@trusted => getenv(overflowVariable) !is null)())
            runOverflowChild();
    }

    @("overflowing a task fiber's stack faults in its guard pages")
    unittest
    {
        import std.file : thisExePath;
        import std.process : Config, spawnProcess, wait;
        import std.stdio : File;

        auto devnull = File("/dev/null", "w");
        auto child = spawnProcess([thisExePath()], File("/dev/null"), devnull, devnull,
                [overflowVariable: "1"], Config.none);
        const status = wait(child);
        assert(status == exitInGuard, "overflow did not fault in the guard pages");
    }
}
