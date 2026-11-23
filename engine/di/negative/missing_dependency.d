/// Negative compiler fixture for missing dependency.
module missing_dependency;

import flint.arena : Error;
import flint.engine.di : AppContext;

@safe:

private struct Missing
{
}

private class Consumer
{
    this(Missing)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Consumer) context;
    return context.initialize();
}
