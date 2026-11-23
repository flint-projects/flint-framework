/// Broker-neutral messaging options and delivery values.
module flint.engine.mq.types;

import flint.arena : Buffer, RequestArena, Text;
import flint.conc : Context;

@safe:

/// Bind a method to a Kafka topic and consumer group.
struct KafkaListener
{
    /// Topic subscribed by the listener.
    string topic;
    /// Kafka consumer-group identity.
    string group;
}

/// Bind a method to a provisioned JetStream pull consumer.
struct StreamListener
{
    /// Stream name.
    string stream;
    /// Durable pull-consumer name.
    string consumer;
}

/// Provider selected for a queue client.
enum Broker : ubyte
{
    kafka,
    natsJetStream
}

/// The decision returned after handling one delivery.
enum AckAction : ubyte
{
    /// Confirm successfully handled work.
    ack,
    /// Preserve the message for redelivery.
    retry,
    /// Publish to the configured dead-letter destination before acknowledging.
    reject
}

/// Handle-backed fields from the active delivery arena and a generation-checked receipt token.
struct Message
{
    /// Kafka topic or original NATS subject.
    Text topic;
    /// Optional application key.
    Buffer key;
    /// Serialized message body.
    Buffer payload;
    /// Kafka offset or JetStream sequence when representable.
    long offset;
    /// Kafka partition. JetStream uses -1.
    int partition;
    /// Identity for the current handling attempt.
    ulong deliveryToken;
}

/// Startup options and memory budgets for one logical owner and its broker.
struct QueueOptions
{
    /// Provider.
    Broker broker;
    /// Kafka bootstrap servers or one absolute nats:// or tls:// endpoint.
    string endpoints;
    /// Broker-visible client identity.
    string clientId;
    /// Number of admitted delivery and publish slots per direction.
    uint maxInFlight = 1024;
    /// Combined queue payload and per-delivery arena budget in bytes.
    size_t maxQueuedBytes = 16 * 1024 * 1024;
    /// Receipt deadline measured on the process monotonic clock.
    long deliveryTimeoutNanos = 30_000_000_000L;
    /// Optional TLS CA bundle; an absent path uses the platform trust store.
    string caBundle;
    /// Optional Kafka topic or NATS subject to receive rejected deliveries.
    string deadLetterTopic;
    /// Request broker confirmation of JetStream acknowledgements.
    bool confirmedAcks;
}

/// Broker acknowledgement associated with one admitted publish.
struct PublishReceipt
{
    /// Kafka partition or -1 for JetStream.
    int partition;
    /// Kafka offset or -1 for JetStream.
    long offset;
    /// JetStream stream sequence or unique local Kafka publish token.
    ulong sequence;
}

/// Receives one live delivery and explicitly chooses its acknowledgement outcome.
// dfmt off
alias MessageHandler = AckAction delegate(ref Message message, ref scope RequestArena arena,
        ref Context context) @safe nothrow @nogc;
// dfmt on
