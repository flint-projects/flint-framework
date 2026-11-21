/// Common owner-fiber route lookup and application dispatch.
module flint.web.dispatch;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.web.router : Match, RouteTable;
import flint.web.types : Method, Request, RequestContext, RequestMetadata, Response;
import flint.web.wire : responseCode;

@safe:

package(flint.web) Result!Response executeRoute(RouteTable routes, scope RequestMetadata* metadata,
        ref scope RequestContext context) nothrow @nogc
{
    scope request = Request.fromMetadata(metadata);
    Match matched;
    const status = context.arena.read(metadata.path, (scope const(ubyte)[] path) @safe nothrow @nogc {
        matched = routes.find(metadata.method, path);
    });
    if (status != Status.ok)
        return Result!Response(Response.init, Error(Status.ioError, "request path is unavailable"));
    if (matched.error.code != Status.ok)
        return Result!Response(Response.init, matched.error);

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
