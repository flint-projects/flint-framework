module flint.reactor.write_drain_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.reactor : Backend, Completion, ConnectionId, ListenOptions, Reactor, ReactorOptions;
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

private void writeUntilBlocked(Completion completion) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    if (completion.status == Status.cancelled)
    {
        assert(completion.bytes < blockBytes);
        atomicStore(drained, true);
        reactor.stop();
        return;
    }
    assert(completion.status == Status.ok && completion.bytes == blockBytes);
    assert(reactor.write(connection, block[], Context.init, &writeUntilBlocked).ok);
}

private void startWrites(ConnectionId accepted) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    connection = accepted;
    assert(reactor.schedule(Deadline.afterMillis(100), &closeAfterBackpressure).ok);
    assert(reactor.write(connection, block[], Context.init, &writeUntilBlocked).ok);
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
    assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &startWrites).code == Status.ok);
    const port = server.value.localPort.value;

    auto peer = new Thread({
        auto socket = new TcpSocket;
        scope (exit)
            socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 4096);
        socket.connect(new InternetAddress("127.0.0.1", port));
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
    assert(atomicLoad(drained));
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.outstandingOperations == 0);
}

version (linux)
{
    @("epoll closes a socket only after its backpressured write callback retires")
    unittest
    {
        testDrain(Backend.epoll);
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
