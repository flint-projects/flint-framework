module trace_fibers;

import core.lifetime : move;
import flint.engine.actuator : ActuatorOptions, Registry, Span, TraceContext;
import flint.arena : Error, Status;
import flint.conc : Context, Deadline, WorkerOptions, WorkerPool;
import flint.log : LogContext, LogOptions, Logger;
import flint.engine.reactor : Reactor, ReactorOptions, TaskContext;
import std.format : format;
import std.json : parseJSON;
import std.stdio : writeln;

@safe:

private enum requests = 100;
private enum records = requests * 2;

private LogContext logContext() nothrow @nogc
{
    const task = Reactor.current().currentTask();
    if (!task.ok)
        return LogContext.init;
    return LogContext(task.value.requestId, task.value.traceIdHigh, task.value.traceIdLow, task.value.spanId);
}

private ulong fromBytes(scope const(ubyte)[] bytes) pure nothrow @nogc
{
    ulong result;
    foreach (value; bytes)
        result = (result << 8) | value;
    return result;
}

private long now() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

private Error echo(scope const(ubyte)[] data, scope ubyte[] response, out size_t length) nothrow @nogc
{
    if (data.length != 24 || response.length < data.length)
        return Error(Status.invalidArgument, "invalid worker trace packet");
    response[0 .. data.length] = data;
    length = data.length;
    return Error.init;
}

private final class Fixture
{
    Registry registry;
    WorkerPool workers;
    Logger logger;
    Span[requests] parents;
    char[256][records] entries;
    size_t[records] lengths;
    uint written;
    uint dispatched;
    uint finished;

    Status store(scope const(char)[] line) nothrow @nogc
    {
        if (written == records || line.length > entries[0].length)
            return Status.resourceExhausted;
        entries[written][0 .. line.length] = line;
        lengths[written++] = line.length;
        return Status.ok;
    }

    void handle() nothrow @nogc
    {
        auto reactor = Reactor.current();
        const task = reactor.currentTask();
        assert(task.ok && task.value.requestId >= 1 && task.value.requestId <= requests);
        const original = logContext();
        auto parent = parents[original.requestId - 1];
        const trace = parent.context();
        assert(fromBytes(trace.traceId[0 .. 8]) == original.traceIdHigh);
        assert(fromBytes(trace.traceId[8 .. 16]) == original.traceIdLow);
        assert(fromBytes(trace.spanId[]) == original.spanId);
        assert(logger.info("before-worker") == Status.ok);
        ubyte[24] packet;
        packet[0 .. 16] = trace.traceId[];
        packet[16 .. 24] = trace.spanId[];
        auto ticket = workers.submit(task.value.cancellation, packet[], &echo);
        assert(ticket.ok);
        ++dispatched;
        do
        {
            assert(reactor.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
            assert(logContext() == original);
        }
        while (dispatched < requests);
        ubyte[24] result;
        size_t bytes;
        Error outcome;
        do
        {
            outcome = workers.join(ticket.value, result[], bytes);
            if (outcome.code == Status.unavailable)
                assert(reactor.yieldUntil(Deadline.afterMillis(1)).code == Status.ok);
        }
        while (outcome.code == Status.unavailable);
        assert(outcome.code == Status.ok && bytes == packet.length && packet == result);
        assert(logContext() == original && logger.info("after-worker") == Status.ok);
        auto child = registry.beginSpan("fiber-child", trace, now());
        assert(child.ok && child.value.context.traceId == trace.traceId);
        assert(child.value.context.spanId != trace.spanId);
        assert(child.value.finish(now(), false).code == Status.ok);
        assert(parent.finish(now(), false).code == Status.ok);
        if (++finished == requests)
            reactor.stop();
    }

    bool validate()
    {
        if (written != records || registry.exportStats().pending != records)
        {
            writeln("delivered=", written, " queued=", registry.exportStats().pending, " finished=", finished);
            return false;
        }
        bool[2][requests] seen;
        foreach (index; 0 .. written)
        {
            const row = parseJSON(entries[index][0 .. lengths[index]]);
            const id = row["requestId"].integer;
            if (id < 1 || id > requests)
                return false;
            const original = parents[id - 1].context;
            const high = fromBytes(original.traceId[0 .. 8]);
            const low = fromBytes(original.traceId[8 .. 16]);
            if (row["traceId"].str != format!"%016x%016x"(high, low)
                    || row["spanId"].str != format!"%016x"(fromBytes(original.spanId[])))
                return false;
            const message = row["message"].str;
            if (message != "before-worker" && message != "after-worker")
                return false;
            const after = message == "after-worker";
            if (seen[id - 1][after])
                return false;
            seen[id - 1][after] = true;
        }
        return true;
    }
}

/// Drive every fiber through an owned worker packet and verify both emitted log records.
int verifyTraces()
{
    auto task = new Fixture;
    if (task.registry.open(ActuatorOptions.init).code != Status.ok)
        return 1;
    Context shutdown;
    scope (exit)
        task.registry.close(shutdown);
    auto pool = WorkerPool.create(WorkerOptions(4, requests));
    if (!pool.ok)
        return 2;
    move(pool.value, task.workers);
    scope (exit)
        task.workers.shutdown();
    LogOptions logs;
    logs.maxRecordBytes = 256;
    logs.ringBytes = 2 * 1024 * 1024;
    logs.sink = &task.store;
    logs.currentContext = &logContext;
    auto logger = Logger.create(logs);
    if (!logger.ok)
        return 3;
    task.logger = logger.value;
    scope (exit)
        task.logger.close();
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = requests;
    auto reactor = Reactor.create(options);
    if (!reactor.ok)
        return 4;
    foreach (index; 0 .. requests)
    {
        auto parent = task.registry.beginSpan("fiber-parent", TraceContext.init, now());
        if (!parent.ok)
            return 5;
        task.parents[index] = parent.value;
        const span = parent.value.context();
        auto context = TaskContext(index + 1);
        context.traceIdHigh = fromBytes(span.traceId[0 .. 8]);
        context.traceIdLow = fromBytes(span.traceId[8 .. 16]);
        context.spanId = fromBytes(span.spanId[]);
        if (reactor.value.postStartup(0, &task.handle, context).code != Status.ok)
            return 6;
    }
    const ran = reactor.value.run();
    const flushed = task.logger.flush();
    if (ran.code != Status.ok || flushed.code != Status.ok || !task.validate())
    {
        writeln("reactor=", ran, " log_flush=", flushed);
        return 7;
    }
    writeln("interleaved_fibers=", requests, " verified_logs=", records, " queued_spans=", records);
    return 0;
}
