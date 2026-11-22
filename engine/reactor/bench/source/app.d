module app;

import core.stdc.stdio : printf;
import core.thread.osthread : Thread;
import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.reactor : Backend, Completion, ConnectionId, IoId, ListenOptions, Reactor, ReactorOptions;
import probe_workload : cancellationMarker, connectionLimit, maxPayload, runWorkloads, useUring;
import std.exception : enforce;

private IoId[connectionLimit] cancellations;
private bool cancellationScheduled;

private void cancelBatch() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    cancellationScheduled = false;
    foreach (ref ticket; cancellations)
    {
        if (ticket.generation != 0)
        {
            const status = reactor.cancel(ticket).code;
            if (status != Status.ok)
                reactor.stop();
            ticket = IoId.init;
        }
    }
}

private void cancelled(Completion completion, scope const(ubyte)[] bytes) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (completion.status != Status.cancelled || bytes.length != 0)
        reactor.stop();
    reactor.close(completion.connection);
}

private void received(Completion completion, scope const(ubyte)[] bytes) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (completion.status != Status.ok || bytes.length == 0)
    {
        reactor.close(completion.connection);
        return;
    }
    if (bytes.length == 1 && bytes[0] == cancellationMarker)
    {
        const pending = reactor.read(completion.connection, maxPayload, Context.init, &cancelled);
        if (!pending.ok)
        {
            reactor.stop();
            return;
        }
        cancellations[completion.connection.slot] = pending.value;
        if (!cancellationScheduled)
        {
            const timer = reactor.schedule(Deadline.afterMillis(25), &cancelBatch);
            if (!timer.ok)
                reactor.stop();
            cancellationScheduled = true;
        }
        return;
    }

    const accepted = reactor.write(completion.connection, bytes, Context.init, &written);
    if (!accepted.ok)
        reactor.stop();
}

private void written(Completion completion) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (completion.status == Status.ok)
        begin(completion.connection);
    else
        reactor.close(completion.connection);
}

private void begin(ConnectionId connection) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (!reactor.read(connection, maxPayload, Context.init, &received).ok)
        reactor.stop();
}

/// The declared member name, as the report has always spelled the selected backend.
private string backendName(Backend backend) @safe pure nothrow @nogc
{
    final switch (backend)
    {
    case Backend.automatic:
        return "automatic";
    case Backend.ioUring:
        return "ioUring";
    case Backend.kqueue:
        return "kqueue";
    case Backend.iocp:
        return "iocp";
    case Backend.epoll:
        return "epoll";
    }
}

/// Run the capacity, echo, and cancellation workloads against the Flint native reactor.
int main()
{
    ReactorOptions options;
    options.cores = 1;
    options.maxConnectionsPerCore = connectionLimit;
    options.maxPendingIoPerCore = 2 * connectionLimit + 2;
    options.fiberPoolSize = 2;
    options.ioBufferBytes = maxPayload;
    options.backend = useUring() ? Backend.ioUring : Backend.epoll;

    auto server = Reactor.create(options);
    enforce(server.ok, server.error.message);
    const listening = server.value.listen(ListenOptions("127.0.0.1", 0, 2048), &begin);
    enforce(listening.code == Status.ok, listening.message);
    const port = server.value.localPort.value;
    ulong checksum;
    auto driver = new Thread({
        scope (exit)
            server.value.stop();
        checksum = runWorkloads(port);
    }).start();

    const status = server.value.run();
    driver.join();
    enforce(status.code == Status.ok, status.message);
    enforce(checksum != 0, "workload produced no checksum");
    const stats = server.value.workerStats(0).value;
    enforce(stats.outstandingOperations == 0, "shutdown retained operation buffers");
    const backend = backendName(options.backend);
    const pinned = stats.affinityPinned ? "true" : "false";
    printf("backend=%.*s pinned=%.*s worker_cpu_ns=%llu voluntary_switches=%llu involuntary_switches=%llu "
            ~ "outstanding=%u\n", cast(int) backend.length, backend.ptr, cast(int) pinned.length,
            pinned.ptr, stats.cpuNanos, stats.voluntarySwitches, stats.involuntarySwitches,
            stats.outstandingOperations);
    return 0;
}
