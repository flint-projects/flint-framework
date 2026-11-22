/// Exercises gRPC framing across arbitrary transport chunk boundaries.
module flint.rpc.grpc_behavior;

import flint.arena : RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.rpc.grpc : GrpcDecoder, RpcCode, grpcDeadline, grpcPrefix, grpcStatus, maximumMessageBytes;

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
    import flint.rpc.grpc_client : Terminal;

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
