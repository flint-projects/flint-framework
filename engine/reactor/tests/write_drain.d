module flint.engine.reactor.write_drain_test;

import flint.engine.reactor.test_support : readinessBackend;
import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.engine.reactor : Backend, Completion, ConnectionId, ListenOptions, Reactor, ReactorOptions, TaskContext;
import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;

private enum blockBytes = 524_288;
private ubyte[blockBytes] block;
private ConnectionId connection;
private shared bool drained;

private void closeAfterBackpressure() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.close(connection).code == Status.ok);
}

private final class Backpressure
{
    bool received;

    @safe nothrow @nogc void accepted(ConnectionId id)
    {
        auto reactor = Reactor.current();
        connection = id;
        assert(reactor.postWith(id.ownerCore + 1, &beginRead).code == Status.invalidArgument);
        assert(reactor.postWith(id.ownerCore, &beginRead, TaskContext(42)).code == Status.ok);
    }

    @safe nothrow @nogc void beginRead()
    {
        auto reactor = Reactor.current();
        const task = reactor.currentTask();
        assert(task.ok && task.value.requestId == 42);
        assert(reactor.readWith(connection, 1, Context.init, &startWrites).ok);
    }

    @safe nothrow @nogc void startWrites(Completion completion, scope const(ubyte)[] input)
    {
        auto reactor = Reactor.current();
        assert(completion.connection == connection && completion.status == Status.ok);
        assert(input.length == 1 && input[0] == 42);
        received = true;
        assert(reactor.schedule(Deadline.afterMillis(100), &closeAfterBackpressure).ok);
        assert(reactor.writeWith(connection, block[], Context.init, &writeUntilBlocked).ok);
    }

    @safe nothrow @nogc void writeUntilBlocked(Completion completion)
    {
        auto reactor = Reactor.current();
        assert(received);
        if (completion.status == Status.cancelled)
        {
            assert(completion.bytes < blockBytes);
            atomicStore(drained, true);
            reactor.stop();
            return;
        }
        assert(completion.status == Status.ok && completion.bytes == blockBytes);
        assert(reactor.writeWith(connection, block[], Context.init, &writeUntilBlocked).ok);
    }
}

private void testDrain(Backend backend)
{
    atomicStore(drained, false);
    ReactorOptions options;
    options.backend = backend;
    options.cores = 1;
    options.ioBufferBytes = blockBytes;
    options.maxPendingIoPerCore = 2;
    options.fiberPoolSize = 1;
    auto server = Reactor.create(options);
    assert(server.ok, server.error.message);
    auto callbacks = new Backpressure;
    assert(server.value.listenWith(ListenOptions("127.0.0.1", 0, 8), &callbacks.accepted).code == Status.ok);
    const port = server.value.localPort.value;

    auto peer = new Thread({
        auto socket = new TcpSocket;
        scope (exit)
            socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 4096);
        socket.connect(new InternetAddress("127.0.0.1", port));
        const ubyte[1] request = [42];
        assert(socket.send(request[]) == 1);
        foreach (_; 0 .. 3000)
        {
            if (atomicLoad(drained))
                return;
            Thread.sleep(1.msecs);
        }
        assert(0, "close did not retire the blocked write");
    }).start();
    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    assert(peer.join(false) is null);
    assert(atomicLoad(drained) && callbacks.received);
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.outstandingOperations == 0);
}

// Linux epoll and io_uring, and macOS kqueue (ADR-024).
version (Posix)
{
    @("epoll closes a socket only after its backpressured write callback retires")
    unittest
    {
        testDrain(readinessBackend);
    }

    version (FlintNativeLiburing)
    {
        @("io_uring close drains the original backpressured write CQE")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") != "1")
                testDrain(Backend.ioUring);
        }
    }
}
else version (Windows)
{
    @("IOCP closes a socket only after its backpressured write completion retires")
    unittest
    {
        testDrain(Backend.iocp);
    }
}
