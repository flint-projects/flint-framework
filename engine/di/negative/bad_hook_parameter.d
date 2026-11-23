/// Negative compiler fixture for bad hook parameter.
module bad_hook_parameter;

import flint.arena : Error;
import flint.engine.di : AppContext, PostConstruct;

@safe:

private class Worker
{
    @PostConstruct
    void start(uint)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker) context;
    return context.initialize();
}
