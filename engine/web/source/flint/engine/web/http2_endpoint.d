/// HTTP/2 as the server runtime sees it: an interface and the factory `flint.engine.web.h2.enableHttp2` installs, so a
/// program that never enables HTTP/2 links neither the driver nor nghttp2.
module flint.engine.web.http2_endpoint;

import core.atomic : atomicLoad, atomicStore;
import flint.conc : Context;
import flint.engine.reactor : ConnectionId;
import flint.engine.web.router : RouteTable;
import flint.engine.web.transport : TlsTransport;
import flint.engine.web.types : ServerOptions;

@safe:
package(flint.engine.web):

/// The HTTP/2 sessions of one server.
interface Http2Endpoint
{
    /// Admit an accepted connection that speaks HTTP/2.
    void accept(ConnectionId id) nothrow @nogc;
    /// The TLS transport its sessions read and write through, when the listener is TLS.
    void setTls(TlsTransport value);
    /// Sessions between admission and retirement.
    uint activeCount() nothrow @nogc;
    /// Streams between admission and retirement.
    uint activeStreams() nothrow @nogc;
    /// Retire every session.
    void release() nothrow @nogc;
}

/// Creates the HTTP/2 runtime for a server.
// dfmt off
alias Http2Factory = Http2Endpoint function(ServerOptions options, RouteTable routes, Context root,
        Context drain) @safe;
// dfmt on

private shared Http2Factory installedHttp2;

/// Install the HTTP/2 runtime; `flint.engine.web.h2.enableHttp2` calls it.
void installHttp2(Http2Factory factory) nothrow @nogc
{
    atomicStore(installedHttp2, factory);
}

/// The installed HTTP/2 factory; null in a program that never enabled HTTP/2.
Http2Factory http2Factory() nothrow @nogc
{
    return atomicLoad(installedHttp2);
}
