/++
Java's `System.currentTimeMillis()` without `std.datetime`, whose `Clock` instantiates its templates in every module
that asks for the time (ADR-030 section 5).
+/
module flint.engine.aot.clock;

import flint.engine.aot.sys.clock : epochMillis;

@safe:

/// Milliseconds since 1970-01-01T00:00Z, as `System.currentTimeMillis()`; 0 if the wall clock is unavailable.
long currentTimeMillis() nothrow @nogc
{
    const millis = epochMillis();
    return millis < 0 ? 0 : millis;
}

unittest
{
    // 2026-01-01T00:00Z: any working clock reads later.
    assert(currentTimeMillis() > 1_767_225_600_000);
}
