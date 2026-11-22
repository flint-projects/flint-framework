/// Same verified payloads and timing for the Flint and direct-provider Kafka probes.
module workload;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.stdc.stdlib : qsort;
import flint.conc : Deadline;

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
    sortTimings(timings[]);
    const p99 = timings[$ - (iterations / 100) - 1];
    if (duration < 100_000_000)
        return false;
    report(partitions, bytes, p99, duration, checksum, allocated);
    return true;
}

// SAFETY: qsort passes this comparator two element addresses inside the slice given to sortTimings.
private extern (C) int compareTimings(const void* left, const void* right) @trusted nothrow @nogc
{
    const first = *cast(const(long)*) left;
    const second = *cast(const(long)*) right;
    return (first > second) - (first < second);
}

// SAFETY: The base pointer, element count and element size describe exactly the live slice.
private void sortTimings(scope long[] timings) @trusted nothrow @nogc
{
    qsort(timings.ptr, timings.length, long.sizeof, &compareTimings);
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
// The rate is the same integer records-per-second quotient as before formatting.
private void report(uint partitions, size_t bytes, long p99, long duration, ulong checksum, ulong allocated) @trusted
{
    printf("partitions=%u payload_bytes=%zu records=%d p99_ns=%lld elapsed_ns=%lld records_per_second=%llu "
            ~ "checksum=%llu owner_gc_bytes=%llu\n", partitions,
            bytes, iterations, p99, duration, (iterations * 1_000_000_000UL) / duration, checksum, allocated);
}

private long now() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}
