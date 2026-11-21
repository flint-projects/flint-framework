module flint.reactor.task_test;

import flint.arena : Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : Reactor, ReactorOptions, TaskContext;

private uint stage;

private void checkContext(ulong expected) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    const task = reactor.currentTask();
    assert(task.ok && task.value.requestId == expected);
    assert(task.value.traceIdHigh == expected + 100);
    assert(task.value.traceIdLow == expected + 200 && task.value.spanId == expected + 300);
    assert(reactor.currentCore == 0);
}

private TaskContext tracedTask(ulong requestId) @safe nothrow @nogc
{
    auto context = TaskContext(requestId);
    context.traceIdHigh = requestId + 100;
    context.traceIdLow = requestId + 200;
    context.spanId = requestId + 300;
    return context;
}

private void forbidden() @safe nothrow @nogc
{
    assert(0, "cancelled timer ran");
}

private void armTimers() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.currentTask().error.code == Status.notFound);
    assert(reactor.yieldUntil(Deadline.afterMillis(0)).code == Status.notFound);
    assert(stage == 2);
    stage = 3;
}

private void firstTask() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(stage == 0);
    stage = 1;
    checkContext(71);
    auto timer = reactor.schedule(Deadline.afterMillis(1), &forbidden);
    assert(timer.ok);
    assert(reactor.cancel(timer.value).code == Status.ok);
    assert(reactor.cancel(timer.value).code == Status.notFound);
    assert(reactor.schedule(Deadline.afterMillis(5), &armTimers).ok);
    assert(reactor.yieldUntil(Deadline.afterMillis(35)).code == Status.ok);

    checkContext(71);
    assert(stage == 3);
    stage = 4;
    reactor.stop();
}

private void secondTask() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    checkContext(92);
    assert(stage == 1);
    stage = 2;
    assert(reactor.yieldUntil(Deadline.afterMillis(90_000)).code == Status.cancelled);
    checkContext(92);
    assert(stage == 4);
}

@("fibers alternate task contexts on one worker and shutdown resumes sleeping tasks")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 2;
    options.maxTimersPerCore = 1;
    options.completionsPerTick = 1;
    auto server = Reactor.create(options);
    assert(server.ok, server.error.message);
    assert(server.value.currentTask().error.code == Status.notFound);
    assert(server.value.post(0, &firstTask, tracedTask(71)).code == Status.ok);
    assert(server.value.post(0, &secondTask, tracedTask(92)).code == Status.ok);
    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.gcAllocated == 0);
}

private final class StartupTask
{
    bool entered;

    @safe nothrow @nogc void run()
    {
        auto reactor = Reactor.current();
        const task = reactor.currentTask();
        assert(task.ok && task.value.requestId == 81);
        entered = true;
        reactor.stop();
    }
}

@("configured owners can transfer a bound startup task before entering the run loop")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto setup = Reactor.create(options);
    assert(setup.ok);
    auto startup = new StartupTask;
    assert(setup.value.postWith(0, &startup.run).code == Status.invalidArgument);
    assert(setup.value.postStartup(0, &startup.run, TaskContext(81)).code == Status.ok);
    assert(setup.value.run().code == Status.ok && startup.entered);
    assert(setup.value.postStartup(0, &startup.run).code == Status.conflict);
}

private final class CancelledTask
{
    uint calls;

    void queue() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        auto source = CancelSource.create(Context.init, Deadline.none());
        assert(source.ok);
        scope (exit)
            source.value.close();
        auto copied = TaskContext(82, source.value.context());
        assert(owner.postWith(0, &unexpected, copied).code == Status.ok);
        assert(owner.postWithCleanup(0, &retire, copied).code == Status.ok);
        source.value.cancel();
    }

    void unexpected() @safe nothrow @nogc
    {
        assert(0, "default task ran after cancellation");
    }

    void retire() @safe nothrow @nogc
    {
        auto owner = Reactor.current();
        const task = owner.currentTask();
        assert(task.ok && task.value.requestId == 82);
        assert(task.value.cancellation.check().code == Status.cancelled);
        ++calls;
        owner.stop();
    }
}

@("owner cleanup runs once when cancellation precedes first dispatch")
unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = 1;
    auto setup = Reactor.create(options);
    assert(setup.ok);
    auto fixture = new CancelledTask;
    assert(setup.value.postStartup(0, &fixture.queue).code == Status.ok);
    assert(setup.value.run().code == Status.ok && fixture.calls == 1);
}
