/// Opaque synchronous callback boundary for the pinned web providers.
module flint.engine.web.ffi.shim;

import flint.arena : Error, Status;

@safe:

/// Normalized fragments from llhttp.
enum HttpEvent : uint
{
    /// The parser began a new request.
    begin = 1,
    /// A fragment of the request target.
    target,
    /// A fragment of the current header name.
    field,
    /// The current header name is complete.
    fieldEnd,
    /// A fragment of the current header value.
    value,
    /// The current header value is complete.
    valueEnd,
    /// The header block is complete.
    headers,
    /// A fragment of the dechunked request body.
    body,
    /// The message is complete.
    complete
}

/// Result of feeding one bounded input slice.
enum HttpProgress : int
{
    /// Native grammar or the event sink rejected the input.
    failed = -1,
    /// The parser consumed all bytes and needs more input.
    more = 0,
    /// The parser stopped at the end of headers.
    headers,
    /// The parser stopped at the end of the request.
    complete
}

/// Validated framing metadata returned at the headers pause.
extern (C) struct Http1Info
{
    /// Explicit content length, or zero if absent.
    ulong contentLength;
    /// Flint method ordinal or uint.max when unsupported.
    uint method;
    /// First HTTP version component.
    ubyte major;
    /// Second HTTP version component.
    ubyte minor;
    /// The protocol permits a subsequent request.
    ubyte keepAlive;
    /// The body is framed as chunks.
    ubyte chunked;
    /// llhttp recognized a protocol upgrade at the header boundary.
    ubyte upgrade;
}

/// Progress and count from one bounded input window.
struct Http1Feed
{
    /// Whether more bytes or a complete boundary was observed.
    HttpProgress progress = HttpProgress.failed;
    /// Number of input bytes accepted by the provider.
    size_t consumed;
    /// Operational rejection reported by the event sink.
    Status rejected;
}

/// Synchronous event sink for one invariant-checked parser call.
alias EventSink = Status delegate(HttpEvent event, scope const(ubyte)[] bytes) @safe nothrow @nogc;

private struct NativeHttp1;

private EventSink activeSink;
private ulong activeToken;
private Status sinkStatus;

version (FlintNativeLlhttp)
{
    private extern (C) alias NativeCallback = int function(ulong token, uint event,
            scope const(ubyte)* bytes, size_t length) @system nothrow @nogc;

    private extern (C) @system nothrow @nogc
    {
        NativeHttp1* flint_http1_new_token(ulong token, NativeCallback callback);
        int flint_http1_feed_some(NativeHttp1*, scope const(ubyte)*, size_t, scope size_t*);
        int flint_http1_headers(const NativeHttp1* parser, scope Http1Info* info);
        void flint_http1_free(NativeHttp1* parser);

        int relay(ulong token, uint event, scope const(ubyte)* bytes, size_t length)
        {
            if (token != activeToken || activeSink is null || event < HttpEvent.begin
                    || event > HttpEvent.complete || (bytes is null && length != 0))
                return -1;
            sinkStatus = activeSink(cast(HttpEvent) event, length == 0 ? null : bytes[0 .. length]);
            return sinkStatus == Status.ok ? 0 : -1;
        }
    }
}

/// Owns a single opaque parser on its reactor core.
struct Http1Parser
{
    private NativeHttp1* native;
    private ulong token;

    @disable this(this);

    @disable void opAssign(Http1Parser parser);

    /// Create an owner-local parser with a nonzero numeric generation.
    // SAFETY: The native instance is uniquely owned here. C retains only token and a static function.
    Error open(ulong generation) scope @trusted nothrow @nogc
    {
        if (generation == 0)
            return Error(Status.invalidArgument, "invalid HTTP connection generation");
        if (native !is null)
            return Error(Status.conflict, "HTTP parser already open");
        version (FlintNativeLlhttp)
        {
            native = flint_http1_new_token(generation, &relay);
            if (native is null)
                return Error(Status.outOfMemory, "unable to allocate HTTP parser");
            token = generation;
            return Error.init;
        }
        else
            return Error(Status.unsupported, "pinned llhttp provider is unavailable");
    }

    /// Consume a prefix of the input and stop at one complete protocol boundary.
    // SAFETY: llhttp calls its fixed relay synchronously on this owner. The sink is rooted for the call
    // and cleared before return. Its scoped pointer-length input remains within llhttp's borrowed slice.
    Http1Feed feed(scope const(ubyte)[] input, scope EventSink sink) scope @trusted nothrow @nogc
    {
        if (native is null || sink is null || activeSink !is null)
            return Http1Feed(HttpProgress.failed, 0, Status.invalidArgument);
        version (FlintNativeLlhttp)
        {
            activeSink = sink;
            activeToken = token;
            sinkStatus = Status.ok;
            scope (exit)
            {
                activeSink = null;
                activeToken = 0;
            }
            size_t consumed;
            const result = flint_http1_feed_some(native, input.ptr, input.length, &consumed);
            if (consumed > input.length || result < HttpProgress.failed || result > HttpProgress.complete)
                return Http1Feed(HttpProgress.failed, 0, Status.ioError);
            return Http1Feed(cast(HttpProgress) result, consumed, sinkStatus);
        }
        else
            return Http1Feed(HttpProgress.failed, 0, Status.unsupported);
    }

    /// Read the typed C ABI record only at a provider-confirmed headers boundary.
    // SAFETY: The checked unique parser is owner-local, and C initializes only this fixed local record.
    bool headers(out Http1Info info) scope @trusted nothrow @nogc
    {
        version (FlintNativeLlhttp)
            return native !is null && flint_http1_headers(native, &info) == 0;
        else
            return false;
    }

    /// Release the parser after all synchronous native callbacks have returned.
    // SAFETY: The owner invokes this outside an active feed. C frees only the uniquely held parser.
    void close() scope @trusted nothrow @nogc
    {
        version (FlintNativeLlhttp)
        {
            if (native !is null && (activeSink is null || activeToken != token))
            {
                flint_http1_free(native);
                native = null;
                token = 0;
            }
        }
    }
}
