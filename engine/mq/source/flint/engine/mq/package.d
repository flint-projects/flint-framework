/// Kafka and JetStream publishing and explicit owner-fiber delivery acknowledgement.
module flint.engine.mq;

import core.atomic : atomicLoad, atomicOp, cas;
import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.mq.ffi.kafka : KafkaBridge, nativeError;
import flint.engine.mq.jetstream : JetStream, name;
import flint.engine.mq.kafka : confirm, waitTurn;

public import flint.engine.mq.types : AckAction, Broker, KafkaListener, Message, MessageHandler,
    PublishReceipt, QueueOptions, StreamListener;

@safe:

/// A broker client initialized at startup and used on one Reactor owner or standalone thread.
struct QueueClient
{
    private ulong slot;
    private ulong generation;
    private ClientState state;

    /// Provision bounded broker queues. The first poll or publish binds the owner.
    Error open(QueueOptions options)
    {
        if (state !is null || !validOptions(options))
            return Error(Status.invalidArgument, "invalid or already opened message queue");
        auto opened = new ClientState(options);
        const initialized = opened.open();
        if (initialized.code == Status.ok)
        {
            state = opened;
            slot = atomicOp!"+="(serial, 1UL);
            generation = slot;
        }
        return initialized;
    }

    /// Publish a copied record and wait for its correlated broker receipt.
    // dfmt off
    Result!PublishReceipt publish(string topic, scope const(ubyte)[] key, scope const(ubyte)[] payload,
            string deduplicationId, ref Context context) nothrow @nogc
    {
        if (state is null)
            return failure(nativeError(Status.conflict));
        const live = state.admit(context);
        if (live.code != Status.ok)
            return failure(live);
        scope (exit)
            --state.active;
        auto deadline = context.withDeadline(state.messageDeadline());
        return state.publish(topic, key, payload, deduplicationId, deadline);
    }
    // dfmt on

    /// Register one owner-fiber action for a Kafka group or JetStream pull consumer.
    Error subscribe(string topic, string consumer, MessageHandler handler)
    {
        if (state is null || state.draining || state.closed || state.active != 0)
            return nativeError(Status.conflict);
        if (handler is null || topic.length == 0 || consumer.length == 0)
            return nativeError(Status.invalidArgument);
        return state.subscribe(topic, consumer, handler);
    }

    /// Deliver one admitted message, returning when the owner is temporarily idle.
    Error poll(ref Context context) nothrow @nogc
    {
        if (state is null)
            return nativeError(Status.conflict);
        const admitted = state.admit(context);
        if (admitted.code != Status.ok)
            return admitted;
        scope (exit)
            --state.active;
        return state.poll(context);
    }

    /// End admission and wait for handling and confirmed receipts until the caller deadline.
    Error drain(ref Context context) nothrow @nogc
    {
        if (state is null)
            return Error.init;
        const owner = state.claim();
        if (owner.code != Status.ok)
            return owner;
        return state.drain(context);
    }

    /// Stop the native worker and release its buffers after the last borrowing operation.
    Error close() nothrow @nogc
    {
        if (state is null)
            return Error.init;
        const owner = state.claim();
        if (owner.code != Status.ok)
            return owner;
        if (state.active != 0)
            return nativeError(Status.conflict);
        state.close();
        state = null;
        slot = generation = 0;
        return Error.init;
    }
}

private shared ulong serial;
private shared ulong threadSerial;
private ulong threadIdentity;

private enum maximumInFlight = 1024;
private enum maximumQueuedBytes = 16 * 1024 * 1024;

private bool validOptions(scope const ref QueueOptions options) pure nothrow @nogc
{
    return options.broker <= Broker.natsJetStream && options.endpoints.length != 0
        && options.clientId.length != 0 && options.maxInFlight != 0 && options.maxInFlight <= maximumInFlight
        && options.maxQueuedBytes != 0 && options.maxQueuedBytes <= maximumQueuedBytes
        && options.deliveryTimeoutNanos > 0 && options.deliveryTimeoutNanos <= 900_000_000_000L;
}

private struct Listener
{
    string topic;
    string group;
    MessageHandler handle;
}

private final class ClientState
{
    private shared ulong owner;
    private QueueOptions options;
    private KafkaBridge kafka;
    private JetStream jetStream;
    private Listener[32] listeners;
    private uint listenerCount;
    private uint listenerCursor;
    private ulong token;
    private uint active;
    private bool draining, closed;

    this(QueueOptions options)
    {
        this.options = options;
    }

    Error open()
    {
        if (options.broker == Broker.natsJetStream)
        {
            jetStream = new JetStream;
            return jetStream.open(options);
        }
        const tls = startingWith(options.endpoints, "ssl://");
        const brokers = tls ? options.endpoints[6 .. $] : options.endpoints;
        if (!tls && options.caBundle.length != 0)
            return nativeError(Status.invalidArgument);
        return kafka.open(options, brokers, tls);
    }

    Error subscribe(string topic, string group, MessageHandler callback)
    {
        if (listenerCount == listeners.length)
            return nativeError(Status.resourceExhausted);
        foreach (ref item; listeners[0 .. listenerCount])
        {
            if (item.topic == topic && item.group == group)
                return nativeError(Status.conflict);
        }
        auto joined = Error.init;
        if (jetStream is null)
            joined = kafka.subscribe(topic, group, listenerCount);
        else if (!name(topic) || !name(group))
            joined = nativeError(Status.invalidArgument);
        if (joined.code == Status.ok)
            listeners[listenerCount++] = Listener(topic, group, callback);
        return joined;
    }

nothrow @nogc:

    Error claim()
    {
        if (threadIdentity == 0)
            threadIdentity = atomicOp!"+="(threadSerial, 1UL);
        const current = atomicLoad(owner);
        if (threadIdentity == 0 || (current != threadIdentity && !cas(&owner, 0UL, threadIdentity)))
            return nativeError(Status.conflict);
        return Error.init;
    }

    Error admit(ref scope const Context context)
    {
        const own = claim();
        if (own.code != Status.ok)
            return own;
        if (draining || closed || active == uint.max)
            return nativeError(Status.conflict);
        const allowed = context.check();
        if (allowed.code == Status.ok)
            ++active;
        return allowed;
    }

    Deadline messageDeadline() const
    {
        const remaining = cast(ulong) options.deliveryTimeoutNanos;
        return Deadline.afterMillis(remaining / 1_000_000 + (remaining % 1_000_000 != 0));
    }

    // dfmt off
    Result!PublishReceipt publish(string topic, scope const(ubyte)[] key, scope const(ubyte)[] payload,
            string dedup, ref scope const Context caller)
    {
        if (jetStream !is null)
            return jetStream.publish(topic, key, payload, dedup, caller);
        if (token == ulong.max)
            return failure(nativeError(Status.resourceExhausted));
        const id = ++token;
        const submitted = kafka.submit(topic, key, payload, dedup, id);
        return submitted.code == Status.ok ? confirm(kafka, id, caller) : failure(submitted);
    }
    // dfmt on

    Error poll(ref Context context)
    {
        const pending = jetStream is null ? deliver(context) : pull(context);
        return pending.code == Status.unavailable ? waitTurn(context) : pending;
    }

    Error drain(ref Context context)
    {
        if (closed)
            return Error.init;
        draining = true;
        if (jetStream !is null)
            return waitForCurrent(context);
        const stopped = kafka.beginDrain();
        if (stopped.code != Status.ok)
            return stopped;
        for (;;)
        {
            const live = context.check();
            if (live.code != Status.ok)
                return nativeError(live.code);
            const result = deliver(context);
            if (result.code != Status.ok && result.code != Status.unavailable)
                return result;
            if (active == 0)
            {
                const flushed = kafka.flushed();
                if (flushed.code != Status.unavailable)
                    return flushed;
            }
            const waited = waitTurn(context);
            if (waited.code != Status.ok)
                return nativeError(waited.code);
        }
    }

    private Error waitForCurrent(ref Context context)
    {
        while (active != 0)
        {
            const waited = waitTurn(context);
            if (waited.code != Status.ok)
                return nativeError(waited.code);
        }
        return context.check();
    }

    void close()
    {
        if (!closed)
        {
            closed = true;
            if (jetStream is null)
                kafka.close();
            else
                jetStream.close();
        }
    }

    private Error pull(ref Context context)
    {
        if (listenerCount == 0)
            return nativeError(Status.unavailable);
        const index = listenerCursor++ % listenerCount;
        const topic = listeners[index].topic;
        const group = listeners[index].group;
        auto deadline = context.withDeadline(messageDeadline());
        return jetStream.poll(topic, group, options.deadLetterTopic, options.confirmedAcks,
                deadline, (ref Message message, ref scope RequestArena arena) @safe nothrow @nogc {
            const decision = listeners[index].handle(message, arena, deadline);
            return validateDecision(decision, deadline);
        });
    }

    private Error deliver(ref Context context)
    {
        auto scopedContext = context.withDeadline(messageDeadline());
        return kafka.deliver((uint index, ref Message message, ref scope RequestArena arena) @safe nothrow @nogc {
            if (index >= listenerCount)
                return Result!AckAction(AckAction.retry, nativeError(Status.conflict));
            const decision = listeners[index].handle(message, arena, scopedContext);
            const assessed = validateDecision(decision, scopedContext);
            if (!assessed.ok() || decision != AckAction.reject)
                return assessed;
            return Result!AckAction(AckAction.ack, relay(message, arena, scopedContext));
        });
    }

    private Error relay(ref Message message, ref scope RequestArena arena, ref scope const Context context)
    {
        if (options.deadLetterTopic.length == 0 || draining)
            return Error(Status.conflict, "dead-letter destination is unavailable");
        Error sent;
        const borrowed = arena.read(message.key, (scope const(ubyte)[] key) @safe nothrow @nogc {
            const read = arena.read(message.payload, (scope const(ubyte)[] payload) @safe nothrow @nogc {
                sent = publish(options.deadLetterTopic, key, payload, "", context).error;
            });
            if (read != Status.ok)
                sent = nativeError(read);
        });
        return borrowed == Status.ok ? sent : nativeError(borrowed);
    }
}

private Result!AckAction validateDecision(AckAction decision, ref scope const Context context) nothrow @nogc
{
    const status = decision <= AckAction.reject ? context.check() : nativeError(Status.invalidArgument);
    return Result!AckAction(decision, status);
}

private Result!PublishReceipt failure(Error error) pure nothrow @nogc
{
    return Result!PublishReceipt(PublishReceipt.init, error);
}

private bool startingWith(scope const(char)[] value, string prefix) pure nothrow @nogc
{
    return value.length >= prefix.length && value[0 .. prefix.length] == prefix;
}

/// Register the current broker's annotated methods on a persistent class component.
Error registerListeners(T)(ref QueueClient client, ref T component)
{
    static assert(is(T == class), "MQ listener component must be a persistent class");
    if (client.state is null || component is null)
        return nativeError(Status.invalidArgument);
    const broker = client.state.options.broker;
    static foreach (label; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getOverloads, T, label, true)))
        {
            static foreach (method; __traits(getOverloads, T, label, true))
            {
                static foreach (marker; __traits(getAttributes, method))
                {
                    static if (is(typeof(marker) == KafkaListener) || is(typeof(marker) == StreamListener))
                    {
                        {
                            const registered = attach!(T, label, method, marker)(client, component, broker);
                            if (registered.code != Status.ok)
                                return registered;
                        }
                    }
                }
            }
        }
    }
    return Error.init;
}

private Error attach(T, string label, alias method, alias marker)(ref QueueClient client, T component, Broker broker)
{
    import std.traits : Parameters;

    static assert(__traits(getOverloads, T, label, true).length == 1,
            "MQ annotated listeners cannot be overloaded: " ~ label);
    alias Args = Parameters!method;
    static assert(Args.length == 3, "MQ listener must accept payload, arena and context: " ~ label);
    enum typed = !is(Args[0] == Message);
    static if (typed)
    {
        alias Payload = Args[0];
        static assert(is(Payload == struct), "MQ typed payload must be a value DTO: " ~ label);
        alias Handler = ConvertedListener!(T, Payload, label);
    }
    else
    {
        static assert(is(typeof(&__traits(getMember, component, label)) : MessageHandler),
                "MQ listener must be @safe nothrow @nogc and return AckAction: " ~ label);
    }
    static if (is(typeof(marker) == KafkaListener))
    {
        if (broker != Broker.kafka)
            return Error.init;
        enum topic = marker.topic;
        enum consumer = marker.group;
    }
    else
    {
        if (broker != Broker.natsJetStream)
            return Error.init;
        enum topic = marker.stream;
        enum consumer = marker.consumer;
    }
    static assert(topic.length && consumer.length, "MQ listener topic and consumer must be supplied: " ~ label);
    static if (typed)
    {
        auto listener = new Handler(component);
        return client.subscribe(topic, consumer, &listener.dispatch);
    }
    else
        return client.subscribe(topic, consumer, &__traits(getMember, component, label));
}

private final class ConvertedListener(T, Payload, string label)
{
    private T component;

    this(T component)
    {
        this.component = component;
    }

    AckAction dispatch(ref Message message, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        import flint.serde : decodeInto;

        Payload payload;
        Error decoded;
        const read = arena.read(message.payload, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            decoded = decodeInto(bytes, payload, arena);
        });
        if (read != Status.ok || decoded.code != Status.ok)
            return AckAction.reject;
        static assert(__traits(compiles, __traits(getMember, component, label)(payload, arena,
                context)), "MQ typed listener must accept payload, arena and context: " ~ label);
        return __traits(getMember, component, label)(payload, arena, context);
    }
}
