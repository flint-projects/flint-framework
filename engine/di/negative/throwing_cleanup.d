/// Negative compiler fixture for throwing cleanup.
module throwing_cleanup;

import flint.arena : Error;
import flint.engine.di : AppContext, PreDestroy;

@safe:

private class Worker
{
    @PreDestroy
    void stop()
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
