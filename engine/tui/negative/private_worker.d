module private_worker;

import flint.engine.tui.sys.worker : launch, park, wake;

@safe:

private bool invalid()
{
    return launch(() @safe nothrow{});
}
