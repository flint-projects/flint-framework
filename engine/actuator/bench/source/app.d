module app;

import flint.actuator : ActuatorOptions, Counter, Histogram, Registry;
import flint.arena : RequestArena, Status;
import flint.conc : Context;
import observe_probe : measure;
import std.algorithm.searching : canFind;
import std.conv : to;
import transport_probe : checkManagementTransport;

@safe:

private final class Observations
{
    Registry registry;
    Counter counter;
    Histogram histogram;

    bool initialize(uint cores)
    {
        ActuatorOptions options;
        options.cores = cores;
        if (registry.openLocal(options).code != Status.ok)
            return false;
        const ticks = registry.counter("updates_total", "observed updates");
        const sample = registry.histogram("observations", [1.0, 2.0, 4.0]);
        if (!ticks.ok || !sample.ok)
            return false;
        counter = ticks.value;
        histogram = sample.value;
        return true;
    }

    void record(uint) nothrow @nogc
    {
        registry.add(counter);
        registry.record(histogram, 2.0);
    }

    bool verify(ulong expected)
    {
        const count = expected.to!string;
        const total = (2 * expected).to!string;
        const bucket = "observations_bucket{le=\"2\"} " ~ count ~ "\n";
        const sum = "observations_sum " ~ total ~ "\n";
        const ticks = "updates_total " ~ count ~ "\n";
        ubyte[4096] bytes;
        scope RequestArena arena = RequestArena(bytes[]);
        const report = registry.scrape(arena);
        if (!report.ok)
            return false;
        bool valid;
        const status = arena.read(report.value, (scope const(ubyte)[] data) @safe nothrow @nogc {
            const text = cast(const(char)[]) data;
            valid = text.canFind(bucket) && text.canFind(sum) && text.canFind(ticks);
        });
        Context closing;
        return status == Status.ok && valid && registry.close(closing).code == Status.ok;
    }
}

@system int main()
{
    if (!checkManagementTransport())
        return 1;
    foreach (cores; [1U, 8U, 32U])
    {
        auto workload = new Observations;
        if (!workload.initialize(cores) || !measure(cores, &workload.record, &workload.verify))
            return 2;
    }
    return 0;
}
