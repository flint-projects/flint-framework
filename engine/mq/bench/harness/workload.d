/// Same verified payloads and timing for the Flint and direct-provider Kafka probes.
module workload;

import core.memory : GC;
import flint.conc : Deadline;
import std.algorithm.sorting : sort;
import std.stdio : writeln;

@safe:

alias Operation = bool delegate(string topic, scope const(ubyte)[] key, scope const(ubyte)[] payload);

private enum iterations = 512;

/// Run each required payload size and partition count.
int measure(scope Operation deliver)
{
    immutable string[2] topics = ["flint-bench-1", "flint-bench-16"];
    uint[2] partitions = [1, 16];
    foreach (index, topic; topics)
    {
        foreach (bytes; [256, 8 * 1024])
            if (!sample(deliver, topic, partitions[index], bytes))
                return 1;
    }
    return 0;
}

private bool sample(scope Operation deliver, string topic, uint partitions, size_t bytes)
{
    ubyte[8192] payload;
    foreach (index, ref value; payload)
        value = cast(ubyte)(index * 31 + 13);
    long[iterations] timings;
    ulong checksum;
    const gcBytes = GC.stats().allocatedInCurrentThread;
    const before = now();
    foreach (index, ref elapsed; timings)
    {
        const ubyte[4] key = [cast(ubyte)(index >> 8), cast(ubyte) index, 33, 91];
        const started = now();
        if (!deliver(topic, key[], payload[0 .. bytes]))
            return false;
        elapsed = now() - started;
        checksum += bytes + key[0] + key[1] + payload[index % bytes];
    }
    const duration = now() - before;
    const allocated = GC.stats().allocatedInCurrentThread - gcBytes;
    auto ordered = sort(timings[]);
    const p99 = ordered[$ - (iterations / 100) - 1];
    if (duration < 100_000_000)
        return false;
    writeln("partitions=", partitions, " payload_bytes=", bytes, " records=", iterations, " p99_ns=", p99,
            " elapsed_ns=", duration, " records_per_second=", (iterations * 1_000_000_000UL) / duration,
            " checksum=", checksum, " owner_gc_bytes=", allocated);
    return true;
}

private long now() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}
