/// Negative compiler fixture for hidden hook.
module hidden_hook;

import flint.arena : Error;
import flint.engine.di : AppContext, PostConstruct;

@safe:

private class Worker
{
    @PostConstruct private void start()
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
