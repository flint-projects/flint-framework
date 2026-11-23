module app;

import core.memory : GC;
import flint.arena : Error, Status;
import flint.conc : Context;
import flint.engine.schedule : Scheduled, ScheduledTask, Scheduler;
import schedule_probe : Outcome, batchSize, cancelled, jobsPerTrial, nextBatch, show;

@safe:

private long clock() pure nothrow @nogc
{
    return 0;
}

private Outcome run()
{
    Scheduler scheduler;
    if (scheduler.open(batchSize, 8, &clock).code != Status.ok || scheduler.poll(0, 0).code != Status.ok)
        return Outcome.init;
    Context context;
    scope (exit)
        scheduler.close(context);
    Outcome result;
    ScheduledTask callback = (ref Context) @safe nothrow @nogc { result.invoke(); return Error.init; };
    ulong[batchSize] tickets;
    long horizon;
    for (uint position; position < jobsPerTrial;)
    {
        const count = nextBatch(position);
        foreach (index; 0 .. count)
        {
            const period = ((index * 751) % batchSize) + 1;
            const added = scheduler.add("probe", Scheduled(null, period), callback);
            if (!added.ok)
                return Outcome.init;
            tickets[index] = added.value;
            if (cancelled(index) && scheduler.cancel(added.value).code != Status.ok)
                return Outcome.init;
        }
        horizon += 2 * batchSize;
        const before = GC.stats.allocatedInCurrentThread;
        if (scheduler.poll(0, horizon).code != Status.ok || GC.stats.allocatedInCurrentThread != before)
            return Outcome.init;
        foreach (ticket; tickets[0 .. count])
        {
            if (scheduler.cancel(ticket).code != Status.ok)
                return Outcome.init;
        }
        position += count;
    }
    return result;
}

int main()
{
    return show(() => run());
}
