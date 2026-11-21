module transport_probe;

import flint.arena : RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient, HttpMethod, HttpRequest;
import flint.web : Method, Request, RequestContext, Response, Server, ServerOptions;
import std.conv : to;
import std.socket : AddressFamily, InternetAddress, TcpSocket;
import std.stdio : writeln;

private enum path = "/actuator-fixture";
private enum payload = "fixture_counter_total 7\n";

private Result!Response scrape(ref scope Request, ref scope RequestContext context) @safe nothrow @nogc
{
    const bytes = context.arena.copyIn(cast(const(ubyte)[]) payload);
    return Result!Response(Response(200, "text/plain", bytes.value), bytes.error);
}

/// Exercise the same linked management transport before counting either variant's observations.
bool checkManagementTransport()
{
    auto reservation = new TcpSocket(AddressFamily.INET);
    reservation.bind(new InternetAddress("127.0.0.1", 0));
    const port = (cast(InternetAddress) reservation.localAddress).port;
    reservation.close();

    ServerOptions options;
    options.cores = 1;
    options.port = port;
    options.maxConnectionsPerCore = 2;
    Server server;
    if (server.start(options).code != Status.ok)
        return false;
    scope (exit)
        server.shutdown(Deadline.afterMillis(1000).monotonicNanoseconds);
    const route = server.route(Method.get, path, (ref scope Request request,
            ref scope RequestContext current) @safe nothrow @nogc { return scrape(request, current); });
    if (route.code != Status.ok)
        return false;
    auto context = Context.init.withDeadline(Deadline.afterMillis(5000));
    if (server.poll(context).code != Status.ok)
        return false;
    HttpClient client;
    if (client.open(ClientOptions.init).code != Status.ok)
        return false;
    scope (exit)
        client.close();
    ubyte[4096] storage;
    scope RequestArena arena = RequestArena(storage[]);
    const uri = "http://127.0.0.1:" ~ port.to!string ~ path;
    const request = HttpRequest(HttpMethod.get, uri);
    const result = client.send(request, arena, context);
    if (!result.ok || result.value.status != 200)
        return false;
    bool equal;
    const status = arena.read(result.value.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        equal = bytes == cast(const(ubyte)[]) payload;
    });
    if (status != Status.ok || !equal)
        return false;
    writeln("verified_management_transport_bytes=", result.value.body.length);
    return true;
}
