/// Verify real JetStream acknowledgements, deduplication and redelivery.
module jetstream_fixture;

import core.lifetime : move;
import flint.arena : Error, RequestArena, Status, Text;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.mq : AckAction, Broker, Message, QueueClient, QueueOptions, StreamListener, registerListeners;
import std.stdio : writeln;

version (FlintMqFixtureSqlite) import sqlite_effect : Effects;

@safe:

int main(string[] arguments)
{
    if (arguments.length < 2 || arguments.length > 3)
        return 2;
    QueueOptions settings;
    settings.broker = Broker.natsJetStream;
    settings.endpoints = arguments[1];
    settings.clientId = "flint-integration";
    settings.maxInFlight = 8;
    settings.maxQueuedBytes = 64 * 1024;
    settings.deliveryTimeoutNanos = 2_000_000_000;
    settings.deadLetterTopic = "flint.dead";
    settings.confirmedAcks = true;
    if (arguments.length == 3 && arguments[2] != "--untrusted")
        settings.caBundle = arguments[2];

    QueueClient client;
    const opened = client.open(settings);
    if (arguments.length == 3 && arguments[2] == "--untrusted")
    {
        assert(opened.code == Status.permissionDenied);
        writeln("untrusted JetStream TLS peer rejected");
        return 0;
    }
    check(opened);
    auto limit = Context.init.withDeadline(Deadline.afterMillis(15_000));
    auto action = new Consumer;
    version (FlintMqFixtureSqlite)
        assert(action.database.open());
    scope (exit)
    {
        version (FlintMqFixtureSqlite)
            assert(action.database.close());
    }
    check(registerListeners(client, action));
    const payload = cast(const(ubyte)[]) "A\r\nB";
    const key = cast(const(ubyte)[]) "ship";
    const admitted = client.publish("flint.orders", key, payload, "order-1", limit);
    check(admitted.error);
    const duplicate = client.publish("flint.orders", key, payload, "order-1", limit);
    check(duplicate.error);
    assert(admitted.value.sequence == duplicate.value.sequence && admitted.value.sequence == 1);
    check(client.publish("flint.orders", key, cast(const(ubyte)[]) "to-dead", "order-2", limit).error);

    auto source = CancelSource.create(limit, Deadline.none());
    check(source.error);
    move(source.value, action.cancelFirst);
    auto firstContext = action.cancelFirst.context();
    for (;;)
    {
        const polled = client.poll(firstContext);
        if (polled.code == Status.cancelled)
            break;
        check(polled);
    }
    assert(action.effects == 1 && action.attempts == 1);
    check(client.close());
    check(client.open(settings));
    check(registerListeners(client, action));
    while (action.attempts < 3)
        check(client.poll(limit));
    assert(action.effects == 1 && action.rejected == 1);
    verifyTyped(client, limit);
    check(client.drain(limit));
    check(client.close());
    writeln("JetStream deduplication, lost-ack redelivery, idempotent dispatch, AckSync and dead-letter passed");
    version (FlintMqFixtureSqlite)
        writeln("SQLite primary-key effect was attempted twice and inserted exactly once");
    return 0;
}

private final class Consumer
{
    version (FlintMqFixtureSqlite) Effects database;
    CancelSource cancelFirst;
    uint attempts, effects, rejected;

    @StreamListener("ORDERS", "flint")
    AckAction receive(ref Message message, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        assert(context.check().code == Status.ok);
        ++attempts;
        assert(message.partition == -1 && message.deliveryToken != 0);
        assert(arena.read(message.key, (scope const(ubyte)[] bytes) {
                assert(bytes == cast(const(ubyte)[]) "ship");
            }) == Status.ok);
        if (message.offset == 2)
        {
            ++rejected;
            return AckAction.reject;
        }
        assert(message.offset == 1);
        assert(arena.read(message.payload, (scope const(ubyte)[] bytes) {
                assert(bytes == cast(const(ubyte)[]) "A\r\nB");
            }) == Status.ok);
        version (FlintMqFixtureSqlite)
        {
            const changed = database.insert(message.offset);
            assert(changed == 0 || changed == 1);
            effects += changed;
        }
        else
        {
            if (effects == 0)
                ++effects;
        }
        if (attempts == 1)
            cancelFirst.cancel();
        return AckAction.ack;
    }
}

private struct Event
{
    uint id;
    Text name;
}

private final class TypedConsumer
{
    uint last;
    uint attempts;

    @StreamListener("TYPES", "typed")
    AckAction decode(ref Event event, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        assert(context.check().code == Status.ok);
        const read = arena.read(event.name.bytes, (scope const(ubyte)[] bytes) {
            assert(bytes == cast(const(ubyte)[]) "typed-delivery");
        });
        assert(read == Status.ok);
        if (++attempts == 1)
            return AckAction.retry;
        last = event.id;
        return AckAction.ack;
    }
}

private void verifyTyped(ref QueueClient client, ref Context context)
{
    auto typed = new TypedConsumer;
    check(registerListeners(client, typed));
    const payload = cast(const(ubyte)[]) `{"id":7,"name":"typed-delivery"}`;
    check(client.publish("flint.types", null, payload, "type-7", context).error);
    while (typed.last == 0)
        check(client.poll(context));
    assert(typed.last == 7 && typed.attempts == 2);
    writeln("compiled typed listener decoded the live broker payload after -NAK redelivery");
}

private void check(Error outcome, size_t line = __LINE__)
{
    if (outcome.code != Status.ok)
    {
        writeln(line, ": ", outcome.code, " ", outcome.message);
        assert(0);
    }
}
