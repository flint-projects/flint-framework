/// Reject access to a key outside the explicit registration list.
module unregistered_get;

import flint.arena : Error;
import flint.di : AppContext;

@safe:

/// Unconfigured dependency key for the negative fixture.
struct Unknown
{
}

private struct Known
{
}

/// Instantiation must reject the unregistered type.
Unknown rejected()
{
    AppContext!Known context;
    return context.get!Unknown();
}
