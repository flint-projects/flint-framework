/// Wire-level RPC server fixture exercised by independent clients.
module app;

import core.atomic : atomicLoad, atomicOp;
import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.reactor : Reactor;
import flint.engine.rpc : GrpcService, RpcCode, RpcHandler, RpcStatus, RpcStream, Sse, SseEvent,
    WebSocket, WebSocketPeer, registerGrpc, registerSse, registerWebSocket, sendEvent, sendHeartbeat;
import flint.engine.web : enableHttp2, Method, Request, RequestContext, Response, Server, ServerOptions;
import std.conv : to;

@safe:

private shared uint abandonedEvents;

/// Launch a loopback server. An explicit h2 mode uses prior knowledge.
int main(string[] arguments)
{
    if (arguments.length != 3)
        return 2;
    ServerOptions options;
    options.port = to!ushort(arguments[1]);
    options.maxConnectionsPerCore = 32;
    options.maxStreamsPerConnection = 64;
    options.http2PriorKnowledge = arguments[2] == "h2";
    if (options.http2PriorKnowledge)
        enableHttp2();
    options.idleTimeoutNanos = 15_000_000_000;
    Server server;
    if (server.start(options).code != Status.ok)
        return 3;
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    auto handlers = new Actions;
    if (server.route(Method.get, "/observed", &handlers.observed).code != Status.ok
            || registerSse(server, Sse("/events"), &handlers.events).code != Status.ok)
        return 4;
    if (options.http2PriorKnowledge)
    {
        if (!addGrpc(server, handlers))
            return 5;
    }
    else if (registerWebSocket(server, WebSocket("/socket"), &handlers.echo).code != Status.ok
            || registerWebSocket(server, WebSocket("/close"), &handlers.close).code != Status.ok)
        return 5;
    Context context;
    for (;;)
    {
        const polled = server.poll(context);
        if (polled.code != Status.ok)
            return 6;
    }
}

private struct GrpcRoute
{
    string method;
    RpcHandler action;
}

private bool addGrpc(ref Server server, Actions handlers)
{
    const service = GrpcService("flint.rpc.fixture.Echo");
    GrpcRoute[] routes = [
        GrpcRoute("Unary", &handlers.unary), GrpcRoute("ClientStream", &handlers.clientStream),
        GrpcRoute("ServerStream", &handlers.serverStream), GrpcRoute("Bidi", &handlers.bidi),
        GrpcRoute("Status", &handlers.status)
    ];
    foreach (route; routes)
    {
        if (registerGrpc(server, service, route.method, route.action).code != Status.ok)
            return false;
    }
    return true;
}

private final class Actions
{
    Error echo(ref scope Request request, ref scope WebSocketPeer peer, ref scope RequestContext context) nothrow @nogc
    {
        for (;;)
        {
            const result = peer.receive(context.arena, context.cancellation);
            if (!result.ok())
                return result.error.code == Status.notFound ? Error.init : result.error;
            const sent = result.value.text ? peer.text(result.value.payload, context.arena,
                    context.cancellation) : peer.binary(result.value.payload, context.arena, context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
    }

    Error close(ref scope Request request, ref scope WebSocketPeer peer, ref scope RequestContext context) nothrow @nogc
    {
        return peer.close(1000, "done");
    }

    Error events(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        scope (exit)
        {
            if (context.cancellation.cancelled())
                atomicOp!"+="(abandonedEvents, 1);
        }
        const message = context.arena.copyIn(cast(const(ubyte)[]) "first\r\nsecond🚀");
        if (!message.ok())
            return message.error;
        const event = SseEvent("update", "id-42", message.value, 600);
        const sent = sendEvent(stream, event, context.arena, context.cancellation);
        if (sent.code != Status.ok)
            return sent;
        const heartbeat = sendHeartbeat(stream, "ready", context.arena, context.cancellation);
        if (heartbeat.code != Status.ok)
            return heartbeat;

        auto loop = Reactor.current();
        while (!context.cancellation.cancelled())
        {
            const waiting = loop.yieldUntil(Deadline.afterMillis(100));
            if (waiting.code != Status.ok)
                break;
        }
        return context.cancellation.check();
    }

    Result!Response observed(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        const text = atomicLoad(abandonedEvents) != 0 ? "cancelled" : "active";
        const data = context.arena.copyIn(cast(const(ubyte)[]) text);
        return Result!Response(Response(200, "text/plain", data.value), data.error);
    }

    Error unary(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        const metadata = request.header("x-flint-check");
        if (metadata.ok() && !goMetadata(metadata.value, context))
            return Error(Status.invalidArgument, "interop metadata did not match");
        const next = stream.receive(context.arena, context.cancellation);
        if (!next.ok())
            return next.error;
        const end = stream.receive(context.arena, context.cancellation);
        if (end.error.code != Status.notFound)
            return end.ok() ? Error(Status.invalidArgument, "unary call has multiple inputs") : end.error;
        return stream.send(next.value, context.arena, context.cancellation);
    }

    private static bool goMetadata(Buffer value, ref scope RequestContext context) nothrow @nogc
    {
        bool matched;
        return context.arena.read(value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            matched = bytes == cast(const(ubyte)[]) "grpc-go";
        }) == Status.ok && matched;
    }

    // dfmt off
    Error serverStream(ref scope Request request, ref scope RpcStream stream,
            ref scope RequestContext context) nothrow @nogc
    {
        const next = stream.receive(context.arena, context.cancellation);
        if (!next.ok())
            return next.error;
        for (uint count; count != 3; ++count)
        {
            const sent = stream.send(next.value, context.arena, context.cancellation);
            if (sent.code != Status.ok)
                return sent;
        }
        return Error.init;
    }
    // dfmt on

    // dfmt off
    Error clientStream(ref scope Request request, ref scope RpcStream stream,
            ref scope RequestContext context) nothrow @nogc
    {
        Buffer last;
        for (;;)
        {
            const next = stream.receive(context.arena, context.cancellation);
            if (!next.ok())
                return next.error.code == Status.notFound ? stream.send(last, context.arena,
                        context.cancellation) : next.error;
            last = next.value;
        }
    }
    // dfmt on

    Error status(ref scope Request request, ref scope RpcStream stream, ref scope RequestContext context) nothrow @nogc
    {
        const message = context.arena.copyIn(cast(const(ubyte)[]) "10% 🚀");
        if (!message.ok())
            return message.error;
        const sent = stream.finish(RpcStatus(RpcCode.aborted, message.value));
        if (sent.code != Status.ok)
            return sent;
        const again = stream.finish(RpcStatus.init);
        return again.code == Status.conflict ? Error.init : Error(Status.ioError, "terminal status was sent twice");
    }

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
}
