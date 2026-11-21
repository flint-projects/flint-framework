/// Typed boundary for the pinned libcurl provider.
module flint.http.ffi.shim;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.http.types : ChunkConsumer, ClientOptions, DestinationPolicy, Header, HttpMethod,
    HttpRequestView, HttpResponse, HttpStreamOptions, HttpVersion;

@safe:

package(flint.http) struct NativeWatch
{
    ptrdiff_t fd;
    uint events;
    ulong generation;
}

private struct NativeOptions
{
    uint connections;
    uint perOrigin;
    size_t bodyBytes;
    size_t headerBytes;
    ulong connectMs;
    ubyte redirects;
    const(char)* caPath;
    size_t caLength;
}

private struct NativeView
{
    uint state;
    uint status;
    uint protocol;
    uint error;
    const(ubyte)* headers;
    size_t headerLength;
    const(ubyte)* body;
    size_t bodyLength;
    const(ubyte)* chunk;
    size_t chunkLength;
    const(char)* redirect;
    size_t redirectLength;
    const(char)* url;
    size_t urlLength;
    uint paused;
}

private struct NativeStreamView
{
    const(ubyte)* head;
    size_t headLength;
    const(ubyte)* trailers;
    size_t trailerLength;
    uint flags;
    uint status;
    uint protocol;
    uint error;
}

private struct NativeLoop;

extern (C) private @system nothrow @nogc
{
    int flint_http_initialize();
    int flint_http_new(const(NativeOptions)* options, NativeLoop** output);
    int flint_http_begin(NativeLoop* loop, const(char)* url, size_t length, uint method, uint stream, ulong* output);
    int flint_http_begin_view(NativeLoop* loop, scope const(char)* url, size_t length, uint method,
            uint flags, const(ubyte)* input, size_t inputLength, scope ulong* output);
    int flint_http_stream_begin(NativeLoop* loop, scope const(char)* url, size_t length, uint mode,
            ubyte allowCleartext, uint receiveRate, scope ulong* output);
    int flint_http_stream_view_request(NativeLoop* loop, ulong id, scope NativeStreamView* output);
    int flint_http_stream_write(NativeLoop* loop, ulong id, scope const(ubyte)* input,
            size_t length, scope size_t* written);
    int flint_http_stream_read(NativeLoop* loop, ulong id, scope ubyte* output, size_t length, scope size_t* received);
    int flint_http_stream_finish_send(NativeLoop* loop, ulong id);
    int flint_http_header(NativeLoop* loop, ulong id, const(char)* key, size_t keyLength,
            const(char)* value, size_t valueLength);
    int flint_http_aws_v4(NativeLoop* loop, ulong id, scope const(char)* region, size_t regionLength,
            scope const(char)* service, size_t serviceLength, scope const(char)* access,
            size_t accessLength, scope const(char)* secret, size_t secretLength);
    int flint_http_body(NativeLoop* loop, ulong id, const(ubyte)* bytes, size_t length);
    int flint_http_activate(NativeLoop* loop, ulong id);
    int flint_http_view_request(NativeLoop* loop, ulong id, NativeView* output);
    int flint_http_consume_chunk(NativeLoop* loop, ulong id);
    int flint_http_follow(NativeLoop* loop, ulong id);
    int flint_curl_cancel(NativeLoop* loop, ulong id);
    int flint_http_release(NativeLoop* loop, ulong id);
    int flint_http_watch_snapshot(NativeLoop* loop, NativeWatch* output, size_t length, ulong* revision, size_t* count);
    int flint_http_due(NativeLoop* loop);
    int flint_http_poll(NativeLoop* loop, uint maxWaitMs);
    int flint_curl_socket(NativeLoop* loop, ptrdiff_t fd, int events);
    void flint_curl_free(NativeLoop* loop);
}

version (linux) version (FlintNativeCurl) version = FlintCurlOnLinux;

version (FlintCurlOnLinux)
{
    private enum provider = true;
}
else
{
    private enum provider = false;
}

private shared Status initialization = Status.unsupported;

// SAFETY: Typed callers supply owned handles and valid buffer bounds. Owner-only native calls copy inputs,
// retain no D pointers, invoke no D callbacks and cannot throw D exceptions.
private Status invoke(alias fn, Args...)(scope Args args) @trusted nothrow @nogc
{
    static if (provider)
        return cast(Status) fn(args);
    else
        return Status.unsupported;
}

shared static this()
{
    initialization = invoke!flint_http_initialize();
}

private Error nativeError(Status code) pure nothrow @nogc
{
    static immutable string[] messages = [
        null, "invalid HTTP URL, method, header or pool setting",
        "HTTP storage exhausted", "HTTP transfer cancelled",
        "HTTP connection deadline elapsed", "HTTP transfer generation expired",
        "HTTP transport owner or transfer state conflict", "HTTP transport failed",
        "HTTP origin unavailable", "HTTP protocol or pinned libcurl provider unavailable",
        "HTTP TLS, redirect or destination policy rejected", "HTTP transfer limit exceeded",
    ];
    static assert(messages.length == Status.max + 1);
    return Error(code, messages[cast(int) code]);
}

package(flint.http) struct TransferView
{
    bool complete;
    bool chunkReady;
    bool redirectReady;
    ushort status;
    HttpVersion protocol;
    Error error;
}

package(flint.http) struct StreamView
{
    bool headReady;
    bool complete;
    ushort status;
    HttpVersion protocol;
    Error error;
}

package(flint.http) alias RequestTransfer = Result!HttpResponse delegate(ulong id) @safe nothrow @nogc;

package(flint.http) struct Bridge
{
    private NativeLoop* loop;
    @disable this(this);

    package(flint.http) bool isOpen() const nothrow @nogc
    {
        return loop !is null;
    }

    package(flint.http) Error open(ClientOptions config) nothrow @nogc
    {
        if (initialization != Status.ok)
            return nativeError(initialization);
        NativeOptions options;
        options.connections = config.maxConnections;
        options.perOrigin = config.maxConnectionsPerOrigin;
        options.bodyBytes = config.maxResponseBytes;
        options.headerBytes = config.maxHeaderBytes;
        immutable nanos = cast(ulong) config.connectTimeoutNanos;
        options.connectMs = nanos / 1_000_000 + (nanos % 1_000_000 != 0);
        options.redirects = config.followRedirects;
        options.caPath = config.caBundle.length ? &config.caBundle[0] : null;
        options.caLength = config.caBundle.length;
        return nativeError(invoke!flint_http_new(&options, &loop));
    }

    package(flint.http) Result!ulong begin(scope const(char)[] url, HttpMethod method, bool streaming) nothrow @nogc
    {
        ulong id;
        const status = invoke!flint_http_begin(loop, url.length ? &url[0] : null, url.length,
                cast(uint) method, cast(uint) streaming, &id);
        return Result!ulong(id, nativeError(status));
    }

    // The scoped action receives only the generation, cannot throw, and runs outside C callbacks.
    // SAFETY: Cancel and release synchronously retire the bounded upload on its owner before return.
    package(flint.http) Result!HttpResponse withRequest(scope const ref HttpRequestView request,
            bool streaming, scope RequestTransfer action) @trusted nothrow @nogc
    {
        static if (!provider)
            return Result!HttpResponse(HttpResponse.init, nativeError(Status.unsupported));
        else
        {
            uint flags = streaming ? 1u : 0u;
            if (request.preservePath)
                flags |= 2;
            if (streaming && request.successBodyOnly)
                flags |= 4;
            ulong id;
            const status = cast(Status) flint_http_begin_view(loop, request.url.ptr,
                    request.url.length, cast(uint) request.method, flags, request.body.ptr, request.body.length, &id);
            if (status != Status.ok)
                return Result!HttpResponse(HttpResponse.init, nativeError(status));
            scope (exit)
                retire(id);
            const aws = request.awsV4;
            if (aws.region.length || aws.service.length || aws.accessKey.length || aws.secretKey.length)
            {
                const signed = cast(Status) flint_http_aws_v4(loop, id, aws.region.ptr,
                        aws.region.length, aws.service.ptr, aws.service.length, aws.accessKey.ptr,
                        aws.accessKey.length, aws.secretKey.ptr, aws.secretKey.length);
                if (signed != Status.ok)
                    return Result!HttpResponse(HttpResponse.init, nativeError(signed));
            }
            return action(id);
        }
    }

    package(flint.http) Result!ulong beginStream(scope const ref HttpStreamOptions options) nothrow @nogc
    {
        ulong id;
        scope url = options.url;
        const status = invoke!flint_http_stream_begin(loop, url.length ? &url[0] : null, url.length,
                cast(uint) options.mode, cast(ubyte) options.allowLoopbackCleartext,
                options.duplexReceiveBytesPerSecond, &id);
        return Result!ulong(id, nativeError(status));
    }

    package(flint.http) Error header(ulong id, scope const ref Header field) nothrow @nogc
    {
        return header(id, field.name, field.value);
    }

    package(flint.http) Error header(ulong id, scope const(char)[] name, scope const(char)[] value) nothrow @nogc
    {
        return nativeError(invoke!flint_http_header(loop, id, name.length ? &name[0] : null,
                name.length, value.length ? &value[0] : null, value.length));
    }

    package(flint.http) Error upload(ulong id, scope const(ubyte)[] bytes) nothrow @nogc
    {
        return nativeError(invoke!flint_http_body(loop, id, bytes.length ? &bytes[0] : null, bytes.length));
    }

    package(flint.http) Error activate(ulong id) nothrow @nogc
    {
        return nativeError(invoke!flint_http_activate(loop, id));
    }

    package(flint.http) TransferView view(ulong id) nothrow @nogc
    {
        NativeView snapshot;
        const result = invoke!flint_http_view_request(loop, id, &snapshot);
        if (result != Status.ok)
        {
            TransferView failure;
            failure.error = nativeError(result);
            return failure;
        }

        enum completeState = 3;
        return TransferView(snapshot.state == completeState, snapshot.chunkLength != 0,
                snapshot.redirectLength != 0, cast(ushort) snapshot.status,
                cast(HttpVersion) snapshot.protocol, nativeError(cast(Status) snapshot.error));
    }

    package(flint.http) StreamView streamView(ulong id) nothrow @nogc
    {
        NativeStreamView snapshot;
        const status = invoke!flint_http_stream_view_request(loop, id, &snapshot);
        if (status != Status.ok || snapshot.error > Status.max || snapshot.protocol > HttpVersion.max)
        {
            StreamView failed;
            failed.error = nativeError(status != Status.ok ? status : Status.ioError);
            return failed;
        }
        return StreamView((snapshot.flags & 1) != 0, (snapshot.flags & 2) != 0,
                cast(ushort) snapshot.status, cast(HttpVersion) snapshot.protocol,
                nativeError(cast(Status) snapshot.error));
    }

    package(flint.http) Result!size_t streamWrite(ulong id, scope const(ubyte)[] input) nothrow @nogc
    {
        size_t written;
        const status = invoke!flint_http_stream_write(loop, id, input.length ? &input[0] : null,
                input.length, &written);
        if (written > input.length)
            return Result!size_t(0, nativeError(Status.ioError));
        return Result!size_t(written, nativeError(status));
    }

    package(flint.http) Result!size_t streamRead(ulong id, scope ubyte[] output) nothrow @nogc
    {
        size_t read;
        const status = invoke!flint_http_stream_read(loop, id, output.length ? &output[0] : null,
                output.length, &read);
        if (read > output.length)
            return Result!size_t(0, nativeError(Status.ioError));
        return Result!size_t(read, nativeError(status));
    }

    package(flint.http) Error finishStreamSend(ulong id) nothrow @nogc
    {
        return nativeError(invoke!flint_http_stream_finish_send(loop, id));
    }

    // dfmt off
    // SAFETY: The owner holds the bounded metadata through a synchronous arena copy with no callback or pointer escape.
    package(flint.http) Result!Buffer copyStreamFields(ulong id, bool trailers,
            ref scope RequestArena arena) @trusted nothrow @nogc
    {
        NativeStreamView snapshot;
        const status = invoke!flint_http_stream_view_request(loop, id, &snapshot);
        if (status != Status.ok)
            return Result!Buffer(Buffer.init, nativeError(status));
        const data = trailers ? snapshot.trailers : snapshot.head;
        const length = trailers ? snapshot.trailerLength : snapshot.headLength;
        if (data is null && length != 0)
            return Result!Buffer(Buffer.init, nativeError(Status.ioError));
        return copyBytes(arena, length == 0 ? null : data[0 .. length]);
    }
    // dfmt on

    // SAFETY: The owner fiber holds both bounded URLs through follow or release, including while suspended.
    // The scope callback cannot retain them or throw.
    package(flint.http) Error allow(ulong id, scope DestinationPolicy policy, bool redirect) @trusted nothrow @nogc
    {
        if (policy is null)
            return Error.init;
        NativeView snapshot;
        const result = invoke!flint_http_view_request(loop, id, &snapshot);
        if (result != Status.ok)
            return nativeError(result);
        const url = redirect ? snapshot.redirect[0 .. snapshot.redirectLength] : snapshot.url[0 .. snapshot.urlLength];
        return policy(url) ? Error.init : nativeError(Status.permissionDenied);
    }

    // SAFETY: The owner fiber holds the validated chunk until delivery ends, even while suspended.
    // The scope callback cannot retain it or throw and libcurl pauses writes to the occupied slot.
    package(flint.http) Error deliver(ulong id, scope ChunkConsumer consume) @trusted nothrow @nogc
    {
        NativeView snapshot;
        const result = invoke!flint_http_view_request(loop, id, &snapshot);
        if (result != Status.ok)
            return nativeError(result);
        if (snapshot.chunkLength == 0)
            return nativeError(Status.conflict);
        return consume(snapshot.chunk[0 .. snapshot.chunkLength]);
    }

    package(flint.http) Error consumeChunk(ulong id) nothrow @nogc
    {
        return nativeError(invoke!flint_http_consume_chunk(loop, id));
    }

    package(flint.http) Error follow(ulong id) nothrow @nogc
    {
        return nativeError(invoke!flint_http_follow(loop, id));
    }

    // SAFETY: The completed owner request keeps the native lengths and data until release.
    // The immediate arena visitors copy bounded slices, cannot throw and do not change threads.
    package(flint.http) Result!HttpResponse copyResponse(ulong id, ref scope RequestArena arena) @trusted nothrow @nogc
    {
        NativeView snapshot;
        const result = invoke!flint_http_view_request(loop, id, &snapshot);
        if (result != Status.ok)
            return Result!HttpResponse(HttpResponse.init, nativeError(result));
        assert(snapshot.state == 3 && snapshot.error == 0);

        const stats = arena.stats();
        const remaining = stats.capacity - stats.used;
        if (snapshot.headerLength > remaining || snapshot.bodyLength > remaining - snapshot.headerLength)
            return Result!HttpResponse(HttpResponse.init, Error(Status.outOfMemory, "HTTP response arena exhausted"));
        auto headers = copyBytes(arena, snapshot.headers[0 .. snapshot.headerLength]);
        if (!headers.ok())
            return Result!HttpResponse(HttpResponse.init, headers.error);
        auto body = copyBytes(arena, snapshot.body[0 .. snapshot.bodyLength]);
        if (!body.ok())
            return Result!HttpResponse(HttpResponse.init, body.error);
        return Result!HttpResponse(HttpResponse(cast(ushort) snapshot.status, headers.value,
                body.value, cast(HttpVersion) snapshot.protocol));
    }

    package(flint.http) void retire(ulong id) nothrow @nogc
    {
        const cancelled = invoke!flint_curl_cancel(loop, id);
        if (cancelled != Status.ok)
            assert(0, "native HTTP transfer could not be cancelled");
        const released = invoke!flint_http_release(loop, id);
        if (released != Status.ok)
            assert(0, "native HTTP transfer could not be released");
    }

    package(flint.http) Error retireStream(ulong id) nothrow @nogc
    {
        return nativeError(invoke!flint_http_release(loop, id));
    }

    package(flint.http) Result!size_t watches(scope NativeWatch[] output, ref ulong revision) nothrow @nogc
    {
        size_t count;
        const status = invoke!flint_http_watch_snapshot(loop, output.length ? &output[0] : null,
                output.length, &revision, &count);
        return Result!size_t(count, nativeError(status));
    }

    package(flint.http) Error due() nothrow @nogc
    {
        return nativeError(invoke!flint_http_due(loop));
    }

    package(flint.http) Error poll(uint maxWaitMs) nothrow @nogc
    {
        return nativeError(invoke!flint_http_poll(loop, maxWaitMs));
    }

    package(flint.http) Error ready(int fd, uint events) nothrow @nogc
    {
        return nativeError(invoke!flint_curl_socket(loop, cast(ptrdiff_t) fd, cast(int) events));
    }

    // SAFETY: The enclosing client clears owner watches first and proves all request fibers
    // have completed on this owner; libcurl cleanup invokes only native bookkeeping callbacks.
    package(flint.http) void close() @trusted nothrow @nogc
    {
        static if (provider)
            flint_curl_free(loop);
        loop = null;
    }
}

private Result!Buffer copyBytes(ref scope RequestArena arena, scope const(ubyte)[] bytes) nothrow @nogc
{
    auto allocation = arena.allocate(bytes.length, 1);
    if (!allocation.ok())
        return allocation;
    const status = arena.write(allocation.value, (scope ubyte[] output) { output[] = bytes[]; });
    return Result!Buffer(allocation.value, nativeError(status));
}
