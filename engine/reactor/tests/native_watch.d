module flint.reactor.native_watch_test;

// Linux epoll and io_uring, and macOS kqueue (ADR-024).
version (Posix)
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    import core.sys.posix.sys.socket : AF_UNIX, SHUT_WR, SOCK_STREAM, send, shutdown, socketpair;
    import core.sys.posix.unistd : close;
    import flint.arena : Status;
    import flint.conc : Deadline;
    import flint.reactor : Backend, NativeInterest, NativeReadyFn, Reactor, ReactorOptions;
    import flint.reactor.test_support : readinessBackend;

    private shared int watched;
    private shared int quietFd;
    private shared uint observations;

    private NativeReadyFn callback() @safe nothrow @nogc
    {
        return delegate void(int fd, NativeInterest events) @safe nothrow @nogc {
            onReady(fd, events);
        };
    }

    private void ownerTask() @safe nothrow @nogc
    {
        auto reactor = Reactor.current();
        const fd = atomicLoad(watched);
        assert(reactor.watchNative(-1, NativeInterest.read, callback()).code == Status.invalidArgument);
        assert(reactor.watchNative(fd, NativeInterest.none, callback()).code == Status.invalidArgument);
        assert(reactor.watchNative(fd, NativeInterest.write, callback()).code == Status.ok);
        assert(reactor.watchNative(fd, NativeInterest.read, callback()).code == Status.ok);
        assert(reactor.watchNative(atomicLoad(quietFd), NativeInterest.read, callback())
                .code == Status.resourceExhausted);
        assert(reactor.yieldUntil(Deadline.afterMillis(30)).code == Status.ok);
        assert(atomicLoad(observations) == 1);
        reactor.stop();
    }

    private void onReady(int fd, NativeInterest events) @safe nothrow @nogc
    {
        auto reactor = Reactor.current();
        assert(reactor.currentCore == 0);
        assert(reactor.currentTask().error.code == Status.notFound);
        assert(fd == atomicLoad(watched));
        assert((events & NativeInterest.read) != 0 && (events & NativeInterest.error) != 0);
        assert((events & NativeInterest.write) == 0);
        assert(reactor.unwatchNative(fd).code == Status.ok);
        assert(reactor.unwatchNative(fd).code == Status.ok);
        assert(reactor.watchNative(atomicLoad(quietFd), NativeInterest.read, callback()).code == Status.ok);
        atomicOp!"+="(observations, 1);
    }

    private void exercise(Backend backend) @system
    {
        ReactorOptions options;
        options.cores = 1;
        options.backend = backend;
        options.fiberPoolSize = 1;
        options.maxNativeWatchesPerCore = 1;
        options.completionsPerTick = 1;
        auto server = Reactor.create(options);
        if (backend == Backend.ioUring && !server.ok)
        {
            assert(server.error.code == Status.unsupported || server.error.code == Status.permissionDenied);
            return;
        }
        assert(server.ok, server.error.message);

        int[2] ready;
        int[2] quiet;
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, ready) == 0);
        scope (exit)
            foreach (fd; ready)
                close(fd);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, quiet) == 0);
        scope (exit)
            foreach (fd; quiet)
                close(fd);
        const ubyte datum = 42;
        assert(send(ready[1], &datum, 1, 0) == 1);
        assert(shutdown(ready[1], SHUT_WR) == 0);

        atomicStore(watched, ready[0]);
        atomicStore(quietFd, quiet[0]);
        atomicStore(observations, 0U);
        assert(server.value.watchNative(ready[0], NativeInterest.read, callback()).code == Status.conflict);
        assert(server.value.post(0, &ownerTask).code == Status.ok);
        assert(server.value.run().code == Status.ok);
        assert(atomicLoad(observations) == 1);
        const stats = server.value.workerStats(0);
        assert(stats.ok && stats.value.gcAllocated == 0);
        assert(send(quiet[0], &datum, 1, 0) == 1);
    }

    @("borrowed descriptors notify outside fibers and survive reactor shutdown")
    @system unittest
    {
        exercise(readinessBackend);
        version (FlintNativeLiburing)
            exercise(Backend.ioUring);
    }
}
