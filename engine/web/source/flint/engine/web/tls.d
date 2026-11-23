/++
TLS for `Server`, attached by application composition. A listener configured with a certificate needs
`enableTls()` before `Server.start`; a program that never calls it links neither the TLS driver nor OpenSSL.
+/
module flint.engine.web.tls;

import flint.conc : Context;
import flint.engine.reactor : AcceptDelegate;
import flint.engine.web.transport : TlsDriver, TlsTransport, installTls;
import flint.engine.web.types : ServerOptions;

@safe:

/// Link the pinned OpenSSL transport and let `Server.start` accept TLS listeners. Idempotent; call it before
/// starting a server whose `ServerOptions` name a certificate and key.
void enableTls() nothrow @nogc
{
    installTls(&createTls);
}

private TlsTransport createTls(ServerOptions limits, Context root, AcceptDelegate http1, AcceptDelegate http2) nothrow
{
    return new TlsDriver!()(limits, root, http1, http2);
}
