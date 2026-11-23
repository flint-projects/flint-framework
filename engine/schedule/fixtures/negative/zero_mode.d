module zero_mode;

import flint.arena : Error;
import flint.conc : Context;
import flint.engine.schedule : Scheduled, Scheduler, registerScheduled;

@safe:

/// Intentionally invalid annotated component.
final class MissingMode
{
    /// Compile-fail fixture entry.
    @Scheduled() Error invoke(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}

/// Force the registration instantiation.
void reject(ref Scheduler scheduler, MissingMode component)
{
    registerScheduled(scheduler, component);
}
