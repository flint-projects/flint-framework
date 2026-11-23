module multiple_modes;

import flint.arena : Error;
import flint.conc : Context;
import flint.engine.schedule : Scheduled, Scheduler, registerScheduled;

@safe:

/// Intentionally invalid annotated component.
final class ConflictingModes
{
    /// Compile-fail fixture entry.
    @Scheduled("* * * * * *", 10) Error invoke(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}

/// Force the registration instantiation.
void reject(ref Scheduler scheduler, ConflictingModes component)
{
    registerScheduled(scheduler, component);
}
