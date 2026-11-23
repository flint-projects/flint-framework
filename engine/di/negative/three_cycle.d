/// Negative compiler fixture for three cycle.
module three_cycle;

import flint.arena : Error;
import flint.engine.di : AppContext;

@safe:

private class Alpha
{
    this(Bravo)
    {
    }
}

private class Bravo
{
    this(Charlie)
    {
    }
}

private class Charlie
{
    this(Alpha)
    {
    }
}

/// Instantiation must reject this explicit context.
Error rejected()
{
    AppContext!(Alpha, Bravo, Charlie) context;
    return context.initialize();
}
