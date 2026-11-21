/// Shared checked Redis round trips over the fixture's verified TLS connection.
module redis_workload;

import core.memory : GC;
import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr, writefln;

@safe:

/// A hit whose bytes were checked against the inserted value, followed by a checked eviction and miss.
struct Observation
{
    /// Whether all four cache operations produced the expected result.
    bool ok;
    /// Sum of the actual bytes returned from Redis.
    ulong checksum;
}

/// Run SET, GET, DEL and a second GET on a fixed binary key.
alias Cycle = Observation delegate(scope const(ubyte)[] key, scope const(ubyte)[] value) @safe nothrow @nogc;

private enum rounds = 1_024;
private static immutable sizes = [64, 4_096];

/// Retrieve an input from the ephemeral local Redis fixture.
string fixture(string name)
{
    const value = environment.get("FLINT_CACHE_REDIS_" ~ name, "");
    return enforce(value, "local Redis benchmark fixture is required");
}

/// Validate the native workload and report observed cycle latency and D GC bytes.
int run(scope Cycle cycle)
{
    ulong checksum;
    foreach (length; sizes)
    {
        ubyte[4096] payload;
        foreach (i, ref item; payload[0 .. length])
            item = cast(ubyte)((i * 29 + length) % 251);
        const ubyte[5] key = ['r', 'b', 0, cast(ubyte)(length >> 8), cast(ubyte) length];
        const expected = payload[0 .. length];
        enforce(cycle(key[], expected).ok, "Redis warm-up operation failed");
        long[rounds] durations;
        const before = GC.stats().allocatedInCurrentThread;
        const started = MonoTime.currTime;
        const observation = sample(cycle, key[], expected, durations[]);
        const elapsed = (MonoTime.currTime - started).total!"nsecs";
        const allocated = GC.stats().allocatedInCurrentThread - before;
        enforce(observation.ok && elapsed >= 100_000_000L, "Redis streaming timing sample failed");
        enforce(allocated == 0, "Redis round trips allocated D GC memory");
        sort(durations[]);
        checksum += observation.checksum;
        report(length, elapsed, durations[(rounds * 99 + 99) / 100 - 1], allocated);
    }
    writefln("redis-round-trips %s", checksum);
    return 0;
}

private Observation sample(scope Cycle cycle, scope const(ubyte)[] key, scope const(ubyte)[] value,
        scope long[] durations) nothrow @nogc
{
    ulong checksum;
    foreach (ref elapsed; durations)
    {
        const started = MonoTime.currTime;
        const result = cycle(key, value);
        elapsed = (MonoTime.currTime - started).total!"nsecs";
        if (!result.ok)
            return Observation.init;
        checksum += result.checksum;
    }
    return Observation(true, checksum);
}

// SAFETY: Phobos exposes a synchronized process file. Only scalar metrics are formatted.
private void report(int bytes, long elapsed, long p99, ulong allocated) @trusted
{
    stderr.writefln("bytes %s cycles %s elapsed_ns %s p99_ns %s d_gc_bytes %s", bytes, rounds,
            elapsed, p99, allocated);
}
