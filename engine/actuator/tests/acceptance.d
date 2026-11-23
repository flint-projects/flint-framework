module flint.actuator.acceptance_test;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.actuator : ActuatorOptions, ExportStats, Health, HealthStatus, Registry, TraceContext;
import flint.actuator.metrics : Metrics;
import flint.actuator.otlp : measurements, traces;
import flint.actuator.spans : SpanRecord;
import flint.arena : Buffer, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient, HttpRequest;
import flint.web : Request, Server, ServerOptions;
import std.algorithm.searching : canFind, count, countUntil;
import std.conv : to;
import std.json : parseJSON;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;
import std.string : indexOf, splitLines, toLower;

@safe:

private string decoded(ref scope RequestArena arena, Buffer input)
{
    auto output = new ubyte[input.length];
    assert(arena.read(input, (scope const(ubyte)[] bytes) @safe nothrow @nogc { output[] = bytes; }) == Status.ok);
    return cast(string) output.idup;
}

private long monotonic() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

/// Select an unused loopback port for an in-process listener.
private ushort freePort() @system
{
    auto probe = new TcpSocket();
    scope (exit)
        probe.close();
    probe.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private struct Received
{
    string path;
    string payload;
}

/// Minimal keep-alive OTLP/HTTP receiver that records every request it acknowledges.
private final class Collector
{
    private TcpSocket listener;
    private Thread serving;
    private Mutex lock;
    private Received[] requests;
    private shared bool running = true;
    string traceReply = "{}";
    string metricReply = "{}";
    ushort port;

    this() @system
    {
        lock = new Mutex;
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(4);
        port = (cast(InternetAddress) listener.localAddress).port;
        serving = new Thread(&serve);
        serving.start();
    }

    string endpoint() const
    {
        return "http://127.0.0.1:" ~ port.to!string;
    }

    Received[] snapshot() @system
    {
        lock.lock();
        scope (exit)
            lock.unlock();
        return requests.dup;
    }

    void stop() @system
    {
        atomicStore(running, false);
        auto wake = new TcpSocket();
        try
            wake.connect(new InternetAddress("127.0.0.1", port));
        catch (Exception)
        {
        }
        wake.close();
        serving.join();
        listener.close();
    }

    private void serve() @system
    {
        while (atomicLoad(running))
        {
            Socket connection;
            try
                connection = listener.accept();
            catch (Exception)
                return;
            if (!atomicLoad(running))
            {
                connection.close();
                return;
            }
            connection.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 200.msecs);
            converse(connection);
            connection.close();
        }
    }

    private void converse(Socket connection) @system
    {
        char[] pending;
        char[4096] chunk;
        bool continued;
        while (atomicLoad(running))
        {
            const headerEnd = pending.indexOf("\r\n\r\n");
            if (headerEnd >= 0)
            {
                const head = pending[0 .. headerEnd].idup;
                if (!continued && head.toLower.canFind("expect: 100-continue"))
                {
                    connection.send("HTTP/1.1 100 Continue\r\n\r\n");
                    continued = true;
                }
                size_t length;
                foreach (line; head.splitLines[1 .. $])
                    if (line.toLower.canFind("content-length:"))
                        length = line[line.indexOf(':') + 1 .. $].stripSpaces.to!size_t;
                const total = headerEnd + 4 + length;
                if (pending.length >= total)
                {
                    const requestLine = head.splitLines[0];
                    const path = requestLine[requestLine.indexOf(' ') + 1 .. requestLine.countUntil("HTTP/") - 1];
                    const content = pending[headerEnd + 4 .. total].idup;
                    pending = pending[total .. $].dup;
                    continued = false;
                    lock.lock();
                    requests ~= Received(path, content);
                    lock.unlock();
                    const reply = path == "/v1/traces" ? traceReply : metricReply;
                    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                        ~ reply.length.to!string ~ "\r\n\r\n" ~ reply;
                    connection.send(response);
                    continue;
                }
            }
            const received = connection.receive(chunk[]);
            if (received == 0)
                return;
            if (received < 0)
                continue;
            pending ~= chunk[0 .. received];
        }
    }
}

private string stripSpaces(string value)
{
    while (value.length != 0 && (value[0] == ' ' || value[0] == '\t'))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == ' ' || value[$ - 1] == '\r'))
        value = value[0 .. $ - 1];
    return value;
}

@("metric_cardinality: runtime updates through stale or forged handles never add series")
unittest
{
    Registry first;
    Registry second;
    Context context;
    ActuatorOptions options;
    options.maxMetricSeries = 2;
    assert(first.open(options).code == Status.ok);
    assert(second.open(options).code == Status.ok);
    const ours = first.counter("requests_total", "");
    const theirs = second.counter("foreign_total", "");
    assert(ours.ok && theirs.ok);
    first.add(theirs.value, 9);
    first.add(ours.value, 2);
    assert(first.counter("second_total", "").ok);
    assert(first.counter("third_total", "").error.code == Status.resourceExhausted);
    ubyte[2048] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const report = first.scrape(arena);
    assert(report.ok);
    const text = decoded(arena, report.value);
    assert(text.count("# TYPE ") == 2 && text.canFind("requests_total 2\n") && !text.canFind("foreign_total"));
    auto table = new Metrics(2, 1);
    const id = table.register("only_total", "", null, false);
    assert(id.ok);
    table.add(id.value + 1, 5);
    table.record(id.value, 1.0);
    table.add(0, 5);
    assert(table.count == 1 && table.snapshot(id.value).sample.counter == 0);
    assert(first.close(context).code == Status.ok && second.close(context).code == Status.ok);
}

@("histogram_buckets: 32 bounds accepted, 33 rejected, boundaries inclusive, invalid samples isolated")
unittest
{
    Registry registry;
    Context context;
    assert(registry.open(ActuatorOptions.init).code == Status.ok);
    double[33] bounds;
    foreach (index, ref value; bounds)
        value = index + 1;
    assert(registry.histogram("too_many", bounds[]).error.code == Status.invalidArgument);
    assert(registry.histogram("descending", [2.0, 1.0]).error.code == Status.invalidArgument);
    assert(registry.histogram("infinite", [1.0, double.infinity]).error.code == Status.invalidArgument);
    const wide = registry.histogram("wide", bounds[0 .. 32]);
    assert(wide.ok);
    foreach (value; [-5.0, 1.0, 1.5, 32.0, 32.5, -double.infinity, double.max, double.max])
        registry.record(wide.value, value);
    ubyte[8192] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const report = registry.scrape(arena);
    assert(report.ok);
    const text = decoded(arena, report.value);
    assert(text.canFind("wide_bucket{le=\"1\"} 2\n"));
    assert(text.canFind("wide_bucket{le=\"2\"} 3\n"));
    assert(text.canFind("wide_bucket{le=\"32\"} 4\n"));
    // double.max is finite; the second one overflows the running sum and is counted as invalid.
    assert(text.canFind("wide_bucket{le=\"+Inf\"} 6\n") && text.canFind("wide_count 6\n"));
    assert(text.canFind("wide_invalid_total 2\n"));
    ulong previous;
    size_t buckets;
    foreach (line; text.splitLines)
        if (line.canFind("wide_bucket{"))
        {
            const value = line[line.indexOf("} ") + 2 .. $].to!ulong;
            assert(value >= previous);
            previous = value;
            ++buckets;
        }
    assert(buckets == 33);
    assert(registry.close(context).code == Status.ok);
}

private bool fetch(ref HttpClient client, string url, ushort status, string expected)
{
    ubyte[8192] storage;
    scope RequestArena arena = RequestArena(storage[]);
    auto context = Context.init.withDeadline(Deadline.afterMillis(2000));
    HttpRequest request;
    request.url = url;
    const response = client.send(request, arena, context);
    if (!response.ok || response.value.status != status)
        return false;
    return decoded(arena, response.value.body).canFind(expected);
}

private shared bool databaseUp = true;
private shared bool allowManagement = true;

@("health_semantics: outage fails readiness only; draining fails readiness while the listener serves")
@system unittest
{
    Registry registry;
    ActuatorOptions options;
    options.authorize = (ref scope Request request) @safe nothrow @nogc => atomicLoad(allowManagement);
    assert(registry.open(options).code == Status.ok);
    assert(registry.health("database", () @safe nothrow @nogc => Health(atomicLoad(databaseUp)
            ? HealthStatus.up : HealthStatus.down, "private-database")).code == Status.ok);
    const port = freePort();
    ServerOptions limits;
    limits.port = port;
    limits.maxConnectionsPerCore = 4;
    Server listener;
    const started = listener.start(limits);
    assert(started.code == Status.ok, started.message);
    scope (exit)
        listener.shutdown(Deadline.afterMillis(1000).monotonicNanoseconds);
    assert(registry.attach(listener).code == Status.ok);
    auto polling = Context.init.withDeadline(Deadline.afterMillis(5000));
    assert(listener.poll(polling).code == Status.ok);
    HttpClient client;
    assert(client.open(ClientOptions.init).code == Status.ok);
    scope (exit)
        client.close();
    const prefix = "http://127.0.0.1:" ~ port.to!string ~ "/actuator";
    assert(fetch(client, prefix ~ "/health/live", 200, `{"status":"UP"}`));
    assert(fetch(client, prefix ~ "/health/ready", 200, `{"status":"UP"}`));
    atomicStore(databaseUp, false);
    assert(fetch(client, prefix ~ "/health/ready", 503, `{"status":"DOWN"}`));
    assert(fetch(client, prefix ~ "/health/live", 200, `{"status":"UP"}`));
    const ready = fetch(client, prefix ~ "/health/ready", 503, `{"status":"DOWN"}`);
    assert(ready && !fetch(client, prefix ~ "/health/ready", 503, "private-database"));
    atomicStore(allowManagement, false);
    assert(fetch(client, prefix ~ "/metrics", 403, "FORBIDDEN"));
    atomicStore(allowManagement, true);
    atomicStore(databaseUp, true);
    assert(fetch(client, prefix ~ "/health/ready", 200, `{"status":"UP"}`));
    Context closing;
    assert(registry.close(closing).code == Status.ok);
    assert(fetch(client, prefix ~ "/health/ready", 503, `{"status":"DOWN"}`));
    assert(fetch(client, prefix ~ "/health/live", 200, `{"status":"UP"}`));
}

@("health_semantics: a shared listener without an authorization policy is refused")
@system unittest
{
    Registry registry;
    assert(registry.open(ActuatorOptions.init).code == Status.ok);
    ServerOptions limits;
    limits.address = "0.0.0.0";
    limits.port = freePort();
    limits.maxConnectionsPerCore = 4;
    Server listener;
    assert(listener.start(limits).code == Status.ok);
    scope (exit)
        listener.shutdown(Deadline.afterMillis(1000).monotonicNanoseconds);
    assert(registry.attach(listener).code == Status.permissionDenied);
    Context closing;
    assert(registry.close(closing).code == Status.ok);
}

@("otlp_json: trace and metric bodies match the checked protobuf-JSON fixtures byte for byte")
@system unittest
{
    SpanRecord row;
    row.name[0 .. 9] = "GET \"/x\"\n";
    row.bytes = 9;
    foreach (index, ref value; row.context.traceId)
        value = cast(ubyte)(0xa0 + index);
    foreach (index, ref value; row.context.spanId)
        value = cast(ubyte)(0x10 + index);
    row.context.flags = 1;
    row.start = 5;
    row.finish = 25;
    SpanRecord child = row;
    child.parent = row.context.spanId;
    child.context.spanId[7] = 0xff;
    child.failed = true;
    ubyte[8192] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const traceBody = traces([row, child], "svc", 1_700_000_000_000_000_000, arena);
    assert(traceBody.ok);
    enum expectedTraces = `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":`
        ~ `{"stringValue":"svc"}}]},"scopeSpans":[{"scope":{"name":"flint.actuator"},"spans":[`
        ~ `{"traceId":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","spanId":"1011121314151617","name":"GET \"/x\"\n",`
        ~ `"kind":1,"startTimeUnixNano":"1700000000000000005","endTimeUnixNano":"1700000000000000025",`
        ~ `"flags":1,"status":{"code":1}},`
        ~ `{"traceId":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","spanId":"10111213141516ff",`
        ~ `"parentSpanId":"1011121314151617","name":"GET \"/x\"\n","kind":1,`
        ~ `"startTimeUnixNano":"1700000000000000005","endTimeUnixNano":"1700000000000000025",`
        ~ `"flags":1,"status":{"code":2}}]}]}]}`;
    assert(decoded(arena, traceBody.value) == expectedTraces);

    auto table = new Metrics(2, 1);
    const counter = table.register("jobs_total", "Jobs \"run\"", null, false);
    const histogram = table.register("latency", "", [0.25, 1.5], true);
    assert(counter.ok && histogram.ok);
    table.add(counter.value, 7);
    foreach (value; [0.25, 1.0, 9.0, double.nan])
        table.record(histogram.value, value);
    const metricBody = measurements(table, 1, 2, "svc", 100, 200, arena);
    assert(metricBody.ok);
    enum expectedMetrics = `{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":`
        ~ `{"stringValue":"svc"}}]},"scopeMetrics":[{"scope":{"name":"flint.actuator"},"metrics":[`
        ~ `{"name":"jobs_total","description":"Jobs \"run\"","sum":{"aggregationTemporality":2,`
        ~ `"isMonotonic":true,"dataPoints":[{"startTimeUnixNano":"100","timeUnixNano":"200","asInt":"7"}]}},`
        ~ `{"name":"latency","histogram":{"aggregationTemporality":2,"dataPoints":[{"startTimeUnixNano":"100",`
        ~ `"timeUnixNano":"200","count":"3","sum":10.25,"explicitBounds":[0.25,1.5],`
        ~ `"bucketCounts":["1","1","1"]}]}}]}]}]}`;
    assert(decoded(arena, metricBody.value) == expectedMetrics);
    parseJSON(expectedTraces);
    parseJSON(expectedMetrics);
}

@("span ring: overflow and retirement are counted, overlong names are rejected")
unittest
{
    Registry registry;
    ActuatorOptions options;
    options.maxSpansQueued = 1;
    options.maxBatchSpans = 1;
    Context context;
    assert(registry.open(options).code == Status.ok);
    char[129] longName = 'n';
    assert(registry.beginSpan(longName[].idup, TraceContext.init, 1).error.code == Status.invalidArgument);
    assert(registry.beginSpan(longName[0 .. 128].idup, TraceContext.init, 1).ok);
    const dropped = registry.beginSpan("dropped", TraceContext.init, 2);
    assert(dropped.ok && registry.exportStats().dropped == 1);
    ubyte[1024] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const report = registry.scrape(arena);
    assert(report.ok && decoded(arena, report.value).canFind("flint_spans_dropped_total 1\n"));
    assert(registry.close(context).code == Status.ok);
    assert(registry.exportStats().dropped == 2);
    assert(registry.beginSpan("closed", TraceContext.init, 3).error.code == Status.unavailable);
}

@("export_overload: an offline collector keeps the ring bounded, counts drops and never fails requests")
@system unittest
{
    Registry registry;
    ActuatorOptions options;
    options.otlpEndpoint = "http://127.0.0.1:" ~ freePort().to!string;
    options.maxSpansQueued = 32;
    options.maxBatchSpans = 8;
    options.exportIntervalNanos = 50_000_000;
    assert(registry.open(options).code == Status.ok);
    ExportStats peak;
    foreach (index; 0 .. 400)
    {
        const start = monotonic();
        auto span = registry.beginSpan("offline", TraceContext.init, start);
        assert(span.ok);
        assert(span.value.finish(start + 1, false).code == Status.ok);
        const stats = registry.exportStats();
        assert(stats.pending <= 32);
        if (stats.pending > peak.pending)
            peak = stats;
        if (index % 50 == 0)
            Thread.sleep(20.msecs);
    }
    auto flush = Context.init.withDeadline(Deadline.afterMillis(3000));
    const forced = registry.exportBatch(flush);
    assert(forced.code != Status.ok);
    const stats = registry.exportStats();
    assert(peak.pending == 32 && stats.dropped >= 400 - 32 && stats.rejected == 0);
    auto shutdown = Context.init.withDeadline(Deadline.afterMillis(3000));
    // The final flush cannot reach the collector; the registry still retires and discards its ring.
    registry.close(shutdown);
    assert(registry.exportStats().pending == 0);
    assert(registry.close(shutdown).code == Status.ok);
}

@("otlp_export: one export round covers every registered series and full span batches leave early")
@system unittest
{
    auto collector = new Collector;
    scope (exit)
        collector.stop();
    collector.metricReply = `{"partialSuccess":{"rejectedDataPoints":"1"}}`;
    collector.traceReply = `{"partialSuccess":{"rejectedSpans":2}}`;
    Registry registry;
    ActuatorOptions options;
    options.otlpEndpoint = collector.endpoint;
    options.serviceName = "acceptance";
    options.maxBatchSpans = 4;
    options.maxSpansQueued = 16;
    options.exportIntervalNanos = 3600L * 1_000_000_000L;
    assert(registry.open(options).code == Status.ok);
    enum series = 70;
    foreach (index; 0 .. series)
    {
        const counter = registry.counter("acceptance_" ~ index.to!string ~ "_total", "");
        assert(counter.ok);
        registry.add(counter.value, index + 1);
    }
    foreach (_; 0 .. 4)
    {
        auto span = registry.beginSpan("batched", TraceContext.init, monotonic());
        assert(span.ok && span.value.finish(monotonic(), false).code == Status.ok);
    }
    // A full batch is sent well before the one-hour periodic interval.
    foreach (_; 0 .. 300)
    {
        if (collector.snapshot().canFind!(r => r.path == "/v1/traces"))
            break;
        Thread.sleep(10.msecs);
    }
    assert(collector.snapshot().canFind!(r => r.path == "/v1/traces"));
    auto context = Context.init.withDeadline(Deadline.afterMillis(5000));
    assert(registry.exportBatch(context).code == Status.ok);
    bool[series] seen;
    size_t metricRequests;
    foreach (request; collector.snapshot())
    {
        if (request.path != "/v1/metrics")
            continue;
        ++metricRequests;
        const document = parseJSON(request.payload);
        foreach (metric; document["resourceMetrics"].array[0]["scopeMetrics"].array[0]["metrics"].array)
        {
            const name = metric["name"].str;
            const index = name["acceptance_".length .. $ - "_total".length].to!size_t;
            assert(metric["sum"]["dataPoints"].array[0]["asInt"].str == (index + 1).to!string);
            seen[index] = true;
        }
    }
    foreach (index, value; seen)
        assert(value, "series " ~ index.to!string ~ " missing from the export round");
    assert(metricRequests >= 3);
    assert(registry.exportStats().rejected == 2 + metricRequests);
    Context closing;
    assert(registry.close(closing).code == Status.ok);
}

@("otlp_export: a partial span batch leaves on the periodic interval without an explicit flush")
@system unittest
{
    auto collector = new Collector;
    scope (exit)
        collector.stop();
    Registry registry;
    ActuatorOptions options;
    options.otlpEndpoint = collector.endpoint;
    options.exportIntervalNanos = 200_000_000;
    assert(registry.open(options).code == Status.ok);
    const started = monotonic();
    auto span = registry.beginSpan("periodic", TraceContext.init, started);
    assert(span.ok && span.value.finish(started + 1, false).code == Status.ok);
    foreach (_; 0 .. 300)
    {
        if (registry.exportStats().pending == 0)
            break;
        Thread.sleep(10.msecs);
    }
    assert(registry.exportStats().pending == 0 && registry.exportStats().dropped == 0);
    const sent = collector.snapshot();
    assert(sent.length == 1 && sent[0].path == "/v1/traces");
    const document = parseJSON(sent[0].payload);
    assert(document["resourceSpans"].array[0]["scopeSpans"].array[0]["spans"].array[0]["name"].str == "periodic");
    Context closing;
    assert(registry.close(closing).code == Status.ok);
}
