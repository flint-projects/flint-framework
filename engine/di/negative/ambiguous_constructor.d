/// Negative compiler fixture for ambiguous constructor.
module ambiguous_constructor;

import flint.arena : Error;
import flint.di : AppContext;

@safe:

private struct Config
{
}

private class Consumer
{
    this()
    {
    }

    this(Config)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Consumer, Config) context;
    return context.initialize();
}
