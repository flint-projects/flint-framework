module flint.reactor.cancel_race_test;

import flint.reactor.test_support : readinessBackend;
import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.reactor : Backend, Completion, ConnectionId, IoId, ListenOptions, Reactor, ReactorOptions;
import std.socket : InternetAddress, TcpSocket;

// ADR-017 decision 7: a read the kernel completed with data before its cancellation took effect is a
// successful completion carrying that data. A cancelled read never reports bytes it does not deliver.

private enum ubyte[] payload = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3];
private shared bool sendNow;
private shared bool sent;
private shared bool finished;
// Results published by the owner loop; the remaining state is loop-thread local.
private shared bool lostBytes;
private shared bool intact;
private shared uint cancelledCompletions;
private ConnectionId connection;
private IoId firstRead;
private ubyte[64] collected;
private size_t collectedBytes;

private void stallThenCancel() @safe nothrow @nogc
{
    // The read is in flight. Have the peer send, give the kernel time to finish the receive, then cancel
    // before this loop has observed that completion.
    atomicStore(sendNow, true);
    foreach (_; 0 .. 2000)
    {
        if (atomicLoad(sent))
            break;
        Thread.sleep(1.msecs);
    }
    assert(atomicLoad(sent), "peer did not send");
    Thread.sleep(30.msecs);
    auto reactor = Reactor.current();
    assert(reactor.cancel(firstRead).code == Status.ok);
}

private void onRead(Completion complete, scope const(ubyte)[] data) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (complete.status != Status.ok)
    {
        assert(complete.status == Status.cancelled);
        atomicStore(cancelledCompletions, atomicLoad(cancelledCompletions) + 1);
        // Reporting a byte count without the bytes loses data the kernel already consumed.
        if (complete.bytes != data.length)
            atomicStore(lostBytes, true);
    }
    else
    {
        assert(complete.bytes == data.length);
        if (data.length == 0)
        {
            atomicStore(intact, collected[0 .. collectedBytes] == payload);
            atomicStore(finished, true);
            assert(reactor.close(complete.connection).code == Status.ok);
            reactor.stop();
            return;
        }
        assert(collectedBytes + data.length <= collected.length);
        collected[collectedBytes .. collectedBytes + data.length] = data;
        collectedBytes += data.length;
    }
    assert(reactor.read(complete.connection, collected.length, Context.init, &onRead).ok);
}

private void abandon() @safe nothrow @nogc
{
    assert(0, "cancel race test deadline elapsed");
}

private void accepted(ConnectionId id) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    connection = id;
    collected[] = 0;
    collectedBytes = 0;
    auto read = reactor.read(id, collected.length, Context.init, &onRead);
    assert(read.ok);
    firstRead = read.value;
    assert(reactor.schedule(Deadline.afterMillis(20), &stallThenCancel).ok);
    assert(reactor.schedule(Deadline.afterMillis(5000), &abandon).ok);
}

private void race(Backend backend)
{
    atomicStore(sendNow, false);
    atomicStore(sent, false);
    atomicStore(finished, false);
    atomicStore(lostBytes, false);
    atomicStore(intact, false);
    atomicStore(cancelledCompletions, 0);

    ReactorOptions options;
    options.backend = backend;
    options.cores = 1;
    options.ioBufferBytes = 4096;
    options.maxPendingIoPerCore = 4;
    options.fiberPoolSize = 1;
    auto server = Reactor.create(options);
    assert(server.ok, server.error.message);
    assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &accepted).code == Status.ok);
    const port = server.value.localPort.value;

    auto peer = new Thread({
        auto socket = new TcpSocket;
        socket.connect(new InternetAddress("127.0.0.1", port));
        foreach (_; 0 .. 3000)
        {
            if (atomicLoad(sendNow))
                break;
            Thread.sleep(1.msecs);
        }
        assert(atomicLoad(sendNow), "reactor never requested the send");
        assert(socket.send(payload) == payload.length);
        atomicStore(sent, true);
        // Closing delivers EOF after the payload, which ends the server's read loop.
        socket.close();
    }).start();
    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    assert(peer.join(false) is null);
    assert(atomicLoad(finished));
    assert(!atomicLoad(lostBytes), "a cancelled read reported bytes it did not deliver");
    assert(atomicLoad(intact), "bytes completed before cancellation were lost");
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.outstandingOperations == 0);
}

// Linux epoll and io_uring, and macOS kqueue (ADR-024).
version (Posix)
{
    @("epoll cancellation of a read with pending data keeps every byte")
    unittest
    {
        race(readinessBackend);
    }

    version (FlintNativeLiburing)
    {
        @("io_uring read completed with data before cancellation is delivered as success")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") != "1")
            {
                race(Backend.ioUring);
                // The race is decided before cancellation reaches the kernel, so the data wins.
                assert(atomicLoad(cancelledCompletions) == 0, "the completed read was reported as cancelled");
            }
        }
    }
}
else version (Windows)
{
    @("IOCP read completed with data before cancellation is delivered as success")
    unittest
    {
        race(Backend.iocp);
        // CancelIoEx no longer finds a completed request, so its packet carries the data.
        assert(atomicLoad(cancelledCompletions) == 0, "the completed read was reported as cancelled");
    }
}
