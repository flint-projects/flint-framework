/// Readiness backends send a write as soon as it starts and register write interest only when the socket would
/// block or takes part of it. Each case checks what the peer receives and what the write callbacks report: a whole
/// write, a write larger than the socket buffers (the remainder goes through EPOLLOUT/EVFILT_WRITE), a write that
/// starts while the buffers are full (EAGAIN on the first attempt), and a write to a peer that has closed.
module flint.engine.reactor.write_now_test;

version (Posix)
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread.osthread : Thread;
    import core.time : msecs;
    import flint.arena : Status;
    import flint.conc : Context, Deadline;
    import flint.engine.reactor : Completion, ConnectionId, ListenOptions, Reactor, ReactorOptions;
    import flint.engine.reactor.test_support : readinessBackend;
    import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;

    private enum Mode
    {
        whole,
        larger,
        backToBack,
        closedPeer
    }

    private enum largeBytes = 262_144;
    private enum smallBytes = 64;
    private immutable ubyte[largeBytes] payload = () {
        ubyte[largeBytes] bytes;
        foreach (index, ref b; bytes)
            b = cast(ubyte)(index * 7 + index / 251);
        return bytes;
    }();

    // The worker thread's writer; set in its accept callback, read by its timer function.
    private Writer current;

    private final class Writer
    {
        Mode mode;
        ConnectionId connection;
        uint writes;
        size_t written;
        Status last = Status.ok;

        @safe nothrow @nogc void accepted(ConnectionId id)
        {
            current = this;
            connection = id;
            assert(Reactor.current().readWith(id, 1, Context.init, &received).ok);
        }

        @safe nothrow @nogc void received(Completion completion, scope const(ubyte)[] input)
        {
            assert(completion.status == Status.ok && input.length == 1 && input[0] == 42);
            final switch (mode)
            {
            case Mode.whole:
                write(payload[0 .. smallBytes]);
                break;
            case Mode.larger, Mode.backToBack:
                write(payload[]);
                break;
            case Mode.closedPeer:
                // The peer closes right after its request; write once it has.
                assert(Reactor.current().schedule(Deadline.afterMillis(200), &writeLate).ok);
                break;
            }
        }

        @safe nothrow @nogc void write(scope const(ubyte)[] data)
        {
            assert(Reactor.current().writeWith(connection, data, Context.init, &wrote).ok);
        }

        @safe nothrow @nogc void wrote(Completion completion)
        {
            ++writes;
            last = completion.status;
            written += completion.bytes;
            // The second write starts while the first one's bytes still fill the socket buffers.
            if (mode == Mode.backToBack && writes == 1 && last == Status.ok)
                return write(payload[]);
            // The first write to a closed peer may still be buffered; the next ones fail once it has reset.
            if (mode == Mode.closedPeer && last == Status.ok && writes < 64)
                return write(payload[0 .. smallBytes]);
            Reactor.current().stop();
        }
    }

    private void writeLate() @safe nothrow @nogc
    {
        current.write(payload[0 .. smallBytes]);
    }

    private Writer serve(Mode mode)
    {
        ReactorOptions options;
        options.backend = readinessBackend;
        options.cores = 1;
        options.ioBufferBytes = largeBytes;
        options.maxPendingIoPerCore = 4;
        options.fiberPoolSize = 1;
        auto server = Reactor.create(options);
        assert(server.ok, server.error.message);
        auto writer = new Writer;
        writer.mode = mode;
        assert(server.value.listenWith(ListenOptions("127.0.0.1", 0, 8), &writer.accepted).code == Status.ok);
        const port = server.value.localPort.value;

        shared bool verified;
        auto peer = new Thread({
            auto socket = new TcpSocket;
            scope (exit)
                socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 4096);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5_000.msecs);
            socket.connect(new InternetAddress("127.0.0.1", port));
            const ubyte[1] request = [42];
            assert(socket.send(request[]) == 1);
            if (mode == Mode.closedPeer)
                return;
            // Let the server's writes meet full buffers before anything is read.
            Thread.sleep(50.msecs);
            const expected = mode == Mode.whole ? smallBytes : mode == Mode.larger ? largeBytes : 2 * largeBytes;
            auto received = new ubyte[expected];
            size_t at;
            while (at < expected)
            {
                const count = socket.receive(received[at .. $]);
                assert(count > 0, "the peer stopped receiving early");
                at += count;
            }
            foreach (index, b; received)
                assert(b == payload[index % largeBytes], "the peer received bytes out of order");
            atomicStore(verified, true);
        }).start();

        const status = server.value.run();
        assert(status.code == Status.ok, status.message);
        assert(peer.join(false) is null);
        assert(mode == Mode.closedPeer || atomicLoad(verified));
        const stats = server.value.workerStats(0);
        assert(stats.ok && stats.value.outstandingOperations == 0);
        return writer;
    }

    @("readiness: a whole write completes at once with every byte")
    unittest
    {
        const writer = serve(Mode.whole);
        assert(writer.writes == 1 && writer.last == Status.ok && writer.written == smallBytes);
    }

    @("readiness: a write larger than the socket buffers finishes through write readiness")
    unittest
    {
        const writer = serve(Mode.larger);
        assert(writer.writes == 1 && writer.last == Status.ok && writer.written == largeBytes);
    }

    @("readiness: a write started on full buffers (EAGAIN first) waits for readiness and completes")
    unittest
    {
        const writer = serve(Mode.backToBack);
        assert(writer.writes == 2 && writer.last == Status.ok && writer.written == 2 * largeBytes);
    }

    @("readiness: writes to a closed peer end in an error, delivered once")
    unittest
    {
        const writer = serve(Mode.closedPeer);
        assert(writer.last != Status.ok && writer.writes < 64);
    }
}
