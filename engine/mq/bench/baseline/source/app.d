/// Equivalent producer workload using only the pinned upstream librdkafka ABI.
module app;

import flint.conc : Deadline;
import std.string : toStringz;
import workload : measure;

private struct Broker;
private struct Configuration;
private struct Topic;
private struct Event
{
    int status;
    Topic* topic;
    int partition;
    void* payload;
    size_t payloadBytes;
    void* key;
    size_t keyBytes;
    long offset;
    void* opaque;
}

private struct Receipt
{
    bool complete;
    bool success;
}

extern (C) private @system nothrow @nogc
{
    alias Delivery = void function(Broker*, const(Event)*, void*) nothrow @nogc;
    Configuration* rd_kafka_conf_new();
    void rd_kafka_conf_destroy(Configuration*);
    int rd_kafka_conf_set(Configuration*, const(char)*, const(char)*, char*, size_t);
    void rd_kafka_conf_set_opaque(Configuration*, void*);
    void rd_kafka_conf_set_dr_msg_cb(Configuration*, Delivery);
    Broker* rd_kafka_new(int, Configuration*, char*, size_t);
    void rd_kafka_destroy(Broker*);
    Topic* rd_kafka_topic_new(Broker*, const(char)*, void*);
    void rd_kafka_topic_destroy(Topic*);
    int rd_kafka_produce(Topic*, int, int, void*, size_t, const(void)*, size_t, void*);
    int rd_kafka_poll(Broker*, int);
    int rd_kafka_flush(Broker*, int);

    void confirm(Broker*, const(Event)* event, void* user)
    {
        auto receipt = cast(Receipt*) user;
        receipt.complete = true;
        receipt.success = event.status == 0 && event.partition >= 0 && event.offset >= 0;
    }
}

int main(string[] arguments) @system
{
    if (arguments.length != 2)
        return 2;
    Receipt receipt;
    auto configuration = rd_kafka_conf_new();
    if (!options(configuration, arguments[1]))
    {
        rd_kafka_conf_destroy(configuration);
        return 3;
    }
    rd_kafka_conf_set_opaque(configuration, &receipt);
    rd_kafka_conf_set_dr_msg_cb(configuration, &confirm);
    auto broker = rd_kafka_new(0, configuration, null, 0);
    if (!broker)
    {
        rd_kafka_conf_destroy(configuration);
        return 3;
    }
    scope (exit)
        rd_kafka_destroy(broker);
    auto first = rd_kafka_topic_new(broker, "flint-bench-1", null);
    scope (exit)
        rd_kafka_topic_destroy(first);
    auto second = rd_kafka_topic_new(broker, "flint-bench-16", null);
    scope (exit)
        rd_kafka_topic_destroy(second);
    return exercise(broker, first, second, receipt);
}

private bool options(Configuration* config, string origin) @system
{
    return rd_kafka_conf_set(config, "bootstrap.servers", origin.toStringz(), null, 0) == 0
        && rd_kafka_conf_set(config, "client.id",
                "flint-mq-bench", null, 0) == 0 && rd_kafka_conf_set(config, "log_level", "0", null, 0) == 0
        && rd_kafka_conf_set(config, "enable.idempotence", "true", null, 0) == 0
        && rd_kafka_conf_set(config, "acks", "all", null,
                0) == 0 && rd_kafka_conf_set(config, "message.copy.max.bytes", "0", null, 0) == 0
        && rd_kafka_conf_set(config, "queue.buffering.max.messages", "1024", null, 0) == 0
        && rd_kafka_conf_set(config, "queue.buffering.max.kbytes",
                "16384", null, 0) == 0 && rd_kafka_conf_set(config, "delivery.timeout.ms", "30000", null, 0) == 0;
}

private int exercise(Broker* broker, Topic* first, Topic* second, ref Receipt receipt) @system
{
    if (!first || !second)
        return 3;
    // SAFETY: The producer copies bounded input and the stack receipt remains live until final flush/destroy.
    const outcome = measure((string topic, scope const(ubyte)[] key, scope const(ubyte)[] bytes) @trusted {
        receipt = Receipt.init;
        auto selected = topic == "flint-bench-1" ? first : second;
        if (rd_kafka_produce(selected, -1, 2, cast(void*) bytes.ptr, bytes.length, key.ptr, key.length, null) != 0)
            return false;
        const limit = Deadline.afterMillis(30_000);
        while (!receipt.complete && Deadline.afterMillis(0).monotonicNanoseconds < limit.monotonicNanoseconds)
            if (rd_kafka_poll(broker, 5) < 0)
                return false;
        return receipt.complete && receipt.success;
    });
    return rd_kafka_flush(broker, 1000) == 0 ? outcome : 4;
}
