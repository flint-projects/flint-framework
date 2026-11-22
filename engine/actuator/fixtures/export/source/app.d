module app;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.actuator : ActuatorOptions, Health, HealthStatus, Registry, TraceContext;
import flint.arena : Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient, HttpRequest;
import flint.web : Server, ServerOptions;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.stdio : writeln;
import trace_fibers : verifyTraces;

@safe:

private shared bool healthy = true;

private void require(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

private void check(Error status)
{
    require(status.code == Status.ok, status.message);
}

private void fetch(ref HttpClient client, string endpoint, ushort status, string expected)
{
    ubyte[8192] storage;
    scope RequestArena arena = RequestArena(storage[]);
    auto context = Context.init.withDeadline(Deadline.afterMillis(1000));
    HttpRequest request;
    request.url = endpoint;
    const response = client.send(request, arena, context);
    check(response.error);
    require(response.value.status == status, "management status differs");
    bool contains;
    require(arena.read(response.value.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            contains = (cast(const(char)[]) bytes).canFind(expected);
        }) == Status.ok && contains, "management response body differs");
}

private void observe(ref Registry registry)
{
    const requests = registry.counter("actuator_fixture_requests_total", "fixture counter");
    check(requests.error);
    registry.add(requests.value, 7);
    const histogram = registry.histogram("actuator_fixture_latency", [0.25, 1.0]);
    check(histogram.error);
    registry.record(histogram.value, 0.5);
    auto task = registry.beginSpan("actuator-fixture-span", TraceContext.init,
            Deadline.afterMillis(0).monotonicNanoseconds);
    check(task.error);
    check(task.value.finish(Deadline.afterMillis(0).monotonicNanoseconds, false));
}

private void offline(ref Registry registry, ref HttpClient client, string live, uint seconds)
{
    const finish = Deadline.afterMillis(cast(ulong) seconds * 1000).monotonicNanoseconds;
    long nextRequest;
    long slowest;
    uint peak;
    uint requests;
    ulong attempted;
    while (Deadline.afterMillis(0).monotonicNanoseconds < finish)
    {
        foreach (_; 0 .. 256)
        {
            const start = Deadline.afterMillis(0).monotonicNanoseconds;
            auto task = registry.beginSpan("offline-request", TraceContext.init, start);
            check(task.error);
            check(task.value.finish(Deadline.afterMillis(0).monotonicNanoseconds, false));
            ++attempted;
        }
        const snapshot = registry.exportStats();
        require(snapshot.pending <= 8192, "export queue exceeded configured capacity");
        if (snapshot.pending > peak)
            peak = snapshot.pending;
        const before = Deadline.afterMillis(0).monotonicNanoseconds;
        if (before >= nextRequest)
        {
            fetch(client, live, 200, `{"status":"UP"}`);
            const duration = Deadline.afterMillis(0).monotonicNanoseconds - before;
            if (duration > slowest)
                slowest = duration;
            nextRequest = Deadline.afterMillis(1000).monotonicNanoseconds;
            ++requests;
        }
        Thread.sleep(10.msecs);
    }
    const drops = registry.exportStats().dropped;
    require(peak == 8192 && drops > 8192, "offline traffic did not exercise the overload policy");
    require(requests >= seconds / 2, "management requests failed to sustain the offline cadence");
    writeln("offline_seconds=", seconds, " spans_attempted=", attempted, " pending_peak=", peak,
            " dropped=", drops, " live_requests=", requests, " max_live_ns=", slowest);
}

private void checkAcknowledgements(ref Registry registry, ref Context context, bool retry)
{
    if (retry)
    {
        const jobs = registry.counter("actuator_fixture_jobs_total", "fixture worker count");
        check(jobs.error);
        registry.add(jobs.value, 4);
        foreach (_; 0 .. 2)
        {
            auto span = registry.beginSpan("acknowledgement-span", TraceContext.init,
                    Deadline.afterMillis(0).monotonicNanoseconds);
            check(span.error);
            check(span.value.finish(Deadline.afterMillis(0).monotonicNanoseconds, false));
        }
    }
    const first = registry.exportBatch(context);
    if (!retry)
    {
        require(first.code == Status.ioError, "invalid collector acknowledgement was accepted");
        require(registry.exportStats().rejected == 0, "invalid acknowledgement affected the rejection count");
        return;
    }
    require(first.code == Status.unavailable, "retryable collector response did not preserve the batch");
    while (registry.exportStats().pending != 0)
    {
        check(context.check());
        Thread.sleep(100.msecs);
    }
    require(registry.exportStats().rejected == 5, "partial success rejection count differs");
}

int main(string[] arguments)
{
    if (arguments.length == 2 && arguments[1] == "traces")
        return verifyTraces();
    if (arguments.length < 3 || arguments.length > 4)
        return 2;
    auto context = Context.init.withDeadline(Deadline.afterMillis(8_000));
    ActuatorOptions options;
    options.otlpEndpoint = arguments[1];
    options.serviceName = "flint-actuator-fixture";
    Registry registry;
    check(registry.open(options));
    scope (exit)
        registry.close(context);
    observe(registry);
    check(registry.health("database", () @safe nothrow @nogc => Health(atomicLoad(healthy)
            ? HealthStatus.up : HealthStatus.down, "private-database")));

    ServerOptions limits;
    limits.port = arguments[2].to!ushort;
    limits.maxConnectionsPerCore = 4;
    Server listener;
    check(listener.start(limits));
    scope (exit)
        listener.shutdown(Deadline.afterMillis(1000).monotonicNanoseconds);
    check(registry.attach(listener));
    check(listener.poll(context));
    HttpClient client;
    check(client.open(ClientOptions.init));
    scope (exit)
        client.close();
    const prefix = "http://127.0.0.1:" ~ arguments[2] ~ "/actuator";
    if (arguments.length == 4)
    {
        switch (arguments[3])
        {
        case "retry":
        case "invalid-ack":
            checkAcknowledgements(registry, context, arguments[3] == "retry");
            break;
        default:
            offline(registry, client, prefix ~ "/health/live", arguments[3].to!uint);
            break;
        }
        auto shutdown = Context.init.withDeadline(Deadline.afterMillis(1000));
        const closed = registry.close(shutdown);
        require(closed.code == Status.ok || closed.code == Status.unavailable, "offline registry did not retire");
        require(registry.exportStats().pending == 0, "retired exporter retained queued spans");
        check(registry.close(shutdown));
        return 0;
    }
    fetch(client, prefix ~ "/health/live", 200, `{"status":"UP"}`);
    fetch(client, prefix ~ "/health/ready", 200, `{"status":"UP"}`);
    atomicStore(healthy, false);
    fetch(client, prefix ~ "/health/ready", 503, `{"status":"DOWN"}`);
    fetch(client, prefix ~ "/health/live", 200, `{"status":"UP"}`);
    fetch(client, prefix ~ "/metrics", 200, "actuator_fixture_requests_total 7\n");
    check(registry.exportBatch(context));
    check(registry.close(context));
    atomicStore(healthy, true);
    fetch(client, prefix ~ "/health/ready", 503, `{"status":"DOWN"}`);
    writeln("Management responses and collector acknowledgement passed.");
    return 0;
}
