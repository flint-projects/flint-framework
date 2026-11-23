/// Reject access to a key outside the explicit registration list.
module unregistered_provide;

import flint.arena : Error;
import flint.engine.di : AppContext;

@safe:

/// Unconfigured dependency key for the negative fixture.
struct Unknown
{
}

private struct Known
{
}

/// Instantiation must reject the unregistered type.
Error rejected()
{
    AppContext!Known context;
    return context.provide(Unknown.init);
}
