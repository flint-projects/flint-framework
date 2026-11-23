module unsafe_listener;

import flint.arena : Error, RequestArena;
import flint.conc : Context;
import flint.engine.mq : AckAction, KafkaListener, Message, QueueClient, registerListeners;

/// A component with a deliberately incompatible annotated method.
class Service
{
    /// Unsafe business code must not be admitted as an owner callback.
    @KafkaListener("orders", "business")
    AckAction receive(ref Message message, ref scope RequestArena arena, ref Context context) @system nothrow @nogc
    {
        return AckAction.ack;
    }
}

/// Instantiate the compile-time listener registration check.
@safe Error attach(ref QueueClient client, ref Service service)
{
    return registerListeners(client, service);
}
