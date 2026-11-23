module transport_probe;

import flint.arena : RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.http : ClientOptions, HttpClient, HttpMethod, HttpRequest;
import flint.engine.web : Method, Request, RequestContext, Response, Server, ServerOptions;
import core.stdc.stdio : printf, snprintf;
import core.sys.posix.arpa.inet : htonl, ntohs;
import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, IPPROTO_TCP, sockaddr_in;
import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, bind, getsockname, sockaddr, socket, socklen_t;
import core.sys.posix.unistd : close;

private enum path = "/actuator-fixture";
private enum payload = "fixture_counter_total 7\n";

private Result!Response scrape(ref scope Request, ref scope RequestContext context) @safe nothrow @nogc
{
    const bytes = context.arena.copyIn(cast(const(ubyte)[]) payload);
    return Result!Response(Response(200, "text/plain", bytes.value), bytes.error);
}

/// Bind an ephemeral loopback TCP port, read it back and release it for the fixture server.
private ushort reservePort()
{
    const reservation = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (reservation < 0)
        throw new Exception("could not create the port reservation socket");
    scope (exit)
        close(reservation);
    sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = address.sizeof;
    if (bind(reservation, cast(const(sockaddr)*)&address, length) != 0 || getsockname(reservation,
            cast(sockaddr*)&address, &length) != 0)
        throw new Exception("could not reserve a loopback port");
    return ntohs(address.sin_port);
}

/// The loopback fixture URI for the reserved port.
private string fixtureUri(ushort port)
{
    char[64] text;
    const written = snprintf(text.ptr, text.length, "http://127.0.0.1:%u%.*s", cast(uint) port,
            cast(int) path.length, path.ptr);
    assert(written > 0 && written < text.length, "fixture URI does not fit");
    return text[0 .. written].idup;
}

/// Exercise the same linked management transport before counting either variant's observations.
bool checkManagementTransport()
{
    const port = reservePort();

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
    const uri = fixtureUri(port);
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
    printf("verified_management_transport_bytes=%zu\n", result.value.body.length);
    return true;
}
