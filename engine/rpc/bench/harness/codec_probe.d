/// Workload and correctness accounting shared by both Protobuf probes.
module codec_probe;

import ffi.alloc_counter : beginCount, endCount;

import sys.allocation : gcBytes;
import core.time : MonoTime;
import std.stdio : writefln;

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
        writefln("bytes=%s count=%s checksum=%s success_checksum=%s elapsed_ns=%s d_gc_bytes=%s",
                size, iterations, checksum, want, elapsed, gc);
        if (cCalls != ulong.max)
            writefln("native_allocation_calls=%s", cCalls);
    }
    return 0;
}
