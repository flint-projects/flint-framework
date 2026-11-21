/// Fixed, shared HTTPS workload for feature and provider reference.
module http_workload;

import core.memory : GC;
import core.time : MonoTime;
import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr, writefln;

@safe:

/// Two entity sizes over the same warm verified connection.
static immutable payloadSizes = [1024, 65_536];

private enum transfers = 2_048;

/// A checked payload visitor.
alias ObserveBytes = void delegate(scope const(ubyte)[] bytes) @safe nothrow @nogc;
/// A complete HTTPS streaming request for a configured workload size.
alias Fetch = bool delegate(size_t index, scope ObserveBytes observe) @safe nothrow @nogc;

/// Read the external test peer and create fixed resource URLs before measuring.
void configure(out string[2] urls, out string ca)
{
    const origin = environment.get("FLINT_HTTP_HTTPS", "");
    ca = environment.get("FLINT_HTTP_CA", "");
    enforce(origin.length != 0 && ca.length != 0, "HTTPS workload requires the local protocol fixture");
    urls = [origin ~ "/bench?n=1024", origin ~ "/bench?n=65536"];
}

/// Check every entity byte, count hot D allocations and consume the fixed result.
int run(scope Fetch fetch)
{
    ulong checksum;
    foreach (index, expected; payloadSizes)
    {
        enforce(sample(fetch, index, expected, 1).ok, "HTTPS warm-up failed");
        const before = GC.stats().allocatedInCurrentThread;
        const started = MonoTime.currTime;
        const observed = sample(fetch, index, expected, transfers);
        const elapsed = (MonoTime.currTime - started).total!"nsecs";
        const allocated = GC.stats().allocatedInCurrentThread - before;
        enforce(observed.ok, "HTTPS streaming workload generated incorrect data");
        enforce(allocated == 0, "HTTPS streaming workload allocated on the D GC");
        enforce(elapsed >= 100_000_000, "HTTPS workload lasted less than 100 milliseconds");
        checksum ^= observed.checksum << index;
        report(expected, elapsed, allocated);
    }
    writefln("http-stream %s", checksum);
    return 0;
}

private struct Sample
{
    bool ok;
    ulong checksum;
}

private Sample sample(scope Fetch fetch, size_t index, size_t expected, size_t count) nothrow @nogc
{
    ulong checksum;
    foreach (request; 0 .. count)
    {
        size_t offset;
        bool correct = true;
        const succeeded = fetch(index, (scope const(ubyte)[] bytes) {
            foreach (value; bytes)
            {
                const predicted = cast(ubyte)((offset * 17 + offset / 11) % 251);
                correct &= value == predicted;
                ++offset;
                checksum += value;
            }
        });
        if (!succeeded || !correct || offset != expected)
            return Sample.init;
    }
    return Sample(true, checksum);
}

// SAFETY: Phobos exposes the process standard error as a synchronized file. This call
// formats only scalar observations after measurement and retains no caller ranges.
private void report(size_t bytes, long elapsed, ulong allocated) @trusted
{
    stderr.writefln("bytes %s transfers %s elapsed_ns %s d_gc_bytes %s", bytes, transfers, elapsed, allocated);
}
