/// Negative compiler fixture for self cycle.
module self_cycle;

import flint.arena : Error;
import flint.di : AppContext;

@safe:

private class Worker
{
    this(Worker)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
