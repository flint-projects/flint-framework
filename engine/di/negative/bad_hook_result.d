/// Negative compiler fixture for bad hook result.
module bad_hook_result;

import flint.arena : Error;
import flint.engine.di : AppContext, PostConstruct;

@safe:

private class Worker
{
    @PostConstruct uint start()
    {
        return 0;
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
