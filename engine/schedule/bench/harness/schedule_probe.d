module schedule_probe;

import core.stdc.stdio : printf;
import core.time : MonoTime;

@safe:

/// Maximum number of simultaneously enrolled jobs.
enum batchSize = 1_024U;
/// Number of jobs to enroll during each trial.
enum jobsPerTrial = 100_000U;

/// Observable callbacks and the consumed trial checksum.
struct Outcome
{
    /// Callbacks observed after the cancellation schedule.
    ulong calls;
    /// Rolling digest of callback invocations.
    ulong checksum = 0x49e2aa6d3c56ef09UL;

    /// Record one callback result.
    void invoke() pure nothrow @nogc
    {
        ++calls;
        checksum = (checksum ^ calls) * 1_099_511_628_211UL;
    }
}

/// Whether the shared input cancels this job before its first callback.
bool cancelled(uint index) pure nothrow @nogc
{
    return index % 3 == 0;
}

/// Find the size of the next workload batch.
uint nextBatch(uint completed) pure nothrow @nogc
{
    const remaining = jobsPerTrial - completed;
    return remaining < batchSize ? remaining : batchSize;
}

/// Verify each trial and report elapsed time and the common digest.
int show(Outcome delegate() @safe load)
{
    const begin = MonoTime.currTime;
    ulong trials;
    /// Rolling digest of callback invocations.
    ulong checksum;
    do
    {
        const result = load();
        if (result.calls != 66_602)
            return 2;
        if (trials != 0 && checksum != result.checksum)
            return 3;
        checksum = result.checksum;
        ++trials;
    }
    while ((MonoTime.currTime - begin).total!"msecs" < 150);
    const elapsed = (MonoTime.currTime - begin).total!"nsecs";
    report(jobsPerTrial * trials, elapsed, checksum);
    return 0;
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void report(ulong jobs, long elapsed, ulong checksum) @trusted nothrow @nogc
{
    printf("jobs=%llu elapsed_ns=%lld checksum=%llu\n", jobs, elapsed, checksum);
}
