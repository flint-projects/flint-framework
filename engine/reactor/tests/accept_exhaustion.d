module flint.reactor.accept_exhaustion_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : msecs;
import flint.arena : Status;
import flint.conc : Deadline;
import flint.reactor : Backend, ConnectionId, ListenOptions, Reactor, ReactorOptions;
import std.socket : InternetAddress, TcpSocket;

version (linux)
{
    private shared uint admitted;

    private void admitOnce(ConnectionId id) @safe nothrow @nogc
    {
        atomicOp!"+="(admitted, 1);
        auto reactor = Reactor.current();
        reactor.close(id);
        reactor.stop();
    }

    private void giveUp() @safe nothrow @nogc
    {
        Reactor.current().stop();
    }

    private void armWatchdog() @safe nothrow @nogc
    {
        assert(Reactor.current().schedule(Deadline.afterMillis(3_000), &giveUp).ok);
    }

    /// Occupy every descriptor below a reduced soft limit and return the fillers.
    private int[] fillDescriptors(uint limit) @trusted
    {
        import core.stdc.errno : EMFILE, errno;
        import core.sys.posix.sys.resource : RLIMIT_NOFILE, getrlimit, rlimit, setrlimit;
        import core.sys.posix.unistd : dup;

        rlimit reduced;
        assert(getrlimit(RLIMIT_NOFILE, &reduced) == 0);
        reduced.rlim_cur = limit;
        assert(setrlimit(RLIMIT_NOFILE, &reduced) == 0);
        int[] fillers;
        for (;;)
        {
            const descriptor = dup(0);
            if (descriptor < 0)
            {
                assert(errno == EMFILE);
                return fillers;
            }
            fillers ~= descriptor;
        }
    }

    private void closeDescriptor(int descriptor) @trusted
    {
        import core.sys.posix.unistd : close;

        close(descriptor);
    }

    private void exhaust(Backend backend) @trusted
    {
        import core.sys.posix.sys.resource : RLIMIT_NOFILE, getrlimit, rlimit, setrlimit;

        atomicStore(admitted, 0U);
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        auto server = Reactor.create(options);
        assert(server.ok, server.error.message);
        assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &admitOnce).code == Status.ok);
        assert(server.value.post(0, &armWatchdog).code == Status.ok);
        const port = server.value.localPort.value;

        rlimit original;
        assert(getrlimit(RLIMIT_NOFILE, &original) == 0);
        auto fillers = fillDescriptors(512);
        scope (exit)
        {
            foreach (descriptor; fillers)
                closeDescriptor(descriptor);
            assert(setrlimit(RLIMIT_NOFILE, &original) == 0);
        }
        assert(fillers.length >= 2);
        // Leave exactly one descriptor for the client, so the owner loop's accept reports EMFILE.
        closeDescriptor(fillers[$ - 1]);
        const spare = fillers[$ - 2];
        fillers = fillers[0 .. $ - 2];

        auto client = new Thread({
            auto peer = new TcpSocket;
            scope (exit)
                peer.close();
            peer.connect(new InternetAddress("127.0.0.1", port));
            Thread.sleep(50.msecs);
            // Free one descriptor; the pending connection must then be admitted.
            closeDescriptor(spare);
            foreach (_; 0 .. 3_000)
            {
                if (atomicLoad(admitted) != 0)
                    break;
                Thread.sleep(1.msecs);
            }
        }).start();

        const status = server.value.run();
        assert(client.join(false) is null);
        assert(status.code == Status.ok, "descriptor exhaustion during accept stopped the reactor");
        assert(atomicLoad(admitted) == 1, "the pending connection was not admitted after descriptors were freed");
    }

    @("epoll keeps serving and admits a backlogged connection after descriptor exhaustion")
    unittest
    {
        exhaust(Backend.epoll);
    }

    version (FlintNativeLiburing)
    {
        @("io_uring keeps serving and admits a backlogged connection after descriptor exhaustion")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") != "1")
                exhaust(Backend.ioUring);
        }
    }

    private shared bool acceptedWithoutDelay;
    private shared bool acceptChecked;

    private void inspectAccepted(ConnectionId id) @safe nothrow @nogc
    {
        import flint.reactor : connectionSendsImmediately;

        atomicStore(acceptedWithoutDelay, connectionSendsImmediately(id));
        atomicStore(acceptChecked, true);
        Reactor.current().close(id);
        Reactor.current().stop();
    }

    private void acceptOneAndInspect(Backend backend) @trusted
    {
        atomicStore(acceptedWithoutDelay, false);
        atomicStore(acceptChecked, false);
        ReactorOptions options;
        options.backend = backend;
        options.cores = 1;
        auto server = Reactor.create(options);
        assert(server.ok, server.error.message);
        assert(server.value.listen(ListenOptions("127.0.0.1", 0, 8), &inspectAccepted).code == Status.ok);
        assert(server.value.post(0, &armWatchdog).code == Status.ok);
        const port = server.value.localPort.value;
        auto client = new Thread({
            auto peer = new TcpSocket;
            scope (exit)
                peer.close();
            peer.connect(new InternetAddress("127.0.0.1", port));
            foreach (_; 0 .. 3_000)
            {
                if (atomicLoad(acceptChecked))
                    break;
                Thread.sleep(1.msecs);
            }
        }).start();
        assert(server.value.run().code == Status.ok);
        assert(client.join(false) is null);
        assert(atomicLoad(acceptChecked));
        assert(atomicLoad(acceptedWithoutDelay), "an accepted socket still coalesces small writes (Nagle)");
    }

    @("epoll admits connections with TCP_NODELAY set")
    unittest
    {
        acceptOneAndInspect(Backend.epoll);
    }

    version (FlintNativeLiburing)
    {
        @("io_uring admits connections with TCP_NODELAY set")
        unittest
        {
            import std.process : environment;

            if (environment.get("FLINT_TEST_URING_DENIED") != "1")
                acceptOneAndInspect(Backend.ioUring);
        }
    }
}
