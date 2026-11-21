module flint.actuator.exporter;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.lifetime : move;
import core.thread : Thread;
import core.time : msecs;
import flint.actuator.metrics : Metrics, saturated;
import flint.actuator.otlp : acknowledged, measurements, traces;
import flint.actuator.spans : SpanRecord, Spans;
import flint.actuator.types : ActuatorOptions;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline, startBackground;
import flint.http : ClientOptions, Header, HttpClient, HttpMethod, HttpRequest;
import flint.reactor : Reactor;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;

@safe:

private enum second = 1_000_000_000L;

package(flint.actuator) Error pause(ref Context context) nothrow @nogc
{
    const ready = context.check();
    if (ready.code != Status.ok)
        return ready;
    auto reactor = Reactor.current();
    const yielded = reactor.yieldUntil(Deadline.afterMillis(1));
    if (yielded.code != Status.notFound)
        return yielded;
    Thread.sleep(1.msecs);
    return context.check();
}

private long now() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

private long plus(long first, long duration) pure nothrow @nogc
{
    return duration > long.max - first ? long.max : first + duration;
}

private struct Delivery
{
    Status status;
    bool retry;
    long retryAfter = -1;
}

private struct RetryWindow
{
    long began;
    long due;
    long backoff = 100_000_000;

    Deadline deadline() const nothrow @nogc
    {
        return began == 0 ? Deadline.none() : Deadline(plus(began, 60 * second));
    }

    bool schedule(Delivery delivery, long at) nothrow @nogc
    {
        if (delivery.retry && began == 0)
            began = at;
        if (!delivery.retry || at - began >= 60 * second)
        {
            this = RetryWindow.init;
            return false;
        }
        ulong entropy = cast(ulong) at * 11_400_714_819_323_198_485UL;
        entropy ^= entropy >> 29;
        const half = backoff / 2;
        const jittered = half + cast(long)(entropy % cast(ulong)(half + 1));
        const delay = delivery.retryAfter >= 0 ? delivery.retryAfter : jittered;
        const time = plus(at, delay < 1_000_000 ? 1_000_000 : delay);
        const end = deadline().monotonicNanoseconds;
        due = time < end ? time : end;
        backoff = backoff < 2_500_000_000L ? backoff * 2 : 5 * second;
        return true;
    }
}

package(flint.actuator) final class Exporter
{
    private Metrics metrics;
    private Spans spans;
    private SpanRecord[] batch;
    private ubyte[] storage;
    private ubyte[] metricPayload;
    private size_t metricBytes;
    private size_t spanCount;
    private uint metricCount;
    private Header[] headers;
    private HttpClient client;
    private CancelSource shutdown;
    private string tracesUrl;
    private string metricsUrl;
    private string service;
    private long interval;
    private ulong wallOffset;
    private ulong started;
    private uint nextMetric = 1;
    private shared bool stopping;
    private shared bool stopped;
    private shared ulong requested;
    private shared ulong completed;
    private shared Status outcome;
    private shared ulong rejected;
    private RetryWindow traceRetry;
    private RetryWindow metricRetry;

    this(ActuatorOptions options, Metrics metrics, Spans spans)
    {
        this.metrics = metrics;
        this.spans = spans;
        batch = new SpanRecord[options.maxBatchSpans];
        storage = new ubyte[2 * 1024 * 1024];
        metricPayload = new ubyte[storage.length];
        headers = [Header("Content-Type", "application/json")];
        const base = options.otlpEndpoint[$ - 1] == '/' ? options.otlpEndpoint[0 .. $ - 1] : options.otlpEndpoint;
        tracesUrl = base ~ "/v1/traces";
        metricsUrl = base ~ "/v1/metrics";
        service = options.serviceName;
        interval = options.exportIntervalNanos;
        const observed = Clock.currTime(UTC());
        const epoch = cast(ulong) observed.toUnixTime * second + cast(ulong)(observed.stdTime % 10_000_000) * 100;
        const monotonic = cast(ulong) now();
        wallOffset = epoch > monotonic ? epoch - monotonic : 0;
        started = saturated(wallOffset, monotonic);
    }

    Error start()
    {
        ClientOptions options;
        options.maxConnections = 1;
        options.maxConnectionsPerOrigin = 1;
        options.maxResponseBytes = 65_536;
        options.connectTimeoutNanos = 2 * second;
        auto source = CancelSource.create(Context.init, Deadline.none());
        if (!source.ok)
            return source.error;
        const opened = client.open(options);
        if (opened.code != Status.ok)
            return opened;
        shutdown = move(source.value);
        const background = startBackground(&run);
        if (background.code != Status.ok)
        {
            client.close();
            shutdown.close();
        }
        return background;
    }

    Error flush(ref Context context) nothrow @nogc
    {
        if (atomicLoad(stopping))
            return Error(Status.unavailable, "telemetry exporter is closing");
        const number = atomicOp!"+="(requested, 1UL);
        while (atomicLoad(completed) < number)
        {
            const ready = pause(context);
            if (ready.code != Status.ok)
                return ready;
            if (atomicLoad(stopped))
                return Error(Status.unavailable, "telemetry exporter stopped");
        }
        const delivered = atomicLoad(outcome);
        return delivered == Status.ok ? Error.init : Error(delivered, "telemetry batch was not acknowledged");
    }

    Error close(ref Context context) nothrow @nogc
    {
        atomicStore(stopping, true);
        shutdown.cancel();
        while (!atomicLoad(stopped))
        {
            const ready = pause(context);
            if (ready.code != Status.ok)
                return ready;
        }
        return Error.init;
    }

    ulong rejections() const nothrow @nogc
    {
        return atomicLoad(rejected);
    }

    private void run() nothrow @nogc
    {
        auto periodic = plus(now(), interval);
        scope (exit)
        {
            client.close();
            shutdown.close();
            atomicStore(stopped, true);
        }
        while (!atomicLoad(stopping))
        {
            const clock = now();
            const serial = atomicLoad(requested);
            const forced = serial != atomicLoad(completed);
            const due = clock >= periodic;
            const queued = spans.pending();
            const retryMetrics = metricRetry.began != 0 && clock >= metricRetry.due;
            const sendTrace = (queued >= batch.length || traceRetry.began != 0) && clock >= traceRetry.due;
            if (forced || due || retryMetrics || sendTrace)
            {
                const status = tick(queued, forced || due || retryMetrics);
                atomicStore(outcome, status);
                atomicStore(completed, serial);
                if (due)
                    periodic = plus(clock, interval);
            }
            else
                Thread.sleep(10.msecs);
        }
    }

    private Status tick(uint queued, bool includeMetrics) nothrow @nogc
    {
        Status current = Status.ok;
        if (queued != 0)
        {
            auto context = shutdown.context().withDeadline(Deadline.afterMillis(5_000));
            current = now() < traceRetry.due ? Status.unavailable : sendSpans(context);
        }
        if (includeMetrics && metrics.count != 0 && now() >= metricRetry.due)
        {
            auto context = shutdown.context().withDeadline(Deadline.afterMillis(5_000));
            const measured = sendMetrics(context);
            if (current == Status.ok)
                current = measured;
        }
        return current;
    }

    private Status sendSpans(ref Context context) nothrow @nogc
    {
        if (spanCount == 0)
            spanCount = spans.snapshot(batch);
        if (spanCount == 0)
            return Status.ok;
        scope RequestArena arena = RequestArena(storage);
        const payload = traces(batch[0 .. spanCount], service, wallOffset, arena);
        const delivered = attempt(tracesUrl, payload, true, traceRetry, arena, context);
        if (!traceRetry.schedule(delivered, now()))
        {
            spans.retire(spanCount, delivered.status != Status.ok);
            spanCount = 0;
        }
        return delivered.status;
    }

    private Status sendMetrics(ref Context context) nothrow @nogc
    {
        scope RequestArena arena = RequestArena(storage);
        Result!Buffer payload;
        if (metricBytes != 0)
            payload = arena.copyIn(metricPayload[0 .. metricBytes]);
        else
            payload = snapshotMetrics(arena);
        const delivered = attempt(metricsUrl, payload, false, metricRetry, arena, context);
        if (!metricRetry.schedule(delivered, now()))
        {
            nextMetric += metricCount;
            metricCount = 0;
            metricBytes = 0;
        }
        return delivered.status;
    }

    private Delivery attempt(string url, Result!Buffer payload, bool trace, ref const RetryWindow retry,
            ref scope RequestArena arena, ref Context parent) nothrow @nogc
    {
        const limit = retry.deadline();
        if (now() >= limit.monotonicNanoseconds)
            return Delivery(Status.timedOut);
        auto context = parent.withDeadline(limit);
        return deliver(url, payload, trace, arena, context);
    }

    private Result!Buffer snapshotMetrics(ref scope RequestArena arena) nothrow @nogc
    {
        const available = metrics.count;
        if (nextMetric > available)
            nextMetric = 1;
        const room = available - nextMetric + 1;
        metricCount = room < 32 ? room : 32;
        const end = saturated(wallOffset, cast(ulong) now());
        const payload = measurements(metrics, nextMetric, metricCount, service, started, end, arena);
        if (!payload.ok)
            return payload;
        const status = arena.read(payload.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            metricPayload[0 .. bytes.length] = bytes;
            metricBytes = bytes.length;
        });
        return status == Status.ok ? payload : Result!Buffer(Buffer.init, Error(status, "metric payload expired"));
    }

    private Delivery deliver(string target, Result!Buffer payload, bool trace,
            ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        if (!payload.ok)
            return Delivery(payload.error.code);
        const request = HttpRequest(HttpMethod.post, target, headers, payload.value);
        auto response = client.send(request, arena, context);
        if (!response.ok)
        {
            const terminal = response.error.code;
            return Delivery(terminal, terminal == Status.unavailable || terminal == Status.timedOut
                    || terminal == Status.ioError);
        }
        const status = response.value.status;
        if (status != 200)
            return failure(status, response.value.headers, arena);
        Result!ulong parsed;
        const read = arena.read(response.value.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            parsed = acknowledged(bytes, trace);
        });
        if (read != Status.ok || !parsed.ok || parsed.value > (trace ? spanCount : metricCount))
            return Delivery(Status.ioError);
        atomicOp!"+="(rejected, parsed.value);
        return Delivery.init;
    }

    private Delivery failure(ushort status, Buffer fields, ref scope RequestArena arena) nothrow @nogc
    {
        const retry = status == 429 || status == 502 || status == 503 || status == 504;
        long delay = -1;
        if (retry)
        {
            const wall = saturated(wallOffset, cast(ulong) now());
            arena.read(fields, (scope const(ubyte)[] contents) @safe nothrow @nogc {
                delay = retryAfter(cast(const(char)[]) contents, wall);
            });
        }
        return Delivery(retry ? Status.unavailable : Status.ioError, retry, delay);
    }
}

package(flint.actuator) long retryAfter(scope const(char)[] headers, ulong wall) pure nothrow @nogc
{
    enum field = "retry-after:";
    while (headers.length != 0)
    {
        size_t length;
        while (length < headers.length && headers[length] != '\n')
            ++length;
        const line = headers[0 .. length];
        headers = headers[length + (length != headers.length) .. $];
        if (line.length <= field.length || !matches(line[0 .. field.length], field))
            continue;
        const value = trim(line[field.length .. $]);
        const seconds = numeric(value);
        if (seconds >= 0)
            return seconds > 60 ? 60 * second : seconds * second;
        const target = httpDate(value);
        const nowSeconds = wall / second;
        if (target <= 0 || cast(ulong) target <= nowSeconds)
            return -1;
        const delay = cast(ulong) target - nowSeconds;
        return delay > 60 ? 60 * second : cast(long) delay * second;
    }
    return -1;
}

private bool matches(scope const(char)[] value, scope const(char)[] lower) pure nothrow @nogc
{
    foreach (index, char ch; value)
    {
        const folded = ch >= 'A' && ch <= 'Z' ? cast(char)(ch + 32) : ch;
        if (folded != lower[index])
            return false;
    }
    return true;
}

private const(char)[] trim(return scope const(char)[] value) pure nothrow @nogc
{
    while (value.length != 0 && (value[0] == ' ' || value[0] == '\t'))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == '\r' || value[$ - 1] == ' ' || value[$ - 1] == '\t'))
        value = value[0 .. $ - 1];
    return value;
}

private long numeric(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length == 0)
        return -1;
    long result;
    foreach (character; value)
    {
        if (character < '0' || character > '9')
            return -1;
        if (result <= 9999)
            result = result * 10 + character - '0';
    }
    return result;
}

private long httpDate(scope const(char)[] date) pure nothrow @nogc
{
    if (date.length != 29 || date[3 .. 5] != ", " || date[25 .. 29] != " GMT")
        return -1;
    const day = numeric(date[5 .. 7]);
    auto year = numeric(date[12 .. 16]);
    const time = httpClock(date[17 .. 25]);
    if (day < 1 || day > 31 || year < 1970 || time < 0)
        return -1;
    enum months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    long month = 1;
    while (month <= 12 && date[8 .. 11] != months[(month - 1) * 3 .. month * 3])
        ++month;
    if (month > 12)
        return -1;
    year -= month <= 2;
    const cycle = year / 400;
    const offset = year - cycle * 400;
    const march = month + (month > 2 ? -3 : 9);
    const days = cycle * 146_097 + offset * 365 + offset / 4 - offset / 100 + (153 * march + 2) / 5 + day - 1 - 719_468;
    return days * 86_400 + time;
}

private long httpClock(scope const(char)[] time) pure nothrow @nogc
{
    if (time[2] != ':' || time[5] != ':')
        return -1;
    const hours = numeric(time[0 .. 2]);
    const minutes = numeric(time[3 .. 5]);
    const seconds = numeric(time[6 .. 8]);
    if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59 || seconds < 0 || seconds > 59)
        return -1;
    return hours * 3600 + minutes * 60 + seconds;
}
