module flint.schedule.lifecycle_test;

import core.thread : Fiber;
import flint.arena : Error, Status;
import flint.conc : Context;
import flint.schedule : Scheduled, ScheduledTask, Scheduler, registerScheduled;

@safe:

private long simulated;

private long clock() nothrow @nogc
{
    return simulated;
}

@("clock jumps coalesce fixed-rate and cron delivery while fixed delay starts at completion")
unittest
{
    Scheduler scheduler;
    Context parent;
    simulated = 0;
    assert(scheduler.open(8, 2, &clock).code == Status.ok);
    int rate;
    int delay;
    int cron;
    assert(scheduler.add("rate", Scheduled(null, 10), (ref Context) @safe nothrow @nogc {
            ++rate;
            return Error.init;
        }).ok);
    assert(scheduler.add("delay", Scheduled(null, 0, 10), (ref Context) @safe nothrow @nogc {
            ++delay;
            simulated += 20;
            return Error.init;
        }).ok);
    assert(scheduler.add("utc", Scheduled("0 0 2 * * *"), (ref Context) @safe nothrow @nogc {
            ++cron;
            return Error.init;
        }).ok);
    const beforeDaylight = 1_711_843_200L;
    assert(scheduler.poll(beforeDaylight, 0).code == Status.ok);
    assert(rate == 0 && delay == 0 && cron == 0);
    assert(scheduler.poll(beforeDaylight + 7200, 10).code == Status.ok);
    assert(rate == 1 && delay == 1 && cron == 1);
    assert(scheduler.poll(beforeDaylight - 86_400, 39).code == Status.ok);
    assert(rate == 2 && delay == 1 && cron == 1);
    assert(scheduler.poll(beforeDaylight + 7200, 40).code == Status.ok);
    assert(rate == 3 && delay == 2 && cron == 1);
    assert(scheduler.poll(beforeDaylight + 4 * 86_400, 60_000_000_000L).code == Status.ok);
    assert(rate == 4 && delay == 3 && cron == 2);
    assert(scheduler.poll(beforeDaylight + 4 * 86_400, 60_000_000_000L).code == Status.ok);
    assert(rate == 4 && delay == 3 && cron == 2);
    assert(scheduler.close(parent).code == Status.ok);
}

@("cancellation cannot hit a reused slot or an ID from an earlier scheduler")
unittest
{
    Scheduler scheduler;
    Context context;
    int runs;
    ScheduledTask increment = (ref Context) @safe nothrow @nogc { ++runs; return Error.init; };
    assert(scheduler.open(1, 1, &clock).code == Status.ok);
    const old = scheduler.add("old", Scheduled(null, 1), increment);
    assert(old.ok && scheduler.cancel(old.value).code == Status.ok);
    const reused = scheduler.add("reused", Scheduled(null, 2), increment);
    assert(reused.ok && old.value != reused.value);
    assert(scheduler.cancel(old.value).code == Status.ok);
    assert(scheduler.poll(0, 0).code == Status.ok);
    assert(scheduler.poll(0, 2).code == Status.ok && runs == 1);
    assert(scheduler.close(context).code == Status.ok);
    assert(scheduler.open(1, 1, &clock).code == Status.ok);
    const reopened = scheduler.add("reopened", Scheduled(null, 1), increment);
    assert(reopened.ok && scheduler.cancel(reused.value).code == Status.ok);
    assert(scheduler.poll(0, 0).code == Status.ok);
    assert(scheduler.poll(0, 1).code == Status.ok && runs == 2);
}

private final class Component
{
    int calls;

    @Scheduled(null, 10) Error step(ref Context context) nothrow @nogc
    {
        ++calls;
        return context.check();
    }
}

@("registered class methods preserve caller identity and direct invocation stays unwrapped")
unittest
{
    auto component = new Component;
    Context context;
    assert(component.step(context).code == Status.ok && component.calls == 1);
    Scheduler scheduler;
    assert(scheduler.open(2, 1, &clock).code == Status.ok);
    assert(registerScheduled(scheduler, component).code == Status.ok);
    assert(scheduler.poll(0, 0).code == Status.ok);
    assert(scheduler.poll(0, 10).code == Status.ok && component.calls == 2);
    assert(scheduler.close(context).code == Status.ok);
}

// SAFETY: Only the currently executing fixture fiber calls this; it remains rooted until rejoined.
private void suspendFixture() @trusted nothrow @nogc
{
    Fiber.yield();
}

@("active jobs use a cancellable context and concurrency is explicitly bounded")
@system unittest
{
    foreach (overlap; [false, true])
    {
        Scheduler scheduler;
        int runs;
        bool cancelled;
        assert(scheduler.open(2, 1, &clock).code == Status.ok);
        ScheduledTask yielding = (ref Context current) @safe nothrow @nogc {
            ++runs;
            suspendFixture();
            cancelled = current.check().code == Status.cancelled;
            return Error.init;
        };
        const id = scheduler.add("yielding", Scheduled(null, 10, 0, overlap), yielding);
        assert(id.ok && scheduler.poll(0, 0).code == Status.ok);
        auto pending = new Fiber({ assert(scheduler.poll(0, 10).code == Status.ok); });
        pending.call();
        assert(runs == 1);
        const next = scheduler.poll(0, 40);
        assert(next.code == (overlap ? Status.unavailable : Status.ok) && runs == 1);
        assert(scheduler.cancel(id.value).code == Status.ok);
        pending.call();
        assert(cancelled && pending.state == Fiber.State.TERM);
        Context context;
        assert(scheduler.close(context).code == Status.ok);
    }
}
