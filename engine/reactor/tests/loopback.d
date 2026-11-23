module flint.engine.reactor.loopback_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.reactor : Backend, Completion, ConnectionId, IoId, ListenOptions, Reactor, ReactorOptions;
import std.socket : InternetAddress, SocketShutdown, TcpSocket;

private enum ubyte[] payload = [11, 42, 127, 14, 2, 8, 255, 0, 34, 7, 5, 19, 13, 9, 17, 1];
private shared bool cancelledInFlight;
private shared uint calls;
private shared uint completedConnections;
private ConnectionId firstConnection;
private IoId cancellationTicket;
private uint connectionsAccepted;

private void onWritten(Completion complete) @safe nothrow @nogc
{
    assert(complete.status == Status.ok && complete.bytes > 0);
    auto reactor = Reactor.current();
    assert(reactor.read(complete.connection, 4, Context.init, &onRead).ok);
}

private void onRead(Completion complete, scope const(ubyte)[] data) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(complete.status == Status.ok && complete.bytes == data.length);
    if (complete.bytes == 0)
    {
        assert(reactor.close(complete.connection).code == Status.ok);
        const completed = atomicLoad(completedConnections) + 1;
        atomicStore(completedConnections, completed);
        if (completed == 2)
            reactor.stop();
        return;
    }
    assert(complete.bytes <= 4);
    ubyte[4] source;
    const length = data.length;
    source[0 .. length] = data;
    assert(reactor.write(complete.connection, source[0 .. length], Context.init, &onWritten).ok);
    source[] = 0;
}

private void markFailed() @safe nothrow @nogc
{
    assert(0, "loopback test deadline elapsed");
}

private void afterCancellation(Completion complete, scope const(ubyte)[] data) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(complete.status == Status.cancelled && data.length == 0);
    assert(reactor.cancel(cancellationTicket).code == Status.conflict);
    assert(reactor.read(complete.connection, 4, Context.init, &onRead).ok);
    atomicStore(cancelledInFlight, true);
}

private void cancelInFlight() @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(reactor.cancel(cancellationTicket).code == Status.ok);
}

private void acceptEcho(ConnectionId id) @safe nothrow @nogc
{
    auto reactor = Reactor.current();
    assert(id.ownerCore == reactor.currentCore);
    ++connectionsAccepted;
    if (connectionsAccepted == 1)
        firstConnection = id;
    else
    {
        assert(id.slot == firstConnection.slot && id.generation != firstConnection.generation);
        assert(reactor.close(firstConnection).code == Status.notFound);
        assert(reactor.cancel(cancellationTicket).code == Status.notFound);
    }
    assert(reactor.read(ConnectionId(id.ownerCore, id.slot + 1, id.generation), 4, Context.init, &onRead).error.code
            == Status.notFound);
    assert(reactor.read(id, 0, Context.init, &onRead).error.code == Status.invalidArgument);
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(15));
    assert(source.ok);
    assert(reactor.read(id, 4, source.value.context(), &afterDeadline).ok);
}

private void afterDeadline(Completion result, scope const(ubyte)[] bytes) @safe nothrow @nogc
{
    assert(result.status == Status.timedOut && bytes.length == 0);
    auto reactor = Reactor.current();
    const id = result.connection;
    const operation = reactor.read(id, 4, Context.init, &afterCancellation);
    assert(operation.ok);
    cancellationTicket = operation.value;
    assert(reactor.read(id, 4, Context.init, &onRead).error.code == Status.conflict);
    assert(reactor.schedule(Deadline.afterMillis(25), &cancelInFlight).ok);
}

private void armWatchdog() @safe nothrow @nogc
{
    import core.atomic : atomicOp;

    auto reactor = Reactor.current();
    assert(reactor.schedule(Deadline.afterMillis(3_000), &markFailed).ok);
    atomicOp!"+="(calls, 1);
}

private void echo(Backend backend)
{
    atomicStore(cancelledInFlight, false);
    atomicStore(completedConnections, 0U);
    atomicStore(calls, 0U);

    ReactorOptions options;
    options.backend = backend;
    options.cores = 1;
    options.maxPendingIoPerCore = 4;
    options.maxConnectionsPerCore = 1;
    options.completionsPerTick = 1;
    options.mailboxCapacity = 1;
    auto server = Reactor.create(options);
    assert(server.ok, server.error.message);
    assert(server.value.currentCore == uint.max);
    assert(server.value.localPort.error.code == Status.notFound);
    assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &acceptEcho).code == Status.ok);
    assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &acceptEcho).code == Status.conflict);
    assert(server.value.post(0, &armWatchdog).code == Status.ok);
    assert(server.value.post(0, &armWatchdog).code == Status.resourceExhausted);
    const port = server.value.localPort.value;
    assert(port != 0);

    auto client = new Thread({
        foreach (round; 0 .. 2)
            runClient(port, round);
    }).start();

    const status = server.value.run();
    assert(status.code == Status.ok, status.message);
    assert(client.join(false) is null);
    assert(atomicLoad(completedConnections) == 2);
    assert(atomicLoad(calls) == 1);
    assert(server.value.run().code == Status.conflict);
    const stats = server.value.workerStats(0);
    assert(stats.ok && stats.value.gcAllocated == 0);
}

private void runClient(ushort port, uint round)
{
    atomicStore(cancelledInFlight, false);
    auto peer = new TcpSocket;
    scope (exit)
        peer.close();
    peer.connect(new InternetAddress("127.0.0.1", port));
    foreach (_; 0 .. 3000)
    {
        if (atomicLoad(cancelledInFlight))
            break;
        Thread.sleep(1.msecs);
    }
    assert(atomicLoad(cancelledInFlight));
    if (round == 0)
    {
        auto overflow = new TcpSocket;
        scope (exit)
            overflow.close();
        overflow.connect(new InternetAddress("127.0.0.1", port));
        ubyte[1] rejected;
        assert(overflow.receive(rejected[]) <= 0);
    }

    auto offsets = payload;
    while (offsets.length != 0)
    {
        const count = peer.send(offsets);
        assert(count > 0);
        offsets = offsets[count .. $];
    }
    peer.shutdown(SocketShutdown.SEND);

    ubyte[payload.length] result;
    size_t received;
    while (received < result.length)
    {
        const count = peer.receive(result[received .. $]);
        assert(count > 0);
        received += count;
    }
    assert(result[] == payload);
    ubyte[1] end;
    assert(peer.receive(end[]) == 0);
}

version (linux)
{
    @("epoll loopback drains partial reads, handles EOF, and cancels an armed read")
    unittest
    {
        echo(Backend.epoll);
    }

    version (FlintNativeLiburing)
    {
        @("io_uring loopback retains a submitted read through cancellation completion")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") == "1")
            {
                ReactorOptions options;
                options.cores = 1;
                options.backend = Backend.ioUring;
                const required = Reactor.create(options);
                assert(required.error.code == Status.permissionDenied);
                options.backend = Backend.automatic;
                const selected = Reactor.create(options);
                assert(selected.ok && selected.value.activeBackend == Backend.epoll);
                echo(Backend.automatic);
            }
            else
                echo(Backend.ioUring);
        }

        @("io_uring reports its accepted setup flags: deferred task running from 6.1, cooperative from 5.19")
        unittest
        {
            import core.sys.posix.sys.utsname : uname, utsname;
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") == "1")
                return;
            // CQSIZE; COOP_TASKRUN | TASKRUN_FLAG; R_DISABLED | SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG
            enum uint cqsize = 1u << 3, cooperative = (1u << 8) | (1u << 9),
                    deferred = (1u << 6) | (1u << 12) | (1u << 13) | (1u << 9);
            ReactorOptions options;
            options.cores = 1;
            options.backend = Backend.ioUring;
            const ring = Reactor.create(options);
            assert(ring.ok, ring.error.message);
            const flags = ring.value.completionSetupFlags();
            assert((flags & cqsize) != 0);
            utsname host;
            assert(() @trusted { return uname(&host); }() == 0);
            uint[2] version_; // major, minor
            size_t part;
            foreach (c; host.release)
            {
                if (c == '.' && part == 0)
                    part = 1;
                else if (c >= '0' && c <= '9')
                    version_[part] = version_[part] * 10 + (c - '0');
                else
                    break;
            }
            const mode = flags & (cooperative | deferred);
            if (version_[0] > 6 || (version_[0] == 6 && version_[1] >= 1))
                assert(mode == deferred);
            else if (version_[0] > 5 || (version_[0] == 5 && version_[1] >= 19))
                assert(mode == cooperative);
            else
                assert(mode == 0);

            options.backend = Backend.epoll;
            const readiness = Reactor.create(options);
            assert(readiness.ok && readiness.value.completionSetupFlags() == 0);
        }
    }
}
else version (OSX)
{
    @("kqueue loopback separates readable data and EOF")
    unittest
    {
        echo(Backend.kqueue);
    }
}
else version (Windows)
{
    @("IOCP loopback drains cancelled OVERLAPPED reads")
    unittest
    {
        echo(Backend.iocp);
    }
}
