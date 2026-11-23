/// The wall clock on Windows, where std.datetime's clock is neither nothrow nor @nogc (ADR-026).
module flint.engine.storage.sys.clock;

@safe:

version (Windows)
{
    import core.sys.windows.winbase : FILETIME;

    // kernel32 since Windows 8; druntime does not declare it.
    private extern (Windows) void GetSystemTimePreciseAsFileTime(FILETIME* now) @system nothrow @nogc;

    /// Seconds since the Unix epoch.
    // SAFETY: GetSystemTimePreciseAsFileTime writes only the local FILETIME and retains no pointer to it.
    package(flint.engine.storage) long windowsUnixSeconds() @trusted nothrow @nogc
    {
        FILETIME now;
        GetSystemTimePreciseAsFileTime(&now);
        // FILETIME counts 100 ns units since 1601-01-01; the Unix epoch is 11644473600 s later.
        const units = (cast(ulong) now.dwHighDateTime << 32) | now.dwLowDateTime;
        return cast(long)(units / 10_000_000) - 11_644_473_600;
    }

    @("the Windows wall clock is in the Unix era and moves forward")
    nothrow @nogc unittest
    {
        const first = windowsUnixSeconds();
        assert(first > 1_700_000_000);
        assert(windowsUnixSeconds() >= first);
    }
}
