/// Common owner-fiber route lookup and application dispatch.
module flint.web.dispatch;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.web.router : Match, RouteTable;
import flint.web.stream : StreamToken;
import flint.web.types : Method, Request, RequestContext, RequestMetadata, Response;
import flint.web.wire : responseCode;

@safe:

package(flint.web) Result!Response executeRoute(RouteTable routes, scope RequestMetadata* metadata,
        ref scope RequestContext context) nothrow @nogc
{
    auto matched = lookupRoute(routes, metadata, context.arena);
    return executeMatched(routes, metadata, context, matched);
}

package(flint.web) Match lookupRoute(RouteTable routes, scope const RequestMetadata* metadata,
        ref scope RequestArena arena) nothrow @nogc
{
    Match matched;
    const status = arena.read(metadata.path, (scope const(ubyte)[] path) @safe nothrow @nogc {
        matched = routes.find(metadata.method, path);
    });
    if (status != Status.ok)
        matched.error = Error(Status.ioError, "request path is unavailable");
    return matched;
}

package(flint.web) Error executeStream(scope RequestMetadata* metadata,
        ref scope RequestContext context, const ref Match matched, scope StreamToken token) nothrow @nogc
{
    scope request = Request.fromMetadata(metadata);
    request.setCaptures(matched.captures[0 .. matched.count]);
    return matched.stream(request, context, token);
}

package(flint.web) Result!Response executeMatched(RouteTable routes, scope RequestMetadata* metadata,
        ref scope RequestContext context, const ref Match matched) nothrow @nogc
{
    // RFC 9110 section 15.5.6: the path exists under other methods; the transport adds Allow.
    if (matched.error.code == Status.notFound && matched.allowed != 0)
        return Result!Response(failureResponse(405, context.arena));
    if (matched.error.code != Status.ok)
        return Result!Response(Response.init, Error(matched.error.code, "invalid or unmatched HTTP route"));
    if (matched.handler is null)
        return Result!Response(Response.init, Error(Status.notFound, "this transport does not serve the route"));

    scope request = Request.fromMetadata(metadata);
    request.setCaptures(matched.captures[0 .. matched.count]);
    const result = matched.handler(request, context);
    if (result.ok() || result.error.code == Status.cancelled || context.cancellation.cancelled())
        return result;
    const advice = routes.advice();
    if (advice is null)
        return result;

    Response response = advice(Error(result.error.code, "request failed"), context);
    response.status = responseCode(result.error.code);
    return Result!Response(response);
}

package(flint.web) Response failureResponse(ushort status, ref scope RequestArena arena) nothrow @nogc
{
    auto message = arena.copyIn(cast(const(ubyte)[]) "{\"error\":\"request failed\"}");
    return Response(status, "application/json", message.ok() ? message.value : Buffer.init);
}

package(flint.web) bool liveBody(Buffer body, ref scope RequestArena arena) nothrow @nogc
{
    return
    body == Buffer.init || arena.read(body, (scope const(ubyte)[]) @safe nothrow @nogc {}) == Status.ok;
}
