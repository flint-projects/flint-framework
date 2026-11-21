/// Negative compiler fixture for multiple inject.
module multiple_inject;

import flint.arena : Error;
import flint.di : AppContext, Inject;

@safe:

private struct Config
{
}

private class Consumer
{
    @Inject this()
    {
    }

    @Inject this(Config)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Consumer, Config) context;
    return context.initialize();
}
