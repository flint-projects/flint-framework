/// Monomorphic Flint request parser and radix-route probe.
module flint.web.probe;

import flint.arena : RequestArena, Result, Status;
import flint.web : Handler, Method, Request, RequestContext, Response;
import flint.web.dispatch : executeRoute;
import flint.web.http1 : Http1Reader, ReadOutcome;
import flint.web.router : RouteTable;
import web_probe : Example, measure, observe;

@safe:

private Handler endpoint(uint route)
{
    return (ref scope Request request, ref scope RequestContext context) @safe nothrow @nogc {
        return Result!Response(Response(cast(ushort)(200 + route)));
    };
}

/// Run complete plaintext requests through the pinned Flint parser and router.
int main()
{
    auto routes = new RouteTable;
    if (routes.insert(Method.get, "/health", endpoint(1)).code != Status.ok
            || routes.insert(Method.get, "/users/:id", endpoint(2)).code != Status.ok
            || routes.insert(Method.get, "/assets/*tail", endpoint(3)).code != Status.ok)
        return 1;

    ubyte[4096] storage;
    scope context = RequestContext(RequestArena(storage[]));
    Http1Reader parser;
    if (parser.open(1, new ubyte[1024], 1024, 32).code != Status.ok)
        return 1;
    scope (exit)
        parser.close();

    return measure((scope const Example input) @safe nothrow @nogc {
        return runOne(routes, parser, context, input.request);
    }) ? 0 : 1;
}

private nothrow @nogc:

uint runOne(RouteTable routes, ref Http1Reader parser, ref scope RequestContext context, scope string request)
{
    if (context.arena.reset() != Status.ok || !parser.begin())
        return 0;
    size_t used;
    const result = parser.feed(cast(const(ubyte)[]) request, context.arena, used);
    if (result != ReadOutcome.request || used != request.length)
        return 0;
    const response = executeRoute(routes, &parser.metadata, context);
    if (!response.ok() && response.error.code != Status.notFound)
        return 0;
    const route = response.ok() ? cast(uint)(response.value.status - 200) : 4U;
    return observe(context.arena, route, parser.metadata.body.length());
}
