/// Shared checked fixture and cached JWS verification samples.
module security_workload;

import core.atomic : atomicLoad, atomicOp;
import core.memory : GC;
import core.stdc.stdio : fprintf, printf, stderr;
import core.stdc.stdlib : getenv, qsort;
import core.stdc.string : strlen;
import core.time : MonoTime;
import flint.arena : RequestArena, Status, Text;
import std.exception : enforce;

@safe:

/// Verify one already-prepared signed input and return its verified claim checksum.
alias Check = ulong delegate() @safe nothrow @nogc;

/// Number of measured verifications per supported benchmark algorithm.
enum rounds = 10_000;

/// Read an ephemeral loopback fixture setting without printing it.
string fixture(string name)
{
    return enforce(variable("FLINT_SECURITY_" ~ name), "local security fixture is required");
}

// SAFETY: The name is copied with a terminating NUL; getenv returns null or a NUL-terminated
// environment string that is copied before returning. An unset name yields the empty literal.
private string variable(string name) @trusted
{
    const value = getenv((name ~ '\0').ptr);
    return value is null ? "" : value[0 .. strlen(value)].idup;
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
    sortDurations(durations[]);
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
    printChecksum(checksum);
}

// SAFETY: The C format string is a fixed NUL-terminated literal with a matching scalar argument.
private void printChecksum(ulong checksum) @trusted nothrow @nogc
{
    printf("cached-jws %llu\n", checksum);
}

// SAFETY: qsort passes this comparator two element addresses inside the slice given to sortDurations.
private extern (C) int compareDurations(const void* left, const void* right) @trusted nothrow @nogc
{
    const first = *cast(const(long)*) left;
    const second = *cast(const(long)*) right;
    return (first > second) - (first < second);
}

// SAFETY: The base pointer, element count and element size describe exactly the live slice.
private void sortDurations(scope long[] durations) @trusted nothrow @nogc
{
    qsort(durations.ptr, durations.length, long.sizeof, &compareDurations);
}

// SAFETY: Output contains only static algorithm names, printed with their explicit length, and
// measured counts matching a fixed NUL-terminated literal format. No fixture data is printed.
private void report(string name, long elapsed, long median, long p99, ulong gc, ulong native) @trusted nothrow @nogc
{
    fprintf(stderr,
            "%.*s count %d elapsed_ns %lld median_ns %lld p99_ns %lld d_gc_bytes %llu native_heap_allocations %llu\n",
            cast(int) name.length, name.ptr, rounds, elapsed, median, p99, gc, native);
}

private shared ulong allocations;

version (OSX)
{
    // Apple's linker has no --wrap. libSystem calls malloc_logger, the hook Instruments uses, once
    // for every allocation, reallocation and free in the process; allocations and reallocations
    // carry MALLOC_LOG_TYPE_ALLOCATE (ADR-024).
    private alias MallocLogger = extern (C) void function(uint type, size_t zone, size_t size,
            size_t pointer, size_t result, uint skippedFrames) @system nothrow @nogc;
    private extern (C) extern __gshared MallocLogger malloc_logger;

    private extern (C) void countAllocation(uint type, size_t, size_t, size_t, size_t, uint) @system nothrow @nogc
    {
        enum allocate = 2; // MALLOC_LOG_TYPE_ALLOCATE
        if (type & allocate)
            atomicOp!"+="(allocations, 1);
    }

    // SAFETY: Installs a counter that touches only one shared atomic and retains no pointer.
    shared static this() @trusted
    {
        malloc_logger = &countAllocation;
    }
}
else
{
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
}
