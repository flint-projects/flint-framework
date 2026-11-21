/// Shared checked fixture and cached JWS verification samples.
module security_workload;

import core.atomic : atomicLoad, atomicOp;
import core.memory : GC;
import core.time : MonoTime;
import flint.arena : RequestArena, Status, Text;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr, writefln;

@safe:

/// Verify one already-prepared signed input and return its verified claim checksum.
alias Check = ulong delegate() @safe nothrow @nogc;

/// Number of measured verifications per supported benchmark algorithm.
enum rounds = 10_000;

/// Read an ephemeral loopback fixture setting without printing it.
string fixture(string name)
{
    return enforce(environment.get("FLINT_SECURITY_" ~ name, ""), "local security fixture is required");
}

/// Derive the observable checksum from the verified subject and expiry.
ulong claimsChecksum(ref scope RequestArena arena, Text subject, long expiry) nothrow @nogc
{
    bool expected;
    ulong sum;
    const used = arena.read(subject.bytes, (scope const(ubyte)[] bytes) {
        expected = bytes == cast(const(ubyte)[]) "atlas";
        foreach (item; bytes)
            sum += item;
    });
    return used == Status.ok && expected && expiry == 1000 ? sum + expiry : 0;
}

/// Sample a warmed key, verify every result, and record provider and D allocator activity.
ulong measure(string algorithm, scope Check check)
{
    foreach (warmup; 0 .. 2)
        enforce(check() != 0, "security benchmark warm-up failed");
    long[rounds] durations;
    const gcBefore = GC.stats().allocatedInCurrentThread;
    const nativeBefore = atomicLoad(allocations);
    const started = MonoTime.currTime;
    const checksum = sample(check, durations[]);
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    const allocated = GC.stats().allocatedInCurrentThread - gcBefore;
    const native = atomicLoad(allocations) - nativeBefore;
    enforce(checksum && elapsed >= 100_000_000 && allocated == 0 && native > 0,
            "security benchmark sample, timed workload or allocation check failed");
    sort(durations[]);
    report(algorithm, elapsed, durations[rounds / 2], durations[rounds * 99 / 100 - 1], allocated, native);
    return checksum;
}

private ulong sample(scope Check check, scope long[] durations) nothrow @nogc
{
    ulong checksum;
    foreach (ref spent; durations)
    {
        const begin = MonoTime.currTime;
        const current = check();
        spent = (MonoTime.currTime - begin).total!"nsecs";
        if (!current)
            return 0;
        checksum += current;
    }
    return checksum;
}

/// Print one release-checked scalar derived from all actual verification results.
void finish(ulong checksum)
{
    enforce(checksum == 30_660_000, "security verification checksum mismatch");
    writefln("cached-jws %s", checksum);
}

// SAFETY: Output contains only static algorithm names and measured counts. No fixture data is printed.
private void report(string name, long elapsed, long median, long p99, ulong gc, ulong native) @trusted nothrow
{
    try
    {
        stderr.writefln("%s count %s elapsed_ns %s median_ns %s p99_ns %s d_gc_bytes %s native_heap_allocations %s",
                name, rounds, elapsed, median, p99, gc, native);
    }
    catch (Exception)
    {
        // Metrics are observational and cannot affect verification results.
    }
}

private shared ulong allocations;

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "__real_malloc") void* nativeMalloc(size_t size);
    pragma(mangle, "__real_calloc") void* nativeCalloc(size_t count, size_t size);
    pragma(mangle, "__real_realloc") void* nativeRealloc(void* pointer, size_t size);

    // Called only through the real C allocator ABI. No D object or callback escapes.
    pragma(mangle, "__wrap_malloc") void* countMalloc(size_t size)
    {
        atomicOp!"+="(allocations, 1);
        return nativeMalloc(size);
    }

    pragma(mangle, "__wrap_calloc") void* countCalloc(size_t count, size_t size)
    {
        atomicOp!"+="(allocations, 1);
        return nativeCalloc(count, size);
    }

    pragma(mangle, "__wrap_realloc") void* countRealloc(void* pointer, size_t size)
    {
        atomicOp!"+="(allocations, 1);
        return nativeRealloc(pointer, size);
    }
}
