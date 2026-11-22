/// Workload and correctness accounting shared by both Protobuf probes.
module codec_probe;

import ffi.alloc_counter : beginCount, endCount;

import sys.allocation : gcBytes;
import core.stdc.stdio : printf;
import core.time : MonoTime;

@safe:

/// Consume one independently encoded and decoded payload. Zero means a failed run.
alias Trial = ulong function(uint payloadBytes) @safe nothrow @nogc;

private enum sampleNanos = 150_000_000;

private ulong expected(uint payloadBytes) pure nothrow @nogc
{
    const sizeField = payloadBytes < 16_384 ? 2 : 3;
    const encoded = payloadBytes + sizeField + 5;
    const last = ((payloadBytes - 1) * 17 + 3) & 255;
    return encoded + 17 * 3 + 31 * last + 43;
}

/// Check every reply, then time equally shaped 128-byte and 64-KiB operations.
int runProbe(Trial trial)
{
    foreach (size; [128U, 65_536U])
    {
        const want = expected(size);
        if (trial(size) != want)
            return 1;
        const before = gcBytes();
        beginCount();
        const started = MonoTime.currTime;
        uint iterations;
        ulong checksum;
        long elapsed;
        do
        {
            const observed = trial(size);
            if (observed != want)
                return 2;
            checksum += observed;
            ++iterations;
            elapsed = (MonoTime.currTime - started).total!"nsecs";
        }
        while (elapsed < sampleNanos);
        const cCalls = endCount();
        const gc = gcBytes() - before;
        report(size, iterations, checksum, want, elapsed, gc, cCalls);
    }
    return 0;
}

// SAFETY: Each C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(uint size, uint count, ulong checksum, ulong want, long elapsed, ulong gc, ulong calls) @trusted
{
    printf("bytes=%u count=%u checksum=%llu success_checksum=%llu elapsed_ns=%lld d_gc_bytes=%llu\n",
            size, count, checksum, want, elapsed, gc);
    if (calls != ulong.max)
        printf("native_allocation_calls=%llu\n", calls);
}
