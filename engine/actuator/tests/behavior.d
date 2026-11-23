module flint.engine.actuator.behavior_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.engine.actuator : ActuatorOptions, Health, HealthStatus, Registry, TraceContext;
import flint.engine.actuator.exporter : retryAfter;
import flint.engine.actuator.metrics : Metrics;
import flint.engine.actuator.otlp : acknowledged, measurements, traces;
import flint.engine.actuator.spans : SpanRecord;
import flint.arena : Buffer, RequestArena, Status;
import flint.conc : Context, Deadline;
import std.algorithm.searching : canFind, startsWith;
import std.conv : to;
import std.json : parseJSON;
import std.string : lastIndexOf, splitLines;

@safe:

private string decoded(ref scope RequestArena arena, Buffer input)
{
    auto output = new ubyte[input.length];
    assert(arena.read(input, (scope const(ubyte)[] bytes) @safe nothrow @nogc { output[] = bytes; }) == Status.ok);
    return cast(string) output.idup;
}

@("metric series reject conflicting names, invalid bounds, and cardinality overflow")
unittest
{
    // Keep the startup registry rooted throughout the allocation-heavy registration loop.
    static Registry registry;
    scope (exit)
        registry = Registry.init;
    Context context;
    assert(registry.open(ActuatorOptions.init).code == Status.ok);
    assert(registry.histogram("duration", [0.5, 1.0]).ok);
    assert(registry.counter("duration_count", "").error.code == Status.conflict);
    assert(registry.counter("flint_spans_dropped_total", "").error.code == Status.conflict);
    assert(registry.counter("unsafe_help", "control\x00").error.code == Status.invalidArgument);
    assert(registry.histogram("repeated", [1.0, 1.0]).error.code == Status.invalidArgument);
    assert(registry.histogram("bad", [double.nan]).error.code == Status.invalidArgument);
    foreach (index; 1 .. 4096)
        assert(registry.counter("counter_" ~ index.to!string, "").ok);
    assert(registry.counter("overflow", "").error.code == Status.resourceExhausted);
    assert(registry.close(context).code == Status.ok);
}

private final class ScrapeRace
{
    Registry registry;
    shared bool running = true;
    shared bool active;

    void write()
    {
        const histogram = registry.histogram("race_window", [1.0, 2.0]);
        assert(histogram.ok);
        registry.record(histogram.value, 0.5);
        atomicStore(active, true);
        while (atomicLoad(running))
        {
            registry.record(histogram.value, 0.5);
            registry.record(histogram.value, 1.5);
            registry.record(histogram.value, 3.0);
        }
    }
}

@("scrape emits complete cumulative bucket sets while a producer updates them")
@system unittest
{
    auto race = new ScrapeRace;
    assert(race.registry.open(ActuatorOptions.init).code == Status.ok);
    auto writer = new Thread(&race.write);
    writer.start();
    scope (exit)
    {
        atomicStore(race.running, false);
        writer.join();
        Context context;
        assert(race.registry.close(context).code == Status.ok);
    }
    while (!atomicLoad(race.active))
        Thread.sleep(1.msecs);
    uint observed;
    foreach (_; 0 .. 2000)
    {
        ubyte[4096] storage;
        scope RequestArena arena = RequestArena(storage[]);
        const report = race.registry.scrape(arena);
        assert(report.ok);
        ulong[3] counts;
        size_t count;
        foreach (line; decoded(arena, report.value).splitLines)
        {
            if (line.startsWith("race_window_bucket{"))
            {
                assert(count < counts.length);
                const value = line.lastIndexOf(' ') + 1;
                counts[count++] = line[value .. $].to!ulong;
            }
            enum countPrefix = "race_window_count ";
            if (line.startsWith(countPrefix))
            {
                assert(count == 3 && counts[2] == line[countPrefix.length .. $].to!ulong);
                assert(counts[0] <= counts[1] && counts[1] <= counts[2]);
                observed += counts[2] != 0;
            }
        }
    }
    assert(observed != 0);
}

@("Prometheus snapshots merge cumulative buckets and separate invalid values")
unittest
{
    Registry registry;
    Context context;
    assert(registry.open(ActuatorOptions.init).code == Status.ok);
    const counter = registry.counter("requests_total", "One\\two\nthree");
    const histogram = registry.histogram("delay", [0.5, 1.0]);
    assert(counter.ok && histogram.ok);
    registry.add(counter.value, 3);
    foreach (value; [0.25, 0.5, 1.0, 1.25, double.nan, double.infinity])
        registry.record(histogram.value, value);
    ubyte[2048] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const snapshot = registry.scrape(arena);
    assert(snapshot.ok);
    const observed = decoded(arena, snapshot.value);
    assert(observed.canFind("# HELP requests_total One\\\\two\\nthree\n"));
    assert(observed.canFind("requests_total 3\n"));
    assert(observed.canFind("delay_bucket{le=\"0.5\"} 2\n"));
    assert(observed.canFind("delay_bucket{le=\"1\"} 3\n"));
    assert(observed.canFind("delay_bucket{le=\"+Inf\"} 4\n"));
    assert(observed.canFind("delay_sum 3\n") && observed.canFind("delay_count 4\n"));
    assert(observed.canFind("delay_invalid_total 2\n"));
    assert(registry.close(context).code == Status.ok);
}

@("readiness hides failed dependency details and guards recursive probes")
unittest
{
    Registry registry;
    Context context;
    bool available = true;
    assert(registry.open(ActuatorOptions.init).code == Status.ok);
    assert(registry.health("database", () @safe nothrow @nogc => Health(available ? HealthStatus.up
            : HealthStatus.down, "db.internal")).code == Status.ok);
    assert(registry.ready());
    available = false;
    assert(!registry.ready());
    available = true;
    auto check = registry;
    assert(registry.health("recursion", () @safe nothrow @nogc => Health(check.ready()
            ? HealthStatus.up : HealthStatus.down, "internal")).code == Status.ok);
    assert(!registry.ready());
    assert(registry.close(context).code == Status.ok);
    assert(!registry.ready());
}

@("span identities preserve parent correlation and overflow leaves an inert handle")
unittest
{
    Registry registry;
    ActuatorOptions options;
    options.maxSpansQueued = 2;
    options.maxBatchSpans = 2;
    Context context;
    assert(registry.open(options).code == Status.ok);
    const time = Deadline.afterMillis(0).monotonicNanoseconds;
    const root = registry.beginSpan("root", TraceContext.init, time);
    assert(root.ok, root.error.message);
    assert(root.value.context.traceId != TraceContext.init.traceId);
    auto child = registry.beginSpan("child", root.value.context, time + 1);
    assert(child.ok && child.value.context.traceId == root.value.context.traceId);
    assert(child.value.context.spanId != root.value.context.spanId);
    assert(child.value.finish(time, false).code == Status.invalidArgument);
    assert(child.value.finish(time + 2, false).code == Status.ok);
    assert(child.value.finish(time + 2, false).code == Status.notFound);
    auto inert = registry.beginSpan("overflow", root.value.context, time + 3);
    assert(inert.ok && inert.value.finish(time + 4, true).code == Status.ok);
    assert(registry.close(context).code == Status.ok);
}

@("OTLP JSON encodes identifiers and timestamps and counts explicit partial acknowledgements")
@system unittest
{
    SpanRecord row;
    row.name[0 .. 4] = "work";
    row.bytes = 4;
    row.context.traceId[15] = 1;
    row.context.spanId[7] = 2;
    row.parent[7] = 3;
    row.start = 4;
    row.finish = 11;
    row.failed = true;
    ubyte[4096] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const traceBody = traces([row], "fixture", 1_000_000_000, arena);
    assert(traceBody.ok);
    const document = parseJSON(decoded(arena, traceBody.value));
    const trace = document["resourceSpans"].array[0]["scopeSpans"].array[0]["spans"].array[0];
    assert(trace["traceId"].str == "00000000000000000000000000000001");
    assert(trace["spanId"].str == "0000000000000002" && trace["parentSpanId"].str == "0000000000000003");
    assert(trace["startTimeUnixNano"].str == "1000000004" && trace["status"]["code"].integer == 2);
    auto metrics = new Metrics(1, 1);
    const inserted = metrics.register("total", "", null, false);
    assert(inserted.ok);
    metrics.add(inserted.value, 5);
    const metricBody = measurements(metrics, 1, 1, "fixture", 100, 200, arena);
    assert(metricBody.ok);
    const points = parseJSON(decoded(arena, metricBody.value));
    const metric = points["resourceMetrics"].array[0]["scopeMetrics"].array[0]["metrics"].array[0];
    assert(metric["sum"]["dataPoints"].array[0]["asInt"].str == "5");
    const partial = acknowledged(cast(const(ubyte)[]) `{"partialSuccess":{"rejectedSpans":"2"}}`, true);
    assert(partial.ok && partial.value == 2);
    const numeric = acknowledged(cast(const(ubyte)[]) `{"partialSuccess":{"rejectedDataPoints":7}}`, false);
    assert(numeric.ok && numeric.value == 7);
    assert(acknowledged(cast(const(ubyte)[]) `{}`, true).ok);
    assert(!acknowledged(cast(const(ubyte)[]) `{"partialSuccess":{"rejectedSpans":""}}`, true).ok);
    assert(!acknowledged(cast(const(ubyte)[]) `not-json`, false).ok);
    assert(retryAfter("HTTP/1.1 503\r\nRetry-After: 31\r\n", 0) == 31_000_000_000);
    assert(retryAfter("retry-after: Thu, 01 Jan 1970 00:00:19 GMT\r\n", 15_000_000_000) == 4_000_000_000);
}
