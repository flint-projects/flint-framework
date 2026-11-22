/// Client-side gRPC framing and terminal status over the pinned HTTP/2 transport.
module flint.rpc.grpc_client;

import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.http : HttpClient, HttpResponse, HttpStream, HttpStreamField, HttpStreamMode,
    HttpStreamOptions, HttpVersion;
import flint.rpc.grpc : GrpcDecoder, RpcCode, RpcStatus, grpcPrefix, grpcStatus, maximumMessageBytes;
import flint.rpc.grpc_route : grpcMedia, identifier;
import flint.rpc.metadata : asciiEqual, visitFields;
import flint.rpc.session : GrpcService;
import flint.rpc.utf8 : utf8Valid;

@safe:

/// An outgoing gRPC method and its bounded HTTP destination.
struct GrpcCallOptions
{
    /// HTTPS origin. Explicit Linux numeric loopback HTTP can be enabled for local peers.
    const(char)[] origin;
    /// Fully qualified Protobuf service.
    GrpcService service;
    /// Exact generated method name.
    string method;
    /// Allow plaintext HTTP/2 only on numeric loopback.
    bool allowLoopbackCleartext;
    /// Application metadata passed to the server.
    const(HttpStreamField)[] metadata;
    /// Largest single uncompressed message admitted in either direction.
    size_t maxMessageBytes = maximumMessageBytes;
    /// Receive-rate target in bytes per second. It also limits pinned curl HTTP/2 stream credit.
    uint receiveBytesPerSecond = 256 * 1024;
}

/// Begin a unary or streaming call. The caller controls message cardinality and upload EOF.
// dfmt off
Result!GrpcCall beginGrpc(ref HttpClient transport, scope const ref GrpcCallOptions options,
        ref Context context) nothrow @nogc
{
    if (!identifier(options.service.serviceName, true) || !identifier(options.method, false)
            || options.service.serviceName.length > 256 || options.method.length > 128
            || options.maxMessageBytes == 0 || options.maxMessageBytes > maximumMessageBytes)
        return Result!GrpcCall(GrpcCall.init, Error(Status.invalidArgument, "invalid gRPC method or message limit"));

    char[16_384] target;
    const length = methodUrl(options, target[]);
    if (length == 0)
        return Result!GrpcCall(GrpcCall.init, Error(Status.invalidArgument, "invalid gRPC origin"));

    char[9] timeout;
    HttpStreamField[64] fields;
    const count = requestFields(options.metadata, fields[]);
    if (count == 0)
        return Result!GrpcCall(GrpcCall.init, Error(Status.invalidArgument, "invalid gRPC call metadata"));
    const timeoutLength = formatTimeout(context.deadline(), timeout[]);
    scope extra = timeoutLength == 0
        ? HttpStreamField.init : HttpStreamField("grpc-timeout", timeout[0 .. timeoutLength]);
    scope request = HttpStreamOptions(target[0 .. length], HttpStreamMode.duplex,
            options.allowLoopbackCleartext, fields[0 .. count], options.receiveBytesPerSecond, extra);
    auto opened = transport.openStream(request, context);
    if (!opened.ok())
        return Result!GrpcCall(GrpcCall.init, opened.error);
    return Result!GrpcCall(GrpcCall(move(opened.value), options.maxMessageBytes));
}

// dfmt on

private size_t methodUrl(scope const ref GrpcCallOptions options, scope char[] output) pure nothrow @nogc
{
    scope const(char)[] authority = options.origin;
    if (authority.length >= 8 && authority[0 .. 8] == "https://")
        authority = authority[8 .. $];
    else if (authority.length >= 7 && authority[0 .. 7] == "http://")
        authority = authority[7 .. $];
    else
        return 0;
    if (authority.length == 0 || output.length < 2)
        return 0;
    foreach (value; authority)
    {
        if (value == '/' || value == '?' || value == '#' || value == '@' || value <= ' ')
            return 0;
    }
    const service = options.service.serviceName;
    const method = options.method;
    const prefix = options.origin.length;
    const suffix = service.length + method.length + 2;
    if (suffix > output.length || prefix > output.length - suffix)
        return 0;
    output[0 .. prefix] = options.origin;
    output[prefix] = '/';
    output[prefix + 1 .. prefix + 1 + service.length] = service;
    const end = prefix + service.length + 1;
    output[end] = '/';
    output[end + 1 .. end + 1 + method.length] = method;
    return end + 1 + method.length;
}

private size_t requestFields(scope const(HttpStreamField)[] metadata, scope HttpStreamField[] headers) nothrow @nogc
{
    const capacity = headers.length;
    if (capacity < 3 || metadata.length > capacity - 3)
        return 0;
    size_t count;
    headers[count++] = HttpStreamField("content-type", "application/grpc");
    headers[count++] = HttpStreamField("te", "trailers");
    foreach (ref field; metadata)
    {
        if (asciiEqual(field.name, "content-type") || asciiEqual(field.name, "te") || grpcReserved(field.name))
            return 0;
        headers[count++] = field;
    }
    return count;
}

private bool grpcReserved(scope const(char)[] name) pure nothrow @nogc
{
    return name.length >= 5 && asciiEqual(name[0 .. 5], "grpc-");
}

package(flint.rpc) size_t formatTimeout(Deadline deadline, scope char[] output) nothrow @nogc
{
    if (deadline == Deadline.none() || output.length < 9)
        return 0;
    const now = Deadline.afterMillis(0).monotonicNanoseconds;
    ulong remaining = deadline.monotonicNanoseconds > now ? cast(ulong)(deadline.monotonicNanoseconds - now) : 0;
    static immutable char[6] units = ['n', 'u', 'm', 'S', 'M', 'H'];
    static immutable uint[5] ratios = [1000, 1000, 1000, 60, 60];
    size_t unit;
    while (remaining > 99_999_999 && unit < ratios.length)
    {
        const scale = ratios[unit++];
        remaining = remaining / scale + (remaining % scale != 0);
    }

    char[8] digits;
    size_t first = digits.length;
    do
    {
        digits[--first] = cast(char)('0' + remaining % 10);
        remaining /= 10;
    }
    while (remaining != 0);
    const count = digits.length - first;
    output[0 .. count] = digits[first .. $];
    output[count] = units[unit];
    return count + 1;
}

/// One outbound gRPC call. Maintain one reader and one writer on the client owner.
/// On a Reactor owner thread, separate fibers can pace upload and download independently.
struct GrpcCall
{
    private HttpStream transport;
    private size_t limit;
    private bool haveHead;
    private bool ended;
    private bool sendEnded;
    private bool broken;
    private bool writing;
    private bool reading;
    private Terminal terminalValue;
    private ubyte[4096] input;
    private size_t offset;
    private size_t available;

    @disable this(this);

    private this(HttpStream transport, size_t limit) nothrow @nogc
    {
        this.transport = move(transport);
        this.limit = limit;
    }

nothrow @nogc:

    /// Read the initial HTTP/2 fields, including application metadata.
    Result!HttpResponse head(ref scope RequestArena arena, ref Context context)
    {
        const fields = transport.head(arena, context);
        if (!fields.ok())
            return fields;
        if (!haveHead)
        {
            const validated = acceptHead(fields.value, arena);
            if (validated.code != Status.ok)
                return Result!HttpResponse(HttpResponse.init, validated);
        }
        return fields;
    }

    /// Send one uncompressed message from the caller's arena.
    Error send(Buffer message, ref scope RequestArena arena, ref Context context)
    {
        if (sendEnded || broken || writing)
            return Error(Status.conflict, "gRPC upload is active or closed");
        writing = true;
        scope (exit)
            writing = false;
        if (message == Buffer.init)
            return sendWire(null, context);
        Error sent;
        const checked = arena.read(message, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            sent = sendWire(bytes, context);
        });
        return checked == Status.ok ? sent : Error(checked, "stale gRPC upload buffer");
    }

    /// Finish the upload while retaining the response side.
    Error finishSend(ref Context context)
    {
        if (sendEnded || broken || writing)
            return Error(Status.conflict, "gRPC upload is active or closed");
        const finished = transport.finishSend(context);
        if (finished.code == Status.ok)
            sendEnded = true;
        return finished;
    }

    /// Receive one message. Status.notFound means EOF with a valid remote terminal status.
    Result!Buffer receive(ref scope RequestArena arena, ref Context context)
    {
        if (reading)
            return Result!Buffer(Buffer.init, Error(Status.conflict, "gRPC reader is already active"));
        if (broken)
            return unavailableResult();
        if (ended)
            return endResult();
        reading = true;
        scope (exit)
            reading = false;
        if (!haveHead)
        {
            const opening = head(arena, context);
            if (!opening.ok())
                return receiveFailed(opening.error);
        }

        return receiveWire(arena, context);
    }

    private Result!Buffer receiveWire(ref scope RequestArena arena, ref Context context)
    {
        GrpcDecoder decoder;
        for (;;)
        {
            if (offset == available)
            {
                const consumed = transport.receive(input[], context);
                if (!consumed.ok())
                    return receiveFailed(consumed.error);
                if (consumed.value == 0)
                    return finishReceive(decoder, arena, context);
                if (terminalValue.codeSeen)
                    return receiveFailed(Error(Status.invalidArgument, "gRPC data followed a terminal response head"));
                offset = 0;
                available = consumed.value;
            }
            const progress = decoder.feed(input[offset .. available], arena, limit);
            offset += progress.consumed;
            if (progress.error.code != Status.ok)
                return receiveFailed(progress.error);
            if (progress.complete)
                return Result!Buffer(progress.payload);
        }
    }

    /// Return the remote status after reading through verified EOF.
    Result!RpcStatus status(ref scope RequestArena arena)
    {
        if (broken || !ended)
            return Result!RpcStatus(RpcStatus.init, Error(Status.unavailable, "gRPC terminal status is unavailable"));
        const copied = arena.copyIn(cast(const(ubyte)[]) terminalValue.message[0 .. terminalValue.length]);
        return Result!RpcStatus(RpcStatus(terminalValue.code, copied.value), copied.error);
    }

    /// Return the terminal HTTP/2 fields after reading through EOF.
    Result!Buffer trailers(ref scope RequestArena arena, ref Context context)
    {
        if (broken || !ended)
            return Result!Buffer(Buffer.init, Error(Status.unavailable, "gRPC terminal status is unavailable"));
        return transport.trailers(arena, context);
    }

    /// Release the call and cancel any outstanding transfer on the owner.
    Error close()
    {
        const closed = transport.close();
        if (closed.code == Status.ok)
            broken = true;
        return closed;
    }

    private Error sendWire(scope const(ubyte)[] bytes, ref Context context)
    {
        const prefix = grpcPrefix(bytes.length, limit);
        if (!prefix.ok())
            return prefix.error;
        const first = transport.send(prefix.value[], context);
        if (first.code != Status.ok)
            return abort(first);
        const sent = transport.send(bytes, context);
        return sent.code == Status.ok ? sent : abort(sent);
    }

    private Error abort(Error failure)
    {
        broken = true;
        transport.close();
        return failure;
    }

    private Result!Buffer receiveFailed(Error failure)
    {
        return Result!Buffer(Buffer.init, abort(failure));
    }

    private Error acceptHead(HttpResponse response, ref scope RequestArena arena)
    {
        if (response.status != 200 || response.protocol != HttpVersion.http2)
            return Error(Status.unavailable, "gRPC peer did not return an HTTP/2 success head");

        uint contentTypes;
        bool supportedMedia;
        uint encodings;
        bool supportedEncoding = true;
        const read = arena.read(response.headers, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            visitFields(bytes, (scope const(char)[] name, scope const(char)[] value) @safe nothrow @nogc {
                if (asciiEqual(name, "content-type"))
                {
                    ++contentTypes;
                    supportedMedia = grpcMedia(value);
                }
                else if (asciiEqual(name, "grpc-encoding"))
                {
                    ++encodings;
                    supportedEncoding = asciiEqual(value, "identity");
                }
                else
                    terminalValue.field(name, value);
            });
        });
        if (read != Status.ok || contentTypes != 1 || !supportedMedia)
            return Error(Status.invalidArgument, "invalid gRPC response content type");
        if (encodings > 1 || !supportedEncoding)
            return Error(Status.unsupported, "gRPC response compression is unsupported");
        if (terminalValue.failed)
            return Error(Status.invalidArgument, "invalid gRPC terminal fields in response head");
        haveHead = true;
        return Error.init;
    }

    // dfmt off
    private Result!Buffer finishReceive(ref scope GrpcDecoder decoder, ref scope RequestArena arena,
            ref Context context)
    {
        const complete = decoder.end();
        if (complete.code != Status.ok)
            return receiveFailed(complete);
        const fields = transport.trailers(arena, context);
        if (!fields.ok())
            return receiveFailed(fields.error);
        const visited = arena.read(fields.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            visitFields(bytes, &terminalValue.field);
        });
        if (visited != Status.ok || terminalValue.failed || !terminalValue.codeSeen)
            return receiveFailed(Error(Status.unavailable, "gRPC peer omitted a valid terminal status"));
        ended = true;
        return endResult();
    }
    // dfmt on
}

private Result!Buffer endResult() pure nothrow @nogc
{
    return Result!Buffer(Buffer.init, Error(Status.notFound, "gRPC response messages ended"));
}

private Result!Buffer unavailableResult() pure nothrow @nogc
{
    return Result!Buffer(Buffer.init, Error(Status.unavailable, "gRPC call is no longer live"));
}

package(flint.rpc) struct Terminal
{
    RpcCode code;
    bool codeSeen;
    bool messageSeen;
    bool failed;
    char[4096] message;
    size_t length;

    void field(scope const(char)[] name, scope const(char)[] value) nothrow @nogc
    {
        if (asciiEqual(name, "grpc-status"))
        {
            const parsed = grpcStatus(value);
            failed |= codeSeen || !parsed.ok();
            codeSeen = true;
            code = parsed.value;
        }
        else if (asciiEqual(name, "grpc-message"))
        {
            // gRPC over HTTP/2: an invalid message must not discard the status; keep the raw form.
            failed |= messageSeen;
            messageSeen = true;
            if (!decodeStatusText(value, message[], length))
                length = rawStatusText(value, message[]);
        }
    }
}

private size_t rawStatusText(scope const(char)[] wire, scope char[] result) pure nothrow @nogc
{
    if (!utf8Valid(cast(const(ubyte)[]) wire))
        return 0;
    size_t count = wire.length < result.length ? wire.length : result.length;
    if (count < wire.length)
    {
        while (count != 0 && (wire[count] & 0xc0) == 0x80)
            --count;
    }
    result[0 .. count] = wire[0 .. count];
    return count;
}

private bool decodeStatusText(scope const(char)[] wire, scope char[] result, out size_t written) pure nothrow @nogc
{
    for (size_t index; index < wire.length; ++index)
    {
        if (written == result.length)
            return false;
        char part = wire[index];
        if (part == '%')
        {
            if (wire.length - index < 3)
                return false;
            const high = hexDigit(wire[index + 1]);
            const low = hexDigit(wire[index + 2]);
            if (high < 0 || low < 0)
                return false;
            part = cast(char)((high << 4) | low);
            index += 2;
        }
        result[written++] = part;
    }
    return utf8Valid(cast(const(ubyte)[]) result[0 .. written]);
}

private int hexDigit(char value) pure nothrow @nogc
{
    if (value >= '0' && value <= '9')
        return value - '0';
    if (value >= 'a' && value <= 'f')
        return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
        return value - 'A' + 10;
    return -1;
}
