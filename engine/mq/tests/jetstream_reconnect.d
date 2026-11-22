/// JetStream reconnect behavior (ADR-017 decision 12) against a scripted loopback NATS peer.
module flint.mq.jetstream_reconnect;

version (linux) version (FlintNativeLibrdkafka) version = FlintMqJetStreamPeer;

version (FlintMqJetStreamPeer)
{
    import core.thread.osthread : Thread;
    import core.time : MonoTime, msecs;
    import flint.arena : Error, RequestArena, Result, Status;
    import flint.conc : Context, Deadline;
    import flint.mq : AckAction, Broker, Message, PublishReceipt, QueueClient, QueueOptions;
    import std.algorithm.searching : countUntil, startsWith;
    import std.array : split;
    import std.conv : to;
    import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;

    /// What the peer does with the n-th application publish it receives.
    private enum Reply
    {
        ack,
        /// Never answer, so the client's request deadline expires.
        swallow,
        /// Close the connection without answering.
        hangUp,
        /// Close the connection and stop listening for `outageMillis` before accepting again.
        outage,
    }

    private final class ReconnectPeer
    {
        TcpSocket listener;
        ushort port;
        Reply[] script;
        uint outageMillis = 400;
        uint expectedConnections;
        uint connections;
        string[] published;
        string[] acknowledgements;
        string failure;
        private Socket peer;
        private ubyte[] pending;
        private string[string] inboxes;
        private uint publishes, pulls;
        private bool dropped;

        this()
        {
            listen(0);
        }

        private void listen(ushort requested)
        {
            listener = new TcpSocket;
            listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
            listener.bind(new InternetAddress("127.0.0.1", requested));
            listener.listen(1);
            port = (cast(InternetAddress) listener.localAddress).port;
        }

        void serve()
        {
            try
            {
                while (connections < expectedConnections)
                {
                    peer = listener.accept();
                    ++connections;
                    pending = null;
                    inboxes = null;
                    dropped = false;
                    send(`INFO {"headers":true,"jetstream":true,"max_payload":1048576}` ~ "\r\n");
                    while (!dropped)
                    {
                        const line = readLine();
                        if (line is null)
                            break;
                        handle(line);
                    }
                    hangUp();
                }
            }
            catch (Exception error)
                failure = error.msg;
        }

        private void hangUp()
        {
            if (peer is null)
                return;
            peer.shutdown(SocketShutdown.BOTH);
            peer.close();
            peer = null;
        }

        private void handle(string line)
        {
            auto words = line.split(' ');
            switch (words[0])
            {
            case "PING":
                send("PONG\r\n");
                break;
            case "SUB":
                inboxes[words[1]] = words[2];
                break;
            case "PUB", "HPUB":
                const headers = words[0] == "HPUB";
                const total = words[$ - 1].to!size_t;
                const reply = words.length == (headers ? 5 : 4) ? words[2] : null;
                const data = readBytes(total + 2)[0 .. total];
                const offset = headers ? words[$ - 2].to!size_t : 0;
                respond(words[1], reply, cast(string) data[offset .. $].idup);
                break;
            default:
                break;
            }
        }

        private void respond(string subject, string reply, string payload)
        {
            if (subject.startsWith("$JS.API.CONSUMER.MSG.NEXT."))
            {
                const sid = inboxes[reply];
                if (pulls++ == 0)
                {
                    enum headers = "NATS/1.0\r\n\r\n";
                    enum message = "order-7";
                    const total = (headers.length + message.length).to!string;
                    const sizes = headers.length.to!string ~ " " ~ total;
                    send("HMSG orders.in " ~ sid ~ " $JS.ACK.ORDERS.flint.1.5.1.0.0 " ~ sizes ~ "\r\n"
                            ~ headers ~ message ~ "\r\n");
                }
                else
                {
                    enum empty = "NATS/1.0 404 No Messages\r\n\r\n";
                    send("HMSG " ~ reply ~ " " ~ sid ~ " " ~ empty.length.to!string ~ " "
                            ~ empty.length.to!string ~ "\r\n" ~ empty ~ "\r\n");
                }
                return;
            }
            if (subject.startsWith("$JS.ACK."))
            {
                acknowledgements ~= payload;
                return;
            }
            const action = publishes < script.length ? script[publishes] : Reply.ack;
            ++publishes;
            published ~= subject ~ ":" ~ payload;
            final switch (action)
            {
            case Reply.ack:
                const ack = `{"stream":"AUDIT","seq":` ~ (published.length).to!string ~ `}`;
                send("MSG " ~ reply ~ " " ~ inboxes[reply] ~ " " ~ ack.length.to!string ~ "\r\n" ~ ack ~ "\r\n");
                break;
            case Reply.swallow:
                break;
            case Reply.hangUp:
                dropped = true;
                break;
            case Reply.outage:
                dropped = true;
                hangUp();
                const previous = port;
                listener.close();
                Thread.sleep(outageMillis.msecs);
                listen(previous);
                break;
            }
        }

        private string readLine()
        {
            for (;;)
            {
                const end = (cast(const(char)[]) pending).countUntil("\r\n");
                if (end >= 0)
                {
                    const line = (cast(const(char)[]) pending[0 .. end]).idup;
                    pending = pending[end + 2 .. $];
                    return line;
                }
                if (!fill())
                    return null;
            }
        }

        private ubyte[] readBytes(size_t count)
        {
            while (pending.length < count)
                if (!fill())
                    throw new Exception("NATS peer closed inside a payload");
            auto bytes = pending[0 .. count].dup;
            pending = pending[count .. $];
            return bytes;
        }

        private bool fill()
        {
            ubyte[4096] chunk;
            const received = peer.receive(chunk[]);
            if (received <= 0)
                return false;
            pending ~= chunk[0 .. received];
            return true;
        }

        private void send(string text)
        {
            peer.send(cast(const(ubyte)[]) text);
        }

        void stop()
        {
            // Only wake the peer thread here; it closes its own connection. Shutting a listening socket
            // down also wakes a peer thread blocked in accept.
            auto current = peer;
            if (current !is null)
                current.shutdown(SocketShutdown.BOTH);
            listener.shutdown(SocketShutdown.BOTH);
            listener.close();
        }
    }

    private QueueOptions peerOptions(ushort port, string client)
    {
        QueueOptions options;
        options.broker = Broker.natsJetStream;
        options.endpoints = "nats://127.0.0.1:" ~ port.to!string;
        options.clientId = client;
        options.maxQueuedBytes = 64 * 1024;
        options.deliveryTimeoutNanos = 5_000_000_000;
        return options;
    }

    private Result!PublishReceipt send(ref QueueClient client, string payload, uint millis)
    {
        auto limit = Context.init.withDeadline(Deadline.afterMillis(millis));
        return client.publish("audit.out", null, cast(const(ubyte)[]) payload, "", limit);
    }

    @("a JetStream request timeout fails that request, then the client reconnects for the next one")
    @system unittest
    {
        auto server = new ReconnectPeer;
        server.script = [Reply.ack, Reply.swallow];
        server.expectedConnections = 2;
        auto worker = new Thread(&server.serve).start();
        scope (failure)
        {
            server.stop();
            worker.join(false);
        }
        QueueClient client;
        assert(client.open(peerOptions(server.port, "flint-timeout")).code == Status.ok);

        const first = send(client, "one", 5_000);
        assert(first.ok() && first.value.sequence == 1, first.error.message);
        const started = MonoTime.currTime;
        const lost = send(client, "two", 200);
        assert(!lost.ok() && lost.error.code == Status.timedOut, lost.error.message);
        assert(MonoTime.currTime - started < 2_000.msecs, "the timed-out request hung");
        const recovered = send(client, "three", 5_000);
        assert(recovered.ok(), recovered.error.message);
        assert(recovered.value.sequence == 3);

        assert(client.close().code == Status.ok);
        worker.join();
        server.stop();
        assert(server.failure is null, server.failure);
        assert(server.connections == 2);
        assert(server.published == ["audit.out:one", "audit.out:two", "audit.out:three"]);
    }

    private final class Counter
    {
        uint deliveries;

        AckAction handle(ref Message message, ref scope RequestArena arena, ref Context context) @safe nothrow @nogc
        {
            ++deliveries;
            return AckAction.ack;
        }
    }

    @("a JetStream connection lost mid-request fails promptly and the consumer resumes on the new connection")
    @system unittest
    {
        auto server = new ReconnectPeer;
        server.script = [Reply.hangUp];
        server.expectedConnections = 2;
        auto worker = new Thread(&server.serve).start();
        scope (failure)
        {
            server.stop();
            worker.join(false);
        }
        QueueClient client;
        assert(client.open(peerOptions(server.port, "flint-hangup")).code == Status.ok);
        auto counter = new Counter;
        assert(client.subscribe("ORDERS", "flint", &counter.handle).code == Status.ok);

        const started = MonoTime.currTime;
        const lost = send(client, "one", 5_000);
        assert(!lost.ok() && lost.error.code == Status.unavailable, lost.error.message);
        assert(MonoTime.currTime - started < 2_000.msecs, "the interrupted request hung");

        // The registered pull consumer is served on the reconnected transport.
        auto limit = Context.init.withDeadline(Deadline.afterMillis(5_000));
        const polled = client.poll(limit);
        assert(polled.code == Status.ok, polled.message);
        assert(counter.deliveries == 1);
        const sent = send(client, "two", 5_000);
        assert(sent.ok(), sent.error.message);

        assert(client.close().code == Status.ok);
        worker.join();
        server.stop();
        assert(server.failure is null, server.failure);
        assert(server.connections == 2);
        assert(server.acknowledgements == ["+ACK"]);
        assert(server.published == ["audit.out:one", "audit.out:two"]);
    }

    @("during a JetStream outage requests fail without hanging and reconnect backoff stays bounded")
    @system unittest
    {
        auto server = new ReconnectPeer;
        server.script = [Reply.outage];
        server.outageMillis = 600;
        server.expectedConnections = 2;
        auto worker = new Thread(&server.serve).start();
        scope (failure)
        {
            server.stop();
            worker.join(false);
        }
        QueueClient client;
        assert(client.open(peerOptions(server.port, "flint-outage")).code == Status.ok);

        const lost = send(client, "one", 5_000);
        assert(!lost.ok() && lost.error.code == Status.unavailable, lost.error.message);
        // While nothing listens, each request ends by its own deadline with a reconnect status.
        foreach (_; 0 .. 3)
        {
            const started = MonoTime.currTime;
            const refused = send(client, "refused", 100);
            assert(!refused.ok() && refused.error.code == Status.unavailable, refused.error.message);
            assert(MonoTime.currTime - started < 1_000.msecs, "a request hung during the outage");
        }
        const resumed = MonoTime.currTime;
        const recovered = send(client, "two", 10_000);
        assert(recovered.ok(), recovered.error.message);
        // The listener returns within 600 ms; the capped backoff must not add more than its bound.
        assert(MonoTime.currTime - resumed < 3_000.msecs, "reconnect backoff is unbounded");

        assert(client.close().code == Status.ok);
        // Closing the client stops reconnection: later requests are rejected immediately.
        const closed = send(client, "late", 1_000);
        assert(!closed.ok());
        worker.join();
        server.stop();
        assert(server.failure is null, server.failure);
        assert(server.connections == 2);
        assert(server.published == ["audit.out:one", "audit.out:two"]);
    }
}
