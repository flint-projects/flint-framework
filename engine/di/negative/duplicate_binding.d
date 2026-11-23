/// Negative compiler fixture for duplicate binding.
module duplicate_binding;

import flint.arena : Error;
import flint.engine.di : AppContext, Bind;

@safe:

private interface Contract
{
}

private class ServiceA : Contract
{
}

private class ServiceB : Contract
{
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Bind!(Contract, ServiceA), Bind!(Contract, ServiceB)) context;
    return context.initialize();
}
