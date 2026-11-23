/// Caller deadlines preserve ambiguous native ownership until the worker shuts down.
module drain_fixture;

import flint.arena : Status;
import flint.conc : Context, Deadline;
import flint.engine.mq : QueueClient, QueueOptions;
import std.stdio : writeln;

@safe:

int main(string[] arguments)
{
    if (arguments.length != 2)
        return 2;
    QueueOptions options;
    options.clientId = "flint-outage";
    options.endpoints = arguments[1];
    options.maxInFlight = 1;
    options.maxQueuedBytes = 1024;
    options.deliveryTimeoutNanos = 4_000_000_000L;
    QueueClient client;
    assert(client.open(options).code == Status.ok);
    auto deadline = Context.init.withDeadline(Deadline.afterMillis(50));
    const message = cast(const(ubyte)[]) "lost receipt";
    assert(client.publish("outage", null, message, "", deadline).error.code == Status.timedOut);
    Context live;
    assert(client.publish("outage", null, message, "", live).error.code == Status.resourceExhausted);
    auto draining = Context.init.withDeadline(Deadline.afterMillis(50));
    assert(client.drain(draining).code == Status.timedOut);
    assert(client.publish("outage", null, message, "", live).error.code == Status.conflict);
    assert(client.close().code == Status.ok);
    assert(client.close().code == Status.ok);
    writeln("caller timeout retained native slot, overload rejected, drain deadline returned and close joined worker");
    return 0;
}
