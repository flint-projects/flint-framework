/// Per-thread allocation counter for the fixed native benchmark.
module sys.allocation;

import core.memory : GC;

@safe:

/// Return the cumulative allocated D GC bytes on the calling thread.
// SAFETY: The druntime entry point reads a scalar from its own current thread.
ulong gcBytes() @trusted nothrow
{
    return GC.allocatedInCurrentThread();
}
