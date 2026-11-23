/// Bounded gRPC message framing, deadlines and terminal metadata.
module flint.engine.rpc.grpc;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;

@safe:

/// gRPC wire status values.
enum RpcCode : uint
{
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalidArgument = 3,
    deadlineExceeded = 4,
    notFound = 5,
    alreadyExists = 6,
    permissionDenied = 7,
    resourceExhausted = 8,
    failedPrecondition = 9,
    aborted = 10,
    outOfRange = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    dataLoss = 15,
    unauthenticated = 16
}

/// A gRPC status with optional UTF-8 bytes in the stream arena.
struct RpcStatus
{
    /// Wire code.
    RpcCode code;
    /// Optional public status message.
    Buffer message;
}

/// Resource bounds for a single stream in each direction.
struct StreamLimits
{
    /// Maximum complete message length, exclusive of its five-byte prefix.
    size_t maxMessageBytes = maximumMessageBytes;
    /// Maximum number of queued complete messages.
    uint queuedMessages = 16;
    /// Maximum queued bytes before applying backpressure.
    size_t queuedBytes = 1024 * 1024;
}

package(flint.engine.rpc):

enum maximumMessageBytes = 4 * 1024 * 1024;
enum prefixBytes = 5;

struct GrpcProgress
{
    size_t consumed;
    bool complete;
    Buffer payload;
    Error error;
}

/// A decoder stops at one complete message or the end of the supplied transport chunk.
struct GrpcDecoder
{
    private ubyte[prefixBytes] prefix;
    private uint prefixUsed;
    private Buffer current;
    private size_t payloadUsed;
    private Status failed;

    private GrpcProgress fail(size_t consumed, Error failure) scope nothrow @nogc
    {
        failed = failure.code;
        return GrpcProgress(consumed, false, Buffer.init, failure);
    }

    // dfmt off
    GrpcProgress feed(scope const(ubyte)[] wire, ref scope RequestArena arena,
            size_t limit = maximumMessageBytes) scope nothrow @nogc
    {
        if (failed != Status.ok)
            return GrpcProgress(0, false, Buffer.init, Error(failed, "gRPC decoder failed"));

        size_t consumed;
        if (prefixUsed != prefix.length)
        {
            consumed = minimum(prefix.length - prefixUsed, wire.length);
            prefix[prefixUsed .. prefixUsed + consumed] = wire[0 .. consumed];
            prefixUsed += cast(uint) consumed;
            if (prefixUsed != prefix.length)
                return GrpcProgress(consumed);
            const output = reserveMessage(arena, limit);
            if (!output.ok())
                return fail(consumed, output.error);
            current = output.value;
        }

        const copied = minimum(current.length - payloadUsed, wire.length - consumed);
        if (copied != 0)
        {
            const status = arena.write(current, (scope ubyte[] target) @safe nothrow @nogc {
                target[payloadUsed .. payloadUsed + copied] = wire[consumed .. consumed + copied];
            });
            if (status != Status.ok)
            {
                return fail(consumed, Error(status, "gRPC receive arena changed during a message"));
            }
            payloadUsed += copied;
            consumed += copied;
        }
        if (payloadUsed != current.length)
            return GrpcProgress(consumed);
        const ready = current;
        prefixUsed = 0;
        current = Buffer.init;
        payloadUsed = 0;
        return GrpcProgress(consumed, true, ready);
    }
    // dfmt on

    private Result!Buffer reserveMessage(ref scope RequestArena arena, size_t limit) scope nothrow @nogc
    {
        if (prefix[0] == 1)
            return Result!Buffer(Buffer.init, Error(Status.unsupported, "gRPC message compression is disabled"));
        if (prefix[0] != 0)
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid gRPC compression flag"));
        const length = (cast(uint) prefix[1] << 24) | (cast(uint) prefix[2] << 16) | (
                cast(uint) prefix[3] << 8) | prefix[4];
        return length > limit || length > maximumMessageBytes ? Result!Buffer(Buffer.init,
                Error(Status.resourceExhausted, "gRPC message exceeds the byte limit")) : arena.allocate(length, 1);
    }

    Error end() const scope nothrow @nogc
    {
        if (failed != Status.ok)
            return Error(failed, "gRPC decoder failed");
        return prefixUsed == 0 ? Error.init : Error(Status.invalidArgument, "truncated gRPC message");
    }
}

private size_t minimum(size_t first, size_t second) pure nothrow @nogc
{
    return first < second ? first : second;
}

Result!(ubyte[prefixBytes]) grpcPrefix(size_t length, size_t limit = maximumMessageBytes) pure nothrow @nogc
{
    if (length > limit || length > maximumMessageBytes)
        return Result!(ubyte[prefixBytes])([0, 0, 0, 0, 0], Error(Status.resourceExhausted,
                "gRPC message exceeds the byte limit"));
    ubyte[prefixBytes] output = [
        0, cast(ubyte)(length >> 24), cast(ubyte)(length >> 16), cast(ubyte)(length >> 8),
        cast(ubyte) length
    ];
    return Result!(ubyte[prefixBytes])(output);
}

/// Validate one grpc-timeout header and clamp the deadline to the inherited Context.
Result!Context grpcDeadline(scope const(char)[] field, ref scope const Context parent) nothrow @nogc
{
    if (field.length < 2 || field.length > 9)
        return Result!Context(Context.init, Error(Status.invalidArgument, "invalid gRPC timeout length"));

    ulong quantity;
    foreach (value; field[0 .. $ - 1])
    {
        if (value < '0' || value > '9')
            return Result!Context(Context.init, Error(Status.invalidArgument, "invalid gRPC timeout digit"));
        quantity = quantity * 10 + value - '0';
    }

    ulong multiplier;
    switch (field[$ - 1])
    {
    case 'H':
        multiplier = 3_600_000_000_000;
        break;
    case 'M':
        multiplier = 60_000_000_000;
        break;
    case 'S':
        multiplier = 1_000_000_000;
        break;
    case 'm':
        multiplier = 1_000_000;
        break;
    case 'u':
        multiplier = 1_000;
        break;
    case 'n':
        multiplier = 1;
        break;
    default:
        return Result!Context(Context.init, Error(Status.invalidArgument, "invalid gRPC timeout unit"));
    }

    const now = Deadline.afterMillis(0).monotonicNanoseconds;
    const available = cast(ulong)(long.max - 1 - now);
    const expires = quantity > available / multiplier ? long.max - 1 : now + cast(long)(quantity * multiplier);
    return Result!Context(parent.withDeadline(Deadline(expires)));
}

/// Terminal status is required. An absent value has the transport meaning unavailable.
Result!RpcCode grpcStatus(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length == 0)
        return Result!RpcCode(RpcCode.unavailable, Error(Status.unavailable, "gRPC terminal status absent"));
    if (value.length > 2)
        return Result!RpcCode(RpcCode.unknown, Error(Status.invalidArgument, "invalid gRPC terminal status"));
    uint code;
    foreach (digit; value)
    {
        if (digit < '0' || digit > '9')
            return Result!RpcCode(RpcCode.unknown, Error(Status.invalidArgument, "invalid gRPC terminal status"));
        code = code * 10 + digit - '0';
    }
    return Result!RpcCode(code <= RpcCode.unauthenticated ? cast(RpcCode) code : RpcCode.unknown);
}
