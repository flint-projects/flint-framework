/// Negative compiler fixture for incompatible binding.
module incompatible_binding;

import flint.arena : Error;
import flint.engine.di : AppContext, Bind;

@safe:

private interface Contract
{
}

private class Service
{
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Bind!(Contract, Service)) context;
    return context.initialize();
}
