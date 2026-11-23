/// Ending the process when a forced shutdown cannot stop the server (ADR-028 section 10).
module flint.web.sys.exit;

@safe:

// SAFETY: Flushes the C streams and ends the process without D's module destructors, because a thread that ignored
// cancellation still uses the server; only runApplication calls it, as its final act, and nothing returns.
package(flint.web) void exitNow(int code) @trusted nothrow @nogc
{
    import core.stdc.stdio : fflush;
    import core.stdc.stdlib : _Exit;

    fflush(null);
    _Exit(code);
}
