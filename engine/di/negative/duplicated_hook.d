/// Negative compiler fixture for duplicated hook.
module duplicated_hook;

import flint.arena : Error;
import flint.di : AppContext, PostConstruct;

@safe:

private class Worker
{
    @PostConstruct void first()
    {
    }

    @PostConstruct void second()
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
