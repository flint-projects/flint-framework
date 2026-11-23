/++
Java's `System.currentTimeMillis()` without `std.datetime`, whose `Clock` instantiates its templates in every module
that asks for the time (ADR-030 section 5).
+/
module flint.engine.aot.clock;

import flint.engine.aot.sys.clock : epochTicks;

@safe:

/// Milliseconds since 1970-01-01T00:00Z, as `System.currentTimeMillis()`; 0 if the wall clock is unavailable.
long currentTimeMillis() nothrow @nogc
{
    return currentTimeTicks() / 10_000;
}

/++
100 ns ticks since 1970-01-01T00:00Z, the resolution of std.datetime's `Clock.currStdTime` (which counts from
0001-01-01); 0 if the wall clock is unavailable. `Instant.now()` splits it into seconds and nanoseconds.
+/
long currentTimeTicks() nothrow @nogc
{
    const ticks = epochTicks();
    return ticks < 0 ? 0 : ticks;
}

unittest
{
    // 2026-01-01T00:00Z: any working clock reads later.
    assert(currentTimeMillis() > 1_767_225_600_000);
    assert(currentTimeTicks() > 17_672_256_000_000_000);
}
