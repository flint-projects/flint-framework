/// Shared transition inputs and independently consumed terminal output.
module tui_probe;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.stdc.stdlib : qsort;
import core.time : MonoTime;
import flint.arena : Error;
import flint.term : Event, EventKind, KeyCode, Size;

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

// SAFETY: qsort passes this comparator two element addresses inside the slice given to sortSamples.
private extern (C) int compareSamples(const void* left, const void* right) @trusted nothrow @nogc
{
    const first = *cast(const(long)*) left;
    const second = *cast(const(long)*) right;
    return (first > second) - (first < second);
}

// SAFETY: The base pointer, element count and element size describe exactly the live slice.
private void sortSamples(scope long[] samples) @trusted nothrow @nogc
{
    qsort(samples.ptr, samples.length, long.sizeof, &compareSamples);
}

// SAFETY: Each C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(Size size, ref const Statistics result, bool measure, uint repeats, long duration) @trusted
{
    printf("tui %ux%u transitions=%d bytes=%llu checksum=%llu\n", size.columns, size.rows,
            transitions, result.output.emitted, result.output.hash);
    if (measure)
        printf("tui p50_ns=%lld p99_ns=%lld samples=%u elapsed_ns=%lld gc_bytes_per_10000_frames=%llu\n",
                result.median, result.p99, repeats, duration, result.allocated);
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
    sortSamples(samples[]);
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
        report(size, result, measure, repeats, duration);
    }
}
