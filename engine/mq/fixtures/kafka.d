/// Correlated producer receipts and retry against an independent Kafka broker.
module kafka_fixture;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.engine.mq : AckAction, Broker, Message, QueueClient, QueueOptions;
import std.stdio : writeln;

@safe:

int main(string[] arguments)
{
    if (arguments.length != 4)
        return 2;
    QueueOptions settings;
    settings.broker = Broker.kafka;
    settings.endpoints = arguments[1];
    settings.clientId = "flint-live-interop";
    settings.maxInFlight = 8;
    settings.maxQueuedBytes = 128 * 1024;
    settings.deliveryTimeoutNanos = 8_000_000_000;
    QueueClient client;
    check(client.open(settings));
    auto context = Context.init.withDeadline(Deadline.afterMillis(20_000));
    const topic = arguments[3];
    auto component = new Component(topic);
    check(client.subscribe(topic, arguments[2], &component.receive));
    check(client.publish(topic, cast(const(ubyte)[]) "order-1", cast(const(ubyte)[]) `{"id":1}`, "order-1", context)
            .error);
    const second = client.publish(topic, cast(const(ubyte)[]) "order-2",
            cast(const(ubyte)[]) `{"id":2}`, "order-2", context);
    check(second.error);
    assert(second.value.offset >= 1 && second.value.partition == 0 && second.value.sequence == 2);
    while (component.handled < 3)
        check(client.poll(context));
    check(client.drain(context));
    check(client.close());
    check(client.close());
    assert(component.onceRetried != 0 && component.total == 3);
    writeln("Kafka receipts, local redelivery with unique token, processing and confirmed drain passed");
    return 0;
}

private final class Component
{
    string topic;
    ulong onceRetried;
    uint handled, total;

    this(string topic)
    {
        this.topic = topic;
    }

    AckAction receive(ref Message message, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        assert(context.check().code == Status.ok);
        assert(message.partition == 0 && message.deliveryToken != 0);
        assert(arena.read(message.topic.bytes, (scope const(ubyte)[] bytes) {
                assert(bytes == cast(const(ubyte)[]) topic);
            }) == Status.ok);
        ++handled;
        if (message.offset == 0 && onceRetried == 0)
        {
            onceRetried = message.deliveryToken;
            return AckAction.retry;
        }
        if (message.offset == 0)
            assert(message.deliveryToken != onceRetried);
        assert(arena.read(message.payload, (scope const(ubyte)[] bytes) {
                total += bytes == cast(const(ubyte)[]) `{"id":1}` ? 1 : 2;
            }) == Status.ok);
        return AckAction.ack;
    }
}

private void check(Error outcome)
{
    if (outcome.code != Status.ok)
    {
        writeln(outcome.code, " ", outcome.message);
        assert(0);
    }
}
