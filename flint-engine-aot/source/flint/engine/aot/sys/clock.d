/++
The wall clock behind `flint.engine.aot.clock`, as flint:log reads it (`flint.log.sys.clock`).
Private to `flint:engine-aot`; applications never import it.
+/
module flint.engine.aot.sys.clock;

@safe:

version (Windows)
{
    import core.sys.windows.winbase : FILETIME;

    private extern (Windows) void GetSystemTimePreciseAsFileTime(FILETIME* time) nothrow @nogc @system;

    /// 100 ns ticks since 1970-01-01T00:00Z, or -1 if the clock reads before the epoch.
    // SAFETY: GetSystemTimePreciseAsFileTime only writes into the local FILETIME.
    @trusted long epochTicks() nothrow @nogc
    {
        enum ulong unixEpoch = 116_444_736_000_000_000; // 1970-01-01 in 100 ns ticks since 1601-01-01.
        FILETIME clock;
        GetSystemTimePreciseAsFileTime(&clock);
        const ticks = (cast(ulong) clock.dwHighDateTime << 32) | clock.dwLowDateTime;
        return ticks < unixEpoch ? -1 : cast(long)(ticks - unixEpoch);
    }
}
else
{
    version (OSX)
    {
        import core.sys.posix.time : timespec;

        // macOS 10.12+ <time.h>: clockid_t is a C enum (int ABI) and CLOCK_REALTIME is 0.
        private enum int CLOCK_REALTIME = 0;
        private extern (C) int clock_gettime(int clock, timespec* value) @system nothrow @nogc;
    }
    else
        import core.sys.posix.time : CLOCK_REALTIME, clock_gettime, timespec;

    /// 100 ns ticks since 1970-01-01T00:00Z, or -1 if the clock is unavailable or reads before the epoch.
    // SAFETY: clock_gettime only writes into the local typed timespec.
    @trusted long epochTicks() nothrow @nogc
    {
        timespec clock;
        if (clock_gettime(CLOCK_REALTIME, &clock) != 0 || clock.tv_sec < 0)
            return -1;
        return cast(long) clock.tv_sec * 10_000_000 + cast(long) clock.tv_nsec / 100;
    }
}

unittest
{
    import std.datetime.systime : Clock;

    // Positive: agrees with std.datetime's clock to within the time between the two reads.
    enum long unixEpochInHnsecs = 621_355_968_000_000_000;
    const before = Clock.currStdTime - unixEpochInHnsecs;
    const now = epochTicks();
    const after = Clock.currStdTime - unixEpochInHnsecs;
    assert(before <= now && now <= after);
    // Negative: never the failure value on a working clock, and never decreasing between two reads.
    assert(now != -1 && epochTicks() >= now);
}
