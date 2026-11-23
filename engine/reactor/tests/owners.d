module flint.reactor.owner_test;

import flint.reactor.test_support : readinessBackend;
import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.reactor : Backend, Completion, ConnectionId, ListenOptions, Reactor, ReactorOptions;
import flint.reactor.sys.workers : availableCpus;
import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;

private shared uint publishedOwner;
private shared uint publishedSlot;
private shared ulong publishedGeneration;
private shared bool retired;

private void onRetired(Completion result, scope const(ubyte)[] data) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.currentCore == result.connection.ownerCore);
    assert(result.status == Status.cancelled && data.length == 0);
    atomicStore(retired, true);
    reactor.stop();
}

private void requestCloseFromAnotherLoop() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    const connection = ConnectionId(atomicLoad(publishedOwner), atomicLoad(publishedSlot),
            atomicLoad(publishedGeneration));
    assert(connection.ownerCore != reactor.currentCore);
    assert(reactor.read(connection, 1, Context.init, &onRetired).error.code == Status.invalidArgument);
    assert(reactor.close(connection).code == Status.ok);
}

private void arm(ConnectionId connection) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.currentCore == connection.ownerCore);
    assert(reactor.read(connection, 1, Context.init, &onRetired).ok);
    atomicStore(publishedOwner, connection.ownerCore);
    atomicStore(publishedSlot, connection.slot);
    atomicStore(publishedGeneration, connection.generation);
    assert(reactor.post(1 - connection.ownerCore, &requestCloseFromAnotherLoop).code == Status.ok);
}

private void watchdog() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    reactor.stop();
}

private void armWatchdog() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.schedule(Deadline.afterMillis(3000), &watchdog).ok);
}

// Linux epoll and io_uring, macOS kqueue (ADR-024) and Windows IOCP (ADR-026).
version (all)
{
    @("foreign worker sends close through the owner mailbox and the owner retires the read")
    unittest
    {
        if (availableCpus().length < 2)
            return;
        atomicStore(retired, false);
        ReactorOptions options;
        options.backend = readinessBackend;
        options.cores = 2;
        options.fiberPoolSize = 1;
        options.maxConnectionsPerCore = 2;
        auto server = Reactor.create(options);
        assert(server.ok);
        assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &arm).code == Status.ok);
        assert(server.value.post(0, &armWatchdog).code == Status.ok);
        const port = server.value.localPort.value;
        auto client = new Thread({
            auto peer = new TcpSocket;
            scope (exit)
                peer.close();
            peer.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 3000.msecs);
            peer.connect(new InternetAddress("127.0.0.1", port));
            ubyte[1] output;
            assert(peer.receive(output[]) == 0);
        }).start();

        const result = server.value.run();
        assert(result.code == Status.ok, result.message);
        assert(client.join(false) is null);
        assert(atomicLoad(retired));
        foreach (core; 0 .. 2)
        {
            const stats = server.value.workerStats(core);
            assert(stats.ok && stats.value.outstandingOperations == 0 && stats.value.gcAllocated == 0);
        }
    }
}
