module negative_period;

import flint.arena : Error;
import flint.conc : Context;
import flint.engine.schedule : Scheduled, Scheduler, registerScheduled;

@safe:

/// Intentionally invalid annotated component.
final class NegativeDelay
{
    /// Compile-fail fixture entry.
    @Scheduled(null, 0, -10)
    Error invoke(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}

/// Force the registration instantiation.
void reject(ref Scheduler scheduler, NegativeDelay component)
{
    registerScheduled(scheduler, component);
}
