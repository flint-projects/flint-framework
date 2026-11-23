/// Negative compiler fixture for duplicate service.
module duplicate_service;

import flint.arena : Error;
import flint.engine.di : AppContext, BeanRegistrar;

@safe:

private class Worker
{
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Worker, BeanRegistrar!Worker) context;
    return context.initialize();
}
