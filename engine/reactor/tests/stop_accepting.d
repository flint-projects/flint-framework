module flint.reactor.stop_accepting_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Context;
import flint.reactor : Backend, Completion, ConnectionId, ListenOptions, Reactor, ReactorOptions;
import flint.reactor.test_support : readinessBackend;
import std.socket : InternetAddress, SocketOSException, TcpSocket;

private shared uint accepted;
private shared uint echoed;

private void admit(ConnectionId id) @safe nothrow @nogc
{
    atomicOp!"+="(accepted, 1U);
    assert(Reactor.current().read(id, 1, Context.init, &received).ok);
}

private void received(Completion complete, scope const(ubyte)[] data) @safe nothrow @nogc
{
    assert(complete.status == Status.ok && data.length == 1);
    ubyte[1] copy = data[0 .. 1];
    assert(Reactor.current().write(complete.connection, copy[], Context.init, &sent).ok);
}

private void sent(Completion complete) @safe nothrow @nogc
{
    assert(complete.status == Status.ok && complete.bytes == 1);
    atomicOp!"+="(echoed, 1U);
    Reactor.current().stop();
}

private void waitFor(scope bool delegate() @safe condition)
{
    foreach (_; 0 .. 3_000)
    {
        if (condition())
            return;
        Thread.sleep(1.msecs);
    }
    assert(0, "condition did not hold within three seconds");
}

private bool refused(ushort port)
{
    auto probe = new TcpSocket;
    scope (exit)
        probe.close();
    try
        probe.connect(new InternetAddress("127.0.0.1", port));
    catch (SocketOSException)
        return true;
    return false;
}

/// An admitted connection keeps its reads and writes after the listener closes, and a new one is refused.
private void stopAccepting(Backend backend, uint cores)
{
    atomicStore(accepted, 0U);
    atomicStore(echoed, 0U);
    ReactorOptions options;
    options.backend = backend;
    options.cores = cores;
    options.maxConnectionsPerCore = 4;
    options.maxPendingIoPerCore = 8;
    auto created = Reactor.create(options);
    assert(created.ok, created.error.message);
    auto reactor = &created.value;
    assert(!reactor.acceptStopped());
    assert(reactor.listen(ListenOptions("127.0.0.1", 0, 8), &admit).code == Status.ok);
    const port = reactor.localPort.value;

    Exception failure;
    auto client = new Thread({
        try
        {
            auto peer = new TcpSocket;
            scope (exit)
                peer.close();
            peer.connect(new InternetAddress("127.0.0.1", port));
            waitFor(() => atomicLoad(accepted) == 1);
            reactor.stopAccepting();
            waitFor(() => reactor.acceptStopped());
            version (Windows)
            {
            }
            else
                assert(refused(port), "a connection was admitted after the listener closed");
            ubyte[1] byteValue = [42];
            assert(peer.send(byteValue[]) == 1);
            ubyte[1] answer;
            assert(peer.receive(answer[]) == 1 && answer[0] == 42);
        }
        catch (Exception error)
            failure = error;
    }).start();

    const status = reactor.run();
    client.join();
    assert(failure is null, failure is null ? "" : failure.msg);
    assert(status.code == Status.ok, status.message);
    assert(atomicLoad(echoed) == 1 && atomicLoad(accepted) == 1);
}

@("stopAccepting closes a readiness listener on every owner while an admitted connection keeps serving")
unittest
{
    stopAccepting(readinessBackend, 2);
}

version (linux)
{
    version (FlintNativeLiburing)
    {
        @("stopAccepting waits for each cancelled io_uring accept before it closes the listener")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") != "1")
                stopAccepting(Backend.ioUring, 2);
        }
    }
}
else version (Windows)
{
    @("stopAccepting retires the IOCP accept while an admitted connection keeps serving")
    unittest
    {
        // Windows keeps the listening socket until release, so this checks admission only.
        stopAccepting(Backend.iocp, 1);
    }
}
