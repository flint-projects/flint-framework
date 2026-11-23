/// Owner-side waits for the isolated librdkafka worker.
module flint.engine.mq.kafka;

import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.mq.ffi.kafka : KafkaBridge, nativeError, pauseNative;
import flint.engine.mq.types : PublishReceipt;
import flint.engine.reactor : Reactor;

@safe:
package(flint.engine.mq):

Error waitTurn(ref scope const Context caller) nothrow @nogc
{
    const active = caller.check();
    if (active.code != Status.ok)
        return active;
    auto owner = Reactor.current();
    if (owner.currentCore() == uint.max)
        return pauseNative();
    return owner.yieldUntil(Deadline.afterMillis(1));
}

// dfmt off
Result!PublishReceipt confirm(ref KafkaBridge bridge, ulong token, ref scope const Context caller) nothrow @nogc
{
    for (;;)
    {
        const receipt = bridge.receipt(token);
        if (receipt.error.code != Status.unavailable)
            return receipt;
        const waited = waitTurn(caller);
        if (waited.code != Status.ok)
        {
            bridge.detach(token);
            return Result!PublishReceipt(PublishReceipt.init, nativeError(waited.code));
        }
    }
}
// dfmt on
