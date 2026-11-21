/// Request-confined RPC stream handles and startup registration.
module flint.rpc.session;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.rpc.grpc : GrpcDecoder, RpcCode, RpcStatus, StreamLimits, grpcPrefix;
import flint.rpc.sse : Sse, SseEvent, encodeEvent, encodeHeartbeat;
import flint.rpc.utf8 : utf8Valid;
import flint.web : Method, Request, RequestContext, Server, StreamField, StreamMode, StreamRoute, StreamToken;

@safe:

/// Typed RPC service startup name.
struct GrpcService
{
    /// Fully qualified service name, including the Protobuf package.
    string serviceName;
}

/// A call running on the stream's owner fiber.
alias RpcHandler = Error delegate(ref scope Request, ref scope RpcStream, ref scope RequestContext) @safe nothrow @nogc;

/// Generation-checked handle to a live RPC or SSE stream.
struct RpcStream
{
    private ulong slot;
    private ulong generation;
    private CallState* state;

    package(flint.rpc) this(return scope CallState* state) nothrow @nogc
    {
        this.state = state;
        slot = state.identity;
        generation = state.identity;
    }

    /// Send an arena payload, resolving transport ownership before returning.
    Error send(Buffer message, ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        if (!live() || state.finished)
            return Error(Status.unavailable, "RPC stream output is closed");
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        if (message == Buffer.init)
            return state.sendBytes(null, context);
        Error result;
        const read = arena.read(message, (scope const(ubyte)[] wire) @safe nothrow @nogc {
            result = state.sendBytes(wire, context);
        });
        return read == Status.ok ? result : Error(read, "RPC send buffer is unavailable");
    }

    /// Receive one uncompressed gRPC message. Not found denotes orderly request EOF.
    Result!Buffer receive(ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        if (!live())
            return Result!Buffer(Buffer.init, Error(Status.unavailable, "RPC stream no longer exists"));
        if (!state.grpc)
            return Result!Buffer(Buffer.init, Error(Status.unsupported, "SSE is response-only"));
        return state.receive(arena, context);
    }

    /// Finish the response exactly once. A gRPC message belongs to the call's request arena.
    Error finish(RpcStatus status) scope nothrow @nogc
    {
        if (!live() || state.finished)
            return Error(Status.conflict, "RPC stream output already finished");
        return state.finish(status);
    }

    /// Request cancellation of all remaining stream work.
    Error cancel() scope nothrow @nogc
    {
        if (!live() || state.finished)
            return Error(Status.conflict, "RPC stream already finished");
        state.finished = true;
        return state.token.cancel();
    }

    private bool live() const scope pure nothrow @nogc
    {
        return state !is null && slot != 0 && slot == generation && state.identity == generation;
    }
}

/// Open an HTTP streaming route with the event-stream media type.
Error registerSse(ref Server server, Sse annotation, RpcHandler action)
{
    if (action is null)
        return Error(Status.invalidArgument, "SSE route requires an action");
    auto runner = new SseRoute(action);
    return server.routeStream(StreamRoute(Method.get, annotation.path, StreamMode.response, &runner.run));
}

/// Encode one server-sent event and submit its bytes to the active stream.
Error sendEvent(ref scope RpcStream stream, scope const ref SseEvent event,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    if (!stream.live() || stream.state.grpc)
        return Error(Status.invalidArgument, "SSE requires an event stream");
    const wire = encodeEvent(event, arena);
    return wire.ok() ? stream.send(wire.value, arena, context) : wire.error;
}

/// Send an application-selected heartbeat comment.
Error sendHeartbeat(ref scope RpcStream stream, scope const(char)[] comment,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    if (!stream.live() || stream.state.grpc)
        return Error(Status.invalidArgument, "SSE requires an event stream");
    const wire = encodeHeartbeat(comment, arena);
    return wire.ok() ? stream.send(wire.value, arena, context) : wire.error;
}

private final class SseRoute
{
    private RpcHandler action;

    this(RpcHandler action)
    {
        this.action = action;
    }

    Error run(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        const opened = token.begin(200, [
            StreamField("content-type", "text/event-stream"), StreamField("cache-control", "no-cache")
        ], context.cancellation);
        if (opened.code != Status.ok)
            return opened;
        scope state = CallState(token, &context.arena, context.cancellation, context.requestId, false);
        scope stream = RpcStream(&state);
        const result = action(request, stream, context);
        if (result.code != Status.ok || state.finished)
            return result;
        return stream.finish(RpcStatus.init);
    }
}

package(flint.rpc) struct CallState
{
    StreamToken token;
    RequestArena* arena;
    Context transport;
    ulong identity;
    bool grpc;
    bool finished;
    StreamLimits limits;
    Status receiveFailure;
    ubyte[4096] input;
    size_t position;
    size_t available;

    this(return scope StreamToken token, return scope RequestArena* arena, Context transport,
            ulong identity, bool grpc, StreamLimits limits = StreamLimits.init) nothrow @nogc
    {
        this.token = token;
        this.arena = arena;
        this.transport = transport;
        this.identity = identity;
        this.grpc = grpc;
        this.limits = limits;
    }

    Error sendBytes(scope const(ubyte)[] wire, ref scope const Context context) scope nothrow @nogc
    {
        if (grpc)
        {
            const prefix = grpcPrefix(wire.length, limits.maxMessageBytes);
            if (!prefix.ok())
                return prefix.error;
            const sent = token.send(prefix.value[], context);
            if (sent.code != Status.ok)
                return sent;
        }
        if (wire.length == 0)
            return Error.init;
        const written = token.send(wire, context);
        if (grpc && written.code != Status.ok)
        {
            finished = true;
            token.cancel();
        }
        return written;
    }

    Result!Buffer receive(ref scope RequestArena destination, ref scope const Context context) scope nothrow @nogc
    {
        if (receiveFailure != Status.ok)
            return Result!Buffer(Buffer.init, Error(receiveFailure, "gRPC receive already failed"));
        GrpcDecoder decoder;
        for (;;)
        {
            const checked = context.check();
            if (checked.code != Status.ok)
                return receiveError(checked);
            if (position == available)
            {
                const received = token.receive(input[], context);
                if (!received.ok())
                    return receiveError(received.error);
                if (received.value == 0)
                {
                    const ended = decoder.end();
                    return ended.code == Status.ok ? Result!Buffer(Buffer.init,
                            Error(Status.notFound, "gRPC request messages ended")) : receiveError(ended);
                }
                position = 0;
                available = received.value;
            }
            const parsed = decoder.feed(input[position .. available], destination, limits.maxMessageBytes);
            position += parsed.consumed;
            if (parsed.error.code != Status.ok)
                return receiveError(parsed.error);
            if (parsed.complete)
                return Result!Buffer(parsed.payload);
        }
    }

    private Result!Buffer receiveError(Error failure) scope nothrow @nogc
    {
        receiveFailure = failure.code;
        return Result!Buffer(Buffer.init, failure);
    }

    Error finish(RpcStatus status) scope nothrow @nogc
    {
        if (status.code > RpcCode.unauthenticated)
            return Error(Status.invalidArgument, "invalid RPC terminal status code");
        if (!grpc)
        {
            finished = true;
            return status.code == RpcCode.ok ? token.finish(null, transport) : token.cancel();
        }

        scope char[2] code;
        const value = cast(uint) status.code;
        code[0] = cast(char)('0' + value / 10);
        code[1] = cast(char)('0' + value % 10);
        const digits = value < 10 ? code[1 .. $] : code[];
        char[4096] message;
        size_t length;
        if (status.message != Buffer.init)
        {
            bool valid;
            const read = arena.read(status.message, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                valid = escapeMessage(bytes, message[], length);
            });
            if (read != Status.ok || !valid)
                return Error(Status.invalidArgument, "invalid or oversized gRPC status message");
        }
        finished = true;
        if (length == 0)
            return token.finish([StreamField("grpc-status", digits)], transport);
        return token.finish([
            StreamField("grpc-status", digits), StreamField("grpc-message", message[0 .. length])
        ], transport);
    }
}

private bool escapeMessage(scope const(ubyte)[] source, scope char[] output, out size_t length) pure nothrow @nogc
{
    if (source.length > output.length || !utf8Valid(source))
        return false;
    foreach (part; source)
    {
        if (part >= 0x20 && part <= 0x7e && part != '%')
        {
            if (length == output.length)
                return false;
            output[length++] = cast(char) part;
        }
        else
        {
            if (output.length - length < 3)
                return false;
            output[length++] = '%';
            output[length++] = "0123456789ABCDEF"[part >> 4];
            output[length++] = "0123456789ABCDEF"[part & 15];
        }
    }
    return true;
}
