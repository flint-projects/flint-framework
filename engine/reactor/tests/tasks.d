module flint.reactor.task_test;

import flint.arena : Status;
import flint.conc : Deadline;
import flint.reactor : Reactor, ReactorOptions, TaskContext;

private uint stage;

private void checkContext(ulong expected) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    const task = reactor.currentTask();
    assert(task.ok && task.value.requestId == expected);
    assert(reactor.currentCore == 0);
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
    assert(server.value.post(0, &firstTask, TaskContext(71)).code == Status.ok);
    assert(server.value.post(0, &secondTask, TaskContext(92)).code == Status.ok);
    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.gcAllocated == 0);
}
