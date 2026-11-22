module bridge_probe;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime;

@safe:

/// Bounded callback that writes one complete FLNT workload and returns an observed checksum.
alias EncodeBatch = uint delegate(uint count) @safe nothrow @nogc;

/// Shared checksum over validated command lengths, first and last text bytes.
uint observe(scope const(ubyte)[] data, uint count) pure nothrow @nogc
{
    if (data.length != 32 + count * 24 || data[0] != 'F' || data[12] != (count & 255)
            || data[13] != (count >> 8) || data[48] != 2 || data[$ - 4] != '4' || data[$ - 3] != '2')
        return 0;
    return count + data[52] + data[$ - 3];
}

/// Measure complete groups for each required guest frame size.
bool measure(scope EncodeBatch encode)
{
    foreach (count; [1U, 100U, 4096U])
    {
        const before = GC.stats.allocatedInCurrentThread;
        const began = MonoTime.currTime;
        uint rounds;
        ulong checksum;
        do
        {
            const value = encode(count);
            if (value != count + '4' + '2')
                return false;
            checksum += value;
            ++rounds;
        }
        while ((MonoTime.currTime - began).total!"msecs" < 150);
        const elapsed = (MonoTime.currTime - began).total!"nsecs";
        if (GC.stats.allocatedInCurrentThread != before)
            return false;
        report(count, rounds, elapsed, checksum);
    }
    return true;
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(uint count, uint rounds, long elapsed, ulong checksum) @trusted nothrow @nogc
{
    printf("commands=%u rounds=%u elapsed_ns=%lld gc_bytes=0 checksum=%llu\n", count, rounds, elapsed, checksum);
}
