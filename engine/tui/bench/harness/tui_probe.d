/// Shared transition inputs and independently consumed terminal output.
module tui_probe;

import core.memory : GC;
import core.time : MonoTime;
import flint.arena : Error;
import flint.term : Event, EventKind, KeyCode, Size;
import std.algorithm.sorting : sort;
import std.stdio : writeln;

@safe:

/// One fixed grapheme workload on either terminal size.
enum header = "界 e\u0301";
/// Terminal cells occupied by the header.
enum headerCells = 4;
/// Model updates included in each replay.
enum transitions = 10_000;

/// Ordinary model state for the equivalent rendering paths.
struct Model
{
    private uint offset;

    /// Process one typed transition.
    void update(Event event) pure nothrow @nogc
    {
        if (event.kind == EventKind.key && event.key.code == KeyCode.character)
            offset = (offset + 1) % 26;
    }

    /// Return one ASCII cell from the fixed stimulus.
    string letter() const pure nothrow @nogc
    {
        enum alphabet = "abcdefghijklmnopqrstuvwxyz";
        return alphabet[offset .. offset + 1];
    }
}

/// Stream one rendered frame to an observing sink.
alias Emit = Error delegate(scope const(char)[]) @safe;
/// Drive a retained renderer with newly updated model state.
alias Paint = void delegate(ref const Model, scope Emit) @safe;
/// Allocate the terminal surfaces for one replay.
alias Setup = Paint function(Size) @safe;

/// Verify a fixture invariant in an optimized build.
void require(bool valid) nothrow @nogc
{
    if (!valid)
        assert(0, "TUI rendering probe invariant failed");
}

private struct Totals
{
    ulong hash = 14_695_981_039_346_656_037UL;
    ulong emitted;
    size_t updateBytes;

    Error observe(scope const(char)[] bytes) nothrow @nogc
    {
        foreach (ch; bytes)
            hash = (hash ^ cast(ubyte) ch) * 1_099_511_628_211UL;
        emitted += bytes.length;
        updateBytes += bytes.length;
        return Error.init;
    }
}

private struct Statistics
{
    Totals output;
    long totalNanos;
    long median;
    long p99;
    ulong allocated;
}

private Statistics run(Size size, Setup setup)
{
    Statistics result;
    auto paint = setup(size);
    Model model;
    paint(model, &result.output.observe);
    const before = GC.stats().allocatedInCurrentThread;
    long[transitions] samples;
    Event next;
    next.kind = EventKind.key;
    next.key.code = KeyCode.character;
    foreach (ref latency; samples)
    {
        result.output.updateBytes = 0;
        const started = MonoTime.currTime;
        model.update(next);
        paint(model, &result.output.observe);
        latency = (MonoTime.currTime - started).total!"nsecs";
        result.totalNanos += latency;
        require(result.output.updateBytes > 0 && result.output.updateBytes < 64);
    }
    result.allocated = GC.stats().allocatedInCurrentThread - before;
    samples[].sort();
    result.median = samples[transitions / 2];
    result.p99 = samples[transitions * 99 / 100];
    return result;
}

/// Exercise both dimensions and optionally accumulate at least 100 ms per measurement group.
void benchmark(bool measure, Setup setup)
{
    foreach (size; [Size(80, 24), Size(200, 60)])
    {
        uint repeats;
        long duration;
        Statistics result;
        do
        {
            result = run(size, setup);
            duration += result.totalNanos;
            ++repeats;
        }
        while (measure && duration < 100_000_000);
        writeln("tui ", size.columns, "x", size.rows, " transitions=", transitions, " bytes=",
                result.output.emitted, " checksum=", result.output.hash);
        if (measure)
            writeln("tui p50_ns=", result.median, " p99_ns=", result.p99, " samples=", repeats,
                    " elapsed_ns=", duration, " gc_bytes_per_10000_frames=", result.allocated);
    }
}
