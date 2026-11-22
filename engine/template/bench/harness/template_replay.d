module template_replay;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.arena : Buffer, RequestArena, Result, Status;

@safe:

/// Render one assembled input through either arena implementation.
alias Render = Result!Buffer function(scope const(char)[], ref scope RequestArena) @safe nothrow @nogc;

/// Resolve an invariant even in an optimized binary.
void require(bool condition) pure nothrow @nogc
{
    if (!condition)
        assert(0, "template probe invariant failed");
}

/// Run the 100,000-iteration replay at both exact rendered sizes.
void benchmark(Render render, bool measure)
{
    enum tail = "ø<&'";
    enum escaped = "ø&lt;&amp;&#39;";
    enum frame = "<main></main>";
    enum repetitions = 100_000;
    foreach (length; [1_024, 65_536])
    {
        auto prefix = new char[length - frame.length - escaped.length];
        prefix[] = 'x';
        const input = (prefix ~ tail).idup;
        const expected = "<main>" ~ prefix ~ escaped ~ "</main>";
        auto bytes = new ubyte[length];
        scope arena = RequestArena(bytes);
        const before = GC.stats().allocatedInCurrentThread;
        const start = MonoTime.currTime;
        ulong consumed;
        foreach (_; 0 .. repetitions)
        {
            require(arena.reset() == Status.ok);
            const result = render(input, arena);
            require(result.ok() && result.value.length() == length);
            require(arena.read(result.value, (scope const(ubyte)[] got) @safe nothrow @nogc {
                    require(got == cast(const(ubyte)[]) expected);
                    consumed += got.length + got[6];
                }) == Status.ok);
        }
        const elapsed = (MonoTime.currTime - start).total!"msecs";
        const allocated = GC.stats().allocatedInCurrentThread - before;
        require(allocated == 0);
        report(length, repetitions, consumed, measure, elapsed, allocated);
    }
}

// SAFETY: Each C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(int length, int repetitions, ulong consumed, bool measure, long elapsed, ulong allocated) @trusted
{
    printf("template bytes=%d repetitions=%d checksum=%llu\n", length, repetitions, consumed);
    if (measure)
        printf("template elapsed_ms=%lld gc_bytes=%llu\n", elapsed, allocated);
}
