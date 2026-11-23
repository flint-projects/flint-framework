module flint.engine.actuator;

import core.atomic : atomicLoad, atomicStore, cas;
import core.sync.mutex : Mutex;
import flint.engine.actuator.exporter : Exporter, pause;
import flint.engine.actuator.metrics : Metrics, validName;
import flint.engine.actuator.prometheus : render;
import flint.engine.actuator.spans : Spans;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.serde : encodeJson;
import flint.engine.web : Method, Request, RequestContext, Response, RouteRegistration, Server;

public import flint.engine.actuator.spans : Span;
public import flint.engine.actuator.types : ActuatorOptions, Counter, ExportStats, Health,
    HealthProbe, HealthStatus, Histogram, ManagementPolicy, TraceContext;

@safe:

private shared ulong lastOwner;
private bool checkingHealth;

private ulong nextOwner() nothrow @nogc
{
    auto previous = atomicLoad(lastOwner);
    while (previous < ulong.max)
    {
        if (cas(&lastOwner, previous, previous + 1))
            return previous + 1;
        previous = atomicLoad(lastOwner);
    }
    return 0;
}

/// Bounded metric, readiness, and tracing registry.
struct Registry
{
    private Runtime control;

    /// Prepare startup tables and optionally launch the OTLP exporter.
    Error open(ActuatorOptions options)
    {
        if (options.otlpEndpoint.length == 0)
            return openLocal(options);
        auto prepared = prepare(options);
        if (!prepared.ok)
            return prepared.error;
        auto runtime = prepared.value;
        runtime.exporter = new Exporter(options, runtime.metrics, runtime.spans);
        const started = runtime.exporter.start();
        if (started.code != Status.ok)
            return started;
        control = runtime;
        return Error.init;
    }

    /// Prepare local metrics, health and span recording without selecting the OTLP transport.
    Error openLocal(ActuatorOptions options)
    {
        if (options.otlpEndpoint.length != 0)
            return Error(Status.invalidArgument, "local registry does not accept an OTLP endpoint");
        auto prepared = prepare(options);
        if (prepared.ok)
            control = prepared.value;
        return prepared.error;
    }

    private Result!Runtime prepare(ActuatorOptions options)
    {
        if (control !is null && !control.retired)
            return Result!Runtime(null, Error(Status.conflict, "actuator already open"));
        if (!validOptions(options))
            return Result!Runtime(null, Error(Status.invalidArgument, "invalid management options"));
        const identity = nextOwner();
        if (identity == 0)
            return Result!Runtime(null, Error(Status.resourceExhausted, "actuator identities exhausted"));
        return Result!Runtime(new Runtime(identity, options));
    }

    /// Register a named monotone counter.
    Result!Counter counter(string name, string help)
    {
        if (control is null || control.draining)
            return Result!Counter(Counter.init, inactive());
        if (!validText(help))
            return Result!Counter(Counter.init, Error(Status.invalidArgument, "metric description is invalid"));
        const added = control.metrics.register(name, help, null, false);
        return Result!Counter(Counter(added.value, control.identity), added.error);
    }

    /// Register ordered finite histogram boundaries before recording observations.
    Result!Histogram histogram(string name, scope const(double)[] bounds)
    {
        if (control is null || control.draining)
            return Result!Histogram(Histogram.init, inactive());
        const added = control.metrics.register(name, null, bounds, true);
        return Result!Histogram(Histogram(added.value, control.identity), added.error);
    }

    /// Record a counter update in the owning core's cell.
    void add(Counter counter, ulong delta = 1) nothrow @nogc
    {
        if (control !is null && counter.owner == control.identity)
            control.metrics.add(counter.id, delta);
    }

    /// Record a finite observation or increment the invalid-input count.
    void record(Histogram histogram, double value) nothrow @nogc
    {
        if (control !is null && histogram.owner == control.identity)
            control.metrics.record(histogram.id, value);
    }

    /// Register a bounded dependency check for the readiness route.
    Error health(string name, HealthProbe probe)
    {
        if (control is null || control.draining)
            return inactive();
        return control.health(name, probe);
    }

    /// Evaluate current dependency readiness with a recursion guard.
    bool ready() nothrow @nogc
    {
        return control !is null && control.ready();
    }

    /// Render a consistent per-series Prometheus snapshot into the caller arena.
    Result!Buffer scrape(ref scope RequestArena arena) nothrow @nogc
    {
        return control is null ? Result!Buffer(Buffer.init, inactive()) : control.scrape(arena);
    }

    /// Start a child span or establish a new portable trace identity.
    Result!Span beginSpan(string name, TraceContext parent, long monotonicNanos) nothrow @nogc
    {
        if (control is null || control.draining)
            return Result!Span(Span.init, inactive());
        if (name.length == 0 || name.length > 128 || !validText(name))
            return Result!Span(Span.init, Error(Status.invalidArgument, "invalid span name"));
        return control.spans.begin(name, parent, monotonicNanos);
    }

    /// Request one exporter round and await its receipt within the supplied context.
    Error exportBatch(ref Context context) nothrow @nogc
    {
        return control is null ? inactive() : control.exportBatch(context);
    }

    /// Observe ended spans awaiting export, overload drops and collector partial rejections.
    ExportStats exportStats() nothrow @nogc
    {
        if (control is null)
            return ExportStats.init;
        const rejected = control.exporter is null ? 0 : control.exporter.rejections();
        return ExportStats(control.spans.pending(), control.spans.dropped(), rejected);
    }

    /// Attach an atomic route set to the prepared management listener.
    Error attach(ref Server server)
    {
        if (control is null || control.draining)
            return inactive();
        if (control.options.authorize is null && !server.isLoopbackListener())
            return Error(Status.permissionDenied, "management routes on a shared listener require authorization");
        const base = control.options.pathPrefix;
        const RouteRegistration[3] routes = [
            RouteRegistration(Method.get, base ~ "/health/live", &control.liveRoute),
            RouteRegistration(Method.get, base ~ "/health/ready", &control.readyRoute),
            RouteRegistration(Method.get, base ~ "/metrics", &control.metricsRoute),
        ];
        return server.routeBatch(routes[]);
    }

    /// Switch readiness to unavailable and finish bounded export shutdown.
    Error close(ref Context context) nothrow @nogc
    {
        return control is null ? Error.init : control.close(context);
    }
}

private Error inactive() pure nothrow @nogc
{
    return Error(Status.unavailable, "actuator is closed");
}

private bool validOptions(ActuatorOptions options) nothrow @nogc
{
    const path = options.pathPrefix;
    if (path.length < 2 || path.length > 128 || path[0] != '/' || path[$ - 1] == '/')
        return false;
    if (options.maxMetricSeries == 0 || options.maxMetricSeries > 4096 || options.maxSpansQueued == 0
            || options.maxSpansQueued > 8192 || options.maxBatchSpans == 0 || options.maxBatchSpans > 256
            || options.maxBatchSpans > options.maxSpansQueued || options.exportIntervalNanos <= 0
            || options.cores == 0 || options.cores > 256)
        return false;
    const url = options.otlpEndpoint;
    return options.serviceName.length != 0 && validText(options.serviceName) && goodEndpoint(url);
}

private bool goodEndpoint(string url) pure nothrow @nogc
{
    if (url.length == 0)
        return true;
    if (url.length > 2048)
        return false;
    foreach (char c; url)
        if (c <= 32 || c == '?' || c == '#')
            return false;
    return (url.length > 7 && url[0 .. 7] == "http://") || (url.length > 8 && url[0 .. 8] == "https://");
}

private bool validText(scope const(char)[] value) nothrow @nogc
{
    if (value.length > 256)
        return false;
    ubyte[1600] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    return encodeJson(value, arena).ok;
}

private struct NamedProbe
{
    string name;
    HealthProbe run;
}

private final class Runtime
{
    ActuatorOptions options;
    Metrics metrics;
    Spans spans;
    Exporter exporter;
    immutable ulong identity;
    private SharedHealth checks;
    private shared bool closing;
    private shared bool closingOwner;
    private shared bool closed;

    this(ulong id, ActuatorOptions options)
    {
        this.options = options;
        identity = id;
        metrics = new Metrics(options.maxMetricSeries, options.cores);
        spans = new Spans(options.maxSpansQueued);
        checks = new SharedHealth;
    }

    bool draining() const nothrow @nogc
    {
        return atomicLoad(closing);
    }

    bool retired() const nothrow @nogc
    {
        return atomicLoad(closed);
    }

    Error health(string name, HealthProbe probe)
    {
        if (probe is null || !validName(name))
            return Error(Status.invalidArgument, "invalid readiness probe");
        return checks.add(name, probe);
    }

    bool ready() nothrow @nogc
    {
        if (draining || checkingHealth)
            return false;
        checkingHealth = true;
        scope (exit)
            checkingHealth = false;
        return checks.ready();
    }

    Result!Buffer scrape(ref scope RequestArena arena) nothrow @nogc
    {
        const rejected = exporter is null ? 0 : exporter.rejections();
        return render(metrics, spans.dropped(), rejected, arena);
    }

    Error exportBatch(ref Context context) nothrow @nogc
    {
        return exporter is null ? Error(Status.unsupported, "no OTLP destination configured") : exporter.flush(context);
    }

    Error close(ref Context context) nothrow @nogc
    {
        while (!cas(&closingOwner, false, true))
        {
            if (retired)
                return Error.init;
            const wait = pause(context);
            if (wait.code != Status.ok)
                return wait;
        }
        scope (exit)
            atomicStore(closingOwner, false);
        if (retired)
            return Error.init;
        const first = cas(&closing, false, true);
        Error flushed;
        if (exporter !is null)
        {
            if (first && spans.pending() != 0)
                flushed = exporter.flush(context);
            const retired = exporter.close(context);
            if (retired.code != Status.ok)
                return retired;
        }
        spans.close();
        atomicStore(closed, true);
        return flushed;
    }

    Result!Response liveRoute(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return authorized(request) ? response(200, "{\"status\":\"UP\"}", context) : response(403,
                "{\"status\":\"FORBIDDEN\"}", context);
    }

    Result!Response readyRoute(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        if (!authorized(request))
            return response(403, "{\"status\":\"FORBIDDEN\"}", context);
        if (ready())
            return response(200, "{\"status\":\"UP\"}", context);
        return response(503, "{\"status\":\"DOWN\"}", context);
    }

    Result!Response metricsRoute(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        if (!authorized(request))
            return response(403, "{\"status\":\"FORBIDDEN\"}", context);
        const report = scrape(context.arena);
        return Result!Response(Response(200, "text/plain; version=0.0.4; charset=utf-8", report.value), report.error);
    }

    private bool authorized(ref scope Request request) nothrow @nogc
    {
        return options.authorize is null || options.authorize(request);
    }
}

private Result!Response response(ushort code, string body, ref scope RequestContext context) nothrow @nogc
{
    const bytes = context.arena.copyIn(cast(const(ubyte)[])
            body);
    return Result!Response(Response(code, "application/json", bytes.value), bytes.error);
}

private final class SharedHealth
{
    private NamedProbe[256] probes;
    private shared uint used;
    private Mutex lock;

    this()
    {
        lock = new Mutex;
    }

    Error add(string name, HealthProbe probe)
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        const current = atomicLoad(used);
        if (current == probes.length)
            return Error(Status.resourceExhausted, "readiness probe capacity reached");
        foreach (ref entry; probes[0 .. current])
            if (entry.name == name)
                return Error(Status.conflict, "duplicate readiness probe");
        probes[current] = NamedProbe(name, probe);
        atomicStore(used, current + 1);
        return Error.init;
    }

    bool ready() nothrow @nogc
    {
        foreach (ref probe; probes[0 .. atomicLoad(used)])
            if (probe.run().status != HealthStatus.up)
                return false;
        return true;
    }
}
