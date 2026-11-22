/// Narrow private bindings to the pinned librdkafka shim.
module flint.mq.ffi.kafka;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.mq.types : AckAction, Message, PublishReceipt, QueueOptions;

@safe:

private struct NativeClient;

private struct Settings
{
    const(char)* brokers;
    const(char)* clientId;
    const(char)* caBundle;
    ulong deliveryMs;
    size_t byteLimit;
    uint slots;
    ubyte tls;
}

private struct Receipt
{
    long offset;
    int partition;
    int status;
    ulong token;
}

private struct Delivery
{
    ubyte* storage;
    size_t capacity, topicBytes, keyBytes, payloadBytes;
    ulong token;
    long offset;
    int partition;
    uint listener;
}

extern (C) private @system nothrow @nogc
{
    int flint_kafka_open(scope const Settings*, scope NativeClient**);
    int flint_kafka_produce_id(NativeClient*, scope const(char)*, scope const(ubyte)*, size_t,
            scope const(ubyte)*, size_t, scope const(char)*, ulong);
    int flint_kafka_receipt_take(NativeClient*, ulong, scope Receipt*);
    int flint_kafka_receipt_detach(NativeClient*, ulong);
    int flint_kafka_subscribe(NativeClient*, scope const(char)*, scope const(char)*, uint);
    int flint_kafka_take(NativeClient*, scope Delivery*);
    int flint_kafka_decide(NativeClient*, ulong, ubyte);
    int flint_kafka_drain_begin(NativeClient*);
    int flint_kafka_flush(NativeClient*, int);
    void flint_kafka_free(NativeClient*);
}

version (linux) version (FlintNativeLibrdkafka) version = FlintKafkaOnLinux;
version (OSX) version (FlintNativeLibrdkafka) version = FlintKafkaOnLinux; // ADR-024
version (FlintKafkaOnLinux)
    private enum available = true;
else
    private enum available = false;

    package(flint.mq):

    alias Dispatch = Result!AckAction delegate(uint, ref Message, ref scope RequestArena) @safe nothrow @nogc;

struct KafkaBridge
{
    private NativeClient* handle;

nothrow @nogc:

    Error open(scope const ref QueueOptions options, scope const(char)[] brokers, bool tls)
    {
        char[2049] addresses, bundle;
        char[129] identity;
        if (!terminated(brokers, addresses[]) || !terminated(options.clientId, identity[])
                || !terminated(options.caBundle, bundle[]))
            return Error(Status.invalidArgument, "invalid Kafka endpoints, client id or CA path");
        const span = cast(ulong) options.deliveryTimeoutNanos;
        const milliseconds = span / 1_000_000 + (span % 1_000_000 != 0);
        scope settings = Settings(&addresses[0], &identity[0], options.caBundle.length
                ? &bundle[0] : null, milliseconds, options.maxQueuedBytes, options.maxInFlight, cast(ubyte) tls);
        return openNative(settings);
    }

    // SAFETY: Stack strings are copied during setup. Only an opaque C-owned worker handle is retained.
    @trusted private Error openNative(scope const ref Settings settings)
    {
        static if (available)
            return nativeError(flint_kafka_open(&settings, &handle));
        else
            return nativeError(Status.unsupported);
    }

    Error submit(scope const(char)[] topic, scope const(ubyte)[] key, scope const(ubyte)[] payload,
            scope const(char)[] dedup, ulong token) scope
    {
        char[250] destination;
        char[129] identity;
        if (!terminated(topic, destination[]) || !terminated(dedup, identity[]))
            return nativeError(Status.invalidArgument);
        return nativeError(invoke!flint_kafka_produce_id(handle, &destination[0], key.length
                ? &key[0] : null, key.length, payload.length ? &payload[0] : null, payload.length,
                dedup.length ? &identity[0] : null, token));
    }

    Result!PublishReceipt receipt(ulong token) scope
    {
        Receipt response;
        const state = invoke!flint_kafka_receipt_take(handle, token, &response);
        if (state != Status.ok)
            return Result!PublishReceipt(PublishReceipt.init, nativeError(state));
        return Result!PublishReceipt(PublishReceipt(response.partition, response.offset,
                response.token), nativeError(response.status));
    }

    void detach(ulong token) scope
    {
        invoke!flint_kafka_receipt_detach(handle, token);
    }

    Error subscribe(scope const(char)[] topic, scope const(char)[] group, uint listener) scope
    {
        char[250] destination;
        char[129] identity;
        if (!terminated(topic, destination[]) || !terminated(group, identity[]))
            return nativeError(Status.invalidArgument);
        return nativeError(invoke!flint_kafka_subscribe(handle, &destination[0], &identity[0], listener));
    }

    Error deliver(scope Dispatch action) scope
    {
        Delivery incoming;
        const pending = invoke!flint_kafka_take(handle, &incoming);
        if (pending != Status.ok)
            return nativeError(pending);
        const result = dispatch(incoming, action);
        const decision = result.ok() && result.value == AckAction.ack ? AckAction.ack : AckAction.retry;
        const accepted = invoke!flint_kafka_decide(handle, incoming.token, cast(ubyte) decision);
        return result.ok() ? nativeError(accepted) : result.error;
    }

    Error beginDrain() scope
    {
        return nativeError(invoke!flint_kafka_drain_begin(handle));
    }

    Error flushed() scope
    {
        return nativeError(invoke!flint_kafka_flush(handle, 0));
    }

    // SAFETY: The owner has retired all visiting calls; native shutdown joins the worker before freeing its storage.
    @trusted void close() scope
    {
        static if (available)
            flint_kafka_free(handle);
        handle = null;
    }
}

// SAFETY: Only a held, bounds-checked native delivery is leased to the synchronous @safe visitor.
// The worker keeps it live across revocation and runs no D callback. decide ends the visit before freeing bytes.
private Result!AckAction dispatch(scope Delivery incoming, scope Dispatch action) @trusted nothrow @nogc
{
    const size_t[3] sizes = [incoming.topicBytes, incoming.keyBytes, incoming.payloadBytes];
    if (incoming.storage is null || incoming.capacity > 16 * 1024 * 1024 || incoming.topicBytes > 249)
        return Result!AckAction(AckAction.retry, nativeError(Status.ioError));
    foreach (bytes; sizes)
        if (bytes > incoming.capacity)
            return Result!AckAction(AckAction.retry, nativeError(Status.ioError));
    const keyAt = (incoming.topicBytes + 7) & ~cast(size_t) 7;
    const bodyAt = keyAt + ((incoming.keyBytes + 7) & ~cast(size_t) 7);
    if (bodyAt > incoming.capacity || incoming.payloadBytes > incoming.capacity - bodyAt)
        return Result!AckAction(AckAction.retry, nativeError(Status.ioError));
    return visit(incoming, incoming.storage[0 .. incoming.capacity], keyAt, bodyAt, action);
}

private Result!AckAction visit(scope Delivery incoming, scope ubyte[] bytes, size_t keyAt,
        size_t bodyAt, scope Dispatch action) nothrow @nogc
{
    auto arena = RequestArena(bytes);
    const topic = arena.copyIn(bytes[0 .. incoming.topicBytes]);
    const key = arena.copyIn(bytes[keyAt .. keyAt + incoming.keyBytes]);
    const payload = arena.copyIn(bytes[bodyAt .. bodyAt + incoming.payloadBytes]);
    if (!topic.ok() || !key.ok() || !payload.ok())
        return Result!AckAction(AckAction.retry, nativeError(Status.ioError));
    Message message = Message(Text(topic.value), key.value, payload.value, incoming.offset,
            incoming.partition, incoming.token);
    return action(incoming.listener, message, arena);
}

bool terminated(scope const(char)[] value, scope char[] output) pure nothrow @nogc
{
    if (value.length >= output.length)
        return false;
    foreach (byteValue; value)
        if (byteValue == 0)
            return false;
    output[0 .. value.length] = value[];
    output[value.length] = 0;
    return true;
}

// SAFETY: Typed callers supply bounded pointers; native calls copy immediately or return scalar results.
// No worker receives a D callback or pointer to caller-owned storage.
private Status invoke(alias fn, Args...)(scope Args arguments) @trusted nothrow @nogc
{
    static if (available)
        return cast(Status) fn(arguments);
    else
        return Status.unsupported;
}

private Error nativeError(int value) pure nothrow @nogc
{
    return nativeError(cast(Status) value);
}

Error nativeError(Status status) pure nothrow @nogc
{
    static immutable string[] messages = [
        "", "invalid broker operation", "broker storage exhausted", "broker operation cancelled",
        "broker receipt timed out; operation outcome may be ambiguous", "broker token unavailable",
        "broker operation conflicted with its owner or generation", "broker operation failed",
        "broker operation pending", "pinned broker provider is unavailable",
        "broker rejected credentials or access", "broker queue limit exceeded"
    ];
    const index = cast(uint) status;
    if (index >= messages.length)
        return Error(Status.ioError, "unrecognized broker status");
    return status == Status.ok ? Error.init : Error(status, messages[index]);
}

Error pauseNative() nothrow @nogc
{
    import flint.mq.ffi.socket : pauseSocket;

    return pauseSocket();
}
