/// Exercise the opt-in limit on an exact response-stream route.
module app;

import core.atomic : atomicLoad, atomicStore;
import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.web : Method, Request, RequestContext, Response, Server, ServerOptions,
    StreamMode, StreamRoute, StreamToken;
import std.conv : to;

@safe:

private shared bool stop;

private final class Fixture
{
    Result!Response ordinary(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return Result!Response(Response(204));
    }

    Result!Response shutdown(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        atomicStore(stop, true);
        return Result!Response(Response(204));
    }

    Error larger(ref scope Request request, ref scope RequestContext context, scope StreamToken stream) nothrow @nogc
    {
        const payload = request.body();
        if (!payload.ok() || (payload.value.length() != 1_048_577 && payload.value.length() != 4_194_304))
            return Error(Status.invalidArgument, "incorrect fixture body size");
        const started = stream.begin(200, [], context.cancellation);
        if (started.code != Status.ok)
            return started;
        const sent = stream.send(cast(const(ubyte)[]) "large request accepted", context.cancellation);
        return sent.code == Status.ok ? stream.finish([], context.cancellation) : sent;
    }
}

int main(string[] args)
{
    if (args.length != 3)
        return 1;
    ServerOptions options;
    options.port = to!ushort(args[1]);
    options.http2PriorKnowledge = args[2] == "h2";
    options.maxConnectionsPerCore = 4;
    options.maxStreamsPerConnection = 4;
    options.maxStreamingRequestBytes = 4 * 1024 * 1024;
    Server server;
    if (server.start(options).code != Status.ok)
        return 2;
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);

    auto fixture = new Fixture;
    if (server.route(Method.post, "/ordinary", &fixture.ordinary).code != Status.ok
            || server.route(Method.get, "/shutdown", &fixture.shutdown).code != Status.ok
            || server.routeStream(StreamRoute(Method.post, "/large", StreamMode.response,
                &fixture.larger)).code != Status.ok)
        return 3;
    Context context;
    while (!atomicLoad(stop))
    {
        if (server.poll(context).code != Status.ok)
            return 4;
    }
    return 0;
}
