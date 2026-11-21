/// HTTP/2 gRPC route registration and per-call status mapping.
module flint.rpc.grpc_route;

import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.rpc.grpc : RpcCode, RpcStatus, StreamLimits, grpcDeadline, maximumMessageBytes;
import flint.rpc.session : CallState, GrpcService, RpcHandler, RpcStream;
import flint.web : Method, Request, RequestContext, Server, StreamField, StreamMode, StreamRoute, StreamToken;

@safe:

/// Explicitly register one generated gRPC method. The action handles its declared message cardinality.
Error registerGrpc(ref Server server, GrpcService service, string method, RpcHandler action,
        StreamLimits limits = StreamLimits.init)
{
    if (action is null || !identifier(service.serviceName, true) || !identifier(method, false)
            || service.serviceName.length > 256 || method.length > 128 || limits.maxMessageBytes == 0
            || limits.maxMessageBytes > maximumMessageBytes || limits.queuedMessages == 0
            || limits.queuedMessages > 16 || limits.queuedBytes < 65_535 || limits.queuedBytes > 1024 * 1024)
        return Error(Status.invalidArgument, "invalid gRPC method or stream limits");
    auto route = new GrpcRoute(action, limits);
    return server.routeStream(StreamRoute(Method.post, "/" ~ service.serviceName ~ "/" ~ method,
            StreamMode.duplex, &route.run));
}

private bool identifier(scope const(char)[] spelling, bool qualified) pure nothrow @nogc
{
    bool first = true;
    foreach (byteValue; spelling)
    {
        if (byteValue == '_' || (byteValue >= 'a' && byteValue <= 'z') || (byteValue >= 'A'
                && byteValue <= 'Z') || (!first && byteValue >= '0' && byteValue <= '9'))
            first = false;
        else if (qualified && !first && byteValue == '.')
            first = true;
        else
            return false;
    }
    return !first;
}

private final class GrpcRoute
{
    private RpcHandler action;
    private StreamLimits limits;

    this(RpcHandler action, StreamLimits limits)
    {
        this.action = action;
        this.limits = limits;
    }

    Error run(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        if (!headerMatches(request, context.arena, "content-type", &grpcMedia)
                || !headerMatches(request, context.arena, "te", &trailers))
        {
            const rejected = token.begin(415, null, context.cancellation);
            return rejected.code == Status.ok ? token.finish(null, context.cancellation) : rejected;
        }

        const opened = token.begin(200, [StreamField("content-type", "application/grpc")], context.cancellation);
        if (opened.code != Status.ok)
            return opened;
        scope state = CallState(token, &context.arena, context.cancellation, context.requestId, true, limits);
        scope stream = RpcStream(&state);

        const encodingCount = request.headerCount("grpc-encoding");
        if (encodingCount != 0 && !headerMatches(request, context.arena, "grpc-encoding", &identity))
            return stream.finish(RpcStatus(RpcCode.unimplemented));

        const parent = context.cancellation;
        const timed = deadline(request, context.arena, parent);
        if (!timed.ok())
            return stream.finish(RpcStatus(RpcCode.invalidArgument));
        context.cancellation = timed.value;
        const before = context.cancellation.check();
        if (before.code != Status.ok)
            return stream.finish(RpcStatus(mapped(before.code)));
        const result = action(request, stream, context);
        if (state.finished)
            return result;

        const checked = context.cancellation.check();
        const outcome = checked.code != Status.ok ? checked.code : (state.receiveFailure != Status.ok
                ? state.receiveFailure : result.code);
        return stream.finish(RpcStatus(mapped(outcome)));
    }
}

private alias FieldCheck = bool function(scope const(char)[]) @safe pure nothrow @nogc;

// dfmt off
private bool headerMatches(ref scope Request request, ref scope RequestArena arena,
        string name, FieldCheck check) nothrow @nogc
{
    if (request.headerCount(name) != 1)
        return false;
    const field = request.header(name);
    bool matched;
    return field.ok() && arena.read(field.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        matched = check(trim(cast(const(char)[]) bytes));
    }) == Status.ok && matched;
}
// dfmt on

private const(char)[] trim(return scope const(char)[] value) pure nothrow @nogc
{
    while (value.length != 0 && (value[0] == ' ' || value[0] == '\t'))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == ' ' || value[$ - 1] == '\t'))
        value = value[0 .. $ - 1];
    return value;
}

private bool grpcMedia(scope const(char)[] field) pure nothrow @nogc
{
    size_t end;
    while (end < field.length && field[end] != ';')
        ++end;
    const media = trim(field[0 .. end]);
    return media == "application/grpc" || media == "application/grpc+proto";
}

private bool trailers(scope const(char)[] value) pure nothrow @nogc
{
    return equalAscii(value, "trailers");
}

private bool identity(scope const(char)[] value) pure nothrow @nogc
{
    return equalAscii(value, "identity");
}

private bool equalAscii(scope const(char)[] value, string lowercase) pure nothrow @nogc
{
    if (value.length != lowercase.length)
        return false;
    foreach (index, byteValue; value)
    {
        const candidate = byteValue >= 'A' && byteValue <= 'Z' ? byteValue + ('a' - 'A') : byteValue;
        if (candidate != lowercase[index])
            return false;
    }
    return true;
}

// dfmt off
private Result!Context deadline(ref scope Request request, ref scope RequestArena arena,
        ref scope const Context parent) nothrow @nogc
{
    const count = request.headerCount("grpc-timeout");
    if (count == 0)
        return Result!Context(parent);
    if (count != 1)
        return Result!Context(Context.init, Error(Status.invalidArgument, "duplicate gRPC timeout"));
    const field = request.header("grpc-timeout");
    if (!field.ok())
        return Result!Context(Context.init, field.error);
    Result!Context result;
    const read = arena.read(field.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        result = grpcDeadline(trim(cast(const(char)[]) bytes), parent);
    });
    if (read != Status.ok)
        return Result!Context(Context.init, Error(read, "gRPC timeout is unavailable"));
    return Result!Context(result.value, result.error);
}
// dfmt on

private RpcCode mapped(Status status) pure nothrow @nogc
{
    static immutable RpcCode[] codes = [
        RpcCode.ok, RpcCode.invalidArgument, RpcCode.resourceExhausted, RpcCode.cancelled,
        RpcCode.deadlineExceeded, RpcCode.notFound, RpcCode.alreadyExists, RpcCode.internal,
        RpcCode.unavailable, RpcCode.unimplemented, RpcCode.permissionDenied,
        RpcCode.resourceExhausted
    ];
    const index = cast(uint) status;
    return index < codes.length ? codes[index] : RpcCode.internal;
}
