module forge_lease;

import flint.sql : Connection;

@safe:

/// Attempt to rewrite an opaque lease's generation.
Connection forgeLease()
{
    Connection lease;
    lease.generation = 1;
    return lease;
}
