/// Fixed setup, correctness checks, counters and timing shared by both DI probes.
module di_probe_harness;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.arena : RequestArena, Status;

@safe:

/// Failed correctness check sentinel.
enum ulong failed = ulong.max;

/// Changing data supplied to each startup trial.
struct Settings
{
    /// Value carried from the configured root into dependent beans.
    uint nonce;
    /// Sum of the ordinals of initialized beans.
    uint initialized;
}

/// Shared constructor work executed for every startup bean.
uint initializeWorker(ref Settings settings, uint ordinal) nothrow @nogc
{
    settings.initialized += ordinal;
    return settings.nonce + ordinal;
}

/// A real singleton with an explicit dependency on the configured root.
struct Worker(uint ordinal)
{
    /// An observed constructor result.
    uint value;

    /// Capture the supplied settings value.
    this(ref Settings settings) nothrow @nogc
    {
        value = initializeWorker(settings, ordinal);
    }
}

/// The runtime dispatch targets share the same result contract.
interface Reader
{
    /// Return the configured value and a changing input.
    uint read(uint input) nothrow @nogc;
}

/// A concrete value also exposed through the Reader contract.
final class Counter : Reader
{
    /// Configuration inspected by both operations.
    uint value;

    /// Read through an interface reference.
    override uint read(uint input) nothrow @nogc
    {
        return value + input;
    }
}

/// Timed operation that receives a varying input for each iteration.
alias Operation = ulong delegate(uint) @safe;

/// Run the fixed shared arena setup and verify its copied byte checksum.
bool checkArena() nothrow @nogc
{
    align(8) ubyte[256] backing;
    scope arena = RequestArena(backing[]);
    auto copied = arena.copyIn(cast(const(ubyte)[]) "di");
    if (!copied.ok())
        return false;

    uint checksum;
    const result = arena.read(copied.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        foreach (value; bytes)
            checksum += value;
    });
    return result == Status.ok && checksum == 205 && arena.reset() == Status.ok;
}

/// Keep the interface call at a separate, typed call site in both probes.
pragma(inline, false) uint invoke(Reader reader, uint input) nothrow @nogc
{
    return reader.read(input);
}

// SAFETY: The fixed format bounds reads to the checked length of the scoped name.
private void reportAllocation(scope string name, ulong allocated) @trusted
{
    if (name.length != 0 && name.length <= int.max)
        printf("%.*s startup_allocated_bytes=%llu\n", cast(int) name.length, name.ptr, allocated);
}

// SAFETY: The fixed format bounds reads to the checked length of the scoped name.
private void reportTime(scope string name, ulong iterations, long elapsed, ulong checksum, uint check) @trusted
{
    if (name.length != 0 && name.length <= int.max)
        printf("%.*s operations=%llu elapsed_ns=%lld ns_per_op=%.3f checksum=%llu check_value=%u\n",
                cast(int) name.length, name.ptr, iterations, elapsed,
                cast(double) elapsed / iterations, checksum, check);
}

/// Run exactly one warmed sample of startup GC bytes, then time verified operations.
pragma(inline, false) bool measure(string name, uint fixedValue, bool startup, scope Operation operation)
{
    enum uint sampleInput = 21;
    if (operation(sampleInput) != fixedValue + sampleInput)
        return false;

    if (startup)
    {
        const before = GC.stats().allocatedInCurrentThread;
        const sample = operation(sampleInput);
        const after = GC.stats().allocatedInCurrentThread;
        if (sample != fixedValue + sampleInput || after < before)
            return false;
        reportAllocation(name, after - before);
    }

    ulong iterations;
    ulong checksum;
    long elapsed;
    const start = MonoTime.currTime;
    do
    {
        foreach (index; 0 .. 128)
        {
            const input = cast(uint)((iterations + index) % 251);
            const value = operation(input);
            if (value != fixedValue + input)
                return false;
            checksum += value;
        }
        iterations += 128;
        elapsed = (MonoTime.currTime - start).total!"nsecs";
    }
    while (elapsed < 150_000_000);

    reportTime(name, iterations, elapsed, checksum, fixedValue + sampleInput);
    return true;
}
