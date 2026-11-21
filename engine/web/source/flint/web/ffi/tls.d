/// Pinned OpenSSL memory BIO boundary. Socket buffers stay on the reactor.
module flint.web.ffi.tls;

import flint.arena : Error, Status;

@safe:
package(flint.web):

enum TlsProgress : int
{
    failed = -1,
    waiting = 0,
    ready,
    eof
}

struct TlsStep
{
    TlsProgress progress = TlsProgress.failed;
    size_t bytes;
}

private struct NativeServer;
private struct NativeSession;

version (FlintNativeOpenssl)
{
    private extern (C) @system nothrow @nogc
    {
        NativeServer* flint_tls_open(scope const(char)* certificate, scope const(char)* key, int offerH2);
        void flint_tls_close(NativeServer* server);
        NativeSession* flint_tls_accept(NativeServer* server);
        void flint_tls_free(NativeSession* session);
        int flint_tls_receive(NativeSession* session, scope const(ubyte)* input, size_t length);
        int flint_tls_handshake(NativeSession* session);
        int flint_tls_protocol(const NativeSession* session);
        int flint_tls_read(NativeSession*, scope ubyte*, size_t, scope size_t*);
        int flint_tls_write(NativeSession*, scope const(ubyte)*, size_t, scope size_t*);
        size_t flint_tls_pending(const NativeSession* session);
        size_t flint_tls_send(NativeSession* session, scope ubyte* output, size_t capacity);
        int flint_tls_shutdown(NativeSession* session);
    }
}

/// Startup owner of immutable credentials and ALPN. Retires after all accepted sessions.
struct TlsServer
{
    private NativeServer* native;

    @disable this(this);
    @disable void opAssign(TlsServer replacement);

    // SAFETY: Paths are validated and copied into bounded NUL-terminated locals. The provider loads them synchronously.
    Error open(scope string certificate, scope string key, bool offerH2) scope @trusted nothrow @nogc
    {
        if (native !is null)
            return Error(Status.conflict, "TLS server credentials already loaded");
        version (FlintNativeOpenssl)
        {
            char[4097] certificatePath;
            char[4097] keyPath;
            if (!putPath(certificate, certificatePath) || !putPath(key, keyPath))
                return Error(Status.invalidArgument, "invalid TLS credential path");
            native = flint_tls_open(certificatePath.ptr, keyPath.ptr, offerH2);
            return native is null ? Error(Status.invalidArgument, "unable to load TLS certificate or private key")
                : Error.init;
        }
        else
            return Error(Status.unsupported, "pinned OpenSSL provider is unavailable");
    }

    // SAFETY: The context is initialized and immutable during admission. Only the owner worker uses the new SSL.
    bool accept(ref TlsSession session) scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            if (native is null || session.native !is null)
                return false;
            session.native = flint_tls_accept(native);
            return session.native !is null;
        }
        else
            return false;
    }

    // SAFETY: All worker loops have joined and every unique SSL session was released before its context.
    void close() scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            flint_tls_close(native);
            native = null;
        }
    }
}

private bool putPath(scope string name, ref scope char[4097] path) pure nothrow @nogc
{
    if (name.length == 0 || name.length >= path.length)
        return false;
    foreach (position, character; name)
    {
        if (character == 0)
            return false;
        path[position] = character;
    }
    path[name.length] = 0;
    return true;
}

/// Unique owner-core TLS session. OpenSSL never receives a D callback or stores a D slice.
struct TlsSession
{
    private NativeSession* native;

    @disable this(this);
    @disable void opAssign(TlsSession replacement);

    // SAFETY: The live owner passes a sized ciphertext slice. OpenSSL copies it into its bounded BIO.
    bool receive(scope const(ubyte)[] bytes) scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
            return native !is null && flint_tls_receive(native, bytes.ptr, bytes.length) == 0;
        else
            return false;
    }

    // SAFETY: The live session runs only on its owner. Handshake touches OpenSSL-owned state only.
    TlsProgress handshake() scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
            return native is null ? TlsProgress.failed : convert(flint_tls_handshake(native));
        else
            return TlsProgress.failed;
    }

    // SAFETY: Negotiation returns a scalar from the live owner-local session.
    bool useH2() const scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
            return native !is null && flint_tls_protocol(native) == 2;
        else
            return false;
    }

    // SAFETY: OpenSSL writes only within the scoped output and retains neither it nor the local byte count.
    TlsStep read(scope ubyte[] output) scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            if (native is null || output.length == 0 || output.length > 4096)
                return TlsStep.init;
            size_t written;
            const progress = convert(flint_tls_read(native, output.ptr, output.length, &written));
            return written <= output.length ? TlsStep(progress, written) : TlsStep.init;
        }
        else
            return TlsStep.init;
    }

    // SAFETY: The owner keeps the same sized plaintext until the call succeeds. OpenSSL retains no input pointer.
    TlsStep write(scope const(ubyte)[] input) scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            if (native is null || input.length == 0 || input.length > 4096)
                return TlsStep.init;
            size_t consumed;
            const progress = convert(flint_tls_write(native, input.ptr, input.length, &consumed));
            return consumed <= input.length ? TlsStep(progress, consumed) : TlsStep.init;
        }
        else
            return TlsStep.init;
    }

    // SAFETY: This borrowed query reads only the live, owner-local ciphertext backlog.
    bool pending() const scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
            return native !is null && flint_tls_pending(native) != 0;
        else
            return false;
    }

    // SAFETY: The bounded local array remains valid while BIO copies. It is transferred later by the Reactor.
    size_t send(scope ubyte[] output) scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            if (native is null || output.length == 0 || output.length > 4096)
                return 0;
            const written = flint_tls_send(native, output.ptr, output.length);
            return written <= output.length ? written : 0;
        }
        else
            return 0;
    }

    // SAFETY: The owner runs the shutdown step only after application I/O stops. Ciphertext stays in the native BIO.
    bool shutdown() scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
            return native !is null && flint_tls_shutdown(native) >= 0;
        else
            return false;
    }

    // SAFETY: Both encrypted operations have retired. OpenSSL frees only its uniquely held objects.
    void close() scope @trusted nothrow @nogc
    {
        version (FlintNativeOpenssl)
        {
            flint_tls_free(native);
            native = null;
        }
    }
}

private TlsProgress convert(int code) pure nothrow @nogc
{
    return code < TlsProgress.failed || code > TlsProgress.eof ? TlsProgress.failed : cast(TlsProgress) code;
}
