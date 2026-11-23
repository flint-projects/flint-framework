module flint.engine.schedule.lifecycle_test;

import core.memory : GC;
import core.thread.fiber : Fiber;
import core.thread.osthread : Thread;
import flint.arena : Error, Status;
import flint.conc : Context;
import flint.engine.schedule : Retryable, Scheduled, ScheduledTask, Scheduler, registerScheduled;

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

    @Scheduled(null, 10)
    Error step(ref Context context) nothrow @nogc
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

private ScheduledTask succeed()
{
    return (ref Context) @safe nothrow @nogc => Error.init;
}

@("schedule_conflicts: zero, negative and duplicate modes, bad cron and bad owners fail registration")
@system unittest
{
    Scheduler scheduler;
    ScheduledTask task = (ref Context) @safe nothrow @nogc => Error.init;
    assert(scheduler.add("early", Scheduled(null, 10), task).error.code == Status.invalidArgument);
    assert(scheduler.open(0).code == Status.invalidArgument);
    assert(scheduler.open(65_537).code == Status.invalidArgument);
    assert(scheduler.open(4, 0, &clock).code == Status.invalidArgument);
    assert(scheduler.open(4, 5, &clock).code == Status.invalidArgument);
    assert(scheduler.open(4, 2, null).code == Status.invalidArgument);
    assert(scheduler.open(2, 1, &clock).code == Status.ok);
    assert(scheduler.open(2, 1, &clock).code == Status.conflict);
    const Scheduled[] invalid = [
        Scheduled.init, Scheduled(null, 0, 0, true), Scheduled(null, -1), Scheduled(null, 0, -1),
        Scheduled(null, long.min), Scheduled("* * * * * *", 10), Scheduled("* * * * * *", 0, 10),
        Scheduled(null, 10, 10), Scheduled(null, -10, 10)
    ];
    foreach (schedule; invalid)
        assert(scheduler.add("bad", schedule, task).error.code == Status.invalidArgument);
    assert(scheduler.add("cron", Scheduled("0 0 0 * MAR *"), task).error.code == Status.invalidArgument);
    assert(scheduler.add("", Scheduled(null, 10), task).error.code == Status.invalidArgument);
    assert(scheduler.add("null", Scheduled(null, 10), null).error.code == Status.invalidArgument);
    Status foreign;
    auto other = new Thread({
        foreign = scheduler.add("foreign", Scheduled(null, 10), task).error.code;
        if (foreign == Status.invalidArgument)
            foreign = scheduler.poll(0, 0).code;
    });
    other.start();
    other.join();
    assert(foreign == Status.invalidArgument);
    assert(scheduler.add("first", Scheduled(null, 10), task).ok);
    assert(scheduler.add("second", Scheduled(null, 0, 10), task).ok);
    assert(scheduler.add("third", Scheduled(null, 10), task).error.code == Status.resourceExhausted);
    assert(scheduler.poll(0, -1).code == Status.invalidArgument);
    Context context;
    assert(scheduler.close(context).code == Status.ok);
    assert(scheduler.add("closed", Scheduled(null, 10), task).error.code == Status.invalidArgument);
    assert(scheduler.poll(0, 0).code == Status.invalidArgument);
    assert(scheduler.cancel(1).code == Status.invalidArgument);
    assert(scheduler.close(context).code == Status.ok);
}

@("clock_jump: wall time +-24 h and a 60 s monotonic pause deliver once without duplicates or catch-up")
unittest
{
    Scheduler scheduler;
    Context context;
    simulated = 0;
    assert(scheduler.open(8, 2, &clock).code == Status.ok);
    int minute;
    int rate;
    int delay;
    int tiny;
    assert(scheduler.add("minute", Scheduled("0 * * * * *"), (ref Context) @safe nothrow @nogc {
            ++minute;
            return Error.init;
        }).ok);
    assert(scheduler.add("rate", Scheduled(null, 1_000_000_000), (ref Context) @safe nothrow @nogc {
            ++rate;
            return Error.init;
        }).ok);
    assert(scheduler.add("delay", Scheduled(null, 0, 1_000_000_000), (ref Context) @safe nothrow @nogc {
            ++delay;
            return Error.init;
        }).ok);
    assert(scheduler.add("tiny", Scheduled(null, 1), (ref Context) @safe nothrow @nogc {
            ++tiny;
            return Error.init;
        }).ok);
    enum long start = 1_704_067_200;
    enum long second = 1_000_000_000;
    void expect(long wall, long monotonic, int minutes, int rates, int delays, int tinies)
    {
        assert(scheduler.poll(wall, monotonic).code == Status.ok);
        assert(minute == minutes && rate == rates && delay == delays && tiny == tinies);
    }

    expect(start, 0, 0, 0, 0, 0);
    expect(start + 60, second, 1, 1, 1, 1);
    expect(start + 60 - 86_400, second + 1, 1, 1, 1, 2);
    expect(start + 60, second + 2, 1, 1, 1, 3);
    expect(start + 60, second / 2, 1, 1, 1, 3);
    expect(start + 60 + 86_400, second + 3, 2, 1, 1, 4);
    expect(start + 60 + 86_400, 61 * second + 3, 2, 2, 2, 5);
    expect(start + 60 + 86_400, 61 * second + 3, 2, 2, 2, 5);
    expect(start + 120 + 86_400, 62 * second + 3, 3, 3, 3, 6);
    expect(start + 120 + 86_400, 63 * second - 1, 3, 3, 3, 7);
    expect(start + 120 + 86_400, 63 * second, 3, 4, 3, 8);
    expect(start + 120 + 86_400, 63 * second + 3, 3, 4, 4, 9);
    assert(scheduler.close(context).code == Status.ok);
}

@("nonoverlap: concurrent jobs stop at the explicit active limit and fixed delay never overlaps")
@system unittest
{
    Scheduler scheduler;
    int runs;
    int active;
    int peak;
    assert(scheduler.open(4, 2, &clock).code == Status.ok);
    ScheduledTask overlapping = (ref Context) @safe nothrow @nogc {
        ++runs;
        if (++active > peak)
            peak = active;
        suspendFixture();
        --active;
        return Error.init;
    };
    const id = scheduler.add("overlap", Scheduled(null, 10, 0, true), overlapping);
    assert(id.ok && scheduler.poll(0, 0).code == Status.ok);
    auto first = new Fiber({ assert(scheduler.poll(0, 10).code == Status.ok); });
    auto second = new Fiber({ assert(scheduler.poll(0, 20).code == Status.ok); });
    first.call();
    second.call();
    assert(runs == 2 && peak == 2);
    assert(scheduler.poll(0, 30).code == Status.unavailable && runs == 2);
    first.call();
    second.call();
    assert(first.state == Fiber.State.TERM && second.state == Fiber.State.TERM && active == 0);
    assert(scheduler.cancel(id.value).code == Status.ok);
    runs = 0;
    peak = 0;
    const delayed = scheduler.add("delay", Scheduled(null, 0, 10, true), overlapping);
    assert(delayed.ok);
    auto third = new Fiber({ assert(scheduler.poll(0, 40).code == Status.ok); });
    third.call();
    assert(runs == 1);
    assert(scheduler.poll(0, 1_000).code == Status.ok && runs == 1 && peak == 1);
    third.call();
    assert(third.state == Fiber.State.TERM);
    Context context;
    assert(scheduler.close(context).code == Status.ok);
}

@("close cancels admitted children, refuses new work and joins once they retire")
@system unittest
{
    Scheduler scheduler;
    bool observed;
    assert(scheduler.open(2, 1, &clock).code == Status.ok);
    ScheduledTask waiting = (ref Context current) @safe nothrow @nogc {
        suspendFixture();
        observed = current.check().code == Status.cancelled;
        return Error.init;
    };
    assert(scheduler.add("waiting", Scheduled(null, 10), waiting).ok);
    assert(scheduler.poll(0, 0).code == Status.ok);
    auto running = new Fiber({ assert(scheduler.poll(0, 10).code == Status.ok); });
    running.call();
    Context context;
    assert(scheduler.close(context).code == Status.unavailable);
    assert(scheduler.poll(0, 20).code == Status.cancelled);
    assert(scheduler.add("late", Scheduled(null, 10), succeed()).error.code == Status.invalidArgument);
    running.call();
    assert(observed && running.state == Fiber.State.TERM);
    assert(scheduler.close(context).code == Status.ok);
    assert(scheduler.open(1, 1, &clock).code == Status.ok);
    assert(scheduler.close(context).code == Status.ok);
}

private struct Counter
{
    int calls;
    int* mirror;

    @Scheduled(null, 10)
    Error tick(ref Context context) nothrow @nogc
    {
        *mirror = ++calls;
        return context.check();
    }
}

private final class Flaky
{
    int calls;

    @Scheduled(null, 10)
    @Retryable(3, 0, 0)
    Error tick(ref Context) nothrow @nogc
    {
        return ++calls < 3 ? Error(Status.unavailable) : Error.init;
    }
}

private final class Pair
{
    @Scheduled(null, 10)
    Error first(ref Context context) nothrow @nogc
    {
        return context.check();
    }

    @Scheduled(null, 20)
    Error second(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}

@("registration copies struct values, shares struct pointers, wraps @Retryable and rolls back partial failure")
unittest
{
    Context context;
    int* mirror = new int;
    auto value = Counter(0, mirror);
    Scheduler scheduler;
    assert(scheduler.open(4, 1, &clock).code == Status.ok);
    assert(registerScheduled(scheduler, value).code == Status.ok);
    assert(scheduler.poll(0, 0).code == Status.ok && scheduler.poll(0, 10).code == Status.ok);
    assert(*mirror == 1 && value.calls == 0);
    auto shared_ = new Counter(0, mirror);
    assert(registerScheduled(scheduler, shared_).code == Status.ok);
    assert(scheduler.poll(0, 20).code == Status.ok);
    assert(shared_.calls == 1);
    Counter* missing;
    assert(registerScheduled(scheduler, missing).code == Status.invalidArgument);
    Flaky absent;
    assert(registerScheduled(scheduler, absent).code == Status.invalidArgument);
    auto flaky = new Flaky;
    assert(flaky.tick(context).code == Status.unavailable && flaky.calls == 1);
    flaky.calls = 0;
    assert(registerScheduled(scheduler, flaky).code == Status.ok);
    assert(scheduler.poll(0, 30).code == Status.ok && flaky.calls == 3);
    assert(scheduler.close(context).code == Status.ok);

    assert(scheduler.open(1, 1, &clock).code == Status.ok);
    auto pair = new Pair;
    assert(registerScheduled(scheduler, pair).code == Status.resourceExhausted);
    assert(scheduler.add("after rollback", Scheduled(null, 5), succeed()).ok);
    assert(scheduler.close(context).code == Status.ok);
}

@("scheduler_bench: 100k jobs through repeated slots allocate nothing after open and poll stays GC-free")
unittest
{
    enum uint capacity = 1_024;
    enum uint total = 100_000;
    Scheduler scheduler;
    Context context;
    assert(scheduler.open(capacity, 8, &clock).code == Status.ok && scheduler.poll(0, 0).code == Status.ok);
    ulong calls;
    ScheduledTask callback = (ref Context) @safe nothrow @nogc { ++calls; return Error.init; };
    ulong[capacity] tickets;
    long horizon;
    const before = GC.stats.allocatedInCurrentThread;
    for (uint position; position < total;)
    {
        const count = total - position < capacity ? total - position : capacity;
        foreach (index; 0 .. count)
        {
            const added = scheduler.add("bench", Scheduled(null, (index * 751) % capacity + 1), callback);
            assert(added.ok);
            tickets[index] = added.value;
            if (index % 3 == 0)
                assert(scheduler.cancel(added.value).code == Status.ok);
        }
        horizon += 2 * capacity;
        const polled = GC.stats.allocatedInCurrentThread;
        assert(scheduler.poll(0, horizon).code == Status.ok);
        assert(GC.stats.allocatedInCurrentThread == polled);
        foreach (ticket; tickets[0 .. count])
            assert(scheduler.cancel(ticket).code == Status.ok);
        position += count;
    }
    assert(GC.stats.allocatedInCurrentThread == before);
    assert(calls == 66_602);
    assert(scheduler.close(context).code == Status.ok);
}
