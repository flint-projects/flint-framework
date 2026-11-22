/// In-process gRPC over the pinned HTTP/2 server and client: call shapes, wire errors, deadlines and teardown.
module flint.rpc.grpc_transport_behavior;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.reactor : Reactor;
import flint.http : ClientOptions, HttpClient, HttpStream, HttpStreamField, HttpStreamMode, HttpStreamOptions;
import flint.rpc : GrpcCall, GrpcCallOptions, GrpcService, RpcCode, RpcStatus, RpcStream,
    StreamLimits, beginGrpc, registerGrpc;
import flint.web : Method, Request, RequestContext, Server, ServerOptions, StreamField, StreamMode,
    StreamRoute, StreamToken;

@safe:

private enum service = "flint.rpc.transport.Echo";

/// Server actions. Shared counters let the test thread observe owner-fiber outcomes.
private final class Actions
{
    shared uint onceOnly;
    shared uint heldRuns;
    shared uint heldMessages;
    shared uint heldOutcome;

    Error unary(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        const next = stream.receive(context.arena, context.cancellation);
        if (!next.ok())
            return next.error;
        const end = stream.receive(context.arena, context.cancellation);
        if (end.error.code != Status.notFound)
            return end.ok() ? Error(Status.invalidArgument, "unary call has several inputs") : end.error;
        return stream.send(next.value, context.arena, context.cancellation);
    }

    // dfmt off
    Error clientStream(ref scope Request request, ref scope RpcStream stream,
            ref scope RequestContext context) nothrow @nogc
    {
        uint count;
        for (;;)
        {
            const next = stream.receive(context.arena, context.cancellation);
            if (!next.ok())
            {
                if (next.error.code != Status.notFound)
                    return next.error;
                ubyte[1] total = [cast(ubyte) count];
                const reply = context.arena.copyIn(total[]);
                return reply.ok() ? stream.send(reply.value, context.arena, context.cancellation) : reply.error;
            }
            ++count;
        }
    }
    // dfmt on

    // dfmt off
    Error serverStream(ref scope Request request, ref scope RpcStream stream,
            ref scope RequestContext context) nothrow @nogc
    {
        const next = stream.receive(context.arena, context.cancellation);
        if (!next.ok())
            return next.error;
        foreach (_; 0 .. 3)
        {
            const sent = stream.send(next.value, context.arena, context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
        return Error.init;
    }
    // dfmt on

    Error bidi(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        for (;;)
        {
            const item = stream.receive(context.arena, context.cancellation);
            if (!item.ok())
                return item.error.code == Status.notFound ? Error.init : item.error;
            const sent = stream.send(item.value, context.arena, context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
    }

    Error status(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        const message = context.arena.copyIn(cast(const(ubyte)[]) "10% \xf0\x9f\x9a\x80");
        if (!message.ok())
            return message.error;
        if (stream.finish(RpcStatus(RpcCode.aborted, message.value)).code != Status.ok)
            return Error(Status.ioError, "first terminal status failed");
        // Completion happens exactly once: later finish, send and cancel calls are rejected.
        const again = stream.finish(RpcStatus.init);
        const cancelled = stream.cancel();
        const sent = stream.send(Buffer.init, context.arena, context.cancellation);
        const once = again.code == Status.conflict && cancelled.code == Status.conflict && sent.code != Status.ok;
        atomicStore(onceOnly, once ? 1 : 2);
        return Error.init;
    }

    Error wait(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        for (;;)
        {
            const item = stream.receive(context.arena, context.cancellation);
            if (!item.ok() && item.error.code != Status.notFound)
                return item.error;
            if (!item.ok())
                break;
        }
        auto loop = Reactor.current();
        while (context.cancellation.check().code == Status.ok)
        {
            if (loop.yieldUntil(Deadline.afterMillis(10)).code != Status.ok)
                break;
        }
        return context.cancellation.check();
    }

    Error hold(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        scope (exit)
            atomicOp!"+="(heldRuns, 1);
        for (;;)
        {
            const item = stream.receive(context.arena, context.cancellation);
            if (!item.ok())
            {
                atomicStore(heldOutcome, cast(uint) item.error.code + 1);
                return item.error;
            }
            atomicOp!"+="(heldMessages, 1);
        }
    }
}

/// Raw routes that produce invalid or incomplete gRPC responses for the client.
private final class RawRoutes
{
    Error noStatus(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        static immutable ubyte[6] message = [0, 0, 0, 0, 1, 42];
        return reply(context, token, message[], null);
    }

    Error oversized(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        static immutable ubyte[5] prefix = [0, 0, 0x40, 0, 1];
        return reply(context, token, prefix[], [StreamField("grpc-status", "0")]);
    }

    Error compressed(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        static immutable ubyte[5] prefix = [1, 0, 0, 0, 0];
        return reply(context, token, prefix[], [StreamField("grpc-status", "0")]);
    }

    Error truncated(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        static immutable ubyte[6] partial = [0, 0, 0, 0, 3, 1];
        return reply(context, token, partial[], [StreamField("grpc-status", "0")]);
    }

    Error badStatus(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        return reply(context, token, null, [StreamField("grpc-status", "x")]);
    }

    Error wrongMedia(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        drain(context, token);
        const opened = token.begin(200, [StreamField("content-type", "text/plain")], context.cancellation);
        if (opened.code != Status.ok)
            return opened;
        return token.finish([StreamField("grpc-status", "0")], context.cancellation);
    }

    private static void drain(ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        ubyte[512] sink;
        for (;;)
        {
            const read = token.receive(sink[], context.cancellation);
            if (!read.ok() || read.value == 0)
                return;
        }
    }

    // dfmt off
    private static Error reply(ref scope RequestContext context, scope StreamToken token,
            scope const(ubyte)[] data, scope const(StreamField)[] trailers) nothrow @nogc
    {
        drain(context, token);
        const opened = token.begin(200, [StreamField("content-type", "application/grpc")], context.cancellation);
        if (opened.code != Status.ok)
            return opened;
        if (data.length != 0)
        {
            const sent = token.send(data, context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
        return token.finish(trailers, context.cancellation);
    }
    // dfmt on
}

/// Select an unused loopback port for an in-process listener.
private ushort freePort() @system
{
    import std.socket : InternetAddress, TcpSocket;

    auto probe = new TcpSocket();
    scope (exit)
        probe.close();
    probe.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private bool contains(ref scope RequestArena arena, Buffer buffer, string match)
{
    import std.string : indexOf;

    bool found;
    assert(arena.read(buffer, (scope const(ubyte)[] data) @safe nothrow @nogc {
            found = indexOf(cast(const(char)[]) data, match) >= 0;
        }) == Status.ok);
    return found;
}

private bool equals(ref scope RequestArena arena, Buffer buffer, scope const(ubyte)[] expected)
{
    bool same;
    assert(arena.read(buffer, (scope const(ubyte)[] data) @safe nothrow @nogc {
            same = data == expected;
        }) == Status.ok);
    return same;
}

private void check(Error status)
{
    assert(status.code == Status.ok, status.message);
}

private struct Fixture
{
    Server server;
    Actions actions;
    RawRoutes raw;
    string origin;
    HttpClient client;
}

private void startFixture(ref Fixture fixture) @system
{
    import std.conv : to;

    ServerOptions options;
    options.port = freePort();
    options.cores = 1;
    options.maxConnectionsPerCore = 16;
    options.maxStreamsPerConnection = 32;
    options.http2PriorKnowledge = true;
    check(fixture.server.start(options));
    fixture.actions = new Actions;
    fixture.raw = new RawRoutes;
    auto actions = fixture.actions;
    const named = GrpcService(service);
    check(registerGrpc(fixture.server, named, "Unary", &actions.unary));
    check(registerGrpc(fixture.server, named, "ClientStream", &actions.clientStream));
    check(registerGrpc(fixture.server, named, "ServerStream", &actions.serverStream));
    check(registerGrpc(fixture.server, named, "Bidi", &actions.bidi));
    check(registerGrpc(fixture.server, named, "Status", &actions.status));
    check(registerGrpc(fixture.server, named, "Hold", &actions.hold));
    check(registerGrpc(fixture.server, named, "Wait", &actions.wait));
    StreamLimits small;
    small.maxMessageBytes = 4;
    check(registerGrpc(fixture.server, named, "Small", &actions.unary, small));
    // Limits beyond the specified bounds and malformed names are rejected at startup.
    StreamLimits invalid;
    invalid.maxMessageBytes = 4 * 1024 * 1024 + 1;
    assert(registerGrpc(fixture.server, named, "Large", &actions.unary, invalid).code == Status.invalidArgument);
    invalid = StreamLimits.init;
    invalid.queuedMessages = 17;
    assert(registerGrpc(fixture.server, named, "Deep", &actions.unary, invalid).code == Status.invalidArgument);
    invalid = StreamLimits.init;
    invalid.queuedBytes = 1024 * 1024 + 1;
    assert(registerGrpc(fixture.server, named, "Wide", &actions.unary, invalid).code == Status.invalidArgument);
    assert(registerGrpc(fixture.server, GrpcService("bad..name"), "Unary", &actions.unary)
            .code == Status.invalidArgument);
    assert(registerGrpc(fixture.server, named, "1st", &actions.unary).code == Status.invalidArgument);
    assert(registerGrpc(fixture.server, named, "Unary", null).code == Status.invalidArgument);
    auto raw = fixture.raw;
    static struct RawRoute
    {
        string method;
        Error delegate(ref scope Request, ref scope RequestContext, scope StreamToken) @safe nothrow @nogc action;
    }

    foreach (route; [
        RawRoute("NoStatus", &raw.noStatus), RawRoute("Oversized", &raw.oversized),
        RawRoute("Compressed", &raw.compressed), RawRoute("Truncated", &raw.truncated),
        RawRoute("BadStatus", &raw.badStatus), RawRoute("WrongMedia", &raw.wrongMedia)
    ])
        check(fixture.server.routeStream(StreamRoute(Method.post,
                "/flint.rpc.transport.Raw/" ~ route.method, StreamMode.duplex, route.action)));
    Context context;
    check(fixture.server.poll(context));
    fixture.origin = "http://127.0.0.1:" ~ options.port.to!string;
    ClientOptions settings;
    settings.maxConnections = settings.maxConnectionsPerOrigin = 1;
    check(fixture.client.open(settings));
}

private GrpcCall open(ref Fixture fixture, string serviceName, string method, ref Context context)
{
    GrpcCallOptions options;
    options.origin = fixture.origin;
    options.service = GrpcService(serviceName);
    options.method = method;
    options.allowLoopbackCleartext = true;
    auto opened = beginGrpc(fixture.client, options, context);
    check(opened.error);
    return move(opened.value);
}

/// Receive every message until verified EOF and return the remote status.
private RpcCode finishCall(ref GrpcCall call, ref scope RequestArena arena, ref Context context)
{
    const end = call.receive(arena, context);
    assert(end.error.code == Status.notFound, end.error.message);
    const terminal = call.status(arena);
    check(terminal.error);
    return terminal.value.code;
}

/// Send raw request bytes with explicit fields and return the HTTP status and the trailers.
private struct RawOutcome
{
    ushort status;
    Buffer trailers;
}

// dfmt off
private RawOutcome rawCall(ref Fixture fixture, string method, scope const(ubyte)[] wire, bool endUpload,
        scope const(HttpStreamField)[] extra, ref scope RequestArena arena)
{
    const url = fixture.origin ~ "/" ~ service ~ "/" ~ method;
    HttpStreamField[4] fields;
    size_t count;
    fields[count++] = HttpStreamField("content-type", "application/grpc");
    foreach (field; extra)
        fields[count++] = field;
    auto context = Context.init.withDeadline(Deadline.afterMillis(8_000));
    const options = HttpStreamOptions(url, HttpStreamMode.duplex, true, fields[0 .. count]);
    auto opened = fixture.client.openStream(options, context);
    check(opened.error);
    auto stream = move(opened.value);
    scope (exit)
        stream.close();
    if (wire.length != 0)
        check(stream.send(wire, context));
    if (endUpload)
    {
        // A server that rejects before reading may complete the transfer before the upload ends.
        const ended = stream.finishSend(context);
        assert(ended.code == Status.ok || ended.code == Status.conflict, ended.message);
    }
    const head = stream.head(arena, context);
    check(head.error);
    ubyte[256] sink;
    for (;;)
    {
        const read = stream.receive(sink[], context);
        check(read.error);
        if (read.value == 0)
            break;
    }
    const trailers = stream.trailers(arena, context);
    return RawOutcome(head.value.status, trailers.ok() ? trailers.value : Buffer.init);
}
// dfmt on

private void waitFor(scope bool delegate() @safe condition) @system
{
    import core.thread.osthread : Thread;
    import core.time : msecs;

    foreach (_; 0 .. 400)
    {
        if (condition())
            return;
        Thread.sleep(10.msecs);
    }
    assert(condition(), "server-side outcome was not observed");
}

@("grpc_interop: all four call shapes, a 64 KiB duplex exchange and terminal status over in-process HTTP/2")
version (FlintNativeNghttp2) @system unittest
{
    Fixture fixture;
    startFixture(fixture);
    scope (exit)
    {
        fixture.client.close();
        fixture.server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }
    ubyte[256 * 1024] storage;
    auto arena = RequestArena(storage[]);
    auto context = Context.init.withDeadline(Deadline.afterMillis(10_000));
    immutable ubyte[3] one = [1, 2, 3];
    const message = arena.copyIn(one[]);
    check(message.error);

    auto unary = open(fixture, service, "Unary", context);
    check(unary.send(message.value, arena, context));
    check(unary.finishSend(context));
    const echoed = unary.receive(arena, context);
    check(echoed.error);
    assert(equals(arena, echoed.value, one[]));
    assert(finishCall(unary, arena, context) == RpcCode.ok);
    check(unary.close());

    auto upload = open(fixture, service, "ClientStream", context);
    foreach (_; 0 .. 5)
        check(upload.send(message.value, arena, context));
    check(upload.finishSend(context));
    const counted = upload.receive(arena, context);
    check(counted.error);
    immutable ubyte[1] five = [5];
    assert(equals(arena, counted.value, five[]));
    assert(finishCall(upload, arena, context) == RpcCode.ok);
    check(upload.close());

    auto download = open(fixture, service, "ServerStream", context);
    check(download.send(message.value, arena, context));
    check(download.finishSend(context));
    foreach (_; 0 .. 3)
    {
        const item = download.receive(arena, context);
        check(item.error);
        assert(equals(arena, item.value, one[]));
    }
    assert(finishCall(download, arena, context) == RpcCode.ok);
    check(download.close());

    ubyte[64 * 1024] large;
    foreach (index, ref value; large)
        value = cast(ubyte) index;
    auto duplex = open(fixture, service, "Bidi", context);
    foreach (round; 0 .. 4)
    {
        large[0] = cast(ubyte) round;
        const framed = arena.copyIn(large[]);
        check(framed.error);
        check(duplex.send(framed.value, arena, context));
        const reply = duplex.receive(arena, context);
        check(reply.error);
        assert(equals(arena, reply.value, large[]));
        assert(arena.reset() == Status.ok);
    }
    check(duplex.finishSend(context));
    assert(finishCall(duplex, arena, context) == RpcCode.ok);
    check(duplex.close());

    // The Status action finishes without reading. Its status arrives while the upload is still open.
    auto terminal = open(fixture, service, "Status", context);
    assert(finishCall(terminal, arena, context) == RpcCode.aborted);
    assert(terminal.finishSend(context).code == Status.conflict);
    const status = terminal.status(arena);
    assert(equals(arena, status.value.message, cast(const(ubyte)[]) "10% \xf0\x9f\x9a\x80"));
    check(terminal.close());
    waitFor(() => atomicLoad(fixture.actions.onceOnly) != 0);
    assert(atomicLoad(fixture.actions.onceOnly) == 1);
}

@("grpc_wire_errors: server maps compression, flags, oversized, truncated, timeout and media errors to status")
version (FlintNativeNghttp2) @system unittest
{
    Fixture fixture;
    startFixture(fixture);
    scope (exit)
    {
        fixture.client.close();
        fixture.server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }
    ubyte[16 * 1024] storage;
    auto arena = RequestArena(storage[]);
    const te = HttpStreamField("te", "trailers");
    static struct Case
    {
        immutable(ubyte)[] wire;
        string expected;
    }

    foreach (item; [
            Case([1, 0, 0, 0, 0], "grpc-status: 12"), Case([3, 0, 0, 0, 0], "grpc-status: 3"),
            Case([0, 0, 0x40, 0, 1], "grpc-status: 8"), Case([0, 0, 0, 0, 3, 1], "grpc-status: 3"),
            Case([0, 0], "grpc-status: 3")
        ])
    {
        const outcome = rawCall(fixture, "Unary", item.wire, true, [te], arena);
        assert(outcome.status == 200 && contains(arena, outcome.trailers, item.expected), item.expected);
        assert(arena.reset() == Status.ok);
    }

    // A route's configured message limit applies before the payload is reserved.
    static immutable ubyte[10] five = [0, 0, 0, 0, 5, 1, 2, 3, 4, 5];
    const limited = rawCall(fixture, "Small", five[], true, [te], arena);
    assert(limited.status == 200 && contains(arena, limited.trailers, "grpc-status: 8"));
    static immutable ubyte[9] four = [0, 0, 0, 0, 4, 1, 2, 3, 4];
    const admitted = rawCall(fixture, "Small", four[], true, [te], arena);
    assert(admitted.status == 200 && contains(arena, admitted.trailers, "grpc-status: 0"));

    // A request deadline that expires while the handler waits produces DEADLINE_EXCEEDED trailers.
    static immutable ubyte[6] single = [0, 0, 0, 0, 1, 9];
    const timed = rawCall(fixture, "Wait", single[], true, [
        te, HttpStreamField("grpc-timeout", "50m")
    ], arena);
    assert(timed.status == 200 && contains(arena, timed.trailers, "grpc-status: 4"));
    const malformed = rawCall(fixture, "Unary", null, true, [
        te, HttpStreamField("grpc-timeout", "1x")
    ], arena);
    assert(malformed.status == 200 && contains(arena, malformed.trailers, "grpc-status: 3"));
    const gzip = rawCall(fixture, "Unary", null, true, [
        te, HttpStreamField("grpc-encoding", "gzip")
    ], arena);
    assert(gzip.status == 200 && contains(arena, gzip.trailers, "grpc-status: 12"));
    // Without TE: trailers the request is not gRPC.
    const noTe = rawCall(fixture, "Unary", null, true, null, arena);
    assert(noTe.status == 415);

    // A server that rejects before the upload ends surfaces its status without the client ending it.
    static struct Early
    {
        string method;
        immutable(ubyte)[] wire;
        HttpStreamField extra;
        string expected;
    }

    foreach (item; [
            Early("Unary", [1, 0, 0, 0, 0], te, "grpc-status: 12"),
            Early("Unary", [3, 0, 0, 0, 0], te, "grpc-status: 3"),
            Early("Unary", [0, 0, 0x40, 0, 1], te, "grpc-status: 8"),
            Early("Small", [0, 0, 0, 0, 5, 1, 2, 3, 4, 5], te, "grpc-status: 8"),
            Early("Wait", [0, 0, 0, 0, 1, 9], HttpStreamField("grpc-timeout", "50m"),
                "grpc-status: 4"),
            Early("Unary", null, HttpStreamField("grpc-timeout", "1x"), "grpc-status: 3"),
            Early("Unary", null, HttpStreamField("grpc-encoding", "gzip"), "grpc-status: 12")
        ])
    {
        const fields = item.extra.name == "te" ? [te] : [te, item.extra];
        const outcome = rawCall(fixture, item.method, item.wire, false, fields, arena);
        assert(outcome.status == 200 && contains(arena, outcome.trailers, item.expected), item.expected);
        assert(arena.reset() == Status.ok);
    }
    const early = rawCall(fixture, "Unary", null, false, null, arena);
    assert(early.status == 415);
}

@("grpc_wire_errors: client rejects missing status, oversized and compressed messages, truncation and bad media")
version (FlintNativeNghttp2) @system unittest
{
    Fixture fixture;
    startFixture(fixture);
    scope (exit)
    {
        fixture.client.close();
        fixture.server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }
    ubyte[16 * 1024] storage;
    auto arena = RequestArena(storage[]);
    auto context = Context.init.withDeadline(Deadline.afterMillis(8_000));
    enum raw = "flint.rpc.transport.Raw";

    // A clean end without grpc-status is unavailable, never success.
    auto missing = open(fixture, raw, "NoStatus", context);
    check(missing.finishSend(context));
    const first = missing.receive(arena, context);
    check(first.error);
    const absent = missing.receive(arena, context);
    assert(absent.error.code == Status.unavailable, absent.error.message);
    assert(missing.status(arena).error.code == Status.unavailable);
    assert(missing.receive(arena, context).error.code == Status.unavailable);
    missing.close();

    static struct Case
    {
        string method;
        Status expected;
    }

    foreach (item; [
        Case("Oversized", Status.resourceExhausted), Case("Compressed", Status.unsupported),
        Case("Truncated", Status.invalidArgument), Case("BadStatus", Status.unavailable),
        Case("WrongMedia", Status.invalidArgument)
    ])
    {
        auto call = open(fixture, raw, item.method, context);
        check(call.finishSend(context));
        if (item.method != "WrongMedia")
            check(call.head(arena, context).error);
        const before = arena.stats().used;
        const result = call.receive(arena, context);
        assert(result.error.code == item.expected, item.method);
        if (item.method == "Oversized")
            assert(arena.stats().used == before);
        assert(call.status(arena).error.code == Status.unavailable);
        call.close();
        assert(arena.reset() == Status.ok);
    }
}

@("stream_teardown: cancellation before the first byte, mid-message and after trailers completes once")
version (FlintNativeNghttp2) @system unittest
{
    Fixture fixture;
    startFixture(fixture);
    scope (exit)
    {
        fixture.client.close();
        fixture.server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }
    ubyte[16 * 1024] storage;
    auto arena = RequestArena(storage[]);
    auto context = Context.init.withDeadline(Deadline.afterMillis(8_000));
    immutable ubyte[2] payload = [7, 8];
    const message = arena.copyIn(payload[]);

    // Before the first byte: closing an unstarted call leaves the connection usable.
    auto early = open(fixture, service, "Bidi", context);
    check(early.close());
    assert(early.receive(arena, context).error.code == Status.unavailable);

    // Caller cancellation after the response head is reported as cancelled.
    auto created = CancelSource.create(Context.init, Deadline.none());
    check(created.error);
    auto source = move(created.value);
    auto caller = source.context();
    auto waiting = open(fixture, service, "Bidi", caller);
    check(waiting.head(arena, caller).error);
    source.cancel();
    assert(waiting.receive(arena, caller).error.code == Status.cancelled);
    check(waiting.close());

    // Mid-message: a reset after a partial frame never delivers the partial message to the handler.
    const runs = atomicLoad(fixture.actions.heldRuns);
    {
        const url = fixture.origin ~ "/" ~ service ~ "/Hold";
        const fields = [
            HttpStreamField("content-type", "application/grpc"), HttpStreamField("te", "trailers")
        ];
        const options = HttpStreamOptions(url, HttpStreamMode.duplex, true, fields);
        auto opened = fixture.client.openStream(options, context);
        check(opened.error);
        auto stream = move(opened.value);
        immutable ubyte[8] partial = [0, 0, 0, 0, 10, 1, 2, 3];
        check(stream.send(partial[], context));
        check(stream.head(arena, context).error);
        check(stream.close());
    }
    waitFor(() => atomicLoad(fixture.actions.heldRuns) > runs);
    assert(atomicLoad(fixture.actions.heldMessages) == 0);
    const outcome = atomicLoad(fixture.actions.heldOutcome);
    assert(outcome != 0 && outcome != Status.ok + 1 && outcome != Status.notFound + 1);

    // After trailers: the completed call reports its status, then close releases it exactly once.
    auto done = open(fixture, service, "Unary", context);
    check(done.send(message.value, arena, context));
    check(done.finishSend(context));
    check(done.receive(arena, context).error);
    assert(finishCall(done, arena, context) == RpcCode.ok);
    assert(done.receive(arena, context).error.code == Status.notFound);
    check(done.close());
    assert(done.receive(arena, context).error.code == Status.unavailable);
    assert(done.status(arena).error.code == Status.unavailable);
    assert(done.send(message.value, arena, context).code == Status.conflict);

    // The shared connection still serves a new call after every teardown above.
    auto after = open(fixture, service, "Unary", context);
    check(after.send(message.value, arena, context));
    check(after.finishSend(context));
    const reply = after.receive(arena, context);
    check(reply.error);
    assert(equals(arena, reply.value, payload[]));
    assert(finishCall(after, arena, context) == RpcCode.ok);
    check(after.close());
}
