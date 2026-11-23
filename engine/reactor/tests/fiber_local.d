module flint.engine.reactor.fiber_local_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.engine.reactor : Backend, FiberLocal, Reactor, ReactorOptions, TaskContext;
import flint.engine.reactor.test_support : readinessBackend;

@safe:

private final class Principal
{
    ulong id;

    this(ulong id) nothrow
    {
        this.id = id;
    }
}

private struct Span
{
    ulong trace;
    ulong span;
    string name;
}

private shared FiberLocal!ulong requestId;
private shared FiberLocal!Principal principal;
private shared FiberLocal!Span span;
private shared FiberLocal!string locale;

private enum fibers = 1_000;
private enum rounds = 5;

private final class Interleaved
{
    Principal[fibers] principals;
    string[fibers] names;
    uint finished;
    uint mismatches;
    uint maxConcurrent;
    uint running;

    this()
    {
        import std.conv : to;

        foreach (index; 0 .. fibers)
        {
            principals[index] = new Principal(index);
            names[index] = "task-" ~ index.to!string;
        }
    }

    void play() nothrow @nogc
    {
        auto owner = Reactor.current();
        const self = owner.currentTask().value.requestId;
        // Every task starts unset, even though no task ran before it.
        if (requestId.get() != 0 || principal.get() !is null || span.get() != Span.init)
            ++mismatches;
        ++running;
        if (running > maxConcurrent)
            maxConcurrent = running;
        foreach (round; 0 .. rounds)
        {
            assert(requestId.set(self + 1).code == Status.ok);
            assert(principal.set(principals[self]).code == Status.ok);
            assert(span.set(Span(self, round, names[self])).code == Status.ok);
            // Yield so all other tasks write their own values before this one reads.
            assert(owner.yieldUntil(Deadline.afterMillis(round % 2)).code == Status.ok);
            const seen = span.get();
            if (requestId.get() != self + 1 || principal.get() !is principals[self]
                    || seen.trace != self || seen.span != round || seen.name !is names[self])
                ++mismatches;
        }
        --running;
        if (++finished == fibers)
            owner.stop();
    }
}

@("FiberLocal keeps each of 1,000 interleaved fibers' values apart on both backends")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        options.fiberPoolSize = fibers;
        options.mailboxCapacity = fibers;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        version (FlintNativeLiburing)
        {
            import std.process : environment;

            // With the pinned liburing linked, automatic selection is io_uring unless the test denies it.
            if (backend == Backend.automatic && environment.get("FLINT_TEST_URING_DENIED") != "1")
                assert(owner.value.activeBackend() == Backend.ioUring);
        }
        auto fixture = new Interleaved;
        foreach (index; 0 .. fibers)
            assert(owner.value.postStartup(0, &fixture.play, TaskContext(index)).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.finished == fibers);
        assert(fixture.mismatches == 0);
        // The values were live at the same time, not one task after another.
        assert(fixture.maxConcurrent == fibers);
    }
}

private final class Reuse
{
    uint stage;
    bool clean;
    bool removed;

    void first() nothrow @nogc
    {
        assert(requestId.get() == 0);
        assert(requestId.set(42).code == Status.ok);
        assert(locale.set("fr-CA").code == Status.ok);
        assert(requestId.get() == 42 && locale.get() == "fr-CA");
        locale.remove();
        removed = locale.get() is null && requestId.get() == 42;
        stage = 1;
    }

    void second() nothrow @nogc
    {
        // The same fiber slot runs a new task under a new generation; nothing of the first task shows.
        clean = stage == 1 && requestId.get() == 0 && locale.get() is null;
        Reactor.current().stop();
    }
}

@("a reused fiber slot starts its next task with T.init, and remove forgets a value")
unittest
{
    foreach (backend; [Backend.automatic, readinessBackend])
    {
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        options.fiberPoolSize = 1;
        auto owner = Reactor.create(options);
        assert(owner.ok);
        auto fixture = new Reuse;
        assert(owner.value.postStartup(0, &fixture.first).code == Status.ok);
        assert(owner.value.postStartup(0, &fixture.second).code == Status.ok);
        assert(owner.value.run().code == Status.ok);
        assert(fixture.removed && fixture.clean);
    }
}

private shared FiberLocal!ulong callbackLocal;
private shared ulong callbackSeen = ulong.max;
private shared ulong fiberSeenAfter = ulong.max;

private void onLoop() nothrow @nogc
{
    // A loop callback is off any fiber: it sees the worker thread's own value, not the suspended task's.
    atomicStore(callbackSeen, callbackLocal.get());
    assert(callbackLocal.set(7).code == Status.ok);
}

private void fiberThenLoop() nothrow @nogc
{
    auto owner = Reactor.current();
    assert(callbackLocal.set(99).code == Status.ok);
    assert(owner.schedule(Deadline.afterMillis(0), &onLoop).ok);
    assert(owner.yieldUntil(Deadline.afterMillis(20)).code == Status.ok);
    atomicStore(fiberSeenAfter, callbackLocal.get());
    owner.stop();
}

@("off a fiber FiberLocal falls back to thread-local storage, on the loop and on other threads")
unittest
{
    // The test thread is outside any reactor.
    assert(callbackLocal.get() == 0);
    assert(callbackLocal.set(5).code == Status.ok);
    assert(callbackLocal.get() == 5);

    ulong other = ulong.max;
    auto thread = new Thread(() @trusted { other = callbackLocal.get(); callbackLocal.set(11); });
    () @trusted { thread.start(); thread.join(); }();
    assert(other == 0, "another thread saw this thread's value");
    assert(callbackLocal.get() == 5);

    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &fiberThenLoop).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(atomicLoad(callbackSeen) == 0, "loop callback saw the task's value");
    assert(atomicLoad(fiberSeenAfter) == 99, "loop callback overwrote the task's value");
    callbackLocal.remove();
    assert(callbackLocal.get() == 0);
}

private shared FiberLocal!(ulong[3]) wide;
private shared uint exhausted;

private void tooWide() nothrow @nogc
{
    // Four words do not fit a two-word fiber area; off-fiber storage is unaffected.
    if (wide.set([1, 2, 3]).code == Status.resourceExhausted && wide.get() == [0, 0, 0])
        atomicOp!"+="(exhausted, 1);
    Reactor.current().stop();
}

@("a FiberLocal larger than ReactorOptions.fiberLocalWords is refused on the fiber, not off it")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    options.fiberLocalWords = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &tooWide).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
    assert(atomicLoad(exhausted) == 1);
    assert(wide.set([4, 5, 6]).code == Status.ok && wide.get() == [4, 5, 6]);

    options.fiberLocalWords = 129;
    assert(Reactor.create(options).error.code == Status.invalidArgument);
}

@("FiberLocal rejects types whose copies run code")
unittest
{
    static struct Counted
    {
        int value;
        this(this)
        {
        }
    }

    static struct Owned
    {
        ~this()
        {
        }
    }

    static assert(!__traits(compiles, FiberLocal!Counted));
    static assert(!__traits(compiles, FiberLocal!Owned));
    static assert(__traits(compiles, FiberLocal!(Object)));
    static assert(__traits(compiles, FiberLocal!(const(char)[])));
}
