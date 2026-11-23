/// Flint producer probe against a verified durable Kafka fixture.
module app;

import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.engine.mq : QueueClient, QueueOptions;
import workload : measure;

@safe:

int main(string[] arguments)
{
    if (arguments.length != 2)
        return 2;
    QueueOptions settings;
    settings.endpoints = arguments[1];
    settings.clientId = "flint-mq-bench";
    QueueClient kafka;
    if (kafka.open(settings).code != Status.ok)
        return 3;
    scope (exit)
        kafka.close();
    Context context;
    const outcome = measure((string topic, scope const(ubyte)[] key, scope const(ubyte)[] payload) {
        const receipt = kafka.publish(topic, key, payload, "", context);
        return receipt.ok() && receipt.value.partition >= 0 && receipt.value.offset >= 0;
    });
    auto ending = context.withDeadline(Deadline.afterMillis(1000));
    return kafka.drain(ending).code == Status.ok ? outcome : 4;
}
