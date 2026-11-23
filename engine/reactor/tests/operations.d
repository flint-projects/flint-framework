module flint.engine.reactor.operations_test;

import flint.arena : Status;
import flint.engine.reactor.internal.operations : OperationId, OperationTable;
import flint.engine.reactor.types : ConnectionId;

@safe:

@("cancellation before submit delivers once without entering the backend")
unittest
{
    auto table = OperationTable(1);
    auto connection = ConnectionId(1, 2, 3);
    auto operation = table.reserve(connection).value;
    assert(table.requestCancellation(operation, Status.cancelled) == Status.ok);
    assert(table.start(operation) == Status.cancelled);
    assert(table.reserve(connection).error.code == Status.resourceExhausted);
    const completion = table.finish(operation, Status.ok, 0);
    assert(completion.ok && completion.value.status == Status.cancelled);
    assert(completion.value.connection == connection);
    assert(table.finish(operation, Status.ok, 0).error.code == Status.conflict);
    assert(table.retire(operation) == Status.ok);
}

@("cancelled in-flight read retains its slot until the final completion is delivered")
unittest
{
    auto table = OperationTable(1);
    auto connection = ConnectionId(0, 1, 2);
    auto operation = table.reserve(connection).value;
    assert(table.start(operation) == Status.ok);
    assert(table.requestCancellation(operation, Status.timedOut) == Status.ok);
    assert(table.requestCancellation(operation, Status.cancelled) == Status.ok);
    assert(table.retire(operation) == Status.conflict);
    assert(table.reserve(connection).error.code == Status.resourceExhausted);
    const completion = table.finish(operation, Status.ok, 17);
    assert(completion.ok && completion.value.status == Status.timedOut);
    assert(completion.value.bytes == 17);
    assert(table.reserve(connection).error.code == Status.resourceExhausted);
    assert(table.retire(operation) == Status.ok);

    auto next = table.reserve(ConnectionId(0, 1, 3)).value;
    assert(next.slot == operation.slot && next.generation != operation.generation);
    assert(OperationId.fromToken(next.token) == next);
    assert(table.finish(operation, Status.ok, 0).error.code == Status.notFound);
    assert(table.requestCancellation(operation, Status.cancelled) == Status.notFound);
    assert(table.start(next) == Status.ok);
    const latest = table.finish(next, Status.ok, 4);
    assert(latest.ok && latest.value.connection.generation == 3);
    assert(latest.value.status == Status.ok && latest.value.bytes == 4);
}

@("final completion wins over subsequent cancellation")
unittest
{
    auto table = OperationTable(1);
    auto operation = table.reserve(ConnectionId(0, 0, 1)).value;
    assert(table.finish(operation, Status.ok, 0).error.code == Status.conflict);
    assert(table.start(operation) == Status.ok);
    assert(table.finish(operation, Status.ok, 0).ok);
    assert(table.requestCancellation(operation, Status.cancelled) == Status.conflict);
    assert(table.retire(operation) == Status.ok);
    assert(table.retire(operation) == Status.notFound);
    assert(table.reserve(ConnectionId.init).error.code == Status.invalidArgument);
}

@("a read completed with data before cancellation took effect reports success; other outcomes stay cancelled")
unittest
{
    auto table = OperationTable(1);
    auto connection = ConnectionId(0, 0, 1);

    Status finalStatus(Status kernel, size_t bytes, bool read)
    {
        auto operation = table.reserve(connection).value;
        assert(table.start(operation) == Status.ok);
        assert(table.requestCancellation(operation, Status.timedOut) == Status.ok);
        const completion = table.finish(operation, kernel, bytes, read);
        assert(completion.ok && completion.value.bytes == bytes);
        assert(table.retire(operation) == Status.ok);
        return completion.value.status;
    }

    assert(finalStatus(Status.ok, 17, true) == Status.ok);
    assert(finalStatus(Status.ok, 0, true) == Status.timedOut, "EOF raced with cancellation stays cancelled");
    assert(finalStatus(Status.cancelled, 0, true) == Status.timedOut);
    assert(finalStatus(Status.ioError, 0, true) == Status.timedOut);
    // A write's partial progress under cancellation is still reported as cancelled with its byte count.
    assert(finalStatus(Status.ok, 17, false) == Status.timedOut);
}
