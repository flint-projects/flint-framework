module escaped_delivery;

import flint.arena : RequestArena, Status;
import flint.conc : Context;
import flint.mq : AckAction, Message;

@safe:

private const(ubyte)[] escaped;

/// This consumer is rejected because the delivery bytes escape its visitor.
AckAction consume(ref Message message, ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    const borrowed = arena.read(message.payload, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        escaped = bytes;
    });
    return borrowed == Status.ok ? AckAction.ack : AckAction.retry;
}
