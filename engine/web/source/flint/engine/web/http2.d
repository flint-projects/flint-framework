/// Bounded HTTP/2 stream multiplexing on caller-owned reactor loops.
module flint.engine.web.http2;

import core.atomic : atomicLoad, atomicOp, cas;
import core.lifetime : move;
import core.time : MonoTime, ticksToNSecs;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.reactor : Completion, CompletionDelegate, ConnectionId, IoId, Reactor,
    TaskContext, TaskDelegate, TaskWaker;
import flint.engine.web.dispatch : executeMatched, executeStream, failureResponse, liveBody, lookupRoute;
import flint.engine.web.ffi.http2 : H2Chunk, H2Event, H2Output, H2Session, deferOutput, holdStreamCredit;
import flint.engine.web.http1 : Http1Reader;
import flint.engine.web.http2_endpoint : Http2Endpoint;
import flint.engine.web.router : Match, RouteTable;
import flint.engine.web.stream : StreamEndpoint, StreamField, StreamMode, StreamToken;
import flint.engine.web.stream_queues : StreamQueues;
import flint.engine.web.sys.ownership : releaseBytes, reserveBytes;
import flint.engine.web.transport : TlsTransport, awaitStream, closePlain, readPlain, wakeStream;
import flint.engine.web.types : HeaderRecord, Method, RequestContext, Response, ServerOptions, maximumFields;
import flint.engine.web.wire : allowBytes, formatAllow, httpDate, responseCode, validMediaType;

@safe:

private enum ioBytes = 4096;
private enum streamLimit = 100;
private enum streamsPerCore = 1024;

// RFC 9113 stream errors, passed as scalar choices into the provider.
private enum Protocol : int
{
    ok = 0,
    protocolError = 1,
    internalError = 2,
    refused = 7,
    cancelled = 8,
    exhausted = 11
}

private enum StreamPhase : ubyte
{
    free,
    reading,
    ready,
    admitted,
    responding
}

private struct Session
{
    ConnectionId id;
    H2Session native;
    CancelSource transfer;
    uint[streamLimit] streams;
    bool readActive;
    bool writeActive;
    IoId writeTicket;
    bool closing;
    bool draining;
    bool peerClosing;
    bool reciprocalGoaway;
    size_t sent;
    Deadline firstRequestDeadline;
}

/// A worker-local stream slot cannot recycle while a posted handler or final send can reference it.
private struct Stream
{
    H2Driver!() runtime;
    TaskDelegate action;
    uint index;
    ConnectionId connection;
    int number;
    StreamPhase phase;
    bool providerClosed;
    bool entered;
    bool duplex;
    bool incremental;
    bool inputEnded;
    bool startedOutput;
    bool finishedOutput;
    StreamQueues queues;
    Deadline headerDeadline;
    HeaderRecord[maximumFields] headers;
    Http1Reader assembly;
    RequestContext request;
    CancelSource cancel;
    ubyte[] memory;
    Buffer response;
    size_t offset;
    /// The stream's handler fiber while it waits for input, output credit or the stream's end.
    TaskWaker waiter;

    void execute() nothrow @nogc
    {
        runtime.dispatch(index);
    }
}

// A template class is absent from ModuleInfo, and only flint.engine.web.h2.enableHttp2 instantiates this one, so only
// a program that enables HTTP/2 retains the driver and nghttp2.
package(flint.engine.web) final class H2Driver() : StreamEndpoint, Http2Endpoint
{
    private ServerOptions options;
    private CompletionDelegate writeDone;
    private RouteTable routes;
    private TlsTransport tls;
    private Context root;
    /// Cancelled when the server begins to drain: no new session or stream is admitted.
    private Context drainContext;
    private Session[] connections;
    private Stream[] streams;
    private uint workerStreams;
    private size_t arenaBytes;
    private shared ulong lastRequest;
    private shared uint activeSessions;
    private shared uint liveStreams;

    this(ServerOptions options, RouteTable routes, Context root, Context drain)
    {
        this.options = options;
        writeDone = &written;
        this.routes = routes;
        this.root = root;
        drainContext = drain;
        const bodyCapacity = options.maxBodyBytes > options.maxStreamingRequestBytes
            ? options.maxBodyBytes : options.maxStreamingRequestBytes;
        arenaBytes = options.maxHeaderBytes + bodyCapacity + options.writeQueueBytes + 1024;
        const capacity = options.maxConnectionsPerCore * options.maxStreamsPerConnection;
        workerStreams = capacity < streamsPerCore ? capacity : streamsPerCore;
        connections = new Session[options.cores * options.maxConnectionsPerCore];
        streams = new Stream[options.cores * workerStreams];
        foreach (index, ref stream; streams)
        {
            stream.runtime = this;
            stream.index = cast(uint) index;
            stream.action = &stream.execute;
            stream.assembly.metadata.headers = stream.headers[];
        }
    }

    void setTls(TlsTransport value)
    {
        tls = value;
    }

    uint activeCount() nothrow @nogc
    {
        return atomicLoad(activeSessions);
    }

    /// Streams between admission and retirement; a draining server waits for these, not for idle sessions.
    uint activeStreams() nothrow @nogc
    {
        return atomicLoad(liveStreams);
    }

    void accept(ConnectionId id) nothrow @nogc
    {
        auto connection = slot(id);
        if (connection is null || connection.id.generation != 0 || drainContext.cancelled())
        {
            closePlain(tls, id);
            return;
        }
        auto lifetime = CancelSource.create(root, Deadline.none());
        if (!lifetime.ok() || connection.native.open(id.generation, options.maxStreamsPerConnection).code != Status.ok)
        {
            closePlain(tls, id);
            return;
        }
        move(lifetime.value, connection.transfer);
        connection.id = id;
        atomicOp!"+="(activeSessions, 1U);
        connection.firstRequestDeadline = following(options.headerTimeoutNanos);
        armRead(connection);
        if (!connection.closing && connection.id.generation != 0)
            flush(connection);
    }

    void release() nothrow @nogc
    {
        foreach (ref stream; streams)
        {
            if (stream.phase != StreamPhase.free)
                retire(&stream);
        }
        foreach (ref connection; connections)
        {
            connection.transfer.close();
            connection.native.close();
        }
        root = Context.init;
        drainContext = Context.init;
    }

    private Session* slot(ConnectionId id) return scope nothrow @nogc
    {
        if (id.ownerCore >= options.cores || id.slot >= options.maxConnectionsPerCore)
            return null;
        return &connections[id.ownerCore * options.maxConnectionsPerCore + id.slot];
    }

    private Session* live(ConnectionId id) return scope nothrow @nogc
    {
        auto connection = slot(id);
        return connection !is null && connection.id == id && id.generation != 0 ? connection : null;
    }

    private Stream* streamFor(scope Session* connection, int number) return scope nothrow @nogc
    {
        foreach (index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index != 0 && streams[index - 1].number == number)
                return &streams[index - 1];
        }
        return null;
    }

    private int admitStream(scope Session* connection, int number) scope nothrow @nogc
    {
        // REFUSED_STREAM tells the peer the request was not processed, so it may retry elsewhere.
        if (number <= 0 || connection.closing || connection.peerClosing || drainContext.cancelled())
            return Protocol.refused;

        uint* member;
        foreach (ref index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index == 0)
            {
                member = &index;
                break;
            }
        }
        if (member is null)
            return Protocol.refused;

        immutable first = connection.id.ownerCore * workerStreams;
        foreach (ref stream; streams[first .. first + workerStreams])
        {
            if (stream.phase != StreamPhase.free)
                continue;

            if (!prepareStream(&stream, connection.id, number))
                return Protocol.refused;
            connection.firstRequestDeadline = Deadline.none();
            *member = stream.index + 1;
            return Protocol.ok;
        }
        return Protocol.refused;
    }

    private bool prepareStream(scope Stream* stream, ConnectionId connection, int number) scope nothrow @nogc
    {
        auto source = CancelSource.create(root, Deadline.none());
        if (!source.ok())
            return false;
        const total = arenaBytes + options.maxHeaderBytes;
        stream.memory = reserveBytes(total);
        if (stream.memory.length != total)
            return false;
        auto arena = RequestArena(stream.memory[0 .. arenaBytes]);
        move(arena, stream.request.arena);
        stream.assembly.prepare(stream.memory[arenaBytes .. $], options.maxHeaderBytes, options.maxBodyBytes);
        if (!stream.assembly.begin())
        {
            retire(stream);
            return false;
        }
        move(source.value, stream.cancel);
        stream.request.cancellation = stream.cancel.context();
        stream.connection = connection;
        stream.number = number;
        stream.headerDeadline = following(options.headerTimeoutNanos);
        stream.phase = StreamPhase.reading;
        atomicOp!"+="(liveStreams, 1U);
        return true;
    }

    private int event(scope Session* connection, H2Event event, int number, uint code,
            scope const(ubyte)[] name, scope const(ubyte)[] bytes) scope nothrow @nogc
    {
        if (event == H2Event.begin)
            return admitStream(connection, number);
        if (event == H2Event.goaway)
        {
            if (!connection.peerClosing)
            {
                connection.peerClosing = true;
                connection.firstRequestDeadline = following(options.idleTimeoutNanos);
            }
            return Protocol.ok;
        }
        auto stream = streamFor(connection, number);
        if (stream is null)
            return Protocol.ok;
        // Every remaining event changes input, reset or close state that a waiting handler re-checks.
        wakeStream(stream.waiter);

        if (event == H2Event.reset)
        {
            stream.cancel.cancel();
            return Protocol.ok;
        }
        if (event == H2Event.closed)
        {
            stream.providerClosed = true;
            if (code != Protocol.ok)
                stream.cancel.cancel();
            return Protocol.ok;
        }
        return inputEvent(stream, event, code, name, bytes);
    }

    private int inputEvent(scope Stream* stream, H2Event event, uint code, scope const(ubyte)[] name,
            scope const(ubyte)[] bytes) scope nothrow @nogc
    {
        if (stream.duplex)
            return duplexInput(stream, event, code, bytes);
        if (stream.phase != StreamPhase.reading)
            return Protocol.protocolError;

        Status status;
        switch (event)
        {
        case H2Event.headers:
            stream.headerDeadline = Deadline.none();
            return receivedHeaders(stream);
        case H2Event.field:
            status = stream.assembly.receiveH2Header(name, bytes, code != 0, stream.request.arena);
            break;
        case H2Event.body:
            status = stream.assembly.receiveH2Body(bytes, stream.request.arena);
            break;
        case H2Event.end:
            if (!stream.assembly.finishH2(stream.request.arena))
                return Protocol.protocolError;
            stream.phase = StreamPhase.ready;
            return Protocol.ok;
        default:
            return Protocol.internalError;
        }
        if (status == Status.ok)
            return Protocol.ok;
        stream.cancel.cancel();
        return status == Status.resourceExhausted ? Protocol.exhausted : Protocol.protocolError;
    }

    private int receivedHeaders(scope Stream* stream) scope nothrow @nogc
    {
        const duplexRoutes = routes.hasDuplex();
        if (!duplexRoutes && options.maxStreamingRequestBytes == 0)
            return Protocol.ok;
        if (duplexRoutes && !stream.assembly.finishH2(stream.request.arena))
            return Protocol.protocolError;
        const matched = lookupRoute(routes, &stream.assembly.metadata, stream.request.arena);
        if (matched.stream is null)
            return Protocol.ok;
        if (matched.mode == StreamMode.response && options.maxStreamingRequestBytes != 0)
            stream.assembly.setBodyLimit(options.maxStreamingRequestBytes);
        if (matched.mode != StreamMode.duplex)
            return Protocol.ok;
        if (!openQueues(stream, true))
            return Protocol.exhausted;
        stream.phase = StreamPhase.ready;
        return Protocol.ok;
    }

    private bool openQueues(scope Stream* stream, bool duplex) scope nothrow @nogc
    {
        const outgoing = options.writeQueueBytes < ioBytes ? options.writeQueueBytes : ioBytes;
        if (!stream.queues.open(duplex, outgoing))
            return false;
        stream.incremental = true;
        stream.duplex = duplex;
        return true;
    }

    // dfmt off
    private static int duplexInput(scope Stream* stream, H2Event event, uint code,
            scope const(ubyte)[] bytes) nothrow @nogc
    {
        switch (event)
        {
        case H2Event.field:
            return code != 0 ? Protocol.ok : Protocol.protocolError;
        case H2Event.end:
            stream.inputEnded = true;
            return Protocol.ok;
        case H2Event.body:
            if (stream.phase == StreamPhase.responding)
                return Protocol.ok;
            return stream.queues.admit(bytes) ? holdStreamCredit : Protocol.exhausted;
        default:
            return Protocol.protocolError;
        }
    }
    // dfmt on

    private static Deadline following(long timeout) nothrow @nogc
    {
        const timestamp = ticksToNSecs(MonoTime.currTime.ticks);
        return Deadline(timeout >= long.max - timestamp ? long.max - 1 : timestamp + timeout);
    }

    private Context receiveContext(scope Session* connection) nothrow @nogc
    {
        auto earliest = following(options.idleTimeoutNanos);
        if (connection.firstRequestDeadline.monotonicNanoseconds < earliest.monotonicNanoseconds)
            earliest = connection.firstRequestDeadline;
        foreach (index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index == 0)
                continue;
            const candidate = streams[index - 1].headerDeadline;
            if (candidate.monotonicNanoseconds < earliest.monotonicNanoseconds)
                earliest = candidate;
        }
        return connection.transfer.context().withDeadline(earliest);
    }

    private void armRead(scope Session* connection) nothrow @nogc
    {
        if (connection.closing || connection.draining || connection.readActive)
            return;
        const queued = readPlain(tls, connection.id, ioBytes, receiveContext(connection), &read);
        if (queued == Status.ok)
            connection.readActive = true;
        else
            abort(connection);
    }

    private void read(Completion completion, scope const(ubyte)[] bytes) nothrow @nogc
    {
        auto connection = live(completion.connection);
        if (connection is null)
            return;
        connection.readActive = false;
        if (root.cancelled() && completion.status == Status.cancelled && !connection.closing)
        {
            beginDrain(connection);
            return;
        }
        if (connection.closing || completion.status != Status.ok || bytes.length == 0)
        {
            abort(connection);
            return;
        }
        const parsed = connection.native.feed(bytes, (H2Event kind, int number, uint code,
                scope const(ubyte)[] name, scope const(ubyte)[] value) @safe nothrow @nogc {
            return event(connection, kind, number, code, name, value);
        });
        if (!parsed)
        {
            abort(connection);
            return;
        }

        schedule(connection);
        if (connection.id.generation != 0)
            armRead(connection);
        if (connection.id.generation != 0)
            flush(connection);
    }

    private void schedule(scope Session* connection) nothrow @nogc
    {
        foreach (index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index == 0)
                continue;
            auto stream = &streams[index - 1];
            if (stream.phase != StreamPhase.ready || stream.providerClosed)
                continue;

            stream.request.requestId = requestId();
            stream.phase = StreamPhase.admitted;
            const posted = Reactor.current().postWithCleanup(connection.id.ownerCore,
                    stream.action, TaskContext(stream.request.requestId, stream.request.cancellation));
            if (posted.code != Status.ok)
            {
                stream.phase = StreamPhase.responding;
                if (!connection.native.reply(stream.number, 503, null, 0, true))
                {
                    abort(connection);
                    return;
                }
            }
        }
    }

    private ulong requestId() nothrow @nogc
    {
        for (;;)
        {
            const previous = atomicLoad(lastRequest);
            if (previous == ulong.max)
                return 0;
            if (cas(&lastRequest, previous, previous + 1))
                return previous + 1;
        }
    }

    private void dispatch(uint index) nothrow @nogc
    {
        auto stream = &streams[index];
        auto connection = live(stream.connection);
        if (connection is null || stream.phase != StreamPhase.admitted)
            return;

        stream.entered = true;
        if (discard(connection, stream))
            return;
        const matched = lookupRoute(routes, &stream.assembly.metadata, stream.request.arena);
        if (matched.stream !is null && matched.mode != StreamMode.upgrade)
        {
            dispatchStream(connection, stream, matched);
            return;
        }
        auto result = executeMatched(routes, &stream.assembly.metadata, stream.request, matched);
        const allowed = matched.allowed;
        stream.phase = StreamPhase.responding;
        if (discard(connection, stream))
            return;

        if (result.error.code == Status.cancelled)
        {
            if (!connection.native.reset(stream.number, Protocol.cancelled))
                abort(connection);
            else
                flush(connection);
            return;
        }

        Response response = result.ok() ? result.value
            : failureResponse(responseCode(result.error.code), stream.request.arena);
        queueResponse(connection, stream, response, allowed);
    }

    private void dispatchStream(Session* connection, Stream* stream, const ref Match matched) nothrow @nogc
    {
        if (!stream.incremental && !openQueues(stream, false))
        {
            stream.phase = StreamPhase.responding;
            queueResponse(connection, stream, failureResponse(503, stream.request.arena));
            return;
        }
        scope token = StreamToken(this, stream.index, stream.request.requestId);
        const result = executeStream(&stream.assembly.metadata, stream.request, matched, token);
        if (discard(connection, stream))
            return;
        if (!stream.startedOutput)
        {
            stream.phase = StreamPhase.responding;
            stream.incremental = false;
            queueResponse(connection, stream, failureResponse(result.code == Status.ok
                    ? 500 : responseCode(result.code), stream.request.arena));
            return;
        }
        if (!stream.finishedOutput)
        {
            if (result.code == Status.ok)
                token.finish(null, stream.request.cancellation);
            else
                token.cancel();
        }
        const pending = stream.queues.inbound;
        stream.phase = StreamPhase.responding;
        if (pending != 0 && !stream.providerClosed && !connection.native.consumeStream(stream.number, pending))
        {
            abort(connection);
            return;
        }
        flush(connection);
    }

    private Stream* activeStream(ulong index, ulong generation) return scope nothrow @nogc
    {
        if (index >= streams.length || Reactor.current().currentCore() != index / workerStreams)
            return null;
        auto stream = &streams[cast(size_t) index];
        if (!stream.incremental || stream.phase != StreamPhase.admitted || stream.providerClosed
                || stream.request.requestId != generation || !stream.entered)
            return null;
        const task = Reactor.current().currentTask();
        return task.ok() && task.value.requestId == generation ? stream : null;
    }

    private static Error unavailable() pure nothrow @nogc
    {
        return Error(Status.unavailable, "HTTP/2 stream is no longer active on this fiber");
    }

    override Error begin(ulong index, ulong generation, ushort status,
            scope const(StreamField)[] fields, ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        auto stream = activeStream(index, generation);
        if (stream is null)
            return unavailable();
        if (stream.startedOutput)
            return Error(Status.conflict, "HTTP/2 response already started");
        if (status < 200 || status > 599)
            return Error(Status.invalidArgument, "invalid HTTP/2 response status");
        auto connection = live(stream.connection);
        if (connection is null || connection.closing || connection.draining
                || !connection.native.streamHeaders(stream.number, status, fields))
            return unavailable();
        stream.startedOutput = true;
        flush(connection);
        return stream.request.cancellation.check();
    }

    // dfmt off
    override Result!size_t receive(ulong index, ulong generation, scope ubyte[] output,
            ref scope const Context context) scope nothrow @nogc
    {
        auto stream = activeStream(index, generation);
        if (stream is null)
            return Result!size_t(0, unavailable());
        if (!stream.duplex || output.length == 0)
            return Result!size_t(0, Error(Status.invalidArgument, "HTTP/2 receive requires a duplex stream"));
        while (stream.queues.inbound == 0 && !stream.inputEnded)
        {
            const resumed = waitForStream(stream, context);
            if (resumed.code != Status.ok)
                return Result!size_t(0, resumed);
        }
        const checked = context.check();
        if (checked.code != Status.ok)
            return Result!size_t(0, checked);
        const count = stream.queues.read(output);
        if (count != 0)
        {
            auto connection = live(stream.connection);
            if (connection is null || connection.closing || !connection.native.consumeStream(stream.number, count))
                return Result!size_t(0, unavailable());
            flush(connection);
        }
        return Result!size_t(count);
    }
    // dfmt on

    // dfmt off
    override Error send(ulong index, ulong generation, scope const(ubyte)[] bytes,
            ref scope const Context context) scope nothrow @nogc
    {
        auto stream = activeStream(index, generation);
        if (stream is null)
            return unavailable();
        if (!stream.startedOutput || stream.finishedOutput)
            return Error(Status.conflict, "HTTP/2 stream output is closed");
        size_t offset;
        while (offset < bytes.length)
        {
            while (stream.queues.outbound != 0)
            {
                const available = waitForStream(stream, context);
                if (available.code != Status.ok)
                    return available;
            }
            const sent = queueChunk(stream, bytes[offset .. $], context);
            if (!sent.ok())
                return sent.error;
            offset += sent.value;
        }
        return stream.request.cancellation.check();
    }
    // dfmt on

    // dfmt off
    private Result!size_t queueChunk(scope Stream* stream, scope const(ubyte)[] bytes,
            ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return Result!size_t(0, checked);
        auto connection = live(stream.connection);
        if (connection is null || connection.closing || connection.draining || stream.providerClosed)
            return Result!size_t(0, unavailable());
        const stored = stream.queues.write(bytes);
        if (stored == 0 || !connection.native.resumeStream(stream.number))
            return Result!size_t(0, unavailable());
        flush(connection);
        return Result!size_t(stored);
    }
    // dfmt on

    override Error finish(ulong index, ulong generation, scope const(StreamField)[] trailers,
            ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        auto stream = activeStream(index, generation);
        if (stream is null)
            return unavailable();
        if (!stream.startedOutput || stream.finishedOutput)
            return Error(Status.conflict, "HTTP/2 stream output already closed or not started");
        auto connection = live(stream.connection);
        if (connection is null || connection.closing || connection.draining
                || !connection.native.streamHeaders(stream.number, 0, trailers)
                || !connection.native.resumeStream(stream.number))
            return unavailable();
        stream.finishedOutput = true;
        flush(connection);
        return Error.init;
    }

    override Error cancel(ulong index, ulong generation) scope nothrow @nogc
    {
        auto stream = activeStream(index, generation);
        if (stream is null)
            return unavailable();
        auto connection = live(stream.connection);
        stream.cancel.cancel();
        if (connection is null || connection.closing || !connection.native.reset(stream.number, Protocol.cancelled))
            return unavailable();
        flush(connection);
        return Error.init;
    }

    /// Stream events, output drained by `copyBody` and connection abort wake the waiting handler.
    private Error waitForStream(scope Stream* stream, ref scope const Context context) scope nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        if (stream.providerClosed)
            return unavailable();
        return awaitStream(stream.waiter, context);
    }

    private bool discard(Session* connection, Stream* stream) nothrow @nogc
    {
        if (!connection.closing && !connection.draining && !stream.providerClosed
                && stream.request.cancellation.check().code == Status.ok)
            return false;
        stream.phase = StreamPhase.responding;
        if (connection.closing)
            finishClose(connection);
        else
            flush(connection);
        return true;
    }

    private void queueResponse(Session* connection, Stream* stream, Response response, ubyte allow = 0) nothrow @nogc
    {
        if (response.status < 200 || response.status > 599 || !validMediaType(response.contentType)
                || !liveBody(response.body, stream.request.arena))
            response = failureResponse(500, stream.request.arena);
        if (response.body.length() > options.writeQueueBytes)
            response = failureResponse(503, stream.request.arena);
        if (response.status == 204 || response.status == 304)
            response = Response(response.status, null, Buffer.init);

        // HEAD keeps the representation's Content-Length but sends no content.
        const head = stream.assembly.metadata.method == Method.head;
        stream.response = head ? Buffer.init : response.body;
        stream.offset = 0;
        char[allowBytes] methods = void;
        const allowed = response.status == 405 ? methods[0 .. formatAllow(allow, methods)] : null;
        if (!connection.native.respond(stream.number, response.status, response.contentType,
                response.body.length(), httpDate(), allowed))
            abort(connection);
        else
            flush(connection);
    }

    private H2Chunk copyBody(scope Session* connection, int number, scope ubyte[] output) scope nothrow @nogc
    {
        auto stream = streamFor(connection, number);
        if (stream is null || stream.providerClosed)
            return H2Chunk.init;
        if (stream.incremental)
        {
            const count = stream.queues.send(output);
            if (count != 0)
                wakeStream(stream.waiter);
            const ending = stream.finishedOutput && stream.queues.outbound == 0;
            return H2Chunk(count != 0 || ending ? cast(ptrdiff_t) count : deferOutput, ending);
        }
        if (stream.phase != StreamPhase.responding)
            return H2Chunk.init;
        if (stream.response == Buffer.init)
            return H2Chunk(0, true);

        size_t stored;
        const copied = stream.request.arena.read(stream.response, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            const remaining = bytes.length - stream.offset;
            stored = remaining <= output.length ? remaining : output.length;
            output[0 .. stored] = bytes[stream.offset .. stream.offset + stored];
            stream.offset += stored;
        });
        return copied == Status.ok ? H2Chunk(cast(ptrdiff_t) stored,
                stream.offset == stream.response.length()) : H2Chunk.init;
    }

    private void flush(scope Session* connection) scope nothrow @nogc
    {
        if (connection.closing || connection.writeActive)
            return;

        ubyte[ioBytes] bytes;
        const capacity = options.writeQueueBytes < bytes.length ? options.writeQueueBytes : bytes.length;
        scope sink = H2Output((H2Event kind, int number, uint code, scope const(ubyte)[] name,
                scope const(ubyte)[] data) @safe nothrow @nogc {
            return event(connection, kind, number, code, name, data);
        }, (int number, scope ubyte[] data) @safe nothrow @nogc {
            return copyBody(connection, number, data);
        });
        const written = connection.native.send(bytes[0 .. capacity], sink);
        if (!written.ok())
        {
            abort(connection);
            return;
        }
        const count = written.value;
        if (count == 0)
        {
            reap(connection);
            if (connection.draining)
                abort(connection);
            else if (connection.native.done())
                finishPeerShutdown(connection);
            return;
        }

        // Finish any partially transmitted frame before appending GOAWAY. The idle
        // deadline and explicit connection abort still bound this owned write.
        auto context = Context.init.withDeadline(following(options.idleTimeoutNanos));
        Status write;
        if (tls is null)
        {
            const queued = Reactor.current().writeWith(connection.id, bytes[0 .. count], context, writeDone);
            connection.writeTicket = queued.value;
            write = queued.error.code;
        }
        else
            write = tls.write(connection.id, bytes[0 .. count], context, writeDone);
        if (write != Status.ok)
        {
            abort(connection);
            return;
        }
        connection.writeActive = true;
        connection.sent = count;
    }

    private void finishPeerShutdown(scope Session* connection) scope nothrow @nogc
    {
        if (!connection.peerClosing)
            abort(connection);
        else if (!connection.reciprocalGoaway)
        {
            connection.reciprocalGoaway = true;
            if (!connection.native.drain())
                abort(connection);
            else
                flush(connection);
        }
    }

    private void written(Completion completion) nothrow @nogc
    {
        auto connection = live(completion.connection);
        if (connection is null)
            return;
        connection.writeActive = false;
        connection.writeTicket = IoId.init;
        if (connection.closing || completion.status != Status.ok || completion.bytes != connection.sent)
        {
            abort(connection);
            return;
        }
        if (root.cancelled() && !connection.draining)
        {
            beginDrain(connection);
            return;
        }
        if (!connection.native.pending())
            reap(connection);
        flush(connection);
    }

    private void beginDrain(scope Session* connection) nothrow @nogc
    {
        if (!connection.draining)
        {
            connection.draining = true;
            if (!connection.native.drain())
            {
                abort(connection);
                return;
            }
        }
        flush(connection);
    }

    private void reap(scope Session* connection) scope nothrow @nogc
    {
        foreach (ref index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index == 0)
                continue;
            auto stream = &streams[index - 1];
            if (stream.providerClosed && stream.phase != StreamPhase.admitted)
            {
                retire(stream);
                index = 0;
            }
        }
    }

    private void abort(scope Session* connection) scope nothrow @nogc
    {
        if (!connection.closing)
        {
            connection.closing = true;
            connection.transfer.cancel();
            foreach (index; connection.streams[0 .. options.maxStreamsPerConnection])
            {
                if (index != 0)
                {
                    streams[index - 1].cancel.cancel();
                    wakeStream(streams[index - 1].waiter);
                }
            }
            if (connection.draining || (tls !is null && connection.writeActive))
                closePlain(tls, connection.id);
            else if (connection.writeActive)
                Reactor.current().cancel(connection.writeTicket);
        }
        finishClose(connection);
    }

    private void finishClose(scope Session* connection) scope nothrow @nogc
    {
        if (!connection.closing || connection.readActive || connection.writeActive)
            return;
        foreach (ref index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index == 0)
                continue;
            auto stream = &streams[index - 1];
            if (stream.phase != StreamPhase.admitted)
            {
                retire(stream);
                index = 0;
            }
        }
        foreach (index; connection.streams[0 .. options.maxStreamsPerConnection])
        {
            if (index != 0)
                return;
        }
        // Hold the physical reactor slot through the last entered stream task and I/O callback.
        if (!connection.draining)
            closePlain(tls, connection.id);
        connection.transfer.close();
        connection.native.close();
        connection.id = ConnectionId.init;
        connection.closing = false;
        connection.draining = false;
        connection.peerClosing = false;
        connection.reciprocalGoaway = false;
        atomicOp!"-="(activeSessions, 1U);
    }

    private void retire(scope Stream* stream) scope nothrow @nogc
    {
        if (stream.phase != StreamPhase.free)
            atomicOp!"-="(liveStreams, 1U);
        stream.cancel.cancel();
        stream.request.cancellation = Context.init;
        stream.cancel.close();
        stream.assembly.close();
        destroy(stream.request.arena);
        releaseBytes(stream.memory);
        stream.phase = StreamPhase.free;
        stream.providerClosed = false;
        stream.entered = false;
        stream.duplex = false;
        stream.incremental = false;
        stream.inputEnded = false;
        stream.startedOutput = false;
        stream.finishedOutput = false;
        stream.queues.clear();
        stream.response = Buffer.init;
        stream.waiter = TaskWaker.init;
        stream.number = 0;
        stream.connection = ConnectionId.init;
    }
}
