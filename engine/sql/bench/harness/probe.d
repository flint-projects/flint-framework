module probe;

import core.stdc.stdio : printf;
import core.time : MonoTime;

@safe:

/// Workload inserts and fetches this many signed 64-bit values.
enum rows = 256;
/// Shared schema for the disposable session-local table.
enum schema = "CREATE TEMP TABLE flint_probe (id bigint primary key)";
/// Expected sum of the inserted values.
enum expected = (cast(ulong) rows * (rows + 1)) / 2;

/// Run assertions that stay enabled under the release profile.
void require(bool condition) nothrow @nogc
{
    if (!condition)
        assert(0, "SQL probe invariant failed");
}

/// Timestamp for independent wait and driver timing.
long nanos() nothrow @nogc
{
    return (MonoTime.currTime - MonoTime.init).total!"nsecs";
}

/// Run an isolated workload, returning its result and two duration measurements.
alias Trial = ulong delegate(out long queue, out long driver) @safe;

private struct Timing
{
    long queue;
    long driver;
}

/// Repeat complete measured trials until each driver sample group spans at least 100 ms.
void measureTrial(scope Trial trial, bool measure)
{
    long queueTotal;
    long driverTotal;
    uint samples;
    ulong checksum;
    do
    {
        Timing sample;
        checksum = trial(sample.queue, sample.driver);
        require(checksum == expected && sample.queue >= 0 && sample.driver > 0);
        queueTotal += sample.queue;
        driverTotal += sample.driver;
        ++samples;
    }
    while (measure && driverTotal < 100_000_000);
    report(checksum, queueTotal, driverTotal, samples, measure);
}

// SAFETY: The fixed C format strings are NUL-terminated with matching scalar arguments.
private void report(ulong actual, long queue, long driver, uint samples, bool measure) @trusted nothrow @nogc
{
    printf("sql checksum %llu\n", actual);
    if (measure)
        printf("sql queue_ns=%lld driver_ns=%lld rows_per_trial=%u trials=%u\n", queue, driver, rows, samples);
}
