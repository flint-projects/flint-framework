/// Reactor-owned HTTP request and write lifetimes.
module flint.web.runtime;

import core.atomic : atomicLoad, atomicStore, cas;
import core.lifetime : move;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : AcceptDelegate, Completion, CompletionDelegate, ConnectionId, ListenOptions,
    ReadDelegate, Reactor, ReactorOptions, TaskContext, TaskDelegate;
import flint.web.dispatch : executeMatched, executeStream, failureResponse, lookupRoute;
import flint.web.http2 : H2Runtime;
import flint.web.http1 : BodyLimit, Http1Reader, ReadOutcome;
import flint.web.router : Match, RouteTable, maximumTargetBytes;
import flint.web.stream : StreamEndpoint, StreamField, StreamMode, StreamRoute, StreamToken;
import flint.web.sys.ownership : launchDriver, releaseBytes, reserveBytes;
import flint.web.transport : TlsTransport, closePlain, readPlain, writePlain;
import flint.web.types : ErrorAdvice, Handler, Method, RequestContext, Response, RouteRegistration, ServerOptions;
import flint.web.worker : WorkerLifecycle;
import flint.web.wire : responseCode, validMediaType, writeChunk, writeHeader, writeStreamHeader;

@safe:

private enum ioBytes = 4096;
private enum maxBody = 1_048_576;
private enum maxStreamingBody = 4 * 1024 * 1024;
private enum maxQueue = 262_144;
private enum maxConnections = 4096;

private enum DriverPhase : ubyte
{
    prepared,
    active,
    stopping,
    finished
}

private enum ConnectionPhase : ubyte
{
    free,
    reading,
    handling,
    writing,
    streaming
}

private struct Connection
{
    Runtime owner;
    TaskDelegate handlerTask;
    ConnectionId id;
    ConnectionPhase phase;
    ubyte[] owned;
    ubyte[] pending;
    size_t pendingCount;
    Http1Reader parser;
    RequestContext request;
    CancelSource cancellation;
    Deadline headerDeadline;
    bool hasHeaderDeadline;
    bool keepAlive;
    bool suppressBody;
    bool readActive;
    bool writeActive;
    bool taskActive;
    bool closing;
    StreamMode streamMode;
    bool streamStarted;
    bool streamEnded;
    bool streamRaw;
    Buffer response;
    size_t bodySent;
    size_t writeBytes;

    void runHandler() nothrow @nogc
    {
        owner.dispatch(id);
    }
}

/// TCP server with startup routing and per-core request storage.
struct Server
{
    private Runtime driver;

    /// Bind the listener and prepare its owner loops. Poll begins admission after routes are registered.
    Error start(ServerOptions options)
    {
        if (driver !is null)
            return Error(Status.conflict, "HTTP server already started");

        version (FlintNativeLlhttp)
        {
            if (!validOptions(options))
                return Error(Status.invalidArgument, "invalid HTTP server limits");

            if (allowsH2(options))
            {
                version (FlintNativeNghttp2)
                {
                }
                else
                    return Error(Status.unsupported, "pinned nghttp2 provider is unavailable");
            }
            auto state = new Runtime(options);
            const result = state.prepare();
            if (result.code != Status.ok)
                return result;
            driver = state;
            return Error.init;
        }
        else
            return Error(Status.unsupported, "pinned llhttp provider is unavailable");
    }

    /// Register a route before the first poll publishes the route table.
    Error route(Method method, string path, Handler handler)
    {
        if (driver is null || atomicLoad(driver.phase) != DriverPhase.prepared)
            return Error(Status.conflict, "HTTP routes require a prepared server");
        return driver.routes.insert(method, path, handler);
    }

    /// Publish an entire startup route set only when every entry and collision check succeeds.
    Error routeBatch(scope const(RouteRegistration)[] entries)
    {
        if (driver is null || atomicLoad(driver.phase) != DriverPhase.prepared)
            return Error(Status.conflict, "HTTP routes require a prepared server");
        return driver.routes.insertBatch(entries);
    }

    /// Register a streaming action before the server begins accepting requests.
    Error routeStream(StreamRoute route)
    {
        if (driver is null || atomicLoad(driver.phase) != DriverPhase.prepared)
            return Error(Status.conflict, "streaming HTTP routes require a prepared server");
        if ((route.mode == StreamMode.upgrade && driver.limits.http2PriorKnowledge)
                || (route.mode == StreamMode.duplex && !allowsH2(driver.limits)))
            return Error(Status.unsupported, "listener cannot serve this streaming mode");
        return driver.routes.insertStream(route);
    }

    package(flint.web) uint ownerCount() const nothrow @nogc
    {
        return driver is null ? 0 : driver.limits.cores;
    }

    package(flint.web) Error attachWorker(WorkerLifecycle worker)
    {
        if (driver is null || atomicLoad(driver.phase) != DriverPhase.prepared)
            return Error(Status.conflict, "HTTP worker controllers require a prepared server");
        driver.workers ~= worker;
        return Error.init;
    }

    package(flint.web) Error installAdvice(ErrorAdvice handler)
    {
        if (driver is null || atomicLoad(driver.phase) != DriverPhase.prepared)
            return Error(Status.conflict, "HTTP error advice requires a prepared server");
        return driver.routes.installAdvice(handler);
    }

    /// Whether the live listener was prepared with a numeric loopback address.
    bool isLoopbackListener() const nothrow @nogc
    {
        return driver !is null && atomicLoad(driver.phase) < DriverPhase.stopping
            && loopbackAddress(driver.limits.address);
    }

    /// Authorize admission and report cancellation or terminal owner-loop status.
    Error poll(ref Context context) nothrow @nogc
    {
        if (driver is null)
            return Error(Status.invalidArgument, "HTTP server is not initialized");
        const checked = context.check();
        if (checked.code != Status.ok)
        {
            driver.stop();
            return checked;
        }
        cas(&driver.phase, DriverPhase.prepared, DriverPhase.active);
        if (atomicLoad(driver.phase) == DriverPhase.finished)
            return driver.result.code == Status.ok ? Error(Status.cancelled, "HTTP server stopped") : driver.result;
        Thread.sleep(dur!"msecs"(1));
        return Error.init;
    }

    /// Stop admission and wait through final connection completions up to an absolute deadline.
    Error shutdown(long deadlineNanos) nothrow @nogc
    {
        if (driver is null)
            return Error.init;
        if (driver.reactor.currentCore() != uint.max)
            return Error(Status.conflict, "owner loop cannot wait for its own shutdown");
        driver.stop();
        while (atomicLoad(driver.phase) != DriverPhase.finished)
        {
            const exhausted = now() >= deadlineNanos;
            driver.progressStop(exhausted);
            if (exhausted)
                return Error(Status.timedOut, "HTTP shutdown is still draining");
            Thread.sleep(dur!"msecs"(1));
        }
        driver.release();
        return driver.result;
    }
}

private bool loopbackAddress(string address) pure nothrow @nogc
{
    if (address == "::1" || address == "0:0:0:0:0:0:0:1")
        return true;
    if (address.length < 9 || address[0 .. 4] != "127.")
        return false;

    size_t position = 4;
    foreach (index; 0 .. 3)
    {
        if (!readOctet(address, position))
            return false;
        if (index != 2 && (position == address.length || address[position++] != '.'))
            return false;
    }
    return position == address.length;
}

private bool readOctet(string address, ref size_t position) pure nothrow @nogc
{
    const start = position;
    uint number;
    while (position < address.length && address[position] >= '0' && address[position] <= '9')
    {
        number = number * 10 + (address[position++] - '0');
        if (number > 255 || position - start > 3)
            return false;
    }
    return position != start;
}

@("management listener loopback proof rejects aliases and ambiguous address text")
unittest
{
    assert(loopbackAddress("127.0.0.1"));
    assert(loopbackAddress("127.91.0.2"));
    assert(loopbackAddress("::1"));
    assert(!loopbackAddress("localhost"));
    assert(!loopbackAddress("0.0.0.0"));
    assert(!loopbackAddress("127.0.0.999"));
    assert(!loopbackAddress("127.0.0.1.example"));
    assert(!loopbackAddress("127.0.0."));
    assert(!loopbackAddress("127.1"));
}

private bool validOptions(ServerOptions options) pure nothrow @nogc
{
    return options.cores >= 1 && options.cores <= 16 && options.maxConnectionsPerCore >= 1
        && options.maxConnectionsPerCore <= maxConnections && options.maxHeaderBytes > 0
        && options.maxHeaderBytes <= maximumTargetBytes
        && options.maxBodyBytes <= maxBody
        && options.maxStreamingRequestBytes <= maxStreamingBody && options.writeQueueBytes > 0
        && options.writeQueueBytes <= maxQueue
        && supportedStreamCount(options.maxStreamsPerConnection) && options.headerTimeoutNanos > 0
        && options.idleTimeoutNanos > 0 && validTransport(options);
}

private bool hasTls(ServerOptions options) pure nothrow @nogc
{
    return options.tlsCertificateFile.length != 0;
}

private bool allowsH2(ServerOptions options) pure nothrow @nogc
{
    return options.http2 && (options.http2PriorKnowledge || hasTls(options));
}

private bool validTransport(ServerOptions options) pure nothrow @nogc
{
    if (hasTls(options) != (options.tlsPrivateKeyFile.length != 0))
        return false;
    return !options.http2PriorKnowledge || (options.http2 && !hasTls(options));
}

private bool supportedStreamCount(uint count) pure nothrow @nogc
{
    return count > 0 && count <= 100;
}

private long now() nothrow @nogc
{
    return ticksToNSecs(MonoTime.currTime.ticks);
}

private Deadline following(long delta) nothrow @nogc
{
    const timestamp = now();
    return Deadline(delta >= long.max - timestamp ? long.max - 1 : timestamp + delta);
}

private final class Runtime : StreamEndpoint
{
    private ServerOptions limits;
    private ReadDelegate readDone;
    private CompletionDelegate writeDone;
    private Reactor reactor;
    private RouteTable routes;
    private H2Runtime http2;
    private TlsTransport tls;
    private Connection[] connections;
    private WorkerLifecycle[] workers;
    private CancelSource root;
    private Context serverContext;
    private shared DriverPhase phase;
    private Error result;
    private bool released;
    private size_t arenaBytes;
    private shared ulong nextRequestId;

    this(ServerOptions limits)
    {
        this.limits = limits;
        readDone = &read;
        writeDone = &written;
        const bodyCapacity = limits.maxBodyBytes > limits.maxStreamingRequestBytes
            ? limits.maxBodyBytes : limits.maxStreamingRequestBytes;
        arenaBytes = limits.maxHeaderBytes + bodyCapacity + limits.writeQueueBytes + 1024;
        routes = new RouteTable;
        if (!limits.http2PriorKnowledge)
            connections = new Connection[cast(size_t) limits.cores * limits.maxConnectionsPerCore];
        foreach (ref connection; connections)
        {
            connection.owner = this;
            connection.handlerTask = &connection.runHandler;
        }
    }

    Error prepare()
    {
        ReactorOptions options;
        options.cores = limits.cores;
        options.maxConnectionsPerCore = limits.maxConnectionsPerCore;
        options.maxPendingIoPerCore = limits.maxConnectionsPerCore + 64;
        if (limits.http2PriorKnowledge || hasTls(limits))
        {
            const desired = limits.maxConnectionsPerCore * 2 + 64;
            options.maxPendingIoPerCore = desired <= 8192 ? desired : 8192;
        }
        options.ioBufferBytes = ioBytes;
        const requestSlots = allowsH2(limits) ? limits.maxConnectionsPerCore * limits.maxStreamsPerConnection
            : limits.maxConnectionsPerCore;
        options.fiberPoolSize = requestSlots < 1_088 ? requestSlots : 1_088;
        options.maxTimersPerCore = 64;

        auto created = Reactor.create(options);
        if (!created.ok())
            return created.error;
        reactor = move(created.value);
        scope (failure)
            release();

        auto source = CancelSource.create(Context.init, Deadline.none());
        if (!source.ok())
        {
            release();
            return source.error;
        }
        move(source.value, root);
        serverContext = root.context();
        const listening = prepareListener();
        if (listening.code != Status.ok)
        {
            release();
            return listening;
        }

        try
            launchDriver(&execute);
        catch (Exception)
        {
            release();
            return Error(Status.unavailable, "unable to start HTTP event loop driver");
        }
        return Error.init;
    }

    private Error prepareListener()
    {
        AcceptDelegate acceptedCallback = &accepted;
        AcceptDelegate acceptH2;
        if (allowsH2(limits))
        {
            http2 = new H2Runtime(limits, routes, serverContext);
            acceptH2 = &http2.accept;
            if (limits.http2PriorKnowledge)
                acceptedCallback = acceptH2;
        }
        if (hasTls(limits))
        {
            tls = new TlsTransport(limits, serverContext, &accepted, acceptH2);
            const opened = tls.open();
            if (opened.code != Status.ok)
                return opened;
            acceptedCallback = &tls.accept;
            if (http2 !is null)
                http2.setTls(tls);
        }
        return reactor.listenWith(ListenOptions(limits.address, limits.port, 1024), acceptedCallback);
    }

    private void execute() nothrow
    {
        scope (exit)
        {
            foreach (worker; workers)
            {
                worker.stop();
                const joined = worker.join();
                if (joined.code != Status.ok && result.code == Status.ok)
                    result = joined;
            }
            atomicStore(phase, DriverPhase.finished);
        }
        while (atomicLoad(phase) == DriverPhase.prepared)
            Thread.sleep(dur!"msecs"(1));

        if (atomicLoad(phase) != DriverPhase.active)
            return;
        try
            result = reactor.run();
        catch (Exception)
            result = Error(Status.ioError, "HTTP event loop failed");
        if (result.code == Status.conflict && atomicLoad(phase) == DriverPhase.stopping)
            result = Error.init;
    }

    void stop() nothrow @nogc
    {
        foreach (worker; workers)
            worker.stop();
        for (;;)
        {
            const observed = atomicLoad(phase);
            if (observed >= DriverPhase.stopping)
                return;
            if (cas(&phase, observed, DriverPhase.stopping))
            {
                root.cancel();
                if (observed == DriverPhase.prepared)
                    reactor.stop();
                else
                    progressStop(false);
                return;
            }
        }
    }

    void progressStop(bool force) nothrow @nogc
    {
        if (force || http2 is null || http2.activeCount() == 0)
            reactor.stop();
    }

    void release() nothrow @nogc
    {
        if (released)
            return;
        released = true;
        foreach (ref connection; connections)
        {
            if (connection.phase != ConnectionPhase.free)
                retire(&connection);
        }
        if (http2 !is null)
            http2.release();
        if (tls !is null)
            tls.release();
        root.close();
        serverContext = Context.init;
        destroy(reactor);
    }

    private Connection* slot(ConnectionId id) nothrow @nogc
    {
        if (id.ownerCore >= limits.cores || id.slot >= limits.maxConnectionsPerCore)
            return null;
        return &connections[cast(size_t) id.ownerCore * limits.maxConnectionsPerCore + id.slot];
    }

    private Connection* checked(ConnectionId id, ConnectionPhase expected) nothrow @nogc
    {
        auto connection = slot(id);
        return connection !is null && connection.id == id && connection.phase == expected ? connection : null;
    }

    private void accepted(ConnectionId id) nothrow @nogc
    {
        auto connection = slot(id);
        if (connection is null || connection.phase != ConnectionPhase.free || serverContext.cancelled())
        {
            closePlain(tls, id);
            return;
        }
        connection.id = id;
        connection.phase = ConnectionPhase.reading;
        const capacity = arenaBytes + limits.maxHeaderBytes + ioBytes;
        connection.owned = reserveBytes(capacity);
        if (connection.owned.length != capacity)
        {
            close(connection);
            return;
        }
        auto arena = RequestArena(connection.owned[0 .. arenaBytes]);
        move(arena, connection.request.arena);
        const nameEnd = arenaBytes + limits.maxHeaderBytes;
        connection.pending = connection.owned[nameEnd .. $];
        const opened = connection.parser.open(id.generation,
                connection.owned[arenaBytes .. nameEnd], limits.maxHeaderBytes, limits.maxBodyBytes);
        if (opened.code != Status.ok || !newRequest(connection))
        {
            close(connection);
            return;
        }
        connection.headerDeadline = following(limits.headerTimeoutNanos);
        connection.hasHeaderDeadline = true;
        readMore(connection);
    }

    private bool newRequest(Connection* connection) nothrow @nogc
    {
        auto source = CancelSource.create(serverContext, Deadline.none());
        if (!source.ok() || !connection.parser.begin())
            return false;
        move(source.value, connection.cancellation);
        connection.request.cancellation = connection.cancellation.context();
        connection.request.requestId = 0;
        connection.hasHeaderDeadline = false;
        connection.phase = ConnectionPhase.reading;
        return true;
    }

    private void readMore(scope Connection* connection) scope nothrow @nogc
    {
        if (connection.closing || connection.readActive || connection.pendingCount == connection.pending.length)
            return;
        auto context = connection.request.cancellation.withDeadline(following(limits.idleTimeoutNanos));
        if (connection.phase == ConnectionPhase.reading && connection.hasHeaderDeadline
                && connection.parser.awaitingHeaders())
            context = context.withDeadline(connection.headerDeadline);
        const maximum = connection.pending.length - connection.pendingCount;
        const queued = readPlain(tls, connection.id, maximum, context, readDone);
        if (queued == Status.ok)
            connection.readActive = true;
        else
            close(connection);
    }

    private void read(Completion completion, scope const(ubyte)[] bytes) nothrow @nogc
    {
        auto connection = slot(completion.connection);
        if (connection is null || connection.id != completion.connection || !connection.readActive)
            return;
        connection.readActive = false;
        if (connection.closing || completion.status != Status.ok || bytes.length == 0
                || connection.request.cancellation.cancelled())
        {
            close(connection);
            return;
        }
        if (connection.phase == ConnectionPhase.reading)
        {
            receive(connection, bytes);
            return;
        }
        if (bytes.length > connection.pending.length - connection.pendingCount)
        {
            close(connection);
            return;
        }
        const previous = connection.pendingCount;
        connection.pendingCount += bytes.length;
        connection.pending[previous .. connection.pendingCount] = bytes;
        readMore(connection);
    }

    private void receive(Connection* connection, scope const(ubyte)[] bytes) nothrow @nogc
    {
        if (!connection.hasHeaderDeadline)
        {
            connection.headerDeadline = following(limits.headerTimeoutNanos);
            connection.hasHeaderDeadline = true;
        }

        size_t consumed;
        scope BodyLimit choose = limits.maxStreamingRequestBytes ? &bodyLimitForRoute : null;
        const read = connection.parser.feed(bytes, connection.request.arena, consumed, choose);
        connection.pendingCount = 0;
        final switch (read)
        {
        case ReadOutcome.more:
            readMore(connection);
            return;
        case ReadOutcome.rejected:
            reply(connection, failure(connection,
                    connection.parser.responseStatus), false, false);
            return;
        case ReadOutcome.request:
            break;
        }

        const suffix = bytes[consumed .. $];
        if (suffix.length > connection.pending.length)
        {
            close(connection);
            return;
        }
        foreach (index, byteValue; suffix)
            connection.pending[index] = byteValue;
        connection.pendingCount = suffix.length;
        immutable identity = nextId();
        if (identity == 0)
        {
            reply(connection, failure(connection, 503), false, false);
            return;
        }
        connection.request.requestId = identity;
        connection.phase = ConnectionPhase.handling;
        const queued = Reactor.current().postWithCleanup(connection.id.ownerCore,
                connection.handlerTask, TaskContext(identity, connection.request.cancellation));
        if (queued.code != Status.ok)
            reply(connection, failure(connection, 503), false, false);
        else
        {
            connection.taskActive = true;
            readMore(connection);
        }
    }

    private size_t bodyLimitForRoute(Method method, Buffer path, ref scope RequestArena arena) nothrow @nogc
    {
        size_t result = limits.maxBodyBytes;
        const checked = arena.read(path, (scope const(ubyte)[] target) @safe nothrow @nogc {
            const matched = routes.find(method, target);
            if (matched.stream !is null && matched.mode == StreamMode.response)
                result = limits.maxStreamingRequestBytes;
        });
        return checked == Status.ok ? result : limits.maxBodyBytes;
    }

    private void dispatch(ConnectionId id) nothrow @nogc
    {
        auto connection = checked(id, ConnectionPhase.handling);
        if (connection is null)
            return;
        if (connection.request.cancellation.check().code != Status.ok)
        {
            connection.taskActive = false;
            close(connection);
            return;
        }
        auto matched = lookupRoute(routes, &connection.parser.metadata, connection.request.arena);
        if (matched.stream !is null && matched.mode != StreamMode.duplex)
        {
            dispatchStreaming(connection, matched);
            return;
        }
        if (connection.parser.upgradeRequested)
        {
            connection.taskActive = false;
            reply(connection, failure(connection, 400), false, false);
            return;
        }
        const head = connection.parser.metadata.method == Method.head;
        const keep = connection.parser.keepAlive;
        const response = executeMatched(routes, &connection.parser.metadata, connection.request, matched);
        connection.taskActive = false;
        if (connection.request.cancellation.cancelled() || response.error.code == Status.cancelled)
        {
            close(connection);
            return;
        }
        reply(connection, response.ok() ? response.value : failure(connection,
                responseCode(response.error.code)), keep, head);
    }

    private void dispatchStreaming(Connection* connection, const ref Match matched) nothrow @nogc
    {
        if (connection.parser.upgradeRequested && matched.mode != StreamMode.upgrade)
        {
            connection.taskActive = false;
            reply(connection, failure(connection, 400), false, false);
            return;
        }
        connection.phase = ConnectionPhase.streaming;
        connection.streamMode = matched.mode;
        const index = cast(ulong) connection.id.ownerCore * limits.maxConnectionsPerCore + connection.id.slot;
        scope token = StreamToken(this, index, connection.id.generation);
        const result = executeStream(&connection.parser.metadata, connection.request, matched, token);
        if (!connection.streamStarted && !connection.closing)
        {
            connection.taskActive = false;
            const status = result.code == Status.ok ? 500 : responseCode(result.code);
            reply(connection, failure(connection, status), false, false);
            return;
        }
        if (result.code == Status.ok && !connection.streamEnded && !connection.closing)
            token.finish(null, connection.request.cancellation);
        connection.taskActive = false;
        close(connection);
    }

    private Connection* streamConnection(ulong index, ulong generation) return scope nothrow @nogc
    {
        if (index >= connections.length || reactor.currentCore() != index / limits.maxConnectionsPerCore)
            return null;
        auto connection = &connections[cast(size_t) index];
        if (connection.id.generation != generation || connection.phase != ConnectionPhase.streaming
                || !connection.taskActive || connection.closing)
            return null;
        const task = reactor.currentTask();
        return task.ok() && task.value.requestId == connection.request.requestId ? connection : null;
    }

    private static Error streamUnavailable() pure nothrow @nogc
    {
        return Error(Status.unavailable, "HTTP/1 stream is no longer active on this fiber");
    }

    override Error begin(ulong index, ulong generation, ushort status,
            scope const(StreamField)[] fields, ref scope const Context context) scope nothrow @nogc
    {
        auto connection = streamConnection(index, generation);
        if (connection is null)
            return streamUnavailable();
        if (connection.streamStarted)
            return Error(Status.conflict, "HTTP stream response already started");
        const raw = status == 101 && connection.streamMode == StreamMode.upgrade
            && connection.parser.upgradeRequested && connection.parser.versionMinor == 1;
        if (!raw && (status < 200 || status > 599))
            return Error(Status.invalidArgument, "invalid streaming HTTP response status");

        ubyte[ioBytes] header;
        const count = writeStreamHeader(header[], status, fields, connection.parser.versionMinor, raw);
        if (count == 0)
            return Error(Status.invalidArgument, "invalid or oversized streaming HTTP response headers");
        const sent = writeStream(connection, header[0 .. count], context);
        if (sent.code == Status.ok)
        {
            connection.streamRaw = raw;
            connection.streamStarted = true;
        }
        return sent;
    }

    // dfmt off
    override Result!size_t receive(ulong index, ulong generation, scope ubyte[] output,
            ref scope const Context context) scope nothrow @nogc
    {
        auto connection = streamConnection(index, generation);
        if (connection is null)
            return Result!size_t(0, streamUnavailable());
        if (!connection.streamRaw || output.length == 0)
            return Result!size_t(0, Error(Status.invalidArgument, "raw HTTP/1 stream receive requires an upgrade"));
        while (connection.pendingCount == 0 && !connection.closing)
        {
            const ready = waitForStream(context);
            if (ready.code != Status.ok)
                return Result!size_t(0, ready);
        }
        if (connection.closing)
            return Result!size_t(0, connection.request.cancellation.check());
        const count = output.length < connection.pendingCount ? output.length : connection.pendingCount;
        output[0 .. count] = connection.pending[0 .. count];
        const remaining = connection.pendingCount - count;
        foreach (position; 0 .. remaining)
            connection.pending[position] = connection.pending[count + position];
        connection.pendingCount = remaining;
        readMore(connection);
        return Result!size_t(count);
    }
    // dfmt on

    // dfmt off
    override Error send(ulong index, ulong generation, scope const(ubyte)[] body,
            ref scope const Context context) scope nothrow @nogc
    {
        auto connection = streamConnection(index, generation);
        if (connection is null)
            return streamUnavailable();
        if (!connection.streamStarted || connection.streamEnded)
            return Error(Status.conflict, "HTTP stream output is closed");
        const chunked = !connection.streamRaw && connection.parser.versionMinor == 1;
        const bounded = ioBytes < limits.writeQueueBytes ? ioBytes : limits.writeQueueBytes;
        if (chunked && bounded <= 12)
            return Error(Status.resourceExhausted, "HTTP/1 write queue cannot carry chunk framing");
        const capacity = chunked ? bounded - 12 : bounded;
        ubyte[ioBytes] frame;
        size_t first;
        while (first < body.length)
        {
            const count = body.length - first < capacity ? body.length - first : capacity;
            const piece = body[first .. first + count];
            const framed = chunked ? frame[0 .. writeChunk(frame[], piece)] : piece;
            const sent = writeStream(connection, framed, context);
            if (sent.code != Status.ok)
                return sent;
            first += count;
        }
        return context.check();
    }
    // dfmt on

    override Error finish(ulong index, ulong generation, scope const(StreamField)[] trailers,
            ref scope const Context context) scope nothrow @nogc
    {
        auto connection = streamConnection(index, generation);
        if (connection is null)
            return streamUnavailable();
        if (!connection.streamStarted || connection.streamEnded)
            return Error(Status.conflict, "HTTP stream output already closed or not started");
        if (trailers.length != 0)
            return Error(Status.unsupported, "stream trailers require HTTP/2");
        connection.streamEnded = true;
        if (connection.streamRaw || connection.parser.versionMinor == 0)
            return context.check();
        return writeStream(connection, cast(const(ubyte)[]) "0\r\n\r\n", context);
    }

    override Error cancel(ulong index, ulong generation) scope nothrow @nogc
    {
        auto connection = streamConnection(index, generation);
        if (connection is null)
            return streamUnavailable();
        close(connection);
        return Error.init;
    }

    // dfmt off
    private Error writeStream(scope Connection* connection, scope const(ubyte)[] bytes,
            ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        if (connection.writeActive)
            return Error(Status.conflict, "HTTP/1 response write is already pending");
        if (!submitWrite(connection, bytes))
        {
            close(connection);
            return Error(Status.ioError, "unable to write HTTP stream bytes");
        }
        while (connection.writeActive && !connection.closing)
        {
            const resumed = waitForStream(context);
            if (resumed.code != Status.ok)
            {
                close(connection);
                return resumed;
            }
        }
        return connection.closing ? streamUnavailable() : Error.init;
    }
    // dfmt on

    private Error waitForStream(ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        const waiting = following(1_000_000);
        const caller = context.deadline();
        return reactor.yieldUntil(waiting.monotonicNanoseconds < caller.monotonicNanoseconds ? waiting : caller);
    }

    private ulong nextId() nothrow @nogc
    {
        for (;;)
        {
            const prior = atomicLoad(nextRequestId);
            if (prior == ulong.max)
                return 0;
            if (cas(&nextRequestId, prior, prior + 1))
                return prior + 1;
        }
    }

    private Response failure(Connection* connection, ushort status) nothrow @nogc
    {
        return failureResponse(status, connection.request.arena);
    }

    private void reply(Connection* connection, Response response, bool keep, bool head) nothrow @nogc
    {
        if (response.status < 200 || response.status > 599 || !validMediaType(response.contentType))
            response = failure(connection, 500);
        if (response.body.length() > limits.writeQueueBytes)
        {
            response = failure(connection, 503);
            keep = false;
        }
        if (response.status == 204 || response.status == 304)
            response = Response(response.status, null, Buffer.init);

        connection.phase = ConnectionPhase.writing;
        connection.response = response.body;
        connection.keepAlive = keep;
        connection.suppressBody = head;
        connection.bodySent = 0;
        if (queueHeaders(connection, response))
            return;

        connection.response = Buffer.init;
        connection.keepAlive = false;
        if (!queueHeaders(connection, Response(500, null, Buffer.init)))
            close(connection);
    }

    private bool queueHeaders(Connection* connection, Response response) nothrow @nogc
    {
        ubyte[ioBytes] wire;
        const length = writeHeader(wire[], response.status, response.contentType,
                response.body.length(), connection.keepAlive, connection.parser.versionMinor);
        if (length == 0)
            return false;
        if (response.body == Buffer.init)
            return submitWrite(connection, wire[0 .. length]);

        bool admitted;
        const status = connection.request.arena.read(response.body, (scope const(ubyte)[] body) @safe nothrow @nogc {
            size_t first;
            if (!connection.suppressBody)
            {
                first = body.length <= wire.length - length ? body.length : wire.length - length;
                wire[length .. length + first] = body[0 .. first];
            }
            admitted = submitWrite(connection, wire[0 .. length + first]);
            if (admitted)
                connection.bodySent = first;
        });
        return status == Status.ok && admitted;
    }

    private bool submitWrite(scope Connection* connection, scope const(ubyte)[] bytes) scope nothrow @nogc
    {
        auto context = connection.request.cancellation.withDeadline(following(limits.idleTimeoutNanos));
        const submitted = writePlain(tls, connection.id, bytes, context, writeDone);
        if (submitted == Status.ok)
        {
            connection.writeBytes = bytes.length;
            connection.writeActive = true;
        }
        return submitted == Status.ok;
    }

    private void written(Completion completion) nothrow @nogc
    {
        auto connection = slot(completion.connection);
        if (connection is null || connection.id != completion.connection
                || (connection.phase != ConnectionPhase.writing && connection.phase != ConnectionPhase.streaming))
            return;
        connection.writeActive = false;
        if (connection.closing || completion.status != Status.ok
                || completion.bytes != connection.writeBytes || connection.request.cancellation.cancelled())
        {
            close(connection);
            return;
        }

        if (connection.phase == ConnectionPhase.writing)
            writeNext(connection);
    }

    private void writeNext(Connection* connection) nothrow @nogc
    {
        if (!connection.suppressBody && connection.bodySent < connection.response.length())
        {
            if (!submitBodyChunk(connection))
                close(connection);
            return;
        }

        if (!connection.keepAlive || connection.request.arena.reset() != Status.ok || !newRequest(connection))
        {
            close(connection);
            return;
        }
        if (connection.pendingCount != 0)
            receive(connection, connection.pending[0 .. connection.pendingCount]);
        else
            readMore(connection);
    }

    private bool submitBodyChunk(Connection* connection) nothrow @nogc
    {
        bool admitted;
        const response = connection.response;
        const status = connection.request.arena.read(response, (scope const(ubyte)[] body) @safe nothrow @nogc {
            const remaining = body.length - connection.bodySent;
            const count = remaining < ioBytes ? remaining : ioBytes;
            const end = connection.bodySent + count;
            admitted = submitWrite(connection, body[connection.bodySent .. end]);
            if (admitted)
                connection.bodySent = end;
        });
        return status == Status.ok && admitted;
    }

    private void close(scope Connection* connection) scope nothrow @nogc
    {
        if (!connection.closing)
        {
            connection.closing = true;
            connection.cancellation.cancel();
        }
        // Keep the reactor slot reserved through the final transport or task callback.
        if (!connection.readActive && !connection.writeActive && !connection.taskActive)
        {
            closePlain(tls, connection.id);
            retire(connection);
        }
    }

    private void retire(scope Connection* connection) scope nothrow @nogc
    {
        connection.cancellation.cancel();
        connection.request.cancellation = Context.init;
        connection.cancellation.close();
        connection.parser.close();
        destroy(connection.request.arena);
        connection.pending = null;
        connection.pendingCount = 0;
        releaseBytes(connection.owned);
        connection.phase = ConnectionPhase.free;
        connection.readActive = false;
        connection.writeActive = false;
        connection.taskActive = false;
        connection.closing = false;
        connection.streamStarted = false;
        connection.streamEnded = false;
        connection.streamRaw = false;
        connection.id = ConnectionId.init;
    }
}
