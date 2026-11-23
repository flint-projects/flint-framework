module invalid_cron;

import flint.arena : Error;
import flint.conc : Context;
import flint.engine.schedule : Scheduled, Scheduler, registerScheduled;

@safe:

/// Intentionally invalid annotated component.
final class MalformedCalendar
{
    /// Compile-fail fixture entry.
    @Scheduled("60 0 0 * * *") Error invoke(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}

/// Force the registration instantiation.
void reject(ref Scheduler scheduler, MalformedCalendar component)
{
    registerScheduled(scheduler, component);
}
