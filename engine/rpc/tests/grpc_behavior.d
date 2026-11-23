/// Exercises gRPC framing across arbitrary transport chunk boundaries.
module flint.engine.rpc.grpc_behavior;

import flint.arena : RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.engine.rpc.grpc : GrpcDecoder, RpcCode, grpcDeadline, grpcPrefix, grpcStatus, maximumMessageBytes;

@safe:

unittest
{
    // The first byte of the next message must remain unconsumed.
    immutable ubyte[9] first = [0, 0, 0, 0, 3, 42, 43, 44, 0];
    foreach (split; 0 .. 8)
    {
        ubyte[16] storage;
        auto arena = RequestArena(storage[]);
        GrpcDecoder decoder;
        const initial = decoder.feed(first[0 .. split], arena);
        assert(initial.error.code == Status.ok && !initial.complete && initial.consumed == split);
        const next = decoder.feed(first[split .. $], arena);
        assert(next.complete && next.consumed == 8 - split);
        assert(arena.read(next.payload, (scope const(ubyte)[] decoded) @safe nothrow @nogc {
                assert(decoded == first[5 .. 8]);
            }) == Status.ok);
        assert(decoder.end().code == Status.ok);
    }
}

unittest
{
    ubyte[16] storage;
    auto arena = RequestArena(storage[]);
    immutable ubyte[5] emptyMessage = [0, 0, 0, 0, 0];
    immutable ubyte[5] compressed = [1, 0, 0, 0, 0];
    immutable ubyte[5] invalid = [3, 0, 0, 0, 0];
    immutable ubyte[5] oversized = [0, 0, 64, 0, 1];
    immutable ubyte[7] bodyPrefix = [0, 0, 0, 0, 3, 1, 2];
    GrpcDecoder decoder;
    const empty = decoder.feed(emptyMessage[], arena);
    assert(empty.complete && empty.payload.length == 0 && empty.consumed == 5);
    assert(decoder.feed(compressed[], arena).error.code == Status.unsupported);
    assert(decoder.feed(emptyMessage[], arena).consumed == 0);
    decoder = GrpcDecoder.init;
    assert(decoder.feed(invalid[], arena).error.code == Status.invalidArgument);
    decoder = GrpcDecoder.init;
    assert(decoder.feed(oversized[], arena).error.code == Status.resourceExhausted);
    assert(arena.stats().used == 0);
    decoder = GrpcDecoder.init;
    assert(!decoder.feed(bodyPrefix[], arena).complete);
    assert(decoder.end().code == Status.invalidArgument);
    assert(arena.reset() == Status.ok);
    assert(decoder.feed([3], arena).error.code == Status.invalidArgument);
    decoder = GrpcDecoder.init;
    assert(!decoder.feed(emptyMessage[0 .. 4], arena).complete);
    assert(decoder.end().code == Status.invalidArgument);
    assert(grpcPrefix(maximumMessageBytes).value == [0, 0, 64, 0, 0]);
    assert(grpcPrefix(maximumMessageBytes + 1).error.code == Status.resourceExhausted);
}

unittest
{
    auto parent = Context.init.withDeadline(Deadline.afterMillis(30_000));
    const later = grpcDeadline("99999999H", parent);
    assert(later.ok() && later.value.deadline() == parent.deadline());
    const timedOut = grpcDeadline("0n", parent);
    assert(timedOut.ok() && timedOut.value.check().code == Status.timedOut);
    assert(grpcDeadline("1x", parent).error.code == Status.invalidArgument);
    assert(grpcDeadline("999999999H", parent).error.code == Status.invalidArgument);
    assert(grpcDeadline("1 0S", parent).error.code == Status.invalidArgument);
    assert(grpcStatus("").value == RpcCode.unavailable);
    assert(grpcStatus("4").value == RpcCode.deadlineExceeded);
    assert(grpcStatus("99").value == RpcCode.unknown);
    assert(grpcStatus("1x").error.code == Status.invalidArgument);
}

@("client terminal status keeps the code when grpc-message is not valid percent-encoded UTF-8")
unittest
{
    import flint.engine.rpc.grpc_client : Terminal;

    // PROTOCOL-HTTP2: an invalid grpc-message must not discard the status. At worst it stays raw.
    Terminal percent;
    percent.field("grpc-status", "5");
    percent.field("grpc-message", "100% done");
    assert(!percent.failed && percent.codeSeen && percent.code == RpcCode.notFound);
    assert(percent.message[0 .. percent.length] == "100% done");

    Terminal binary;
    binary.field("grpc-message", "bad %FF byte");
    binary.field("grpc-status", "13");
    assert(!binary.failed && binary.code == RpcCode.internal);
    assert(binary.message[0 .. binary.length] == "bad %FF byte");

    char[5000] wide;
    wide[] = 'x';
    Terminal oversized;
    oversized.field("grpc-status", "9");
    oversized.field("grpc-message", wide[]);
    assert(!oversized.failed && oversized.code == RpcCode.failedPrecondition);
    assert(oversized.length == oversized.message.length && oversized.message[0] == 'x');

    Terminal encoded;
    encoded.field("grpc-status", "10");
    encoded.field("grpc-message", "10%25 %F0%9F%9A%80");
    assert(!encoded.failed && encoded.message[0 .. encoded.length] == "10% 🚀");

    Terminal repeated;
    repeated.field("grpc-status", "0");
    repeated.field("grpc-status", "0");
    assert(repeated.failed);
}

@("grpc_wire_errors: a configured limit is enforced from the prefix before any payload allocation")
unittest
{
    ubyte[64] storage;
    auto arena = RequestArena(storage[]);
    immutable ubyte[9] exact = [0, 0, 0, 0, 4, 1, 2, 3, 4];
    immutable ubyte[5] overLimit = [0, 0, 0, 0, 5];
    immutable ubyte[5] maximum = [0, 0, 0x40, 0, 0];
    immutable ubyte[5] largest = [0, 0xff, 0xff, 0xff, 0xff];
    GrpcDecoder decoder;
    const admitted = decoder.feed(exact[], arena, 4);
    assert(admitted.complete && admitted.payload.length == 4 && admitted.consumed == exact.length);
    const used = arena.stats().used;
    decoder = GrpcDecoder.init;
    const rejected = decoder.feed(overLimit[], arena, 4);
    assert(rejected.error.code == Status.resourceExhausted && rejected.consumed == overLimit.length);
    assert(arena.stats().used == used);
    // Exactly 4 MiB passes the limit check and then fails only because this arena is small.
    decoder = GrpcDecoder.init;
    const tooBig = decoder.feed(maximum[], arena);
    assert(tooBig.error.code != Status.ok && tooBig.error.code != Status.resourceExhausted);
    assert(arena.stats().used == used);
    decoder = GrpcDecoder.init;
    assert(decoder.feed(largest[], arena, size_t.max).error.code == Status.resourceExhausted);
    assert(arena.stats().used == used);
    // A failed decoder stays failed and consumes nothing further.
    const sticky = decoder.feed(exact[], arena);
    assert(sticky.consumed == 0 && sticky.error.code == Status.resourceExhausted);
    assert(decoder.end().code == Status.resourceExhausted);
    assert(grpcPrefix(5, 4).error.code == Status.resourceExhausted);
    assert(grpcPrefix(0).value == [0, 0, 0, 0, 0]);
}

@("stream_teardown: an arena reset in the middle of a message is detected instead of writing stale storage")
unittest
{
    ubyte[32] storage;
    auto arena = RequestArena(storage[]);
    immutable ubyte[10] message = [0, 0, 0, 0, 5, 1, 2, 3, 4, 5];
    GrpcDecoder decoder;
    const first = decoder.feed(message[0 .. 7], arena);
    assert(first.error.code == Status.ok && !first.complete && first.consumed == 7);
    assert(arena.reset() == Status.ok);
    const after = decoder.feed(message[7 .. $], arena);
    assert(after.error.code != Status.ok && !after.complete && after.consumed == 0);
    assert(decoder.end().code == after.error.code);
    assert(decoder.feed(message[], arena).consumed == 0);
}

@("grpc deadlines take the earlier of grpc-timeout and the inherited context, saturating on overflow")
unittest
{
    import flint.engine.rpc.grpc_client : formatTimeout;

    auto parent = Context.init.withDeadline(Deadline.afterMillis(60_000));
    const shorter = grpcDeadline("100m", parent);
    assert(shorter.ok() && shorter.value.deadline().monotonicNanoseconds < parent.deadline().monotonicNanoseconds);
    assert(shorter.value.deadline().monotonicNanoseconds <= Deadline.afterMillis(100).monotonicNanoseconds);
    const unbounded = Context.init;
    const saturated = grpcDeadline("99999999H", unbounded);
    assert(saturated.ok() && saturated.value.deadline().monotonicNanoseconds == long.max - 1);
    foreach (unit; ["1H", "1M", "1S", "1m", "1u", "1n", "12345678S"])
        assert(grpcDeadline(unit, parent).ok(), unit);
    foreach (bad; ["", "S", "1", "-1S", "1s", "123456789S", "1.5S", "1\0S"])
        assert(grpcDeadline(bad, parent).error.code == Status.invalidArgument, bad);

    // Outbound grpc-timeout uses at most eight digits, rounds up and parses back to no earlier deadline.
    char[9] wire;
    assert(formatTimeout(Deadline.none(), wire[]) == 0);
    foreach (millis; [0L, 1L, 250L, 120_000L, 86_400_000L * 365 * 100])
    {
        const deadline = Deadline.afterMillis(millis);
        const length = formatTimeout(deadline, wire[]);
        assert(length >= 2 && length <= 9);
        const parsed = grpcDeadline(wire[0 .. length], unbounded);
        assert(parsed.ok());
        assert(parsed.value.deadline().monotonicNanoseconds >= deadline.monotonicNanoseconds);
    }
}

@("grpc terminal status: every wire code maps, and a missing or malformed status is never success")
unittest
{
    import flint.engine.rpc.grpc_client : Terminal;

    foreach (uint code; 0 .. 17)
    {
        char[2] text;
        const digits = code < 10 ? 1 : 2;
        if (code < 10)
            text[0] = cast(char)('0' + code);
        else
        {
            text[0] = '1';
            text[1] = cast(char)('0' + code - 10);
        }
        const parsed = grpcStatus(text[0 .. digits]);
        assert(parsed.ok() && parsed.value == cast(RpcCode) code);
    }
    assert(grpcStatus("17").value == RpcCode.unknown && grpcStatus("17").ok());
    assert(grpcStatus("100").error.code == Status.invalidArgument);
    assert(grpcStatus(" 0").error.code == Status.invalidArgument);
    assert(grpcStatus("").error.code == Status.unavailable);

    Terminal messageOnly;
    messageOnly.field("grpc-message", "no status");
    assert(!messageOnly.codeSeen && !messageOnly.failed);
    Terminal malformed;
    malformed.field("grpc-status", "ok");
    assert(malformed.failed);
    Terminal unrelated;
    unrelated.field("x-trailer", "0");
    assert(!unrelated.codeSeen && !unrelated.failed);
}
