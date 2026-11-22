/// JetStream owner behavior against a scripted loopback NATS peer.
module flint.mq.jetstream_handler;

version (linux) version (FlintNativeLibrdkafka) version = FlintMqJetStreamPeer;

version (FlintMqJetStreamPeer)
{
    import core.thread.osthread : Thread;
    import flint.arena : Error, RequestArena, Result, Status;
    import flint.conc : Context, Deadline;
    import flint.mq : AckAction, Broker, Message, PublishReceipt, QueueClient, QueueOptions;
    import std.algorithm.searching : countUntil, startsWith;
    import std.array : split;
    import std.conv : to;
    import std.socket : InternetAddress, Socket, SocketShutdown, TcpSocket;

    /// Serves one connection: one pulled message, PubAck replies and recorded acknowledgements.
    private final class ScriptedPeer
    {
        TcpSocket listener;
        ushort port;
        string[] published;
        string[] acknowledgements;
        string failure;
        private Socket peer;
        private ubyte[] pending;
        private string[string] inboxes;
        private uint pulls;

        this()
        {
            listener = new TcpSocket;
            listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
            listener.listen(1);
            port = (cast(InternetAddress) listener.localAddress).port;
        }

        void serve()
        {
            try
            {
                peer = listener.accept();
                send(`INFO {"headers":true,"jetstream":true,"max_payload":1048576}` ~ "\r\n");
                while (true)
                {
                    const line = readLine();
                    if (line is null)
                        return;
                    handle(line);
                }
            }
            catch (Exception error)
                failure = error.msg;
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
            }
            else if (subject.startsWith("$JS.ACK."))
                acknowledgements ~= payload;
            else
            {
                published ~= subject ~ ":" ~ payload;
                enum ack = `{"stream":"AUDIT","seq":9}`;
                send("MSG " ~ reply ~ " " ~ inboxes[reply] ~ " " ~ ack.length.to!string ~ "\r\n" ~ ack ~ "\r\n");
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
            if (peer !is null)
            {
                peer.shutdown(SocketShutdown.BOTH);
                peer.close();
            }
            listener.close();
        }
    }

    private final class Relay
    {
        QueueClient* client;
        Error forwarded = Error(Status.unavailable, "handler did not run");
        ulong sequence;

        AckAction handle(ref Message message, ref scope RequestArena arena, ref Context context) @safe nothrow @nogc
        {
            const sent = client.publish("audit.out", null, cast(const(ubyte)[]) "seen", "", context);
            forwarded = sent.error;
            sequence = sent.value.sequence;
            return sent.ok() ? AckAction.ack : AckAction.retry;
        }
    }

    @("a JetStream handler can publish on its own client before acknowledging the delivery")
    @system unittest
    {
        auto server = new ScriptedPeer;
        auto worker = new Thread(&server.serve).start();
        scope (failure)
        {
            server.stop();
            worker.join(false);
        }
        QueueOptions options;
        options.broker = Broker.natsJetStream;
        options.endpoints = "nats://127.0.0.1:" ~ server.port.to!string;
        options.clientId = "flint-handler";
        options.maxQueuedBytes = 64 * 1024;
        options.deliveryTimeoutNanos = 5_000_000_000;
        QueueClient client;
        const opened = client.open(options);
        assert(opened.code == Status.ok, opened.message);
        auto relay = new Relay;
        relay.client = &client;
        assert(client.subscribe("ORDERS", "flint", &relay.handle).code == Status.ok);
        auto limit = Context.init.withDeadline(Deadline.afterMillis(5_000));
        const polled = client.poll(limit);
        assert(polled.code == Status.ok, polled.message);
        assert(relay.forwarded.code == Status.ok, relay.forwarded.message);
        assert(relay.sequence == 9);
        assert(client.close().code == Status.ok);
        worker.join();
        server.stop();
        assert(server.failure is null, server.failure);
        assert(server.published == ["audit.out:seen"]);
        assert(server.acknowledgements == ["+ACK"]);
    }

    @("JetStream publish round trips are not stalled by small-segment coalescing")
    @system unittest
    {
        import core.time : MonoTime;

        auto server = new ScriptedPeer;
        auto worker = new Thread(&server.serve).start();
        scope (failure)
        {
            server.stop();
            worker.join(false);
        }
        QueueOptions options;
        options.broker = Broker.natsJetStream;
        options.endpoints = "nats://127.0.0.1:" ~ server.port.to!string;
        options.clientId = "flint-latency";
        options.maxQueuedBytes = 64 * 1024;
        QueueClient client;
        assert(client.open(options).code == Status.ok);
        auto limit = Context.init.withDeadline(Deadline.afterMillis(10_000));
        enum count = 20;
        const started = MonoTime.currTime;
        foreach (_; 0 .. count)
        {
            const sent = client.publish("bench.out", cast(const(ubyte)[]) "k", cast(const(ubyte)[]) "x", "", limit);
            assert(sent.ok(), sent.error.message);
        }
        const elapsed = (MonoTime.currTime - started).total!"msecs";
        assert(client.close().code == Status.ok);
        worker.join();
        server.stop();
        assert(server.failure is null, server.failure);
        assert(server.published.length == count);
        // Split command writes wait on a delayed TCP acknowledgement, about 40 ms per publish on Linux.
        assert(elapsed < 400, "JetStream publishes waited on split command writes");
    }
}
