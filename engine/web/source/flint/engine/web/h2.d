/++
HTTP/2 for `Server`, attached by application composition. A listener that allows HTTP/2 (prior knowledge, or TLS with
`ServerOptions.http2`) needs `enableHttp2()` before `Server.start`; a program that never calls it links neither the
HTTP/2 driver nor nghttp2.
+/
module flint.engine.web.h2;

import flint.conc : Context;
import flint.engine.web.http2 : H2Driver;
import flint.engine.web.http2_endpoint : Http2Endpoint, installHttp2;
import flint.engine.web.router : RouteTable;
import flint.engine.web.types : ServerOptions;

@safe:

/// Link the pinned nghttp2 provider and let `Server.start` accept HTTP/2. Idempotent.
void enableHttp2() nothrow @nogc
{
    installHttp2(&createHttp2);
}

private Http2Endpoint createHttp2(ServerOptions options, RouteTable routes, Context root, Context drain)
{
    return new H2Driver!()(options, routes, root, drain);
}
